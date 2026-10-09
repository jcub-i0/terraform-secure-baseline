# GitHub OIDC Module

## Overview

This module provisions AWS IAM resources required to enable GitHub Actions to authenticate to AWS using OpenID Connect (OIDC).

The account roots in `bootstrap/*/account` instantiate this AWS module; it does not configure the GitHub repository or its Environment protections.

It creates:

- GitHub OIDC Identity Provider
- `GitHub-Plan` Role (planning plus required backend state/lock access)
- Optional `GitHub-Apply` Role (includes AWS-managed `AdministratorAccess`)
- Optional `GitHub-Image-Publisher` role (ECR publication/query permissions)
- Associated IAM policies and attachments

GitHub OIDC supplies temporary AWS role credentials instead of a stored long-lived AWS access key. That authentication choice does not make the role permissions narrow or eliminate credential exposure risks within a job.

The OIDC provider and Plan role are always created when this module is instantiated. Apply and Image Publisher have independent enablement flags. The account roots provide the outer `enable_github_oidc` switch; it is **not** an input of this module.

---

## Features

- OIDC-based authentication (no static credentials)
- Separate Plan and Apply roles
- Separate optional image-publisher role for application publication
- Environment-based Plan trust, environment-or-branch Apply trust, and exact branch-based publisher trust
- Optional KMS access for encrypted resources

---

## Usage

This is an illustrative module call from a root that has already selected the correct AWS provider/account and owns its separate state. Replace the sample identities and key ARN, configure the GitHub Environment separately, and do not add a second copy of the existing account-root module. The low-level `account_id` and `primary_region` inputs construct policy ARNs; they do not select credentials or configure an AWS provider.

```hcl
module "github_oidc" {
  source = "./modules/github_oidc"

  cloud_name     = "tf-secure-baseline"
  environment    = "dev"
  name_prefix    = "tf-secure-baseline-dev"
  primary_region = "us-east-1"
  account_id     = "123456789012"

  owner_github = "your-org"
  repo_github  = "your-repo"

  tf_state_bucket_arn     = "arn:aws:s3:::your-tf-state-bucket"
  tf_state_bucket_cmk_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  environment_apply_github          = "dev"
  enable_apply_role_github           = true
  enable_image_publisher_role_github = true
  branches_image_publisher_github    = ["main"]
}
```

Keep the CI/CD identities in a separate account root, as this repository does. That removes them from the normal workload resource graph; it does not add `prevent_destroy`, an IAM permissions boundary, or a guarantee against an explicit account-root destroy. Review ownership of any existing GitHub OIDC provider before attempting a fresh creation.

---

## Inputs

### Required

All eight required inputs have type `string` and no default. See [variables.tf](variables.tf).

| Name | Description |
|---|---|
| `cloud_name` | Declared naming-context input; not directly referenced in this module's resource/policy expressions. Account roots use it to derive `name_prefix`. |
| `environment` | Used to construct the `${environment}-plan` trust subject; also supports the administrative account contexts. |
| `name_prefix` | Supplied prefix used in role/policy names and resource scopes. |
| `primary_region` | Service Region inserted into policy ARNs, not the Terraform backend Region. |
| `account_id` | Account ID inserted into policy ARNs. The module does not compare it with the caller; account roots derive it from `aws_caller_identity`. |
| `owner_github` | Repository owner used in OIDC subjects. |
| `repo_github` | Repository name used in OIDC subjects. |
| `tf_state_bucket_arn` | Bucket ARN used for IAM grants; does not select or migrate the caller's S3 backend. |

### Optional

| Name | Type | Default | Description |
|---|---|---|---|
| `tf_state_bucket_cmk_arn` | `string` | `null` | Conditional state-CMK decrypt/describe/encrypt/data-key grant in custom Plan/Apply policies. |
| `lambda_cmk_arn` | `string` | `null` | Conditional Lambda-CMK decrypt/describe grant in custom Plan/Apply policies. |
| `secrets_manager_cmk_arn` | `string` | `null` | Conditional Secrets Manager-CMK decrypt/describe grant in custom Plan/Apply policies. |
| `branches_plan_github` | `list(string)` | `["main"]` | Legacy declaration; not referenced by current Plan trust construction. |
| `allow_pull_requests_plan_github` | `bool` | `false` | Legacy declaration; does not add a PR subject or control workflow triggers. |
| `enable_apply_role_github` | `bool` | `false` | Creates Apply role, custom policy and managed-policy attachments. |
| `branches_apply_github` | `list(string)` | `["main"]` | Used only when `environment_apply_github` is null. |
| `environment_apply_github` | `string` | `null` | When non-null, uses the environment subject instead of all branch subjects. |
| `enable_image_publisher_role_github` | `bool` | `false` | Creates publisher role/policy/attachment independently of Apply enablement. |
| `branches_image_publisher_github` | `list(string)` | `["main"]` | Requires a non-empty list with non-blank entries; uses exact branch-subject comparison. Does not check whether a branch exists. |

