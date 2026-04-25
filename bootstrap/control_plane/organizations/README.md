# 🏢 AWS Organizations (`bootstrap/control_plane/organizations`)

## Purpose

Defines the AWS Organizations structure for the platform.

This stack creates and manages Organizational Units (OUs) used to segment accounts and support future governance controls.

---

## Scope

### ✅ This stack DOES:
- Create Organizational Units:
  - `Workloads`
  - `NonProd`
  - `Prod`

### ❌ This stack does NOT:
- Create AWS accounts
- Manage account invitations
- Manage Service Control Policies (SCPs)
- Modify existing organization settings

---

## Important Notes

- This stack assumes:
  - AWS Organizations is already enabled
  - This is the management (bootstrap) account

- The `aws_organizations_organization` resource is intentionally commented out:
  - **Do not enable it if an organization already exists**
  - Enabling it in an existing org can cause errors or unintended behavior

---

## Future Enhancements

- Attach Service Control Policies (SCPs) to OUs
- Automate account placement within OUs
- Expand governance controls at the organization level