# Account Services Stack

## Overview

The `account_services` stack provisions **account-level AWS services** that must exist **once per account/region** and cannot be duplicated across environments.

These services are shared by all environments (`dev`, `staging`, `prod`) and are required for proper security and compliance functionality.

---

## ⚠️ IMPORTANT

This stack contains **singleton resources**.

- Do NOT deploy multiple copies of these resources per environment
- Do NOT attempt to recreate these resources in `baseline/envs/*`
- Some AWS services will fail if duplicate instances are created

---

## Resources Managed

Examples of resources typically managed here:

- GuardDuty detector (1 per account per region)
- IAM Access Analyzer (quota-limited)
- AWS Config service-linked role
- Other account-scoped or service-linked resources

---

## Deployment Order

This stack must be deployed:

1. After `state` and `bootstrap`
2. Before any `baseline/envs/*` stacks

---

## Backend Configuration

Uses the shared Terraform backend:

```hcl
terraform {
  backend "s3" {
    bucket         = "tf-secure-baseline-state"
    key            = "tf-state-account-services"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-secure-baseline-lock"
  }
}
```

---

## Design Principles

- Single source of truth for account-level services
- No environment duplication
- Minimal scope (only resources that cannot be multi-env)
- Separation of concerns for `baseline`

---

## Notes

- Keep this stack small and focused
- Do NOT add environment-specific resources here
- Avoid turning this into a general-purpose "shared" stack

---

## Summary

The `account_services` stack ensures that AWS account-level services are:

- Deployed once
- Managed safely
- Reused across all environments

This prevents conflicts, quota issues, and deployment failures in multi-enviornment setups, like this one.