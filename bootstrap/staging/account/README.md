# Account Substack

## Overview

The `account` substack provisions the **GitHub OIDC execution plane** for a target environment or control-plane context.

It deploys:

- GitHub OIDC provider
- `GitHub-Plan` role
- `GitHub-Apply` role
- Optional `GitHub-Image-Publisher` role
- Supporting IAM policies for Terraform state access and CI/CD operations

This stack is intentionally separated from the main Terraform baseline to prevent Terraform from destroying the IAM roles it is actively using during CI/CD workflows.

---

## Why This Exists

Without this separation, a Terraform apply or destroy workflow could remove the IAM roles required to continue running the workflow.

That can result in:

- Failed applies
- Failed destroys
- Broken GitHub Actions authentication
- Terraform state inconsistencies
- CI/CD pipelines that can no longer assume AWS roles

This stack solves that problem by isolating CI/CD execution resources from the infrastructure they manage.

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

Used by Terraform plan workflows.

Typical responsibilities:

- Read Terraform state
- Acquire Terraform state locks
- Read AWS resources needed for planning
- Generate Terraform execution plans

#### `GitHub-Apply` Role

Used by Terraform apply and destroy workflows.

Typical responsibilities:

- Read and write Terraform state
- Acquire and release Terraform state locks
- Create, update, and destroy AWS resources
- Access required KMS keys for encrypted Terraform-managed resources

#### `GitHub-Image-Publisher` Role

Used only by the `Deploy Application` workflow's AWS publication job.

- Trusts explicitly configured repository branches through GitHub OIDC
- Obtains ECR authorization and publishes/queries images in repositories matching the workload name prefix
- Has no broad Terraform state, ECS, IAM, or administration authority
- Is separate from the release/PR job, which has GitHub write permissions but no AWS credentials or OIDC token

---

## Deployment Order

### Initial Setup

1. Deploy the workload state stack and complete its S3 backend migration.
2. Apply this account stack with GitHub OIDC enabled. Record `plan_role_github_arn`, `apply_role_github_arn`, and, when enabled, `image_publisher_role_github_arn`.
3. Configure the matching GitHub Plan/Apply environments. Store the image publisher ARN as `IMAGE_PUBLISHER_ROLE_GITHUB_ARN` in `<env>-plan`, together with `BRANCHES_IMAGE_PUBLISHER_GITHUB`.
4. Include the Apply role in the appropriate `bucket_admin_principals` configuration before the workload stack must manage protected bucket controls.
5. Deploy `environments/<env>` locally or through the plan-first `Terraform Apply` workflow.
6. Reconcile the account stack after workload deployment with `scripts/bootstrap/reconcile-workload-account.sh <env>` or the `Reconcile Workload Account` workflow. Reconciliation resolves the current workload Lambda/Secrets Manager CMKs and preserves the enabled Image Publisher role and branch allowlist.

Prefer reconciliation over manually copying workload-created CMK outputs back into this stack. The reconciliation workflow uses an exact saved account-stack plan and runs strict bootstrap validation after Apply.

## Usage

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

  primary_region           = var.primary_region
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

| Name | Description |
|------|-------------|
| `cloud_name` | Name of cloud environment |
| `environment` | Environment name, such as `dev`, `prod`, `staging` or `control-plane` |
| `primary_region` | AWS region |
| `enable_github_oidc` | Enable GitHub OIDC federation resources for CI/CD |
| `owner_github` | GitHub organization or username |
| `repo_github` | GitHub repository name |
| `branches_plan_github` | List of branches allowed to assume the github_oidc role |
| `allow_pull_requests_plan_github` | Allow pull_request subject in OIDC trust policy |
| `enable_apply_role_github` | Enable the GitHub-Apply role |
| `environment_apply_github` | GitHub environment allowed to assume the GitHub-Apply role |
| `branches_apply_github` | Branches allowed to assume the GitHub-Apply role |
| `enable_image_publisher_role_github` | Enable the GitHub image-publisher role |
| `branches_image_publisher_github` | Branches allowed to assume the GitHub image-publisher role |
| `tf_state_bucket_arn` | ARN of the Terraform state bucket |
| `tf_state_bucket_cmk_arn` | ARN of the CMK for the tfstate S3 bucket |
| `lambda_cmk_arn` | Lambda CMK (optional on first apply) |
| `secrets_manager_cmk_arn` | Secrets CMK (optional on first apply) |

## Outputs

| Name | Description |
|------|-------------|
| `plan_role_github_arn` | `GitHub-Plan` role ARN |
| `apply_role_github_arn` | `GitHub-Apply` role ARN |
| `image_publisher_role_github_arn` | `GitHub-Image-Publisher` role ARN when enabled |

---

## Important Notes

- This stack should **NOT** be destroyed during normal operations
- This stack is safe to keep deployed permanently
- This stack creates the roles GitHub Actions uses to manage Terraform
- Destroying or misconfiguring this stack can break CI/CD access
- Normal infrastructure destroy workflows should target environment stacks (i.e., `baseline`), **NOT** this stack

For the control plane specifically, this stack should generally be treated as manual/local-only because it manages the IAM roles that GitHub Actions uses to access the control plane.

---

## CI/CD Behavior

GitHub Actions assumes the roles created by this stack using OIDC.

Typical usage:

```text
GitHub environment: dev-plan       -> GitHub-Plan role in dev account
GitHub environment: dev            -> GitHub-Apply role in dev account

GitHub environment: staging-plan   -> GitHub-Plan role in staging account
GitHub environment: staging        -> GitHub-Apply role in staging account

GitHub environment: prod-plan      -> GitHub-Plan role in prod account
GitHub environment: prod           -> GitHub-Apply role in prod account

GitHub environment: control-plane-plan -> GitHub-Plan role in bootstrap account
GitHub environment: control-plane      -> GitHub-Apply role in bootstrap account
```

For workload application publication, store `image_publisher_role_github_arn` as `IMAGE_PUBLISHER_ROLE_GITHUB_ARN` in the matching `<env>-plan` GitHub Environment. Also configure `BRANCHES_IMAGE_PUBLISHER_GITHUB` there as a non-empty JSON branch array matching this stack's trust input. The workflow's configuration-resolution job reads those variables from `<env>-plan`; the AWS publisher job itself intentionally has no GitHub Environment because its OIDC subject is branch based.

For `environment/<env>` stacks, GitHub Actions can safely use these roles to manage baseline infrastructure.

For the `bootstrap/control_plane/account` stack, avoid managing this stack through normal GitHub workflows, because it provisions the roles required by those workflows.

---

## State Management

This stack uses a **separate Terraform state** from the `baseline` stack.

Example environment state layout:

```text
bootstrap/<env>.tfstate
baseline/<env>.tfstate
```

`control_plane` substacks use separate state files:

```text
control-plane/account.tfstate
control-plane/identity-center.tfstate
control-plane/organizations.tfstate
```

Each substack should have its own backend key to avoid state lock conflicts and accidental cross-stack changes.

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

**Do not modify this stack during normal infrastructure changes.**

Examples of changes that should not require this stack:
- Adding application infrastructure
- Updating networking resources
- Updating security services
- Updating Lambda automation logic
- Destroying or redeploying baseline infrastructure

---

## Summary

The `account` substack represents the Terraform execution plane for GitHub Actions.

It must remain **stable, isolated, and separate** from the infrastructure it manages.

This separation prevents CI/CD workflows from destroying their own AWS access and provides a safer foundation for multi-account Terraform operations.