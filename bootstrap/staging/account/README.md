# Account Substack

## Overview

The `account` substack at `bootstrap/staging/account` provisions the **GitHub OIDC execution plane** for the `staging` AWS account.

Implementation reference: `v1.11.0-rc1` (`728166fa17bf42fe06bf540729c6aba1e70e05d5`). This is an account-specific reference, not a workload deployment root.

It deploys:

- GitHub OIDC provider and `GitHub-Plan` role when `enable_github_oidc = true`
- Optional `GitHub-Apply` role when both OIDC and Apply are enabled
- Optional `GitHub-Image-Publisher` role
- Supporting IAM policies for Terraform state access and CI/CD operations

This stack is intentionally separated from workload and governance resource states so their normal lifecycle does not include the CI/CD roles. That separation is not a permissions boundary and does not prevent an explicit change or destroy against this account root.

---

## Why This Exists

Without this separation, a Terraform apply or destroy workflow could remove the IAM roles required to continue running the workflow.

That can result in:

- Failed applies
- Failed destroys
- Broken GitHub Actions authentication
- Terraform state inconsistencies
- CI/CD pipelines that can no longer assume AWS roles

This stack addresses that dependency by keeping CI/CD execution resources in a separate Terraform graph and state. Keep independent administrative access available before changing the roles or their trust.

---

## Architecture

```text
GitHub Actions
    |
    | OIDC token
    v
AWS IAM OIDC Provider
    |
    | sts:AssumeRoleWithWebIdentity
    v
GitHub-Plan / GitHub-Apply / Image-Publisher IAM Roles
    |
    | Role-specific Terraform or ECR permissions
    v
Target Terraform Stack or ECR Repositories
```

The roles created by this stack are used by GitHub Actions to run Terraform workflows without long-lived AWS credentials.

### Role Responsibilities

#### `GitHub-Plan` Role

Used by supported Terraform Plan and evidence workflows; the attached policy is broader than read-only inspection.

Typical responsibilities:

- Read Terraform state
- Acquire Terraform state locks
- Read AWS resources needed for planning
- Generate Terraform execution plans

#### `GitHub-Apply` Role

Intended for approved write operations. The shared module attaches `AdministratorAccess`; do not infer narrow resource authority from the role name.

Typical responsibilities:

- Read and write Terraform state
- Acquire and release Terraform state locks
- Create, update, and destroy AWS resources
- Access required KMS keys for encrypted Terraform-managed resources

#### `GitHub-Image-Publisher` Role

Intended for the `Deploy Application` workflow's AWS publication job. IAM trust selects approved branch subjects, not a specific workflow filename.

- Trusts explicitly configured repository branches through GitHub OIDC
- Obtains ECR authorization and publishes/queries images in repositories matching the workload name prefix
- Has no broad Terraform state, ECS, IAM, or administration authority
- Is separate from the release/PR job, which has GitHub write permissions but no AWS credentials or OIDC token

---

### Trust subjects and actual permissions

The shared [OIDC module](../../../modules/github_oidc/README.md) constructs these subjects:

| Role | Subject used in IAM trust | Configuration boundary |
|---|---|---|
| Plan | `repo:<owner>/<repo>:environment:<environment>-plan` | `StringLike`; the legacy Plan branch/PR inputs do not change this subject. |
| Apply | `repo:<owner>/<repo>:environment:<environment_apply_github>` when non-null; otherwise configured `ref:refs/heads/<branch>` subjects | The environment replaces the branch-subject list; it is not an additional AND condition. |
| Image Publisher | Configured `repo:<owner>/<repo>:ref:refs/heads/<branch>` subjects | `StringEquals`; only exposed by the workload account roots. |

All three roles require the `sts.amazonaws.com` audience and the account's GitHub OIDC provider. Use literal repository/environment names; Plan/Apply use `StringLike`, not the publisher's exact-subject operator. These policies do not select a particular workflow filename.

Configure deployment-branch restrictions and required reviewers in GitHub separately. This AWS Terraform stack does not create those GitHub controls. A job declaring a GitHub Environment is not proof that reviewers or branch restrictions have been configured.

**Plan is not an IAM read-only role.** It attaches AWS-managed `ReadOnlyAccess` plus a custom policy granting `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` over **all objects** in the configured state bucket, not just `.tflock` files. It also grants prefix-scoped `secretsmanager:GetSecretValue`, `secretsmanager:GetRandomPassword`, and conditional KMS actions. Separate state keys are not an IAM isolation boundary for this role.

**Apply attaches AWS-managed `AdministratorAccess`.** Its custom state/secret/KMS policy is additional permission, not an effective least-privilege ceiling. The repository's reviewed-plan workflow and account separation must not be described as an IAM restriction to the resources in that plan. Neither role defines a permissions boundary here.

---

## Deployment Order

