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

## Architecture Role

This stack exists in a separate control plane layer:

```
[state]       → Backend infrastructure (S3 + DynamoDB + KMS)
[bootstrap]   → CI/CD execution roles (GitHub OIDC)
[baseline]    → Deployable infrastructure
```

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

## Files

| File             | Purpose                                  |
|------------------|------------------------------------------|
| main.tf          | Calls the state module                   |
| variables.tf     | Input variables                          |
| outputs.tf       | Exposes backend resource values          |
| README.md        | Documentation                            |

---

## Deployment

### Step 1: Initialize

```bash
terraform init
```

### Step 2: Apply

```bash
terraform apply
```

This creates:
- S3 state bucket
- DynamoDB lock table
- KMS key

---

## Integration with Other Stacks

After deployment, configure:

### bootstrap/backend.tf

```hcl
terraform {
  backend "s3" {
    bucket  = "tf-secure-baseline-state"
    key     = "tf-state-bootstrap"
    region  = "us-east-1"
    encrypt = true
    dynamodb_table = var.tf_state_lock_table_name
  }
}
```

---

### baseline/backend.tf

```hcl
terraform {
  backend "s3" {
    bucket  = "tf-secure-baseline-state"
    key     = "tf-state-baseline"
    region  = "us-east-1"
    encrypt = true
    dynamodb_table = var.tf_state_lock_table_name
  }
}
```

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