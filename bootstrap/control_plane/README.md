# Control Plane (`bootstrap/control_plane`)

The control plane is the centralized management layer for this platform. It is deployed in the bootstrap (management) account and is responsible for organization-wide structure, identity, and foundational state management.

This stack does not deploy application infrastructure. Instead, it governs how infrastructure is organized, accessed, and managed across all accounts.

---

## Responsibilities

The control plane manages three core areas:

1. State (`state/`)
- Provisions the remote backend for Terraform
- Includes:
  - S3 bucket for state storage
  - KMS key for encryption
  - DynamoDB table for state locking
- Serves as the foundation for all other stacks

2. Organizations (`organizations/`)
- Defines the AWS Organizations structure
- Creates and manages Organizational Units (OUs), such as:
  - `Workloads`
  - `NonProd`
  - `Prod`
- Provides the hierarchy used for account segmentation and future governance (e.g., SCPs)

3. Identity Center (`identity_center/`)
- Manages centralized access via AWS IAM Identity Center (SSO)
- Defines:
  - Groups (e.g., `SecOps-Operator`, `SecOps-Analyst`, `SecOps-Engineer`)
  - Permission sets
  - Account assignments across environments
- Enables least-privilege, role-based access to all workload accounts

---

## Design Principles

- Centralized control, decentralized execution
  - Control plane defines access and structure
  - Environment stacks deploy infrastructure
- No circular dependancies
  - Identity Center attaches policies by name
  - Workload accounts define the actual permissions
- Multi-account by default
  - Designed to operate across `dev`, `staging`, and `prod`

---

## Summary

The control plane is the foundation of governance and access for the entire platform. It ensures:
- Consistent account structure
- Secure, centralized identity management
- Reliable Terraform state handling

All workload environments depend on this layer, but it remains isolated from application infrastructure to maintain stability and control.