### Initial Setup

1. Deploy the workload state stack and complete its S3 backend migration.
2. Apply this account stack with GitHub OIDC enabled. Record `plan_role_github_arn`, `apply_role_github_arn`, and, when enabled, `image_publisher_role_github_arn`.
3. Configure the matching GitHub Plan/Apply environments. Store the image publisher ARN as `IMAGE_PUBLISHER_ROLE_GITHUB_ARN` in `<env>-plan`, together with `BRANCHES_IMAGE_PUBLISHER_GITHUB`.
4. Include the Apply role in the appropriate `bucket_admin_principals` configuration before the workload stack must manage protected bucket controls.
5. Deploy `environments/<env>` locally or through the plan-first `Terraform Apply` workflow.
6. Reconcile the account stack after workload deployment with `scripts/bootstrap/reconcile-workload-account.sh <env>` or the `Reconcile Workload Account` workflow. Reconciliation resolves the current workload Lambda/Secrets Manager CMKs and preserves the enabled Image Publisher role and branch allowlist.

Prefer reconciliation over manually copying workload-created CMK outputs back into this stack. The reconciliation workflow uses an exact saved account-stack plan and runs strict bootstrap validation after Apply. It still needs the correct account-root inputs: do not assume it recovers missing OIDC enablement, repository, or publisher branch settings automatically. Preserve the reviewed variable configuration when the workload is rebuilt and its CMKs change.

### Local account plan and apply

Run from the repository root with an authorized **local named profile**. Review the existing [backend.tf](backend.tf), complete [state bootstrap/migration](../state/README.md), and populate `bootstrap/staging/account/terraform.tfvars` from its example without overwriting an existing configuration. Confirm `environment = "staging"`, the intended `primary_region`, repository, enablement flags, and real state-bucket/CMK ARNs. Example account IDs and key IDs are not deployment values.

The account root pins Terraform **1.15.8** and AWS provider **6.66.0**. Retain its tracked lockfile; do not use an upgrade initialization as part of routine release documentation validation.

```bash
export AWS_PROFILE="staging"
export AWS_REGION="us-east-1" # Replace with this account stack's service Region.
export AWS_DEFAULT_REGION="$AWS_REGION"
export EXPECTED_ACCOUNT_ID="<EXPECTED-STAGING-ACCOUNT-ID>"

(
  set -euo pipefail
  umask 077
  [[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || {
    echo "Set the expected 12-digit account ID first." >&2
    exit 1
  }
  ACTUAL_ACCOUNT_ID="$(aws sts get-caller-identity \
    --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --query Account --output text)"
  [[ "$ACTUAL_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
    echo "Wrong AWS account; do not initialize or apply this stack." >&2
    exit 1
  }

  ACCOUNT_DIR="bootstrap/staging/account"
  PLAN_FILE="$PWD/${ACCOUNT_DIR}/account-reviewed.tfplan"
  [[ ! -e "$PLAN_FILE" ]] || {
    echo "A saved plan already exists; review it before creating another." >&2
    exit 1
  }
  terraform -chdir="$ACCOUNT_DIR" init -input=false
  terraform -chdir="$ACCOUNT_DIR" plan -out="$PLAN_FILE"
  terraform -chdir="$ACCOUNT_DIR" show -no-color "$PLAN_FILE"
)
```

This creates a local review artifact, not a GitHub approval or a checksum-verified workflow artifact. `AWS_REGION` does not override `primary_region` in an account root's Terraform variable files: confirm the resolved Terraform input and environment settings agree before approval. Stop on unexpected creation/deletion, a wrong backend, or a failed command.

Only after reviewing that exact plan, while the same authorized credential context and checkout remain selected:

```bash
terraform -chdir="bootstrap/staging/account" apply \
  "$PWD/bootstrap/staging/account/account-reviewed.tfplan"
```

Applying a saved plan is a mutating operation and does not ask for a second interactive approval. Do not add new `-var` overrides to the saved-plan apply. Keep plans out of source control and shared logs; securely retain or remove them after the approved operation according to the evidence policy. A changed state or configuration may require a newly reviewed plan.

## Usage

The following is the existing composition inside this root, not an additional module block to paste alongside it. `locals` and data sources are defined in [main.tf](main.tf).

