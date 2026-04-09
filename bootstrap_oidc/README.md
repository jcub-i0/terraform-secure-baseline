# Bootstrap OIDC Stack

## Overview

This stack provisions the **GitHub OIDC control plane** for the environment.

It deploys:

- GitHub OIDC provider
- GitHub Plan role
- GitHub Apply role

This stack is intentionally separated from the main Terraform baseline to prevent self-destruction during CI/CD operations.

---

## Why This Exists

Without this separation:

- Terraform destroy can remove the IAM roles it is actively using
- This results in:
  - failed applies
  - corrupted state
  - broken pipelines

This stack solves that by isolating execution-plane resources.

---

## Architecture

`bootstrap_oidc` (this stack) ➔ `github_oidc` module

`baseline` stack ➔ All infrastructure (VPC, Lambda, S3, etc.)

---

## Deployment Order

### Initial Setup

1. Deploy `bootstrap` stack

```bash
cd bootstrap_oidc
terraform init
terraform apply
```

2. Deploy `baseline` stack after setting required variables (locally once)

```bash
cd ../baseline
terraform apply
```
> Note the `lambda_cmk_arn` and `secrets_manager_cmk_arn` outputs

3. Define the `lambda_cmk_arn` and `secrets_manager_cmk_arn` variables

```bash
TF_VAR_lambda_cmk_arn="<lambda_cmk_arn>"
TF_VAR_secrets_manager_cmk_arn="<secrets_manager_cmk-arn"
```

4. Re-apply `bootstrap_oidc` stack

```bash
cd bootstrap_oidc
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
| `name_prefix` | Resource naming prefix |
| `primary_region` | AWS region |
| `account_id` | AWS account ID |
| `owner_github` | GitHub org/user |
| `repo_github` | GitHub repo |
| `tf_state_bucket_arn` | Terraform state bucket |
| `tf_state_bucket_cmk_arn` | CMK for state bucket |
| `lambda_cmk_arn` | Lambda CMK (optional on first apply) |
| `secrets_manager_cmk_arn` | Secrets CMK (optional on first apply) |

