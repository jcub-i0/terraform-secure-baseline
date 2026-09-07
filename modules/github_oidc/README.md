# GitHub OIDC Module

## Overview

This module provisions AWS IAM resources required to enable GitHub Actions to authenticate to AWS using OpenID Connect (OIDC).

It creates:

- GitHub OIDC Identity Provider
- `GitHub-Plan` Role (planning plus required backend state/lock access)
- `GitHub-Apply` Role (write / administrative permissions)
- Optional `GitHub-Image-Publisher` role (ECR publication/query permissions)
- Associated IAM policies and attachments

This module enables secure, short-lived credential access from GitHub without storing AWS keys.

---

## Features

- OIDC-based authentication (no static credentials)
- Separate Plan and Apply roles
- Separate optional image-publisher role for application publication
- Branch and environment-based trust conditions
- Optional KMS access for encrypted resources

---

## Usage

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
  tf_state_bucket_cmk_arn = "arn:aws:kms:...:key/..."

  enable_apply_role_github           = true
  enable_image_publisher_role_github = true
  branches_image_publisher_github    = ["main"]
}
```

> NOTE: It's highly recommended that this module is called from a stack separate from your main configuration's stack to prevent the deletion of the `GitHub-Plan` and `GitHub-Apply` roles, in addition to other resources critical for this module's operations.

---

## Inputs

### Required

| Name | Description |
|------|-------------|
| `cloud_name` | Cloud/project name supplied by the account stack |
| `environment` | Workload environment used in Plan-role trust and naming context |
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
| `lambda_cmk_arn` | CMK for Lambda encryption ARN |
| `secrets_manager_cmk_arn` | CMK for Secrets Manager ARN |
| `branches_plan_github` | Declared legacy Plan-branch input; current Plan trust uses the `<environment>-plan` GitHub Environment subject |
| `allow_pull_requests_plan_github` | Declared legacy Plan-PR input; current Plan trust uses the `<environment>-plan` GitHub Environment subject |
| `enable_apply_role_github` | Enable the `GitHub-Apply` role |
| `branches_apply_github` | Branches allowed to assume the `GitHub-Apply` role |
| `environment_apply_github` | GitHub environment allowed to assume the `GitHub-Apply` role |
| `enable_image_publisher_role_github` | Enable the dedicated GitHub image-publisher role |
| `branches_image_publisher_github` | Non-empty branch list allowed to assume the image-publisher role; defaults to `["main"]` |

---

## Outputs

| Name | Description |
|------|-------------|
| `plan_role_github_arn` | `GitHub-Plan` role ARN |
| `apply_role_github_arn` | `GitHub-Apply` role ARN (if enabled) |
| `image_publisher_role_github_arn` | `GitHub-Image-Publisher` role ARN (if enabled) |

---

## Security Model

- Uses GitHub OIDC (`token.actions.githubusercontent.com`)
- Restricts trust to the intended repository and role-specific branch/environment subjects
- Uses exact branch-based subjects for the Image Publisher role
- Requires no long-lived AWS credentials
- Keeps application publication separate from Terraform Apply authority and GitHub release-PR authority

The Plan role trusts the `${environment}-plan` GitHub Environment subject. The Apply role trusts either the configured Apply environment or the configured branches, depending on `environment_apply_github`.

The image-publisher role always uses branch-based subjects:

```text
repo:<owner>/<repo>:ref:refs/heads/<branch>
```

Its policy grants `ecr:GetAuthorizationToken` and ECR image publication/query actions only for repositories matching:

```text
<name_prefix>-*
```

It has no Terraform state, ECS, IAM, or general AWS administration authority. The `Deploy Application` publisher job therefore requests OIDC and only `contents: read`. The separate release/PR job has GitHub repository write permissions but receives no AWS credentials and no OIDC token.

---

## Notes

- The `GitHub-Apply` role should be tightly controlled (branch + environment recommended)
- The image-publisher role should be enabled only for workload account stacks that publish application images, with the allowed branch list kept narrow
- KMS permissions are optional and conditional
- Designed for use in CI/CD pipelines (GitHub Actions)

---

## Example GitHub Usage

```yaml
- name: Configure AWS credentials
  uses: aws-actions/configure-aws-credentials@v6
  with:
    role-to-assume: <apply_role_github_arn>
    aws-region: us-east-1
```