```hcl
module "github_oidc" {
  source = "../../../modules/github_oidc"
  count  = var.enable_github_oidc ? 1 : 0

  cloud_name                      = var.cloud_name
  environment                     = var.environment
  owner_github                    = var.owner_github
  repo_github                     = var.repo_github
  branches_plan_github            = var.branches_plan_github
  allow_pull_requests_plan_github = var.allow_pull_requests_plan_github
  name_prefix                     = local.name_prefix

  tf_state_bucket_arn     = var.tf_state_bucket_arn
  tf_state_bucket_cmk_arn = var.tf_state_bucket_cmk_arn

  primary_region           = data.aws_region.current.region
  account_id               = data.aws_caller_identity.current.account_id
  enable_apply_role_github = var.enable_apply_role_github
  branches_apply_github    = var.branches_apply_github
  environment_apply_github = var.environment_apply_github

  enable_image_publisher_role_github = var.enable_image_publisher_role_github
  branches_image_publisher_github    = var.branches_image_publisher_github

  lambda_cmk_arn          = var.lambda_cmk_arn
  secrets_manager_cmk_arn = var.secrets_manager_cmk_arn
}
```

## Inputs

All defaults below are from this root's [variables.tf](variables.tf), not from the example variable file. `cloud_name`, `environment`, and `primary_region` are required even when OIDC is disabled.

| Name | Type | Default | Required | Behavior |
|---|---|---|---|---|
| `cloud_name` | `string` | none | Yes | Naming component; the root derives `name_prefix` as `${cloud_name}-${environment}`. |
| `environment` | `string` | none | Yes | Explicit logical environment; not inferred from the directory. Use `staging` for this root and its standard workflow trust. |
| `primary_region` | `string` | none | Yes | Account provider/service Region. Passed to the module from `data.aws_region.current.region` after a matching postcondition. |
| `enable_github_oidc` | `bool` | `false` | No | Controls the entire module instance. False omits the OIDC provider and all three roles; changing true to false can plan their deletion. |
| `owner_github` | `string` | `null` | When OIDC enabled | Repository owner. The root checks non-null when OIDC is enabled; operators must still supply the correct non-empty identity. |
| `repo_github` | `string` | `null` | When OIDC enabled | Repository name with the same conditional non-null check. |
| `tf_state_bucket_arn` | `string` | `null` | When OIDC enabled | State-bucket ARN used in IAM permission statements. It does not configure or migrate the Terraform backend. |
| `tf_state_bucket_cmk_arn` | `string` | `null` | No | Adds the custom state-CMK actions when non-null. Supply the actual backend CMK for the intended encrypted-state access; key/bucket policy restrictions still require review. |
| `branches_plan_github` | `list(string)` | `["main"]` | No | Legacy declared/pass-through input; unused by the current Plan subject construction. |
| `allow_pull_requests_plan_github` | `bool` | `false` | No | Legacy declared/pass-through input; does not add a `pull_request` subject or enable GitHub PR execution. |
| `enable_apply_role_github` | `bool` | `false` | No | Creates Apply resources only when the enclosing OIDC module is also enabled. |
| `branches_apply_github` | `list(string)` | `["main"]` | No | Used for Apply trust only when `environment_apply_github` is null. |
| `environment_apply_github` | `string` | `null` | No | When non-null, becomes the sole Apply environment subject instead of branch subjects. Standard configuration here uses `staging`. |
| `enable_image_publisher_role_github` | `bool` | `false` | No | Creates the separate publisher role only when the enclosing OIDC module is enabled. |
| `branches_image_publisher_github` | `list(string)` | `["main"]` | No | Publisher branch subjects. When instantiated, the shared module validates a non-empty list with no whitespace-only entries; it does not verify branch existence. |
| `lambda_cmk_arn` | `string` | `null` | No | Conditional custom decrypt/describe permission for the current workload Lambda CMK; may be null before the workload exists. |
| `secrets_manager_cmk_arn` | `string` | `null` | No | Conditional custom decrypt/describe permission for the current workload Secrets Manager CMK; may be null before the workload exists. |

The [example variable file](terraform.tfvars.example) is a starting configuration, not an additional defaults layer. Review it before copying; it deliberately enables OIDC and Apply. The root obtains the account ID from `aws_caller_identity`; it does not accept an `account_id` input or infer an expected account from the directory. Use explicit caller verification before any apply.

## Outputs

| Name | Description |
|---|---|
| `plan_role_github_arn` | Plan role ARN when OIDC is enabled; otherwise null. |
| `apply_role_github_arn` | Apply role ARN when both OIDC and Apply are enabled; otherwise null. |
| `image_publisher_role_github_arn` | Publisher role ARN when both OIDC and publisher are enabled; otherwise null. |

These outputs come from [outputs.tf](outputs.tf). Null root outputs can be absent from `terraform output -json`; absence is not proof that old IAM resources have actually been removed until the relevant plan has been applied and live state checked.

---

## Important Notes

- This stack should **NOT** be destroyed during normal operations
- This is long-lived administrative infrastructure; trust, permissions, and dependencies still need periodic review
- This stack creates the roles GitHub Actions uses to manage Terraform
- Destroying or misconfiguring this stack can break CI/CD access
- Normal infrastructure destroy workflows should target environment stacks (i.e., `baseline`), **NOT** this stack

