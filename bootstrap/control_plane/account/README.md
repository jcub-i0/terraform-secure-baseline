# Account Substack

## Overview

The `account` substack provisions the **GitHub OIDC execution plane** for a target environment or control-plane context.

It deploys:

- GitHub OIDC provider
- `GitHub-Plan` role
- `GitHub-Apply` role
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
GitHub-Plan / GitHub-Apply IAM Roles
    |
    | Terraform permissions
    v 
Target Terraform Stack
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

---

## Deployment Order

### Initial Setup

The following steps assume the `state` stack has already been deployed.

Refer to the ../state/README.md file for `state` stack setup.

1. Deploy the `account` stack
> For the control plane, `<env>` is `control_plane`
```bash
cd /bootstrap/<env>/account
terraform init
terraform apply
```
> Note the  following output:
> `apply_role_github_arn`

2. Add the apply role to bucket admin principals

Add the `apply_role_github_arn` output value to the `bucket_admin_principals` variable for the relevant `state`/`baseline` stack.

Example:

```bash
export TF_VAR_bucket_admin_principals=["arn:aws:iam::<account_id>:root","arn:aws:iam::<account_id>:role/tf-secure-baseline-<env>-github-apply-role"]
```

This allows the GitHub apply role to manage protected Terraform-managed resources that require elevated administrative access.

3. Deploy the baseline stack

After the required variables are set, deploy the `baseline` stack for the environment.

```bash
cd ../../../baseline/
terraform apply
```

The baseline stack may output additional KMS key ARNs required by the GitHub OIDC roles, such as:

```text
lambda_cmk_arn
secrets_manager_cmk_arn
```

4. Pass `baseline`-created CMK ARNs back into the account stack

Define the `lambda_cmk_arn` and `secrets_manager_cmk_arn` variables

```bash
TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk_arn"
```

5. Re-apply `account` stack

> For the control plane, `<env>` is `control_plane`
```bash
cd ../bootstrap/<env>/account/
terraform apply
```

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
  tf_state_lock_table_arn = var.tf_state_lock_table_arn

  primary_region           = var.primary_region
  account_id               = data.aws_caller_identity.current.account_id
  enable_apply_role_github = var.enable_apply_role_github
  branches_apply_github    = var.branches_apply_github
  environment_apply_github = var.environment_apply_github

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
| `tf_state_bucket_arn` | ARN of the Terraform state bucket |
| `tf_state_bucket_cmk_arn` | ARN of the CMK for the tfstate S3 bucket |
| `tf_state_lock_table_arn` | ARN of the DynamoDB table used for Terraform state locking |
| `lambda_cmk_arn` | Lambda CMK (optional on first apply) |
| `secrets_manager_cmk_arn` | Secrets CMK (optional on first apply) |

## Outputs

| Name | Description |
|------|-------------|
| `plan_role_github_arn` | `GitHub-Plan` role ARN |
| `apply_role_github_arn` | `GitHub-Apply` role ARN |

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