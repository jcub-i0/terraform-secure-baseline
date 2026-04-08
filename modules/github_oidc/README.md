# GitHub OIDC Module

## Overview

This module provisions AWS IAM resources required to enable GitHub Actions to authenticate to AWS using OpenID Connect (OIDC).

It creates:

- GitHub OIDC Identity Provider
- GitHub Plan Role (read-only / planning permissions)
- GitHub Apply Role (write / administrative permissions)
- Associated IAM policies and attachments

This module enables secure, short-lived credential access from GitHub without storing AWS keys.

---

## Features

- OIDC-based authentication (no static credentials)
- Separate Plan and Apply roles
- Branch and environment-based trust conditions
- Optional support for:
  - Terraform state bucket access
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

---