Do not disable OIDC or its role flags as a substitute for workload retirement. These toggles affect the identities used to manage infrastructure, not workload deletion protection.

---

## CI/CD Behavior

GitHub Actions uses the `staging-plan` environment for Plan/evidence and the protected `staging` environment for the standard Apply path. The account root itself is not a target of the standalone Terraform Plan matrix; workload-account updates use the dedicated reconciliation workflow or a reviewed local operation.

The standalone Terraform Plan is informational. Terraform Apply creates its own saved plan, verifies its metadata/checksum after approval, and applies that exact artifact. Keep the same reviewed account, service Region, naming, and state settings across the paired GitHub environments. Required reviewers and branch policies must be configured and verified separately.

For application publication, store `IMAGE_PUBLISHER_ROLE_GITHUB_ARN` and the matching JSON `BRANCHES_IMAGE_PUBLISHER_GITHUB` in `staging-plan`. The configuration-resolution job reads them there, but `publish-image` itself has **no GitHub Environment**, retaining the branch-based subject. The release/PR job has GitHub write authority and no AWS credentials/OIDC token.

Publisher permissions cover repositories matching `<name_prefix>-*`, not only the service selected by a workflow run. The script's ECR credential helper and runner credential-file handling are publication concerns, not proof supplied by IAM-role validation. See the [deployment tooling reference](../../../scripts/deployment/README.md).

After a workload rebuild, reconcile current workload CMKs and verify bootstrap again. Ordinary digest releases do not require recreating the OIDC provider or account roles.

---

## State Management

This root has its own saved state, separate from the infrastructure it manages. The tracked [backend.tf](backend.tf) contains:

| Backend setting | RC1 value |
|---|---|
| Bucket | `tf-secure-baseline-staging-state` |
| Key | `bootstrap/account/staging.tfstate` |
| Region | `us-east-1` |
| Encryption | `true` |
| Native lockfile | `use_lockfile = true` |

These are the repository's example deployment coordinates, not values derived from `cloud_name`, `environment`, `primary_region`, or `tf_state_bucket_arn`. Review the committed backend for an adopter's actual bucket/key/Region before initializing. Changing an IAM ARN input does not migrate state. A changed backend identity requires a deliberately reviewed migration, not an unreviewed apply into empty state.

The sibling state root provisions its bucket/CMK using `state_region`; this account root's provider uses `primary_region`; the S3 backend independently uses its literal `region`. The Regions may differ intentionally. Keep state IAM permissions and backend identity aligned without treating those Region settings as synonyms.

Separate object keys avoid sharing one Terraform state/lock, but the Plan/Apply state policy spans the bucket's entire object prefix. Do not claim per-key IAM isolation. Moving state away from its own bucket also does not remove the state module's literal `prevent_destroy` guards. See the [state reference](../state/README.md).

---

## When to Modify

Only update this stack when changing:

- GitHub repository or organization
- GitHub OIDC trust conditions
- Plan or apply role permissions
- Image-publisher role permissions or authorized branches
- Terraform state access permissions
- GitHub environment names
- Optional KMS permissions required by baseline-created resources

---

## When NOT to Modify

Do not bundle unrelated account/role changes with ordinary workload edits. Reconciliation is still necessary when a rebuild changes CMKs referenced by the account policy.

Examples of changes that should not require this stack:

- Adding application infrastructure
- Updating networking resources
- Updating security services
- Updating Lambda automation logic
- Ordinary application releases or workload changes that do not alter the account-policy inputs

---

## Validation and reconciliation evidence

Use [validate-bootstrap.sh](../../../scripts/validation/validate-bootstrap.sh) after the workload and account inputs are reconciled. This local example assumes a selected named profile and initialized roots; `${VAR:?message}` requires a non-empty variable and prints the message rather than running the command when missing. Presence checks do not validate correctness.

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the staging profile}" \
AWS_REGION="${AWS_REGION:?Set the service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the expected account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh staging
```

When publication is required, also set `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true` and the approved `EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES` JSON for that invocation. Present publisher roles are checked even when optional. This is not an application push test or an IAM effective-permissions simulation. The standard validator expects the paired Plan/Apply environment subjects; choosing branch-only Apply trust requires reconciling validator/workflow expectations, not treating a trust mismatch as a pass.

For GitHub OIDC, do not require a named `AWS_PROFILE`; the workflow supplies temporary credentials. The [validation reference](../../../scripts/validation/README.md) documents strictness and the four-layer evidence boundaries.

## Summary

The `account` substack represents the Terraform execution plane for GitHub Actions.

It must remain **stable, isolated, and separate** from the infrastructure it manages.

This state boundary keeps normal workload resource graphs separate from their CI/CD identities. Safe operation still depends on reviewed IAM authority, correct backend/account selection, configured GitHub protections, and the lifecycle of each dependent stack.
