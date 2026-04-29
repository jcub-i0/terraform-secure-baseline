# Account Substack

## Overview

This stack provisions the **GitHub OIDC control plane** for the environment.

It deploys:

- GitHub OIDC provider
- `GitHub-Plan` role
- `GitHub-Apply` role

This stack is intentionally separated from the main Terraform baseline to prevent self-destruction during CI/CD operations.

---

## Why This Exists

Without this separation:

- The `Terraform Destroy` CI/CD workflow can remove the IAM roles it is actively using
- This results in:
  - Failed applies
  - Corrupted state
  - Broken pipelines

This stack solves that by isolating execution-plane resources.

---

## (Architecture section?)

---

## Deployment Order

### Initial Setup

The following steps assume that you have already deployed the `state` stack (refer to the `/state/README.md` file):

1. Deploy `account` stack

```bash
cd /bootstrap/<env>/account
terraform init
terraform apply
```
>Note the `apply_role_github_arn` output

2. Add the `apply_role_github_arn` output's value to the `bucket_admin_principals` variable (defined in `bootstrap` stack)

Example:

```bash
export TF_VAR_bucket_admin_principals=["arn:aws:iam::<account_id>:root","arn:aws:iam::<account_id>:role/tf-secure-baseline-<env>-github-apply-role"]
```

3. After setting required variables (locally once), deploy `baseline` stack

```bash
cd ../../../baseline/
terraform apply
```
> Note the `lambda_cmk_arn` and `secrets_manager_cmk_arn` outputs

4. Define the `lambda_cmk_arn` and `secrets_manager_cmk_arn` variables

```bash
TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk-arn"
```

5. After setting the variables above, re-apply `account` stack

```bash
cd ../bootstrap/<env>/account/
terraform apply
```

## Usage

```hcl
module "github_oidc" {
  source = "../modules/github_oidc"

  name_prefix    = var.name_prefix
  primary_region = var.primary_region
  account_id     = var.account_id

  owner_github = var.owner_github
  repo_github  = var.repo_github

  tf_state_bucket_arn     = var.tf_state_bucket_arn
  tf_state_bucket_cmk_arn = var.tf_state_bucket_cmk_arn

  lambda_cmk_arn          = var.lambda_cmk_arn
  secrets_manager_cmk_arn = var.secrets_manager_cmk_arn

  enable_apply_role_github = var.enable_apply_role_github
}
```

## Inputs

| Name | Description |
|------|-------------|
| `cloud_name` | Name of cloud |
| `environment` | Name of environment (`dev`, `prod`, `staging` `control-plane`) |
| `primary_region` | AWS region |
| `enable_github_oidc` | Enable GitHub OIDC federation resources for CI/CD |
| `owner_github` | GitHub org/user |
| `repo_github` | GitHub repo |
| `branches_plan_github` | List of branches allowed to assume the github_oidc role |
| `allow_pull_requests_plan_github` | Allow pull_request subject in OIDC trust policy |
| `enable_apply_role_github` | Enable the GitHub-Apply role |
| `environment_apply_github` | GitHub environment allowed to assume the GitHub-Apply role |
| `branches_apply_github` | Branches allowed to assume the GitHub-Apply role |
| `tf_state_bucket_arn` | Terraform state bucket |
| `tf_state_bucket_cmk_arn` | CMK for state bucket |
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
- It is safe to keep this deployed permanently
- Destroy workflows should only target the **baseline stack**

---

## CI/CD Behavior

- GitHub Actions assumes roles created here
- Baseline workflows depend on this stack
- Destroy workflow does **not** affect this stack

---

## State Management

This stack uses a **separate state** from the baseline stack.

Example:

```
bootstrap state: tf-state-bootstrap
baseline state: tf-state
```

---

## When to Modify

Only update this stack when:

- Changing GitHub repo/org
- Modifying role permissions
- Updating trust conditions

---

## When NOT to Modify

Do not modify during normal infra changes.

---

## Summary

This stack represents the execution plane for Terraform.

It must remain stable and separate from the infrastructure it manages.