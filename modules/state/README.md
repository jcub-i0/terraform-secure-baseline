## Overview

The `state` module provisions and secures the core infrastructure required for Terraform remote state management.

This includes:
- A centralized S3 bucket for Terraform state storage
- A DynamoDB table for state locking
- A dedicated KMS key for encryption
- Strict security controls to protect state integrity

This module is **foundational** to the entire platform. All other Terraform stacks (e.g., `bootstrap`, `baseline`) depend on the resources created here.

---

## ⚠️ CRITICAL WARNING ⚠️

🚨 **DO NOT DESTROY THESE RESOURCES** 🚨

The infrastructure created by this module contains:
- Terraform state for all environments
- Locking mechanisms preventing concurrent state corruption

Destroying or corrupting these resources will result in:
- Permanent loss or corruption of infrastructure state
- Inability to safely manage or destroy existing resources
- Potential need for full environment rebuilds

This module must be treated as **critical control plane infrastructure**.

---

## Resources Created

### 🔑 KMS Key
- Customer-managed key (CMK) used for S3 encryption
- Key rotation enabled
- Protected with `prevent_destroy`

---

### 🪣 S3 State Bucket
- Stores Terraform state files
- Versioning enabled (for recovery)
- Server-side encryption using KMS
- Public access fully blocked
- Ownership enforced (no ACLs)
- Protected with `prevent_destroy`

---

### 🔒 DynamoDB Lock Table
- Used for Terraform state locking
- Prevents concurrent modifications
- Point-in-time recovery enabled
- Protected with `prevent_destroy`

---

### 🛡️ Security Controls

The module enforces:
- Deny changes to:
  - Bucket policy
  - Versioning configuration
  - Encryption configuration
- Access restricted to approved admin principals
- Encryption enforced at rest via KMS

---

## Inputs

| Name                     | Description                                      | Required |
|--------------------------|--------------------------------------------------|----------|
| `cloud_name`             | Name of env; used as prefix for resource naming  | Yes      |
| `environment`            | Environment name (e.g., dev, prod)               | Yes      |
| `account_id`             | AWS account ID                                   | Yes      |
| `primary_region`         | AWS region                                       | Yes      |
| `bucket_admin_principals`| ARNs allowed to modify bucket protections        | Yes      |

---

## Outputs

| Name | Description |
|------|-------------|
| `tf_state_bucket_arn` | Name of the state S3 bucket |
| `tf_state_bucket_name` | ARN of the state S3 bucket |
| `tf_state_bucket_cmk_arn` | ARN of the KMS key |
| `tf_state_lock_table_arn` | ARN of the DynamoDB state lock table |

---

## Usage Example

```hcl
module "state" {
  source = "../modules/state"

  cloud_name              = "tf-secure-baseline"
  environment             = "global"
  account_id              = "123456789012"
  primary_region          = "us-east-1"
  bucket_admin_principals = ["arn:aws:iam::123456789012:role/Admin"]
}
```

---

## Design Principles

This module follows:

- Separation of control planes
- Least privilege access
- Immutable infrastructure protections
- High durability and recoverability
- Operational safety over convenience

---

## Notes

- This module should be deployed once per account
- All other Terraform stacks should reference the bucket and lock table created here
- Do not attempt to manage these resources from other stacks