# Terraform State Stack

## Overview

The `state` stack is responsible for provisioning the foundational backend infrastructure used by all other Terraform stacks in this repository.

It deploys:
- Centralized Terraform state storage (S3)
- State locking (DynamoDB)
- Encryption (KMS/CMK)

This stack represents the root of trust for your entire infrastructure.

---

## ⚠️ CRITICAL WARNING ⚠️

🚨 **THIS STACK MUST NEVER BE DESTROYED!** 🚨

This stack contains the backend for:
- `bootstrap` stack (CI/CD execution plane)
- `baseline` stack (infrastructure plane)
- Any future environments (dev, staging, prod)

Destroying this stack will:
- Delete, corrupt, or orphan Terraform state
- Break all Terraform operations
- Make safe infrastructure management impossible
- Potentially require full environment rebuild

**There is NO safe recovery from accidental destruction.**

Treat this stack as:
- Permanent
- Protected
- Highly sensitive

---

## Architecture

This stack exists in a separate control plane layer:

- `state` stack ➔ `bootstrap` and `baseline` stacks
  - `bootstrap` stack ➔ `github_oidc` module
  - `baseline` stack ➔ All infrastructure (VPC, Lambda, S3, etc.)

This separation ensures:
- Terraform cannot destroy its own backend
- CI/CD remains stable
- Infrastructure lifecycle is safe

---

## State Management

Unlike other stacks:

- This stack initially uses local state
- It bootstraps the remote backend used by all other stacks

After deployment:
- Bootstrap and baseline use the S3 backend created here
- This stack may optionally be migrated to remote state later

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
| `tf_state_lock_table_name` | Name of the DynamoDB state lock table |

---

## Files

| File             | Purpose                                  |
|------------------|------------------------------------------|
| main.tf          | Calls the `state` module                   |
| variables.tf     | Input variables                          |
| outputs.tf       | Exposes backend resource values          |
| README.md        | Documentation                            |

---

## Deployment and Integration with Other Stacks

The following steps assume you are using the `bootstrap` stack, which enables OIDC between AWS and GitHub.

If you are not using this feature, ignore any references to the `bootstrap` stack
> For example, for:
> ```bash
> cd ../bootstrap
> terraform init
> cd ../baseline
> terraform init
> ```
> Run this instead:
> ```bash
> cd ../baseline
> terraform init
> ```

### Step 1: Navigate to the `state` stack and initialize it

```bash
cd state
terraform init
```
> The `state` stack intentionally uses **local state** during initial deployment to bootstrap the remote backend

### Step 2: Apply

```bash
terraform apply
```

This creates:
- S3 state bucket
- DynamoDB lock table
- KMS key

### Step 3: Capture outputs for downstream stacks

After apply, note the following outputs:
- `tf_state_bucket_name`
- `tf_state_bucket_arn`
- `tf_state_bucket_cmk_arn`
- `tf_state_lock_table_name`
- `tf_state_lock_table_arn`

### Step 4: Configure backend for `bootstrap` and `baseline` stacks

Update `bootstrap/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket  = "<tf_state_bucket_name>"
    key     = "tf-state-bootstrap"
    region  = "us-east-1"
    encrypt = true
    dynamodb_table = "<tf_state_lock_table_name>"
  }
}
```

Update `baseline/backend.tf`:

```hcl
terraform {
  backend "s3" {
    bucket  = "<tf_state_bucket_name>"
    key     = "tf-state-baseline"
    region  = "us-east-1"
    encrypt = true
    dynamodb_table = "<tf_state_lock_table_name>"
  }
}
```
> These `provider` / `terraform` blocks may already be configure correctly if using default variables

Then initialize the `bootstrap` and `baseline` stacks:

```bash
cd ../bootstrap
terraform init
cd ../baseline
terraform init
```

### Step 5: Proceed with Normal Deployment Flow
> Refer to `/bootstrap/README.md` file 

---

## Operational Guidelines

### DO:
- Protect this stack from deletion
- Restrict access to trusted operators only
- Back up local state if not migrated
- Treat as critical infrastructure

### DO NOT:
- Run terraform destroy
- Modify resources outside Terraform
- Share access broadly
- Recreate manually unless absolutely necessary

---

## Future Enhancements

Optional improvements:
- Remote backend for this stack (tf-state-state)
- Cross-region replication for DR
- Monitoring and alerting on state access
- Access logging / CloudTrail data events

---

## Summary

This stack is **NOT** just another Terraform deployment.

It is the foundation of your entire platform.

Handle it accordingly.