# 🔐 IAM Identity Center (`bootstrap/control_plane/identity_center`)

## Purpose

Manages **centralized identity and access** across all AWS accounts using IAM Identity Center (SSO).

This stack defines:
- User groups (e.g., SecOps roles)
- Permission sets
- Account assignments

It enables **least-privilege, role-based access** to all workload environments (`dev`, `staging`, `prod`).

---

## Scope

### ✅ This stack DOES:
- Create Identity Center groups:
  - `SecOps-Operator`
  - (Optionally) `SecOps-Analyst`, `SecOps-Engineer`
- Create permission sets for each role
- Attach:
  - AWS-managed policies (e.g., `SecurityAudit`, `ReadOnlyAccess`)
  - Customer-managed policies (from workload accounts)
- Assign permission sets to target AWS accounts

### ❌ This stack does NOT:
- Create IAM policies for access (handled by environment/baseline stacks)
- Manage application infrastructure
- Depend on workload modules directly

---

## 🧠 Design Principles

- **Control plane only**
  - All Identity Center resources are managed centrally in the bootstrap account

- **No circular dependencies**
  - Customer-managed policies are referenced by **name/path only**
  - Policies must already exist in the target account

- **Environment-aware access**
  - Each environment (`dev`, `staging`, `prod`) receives its own role assignments

---

## 🔄 Deployment Workflow

Identity Center roles that depend on environment-specific policies (e.g., logs access) follow a two-step process:

1. **Initial apply (minimal roles)**
   - Deploy `SecOps-Operator` and any enabled roles without custom policies

2. **Deploy environment baseline**
   - Creates IAM policies (e.g., logs S3 read, CMK decrypt) in each account

3. **Re-apply Identity Center**
   - Pass policy names as variables, which are output by the `baseline` stack deployed by `environment/<env>`
   - Attach customer-managed policies to permission sets

---

## ⚠️ Important Notes

- Customer-managed policy attachments require:
  - Matching policy name and path in the target account
  - Policies must exist before attachment

- Resources are conditionally created using:
  - Feature flags (e.g., `enable_secops_analyst`)
  - Null checks for policy variables

- Identity Center automatically provisions roles in target accounts:
  - `AWSReservedSSO_*`

---

## 🚀 Future Enhancements

- Enable `SecOps-Analyst` and `SecOps-Engineer` by default
- Expand permission sets for broader operational roles
- Integrate additional least-privilege policies per environment