A null CMK input omits that custom statement; it does not prove the principal has no other KMS access. In particular, the Apply role's managed administrative policy is broader. Input descriptions that refer to legacy Plan branches/PRs must not be mistaken for implemented trust controls.

---

## Outputs

| Name | Description |
|---|---|
| `plan_role_github_arn` | Plan role ARN; always present for an instantiated module. |
| `apply_role_github_arn` | Apply role ARN when enabled; null otherwise. |
| `image_publisher_role_github_arn` | Publisher role ARN when enabled; null otherwise. |

The [account roots](../../bootstrap/dev/account/README.md) wrap these outputs with `try(..., null)` when the whole module is omitted. The administrative roots expose only Plan and Apply. See [outputs.tf](outputs.tf).

---

## Security Model

Authentication trust and AWS permissions are separate contracts. [main.tf](main.tf) is the authority for both.

### OIDC trust selection

All roles use `sts:AssumeRoleWithWebIdentity`, this module's `token.actions.githubusercontent.com` provider, and the `sts.amazonaws.com` audience.

| Role | Subject | Subject operator |
|---|---|---|
| Plan | `repo:<owner>/<repo>:environment:<environment>-plan` | `StringLike` |
| Apply with non-null `environment_apply_github` | `repo:<owner>/<repo>:environment:<environment_apply_github>` | `StringLike` |
| Apply with null `environment_apply_github` | One `repo:<owner>/<repo>:ref:refs/heads/<branch>` per `branches_apply_github` entry | `StringLike` |
| Image Publisher | One `repo:<owner>/<repo>:ref:refs/heads/<branch>` per `branches_image_publisher_github` entry | `StringEquals` |

Apply environment trust **replaces**, rather than combines with, branch subjects. Set allowed deployment branches and required reviewers in GitHub separately; those settings are not created or verified by this AWS module. Plan/Apply use pattern comparison, so use reviewed literal names and do not assume wildcard-containing inputs are rejected. Publisher values are exact: a branch wildcard is not a pattern grant there.

None of these subjects binds a role to a particular workflow file, selected application service, or image digest. A branch-based publisher job must not declare a GitHub Environment that changes its expected subject. The repository's `publish-image` job deliberately omits one, while its separate configuration-resolution job reads variables through `<env>-plan`.

### Plan authority

Plan attaches AWS-managed `ReadOnlyAccess` and a custom policy that includes:

| Custom scope | Allowed actions |
|---|---|
| `tf_state_bucket_arn` | `s3:ListBucket` |
| Every object under `${tf_state_bucket_arn}/*` | `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject` |
| `arn:<partition>:secretsmanager:<primary_region>:<account_id>:secret:<name_prefix>/*` | `secretsmanager:GetSecretValue` |
| `*` | `secretsmanager:GetRandomPassword` |
| Supplied state CMK | `kms:Decrypt`, `kms:DescribeKey`, `kms:Encrypt`, `kms:GenerateDataKey` |
| Supplied Lambda/Secrets Manager CMKs | `kms:Decrypt`, `kms:DescribeKey` |

The object-write/delete grant is **not restricted to lockfiles**. Plan can access state objects across the supplied bucket, and selected secret reads can return sensitive values. A workflow performing read-only inspection does not make these IAM permissions read-only. The attached AWS-managed policy is additional authority; this table is not its complete effective-permissions definition.

### Apply authority

Apply attaches both its custom state/secret/KMS policy and AWS-managed **`AdministratorAccess`**. The custom policy's listed resource scopes do not cap the administrative grant. This module defines no permissions boundary or policy enforcing that API calls correspond only to a reviewed Terraform plan.

