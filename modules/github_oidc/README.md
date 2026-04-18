# GitHub OIDC Module

## Overview

This module provisions AWS IAM resources required to enable GitHub Actions to authenticate to AWS using OpenID Connect (OIDC).

It creates:

- GitHub OIDC Identity Provider
- `GitHub-Plan` Role (read-only / planning permissions)
- `GitHub-Apply` Role (write / administrative permissions)
- Associated IAM policies and attachments

This module enables secure, short-lived credential access from GitHub without storing AWS keys.

---

## Features

- OIDC-based authentication (no static credentials)
- Separate Plan and Apply roles
- Branch and environment-based trust conditions
- Optional support for:
  - DynamoDB state locking
  - KMS access for encrypted resources

---

## Usage

```hcl
module "github_oidc" {
  source = "./modules/github_oidc"

  name_prefix      = "tf-secure-baseline-dev"
  primary_region   = "us-east-1"
  account_id       = "123456789012"

  owner_github = "your-org"
  repo_github  = "your-repo"

  tf_state_bucket_arn     = "arn:aws:s3:::your-tf-state-bucket"
  tf_state_bucket_cmk_arn = "arn:aws:kms:...:key/..."
  
  enable_apply_role_github = true
}
```

> NOTE: It's highly recommended that this module is called from a stack separate from your main configuration's stack to prevent the deletion of the `GitHub-Plan` and `GitHub-Apply` roles, in addition to other resources critical for this module's operations.

---

## Inputs

### Required

| Name | Description |
|------|-------------|
| `name_prefix` | Prefix for IAM resource names |
| `primary_region` | AWS region |
| `account_id` | AWS account ID |
| `owner_github` | GitHub org/user |
| `repo_github` | GitHub repo name |
| `tf_state_bucket_arn` | Terraform state bucket ARN |

### Optional

| Name | Description |
|------|-------------|
| `tf_state_bucket_cmk_arn` | CMK for state bucket ARN |
| `tf_state_lock_table_arn` | DynamoDB lock table ARN |
| `lambda_cmk_arn` | CMK for Lambda encryption ARN |
| `secrets_manager_cmk_arn` | CMK for Secrets Manager ARN |
| `branches_plan_github` | List of branches allowed to assume the `github_plan` role |
| `allow_pull_requests_plan_github` | Allow PRs to trigger `terraform plan` job |
| `enable_apply_role_github` | Enable the `GitHub-Apply` role" |
| `branches_apply_github` | Branches allowed to assume the `GitHub-Apply` role |
| `environment_apply_github` | GitHub environment allowed to assume the `GitHub-Apply` role |

---

## Outputs

| Name | Description |
|------|-------------|
| `plan_role_github_arn` | `GitHub-Plan` role ARN |
| `apply_role_github_arn` | `GitHub-Apply` role ARN (if enabled) |

---

## Security Model

- Uses GitHub OIDC (`token.actions.githubusercontent.com`)
- Restricts access via:
  - Repository
  - Branch
  - Environment (optional)
- No long-lived AWS credentials required

---

## Notes

- The `GitHub-Apply` role should be tightly controlled (branch + environment recommended)
- KMS permissions are optional and conditional
- Designed for use in CI/CD pipelines (GitHub Actions)

---

## Example GitHub Usage

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: <apply_role_github_arn>
    aws-region: us-east-1
```