The repository's exact-plan checks and approvals are workflow controls. Correct account selection, restricted job execution, external policy restrictions, and independent administrative recovery access remain important. These documents do not claim an exhaustive effective-permissions assessment of a deployed account.

### Image Publisher authority

The publisher receives one custom policy and no managed-policy attachment from this module. It allows `ecr:GetAuthorizationToken` on `*` and the following repository actions:

```text
ecr:BatchCheckLayerAvailability
ecr:BatchGetImage
ecr:CompleteLayerUpload
ecr:DescribeImages
ecr:DescribeRepositories
ecr:InitiateLayerUpload
ecr:PutImage
ecr:UploadLayerPart
```

The repository-action scope is exactly the constructed pattern:

```text
arn:<partition>:ecr:<primary_region>:<account_id>:repository/<name_prefix>-*
```

That covers the workload's matching repositories, not only the repository selected in a particular run. The module grants no repository creation/deletion, Terraform-state, ECS, IAM, or general administrative actions to the publisher. Do not confuse its registry-wide authorization-token action with repository-wide administrative permission.

The publication job has AWS OIDC authority and `contents: read`; the release/PR job has GitHub write authority and no AWS credentials/OIDC token. The runner's credential-helper behavior is documented in the [deployment reference](../../scripts/deployment/README.md), not implemented by this IAM module.

### Region, partition, and state boundaries

The account roots set their provider Region from `primary_region`, compare it with `data.aws_region.current.region`, and pass that resolved value here. Their backends independently specify the S3 state Region. Supplying a new bucket ARN or service Region does not rewrite or migrate a backend.

The module derives the partition from `data.aws_partition.current` for its
constructed Secrets Manager/ECR policy scopes and AWS-managed policy attachment
ARNs. Supplied state bucket and KMS ARNs remain caller inputs and are not
rewritten. Partition-aware construction does not establish GovCloud/China
compatibility or qualified cross-Region recovery. Review KMS and bucket
resource policies separately; a custom IAM grant does not rewrite them.

---

## Notes

- Enable only the roles required by the actual workflow model. The shared module defaults Apply and Image Publisher to false, while account example files intentionally enable selected roles.
- Changing the enclosing account root's `enable_github_oidc` from true to false can remove the provider and roles. This is not a cost-profile toggle or a workload-retirement mechanism.
- Keep state-bucket permissions and backend coordinates aligned, but do not treat separate backend keys as per-key IAM isolation.
- Inspect both custom and managed-policy attachments when assessing authority. No claim here replaces deployed-account review or testing an actual role assumption.

### Validation ownership

The workload [bootstrap validator](../../scripts/validation/validate-bootstrap.sh) checks selected state/OIDC contracts. Present publisher roles are checked even when optional; strict publisher evidence requires the expected repository and branch JSON. The standard Plan/Apply checks expect the paired environment subjects. A module-supported branch-only Apply configuration does not automatically satisfy that validator or the standard workflow jobs.

Control-plane validation covers selected control-plane OIDC foundations. Security-operations service evidence is not a dedicated audit of its account root. No validator here proves GitHub Environment reviewer configuration, successful image publication, or complete effective IAM authority. See the [validation reference](../../scripts/validation/README.md).

---

## Example GitHub Usage

This job fragment illustrates environment-based credential acquisition only. It is **not** a replacement for the repository's plan/approval/artifact-verification workflow. Configure the `dev` GitHub Environment, approved branches/reviewers and variables first; its name must match `environment_apply_github`.

```yaml
jobs:
  credential-example:
    runs-on: ubuntu-latest
    environment: dev
    permissions:
      id-token: write
      contents: read
    steps:
      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v6
        with:
          role-to-assume: ${{ vars.APPLY_ROLE_GITHUB_ARN }}
          aws-region: ${{ vars.PRIMARY_REGION }}
          allowed-account-ids: ${{ vars.ACCOUNT_ID }}
      - name: Inspect caller identity
        run: aws sts get-caller-identity
```

Do not require `AWS_PROFILE` in the GitHub OIDC job. Local examples using named profiles and CI jobs receiving temporary environment credentials have different credential setup. Review the actual [Terraform Apply workflow](../../.github/workflows/terraform-apply.yml) before changing deployment behavior.
