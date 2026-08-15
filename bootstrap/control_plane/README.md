# 🧭 Control Plane (`bootstrap/control_plane`)

## Purpose

The control plane is the centralized governance and access layer for `tf-secure-baseline`. It is deployed in the AWS Organizations management account and manages the organization structure, centralized workforce access, control-plane CI/CD roles, and control-plane Terraform state.

It does **not** deploy workload application infrastructure or own the delegated administrator-side configuration of centralized security services.

---

## Substacks

The control plane contains four independently managed Terraform roots:

| Substack | Purpose |
|---|---|
| `state/` | Creates the control-plane S3 state bucket and KMS key, then migrates its own state into that protected backend using `scripts/bootstrap/migrate-state-stack.sh`. |
| `account/` | Creates the control-plane GitHub OIDC Plan and Apply roles used by CI/CD. |
| `organizations/` | Manages the AWS Organization structure and the management-account prerequisites for centralized Security Hub and GuardDuty administration. |
| `identity_center/` | Manages IAM Identity Center groups, permission sets, and account assignments for workload and security-operations accounts. |

### State

The `state` substack follows the same two-phase bootstrap model as the other state stacks:

1. apply locally without an active `backend.tf`;
2. create the S3 state bucket and KMS key;
3. migrate the local state with `scripts/bootstrap/migrate-state-stack.sh`;
4. use the S3 backend with native lockfiles (`use_lockfile = true`).

The control-plane state stack does not use a DynamoDB lock table.

### Account

The `account` substack creates the GitHub OIDC roles used by control-plane automation. Keeping these roles outside the stacks they operate prevents a normal Terraform operation from destroying its own execution identity.

### Organizations

The `organizations` substack owns the AWS Organizations structure and management-account security prerequisites. It manages:

- AWS Organizations in `ALL` features mode;
- `Workloads`, `NonProd`, `Prod`, and `Security` OUs;
- Security Hub trusted access and delegated-administrator registration when enabled;
- GuardDuty trusted access and delegated-administrator registration when enabled;
- GuardDuty Malware Protection trusted service access;
- Security Hub V2 `SECURITYHUB_POLICY` enablement and management-account delegation prerequisites.

The actual centralized Security Hub CSPM, GuardDuty organization protection-plan, and Security Hub V2 workload policy configuration is owned by:

```text
bootstrap/security_operations/security_services
```

### Identity Center

The `identity_center` substack manages centralized workforce access across the workload and security-operations accounts.

The current required access model includes:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

Optional Analyst and Engineer access can be enabled independently for workload and security-operations accounts.

---

## Organization Model

The expected organization hierarchy is:

```text
Root
├── Workloads
│   ├── NonProd
│   │   ├── dev
│   │   └── staging
│   └── Prod
│       └── prod
└── Security
    └── security-operations
```

The `organizations` Terraform root creates and manages the OU hierarchy, but it does not create AWS accounts or perform account invitations. Account placement must already be established through the adopted account-management process and is validated separately by control-plane validation.

---

## Ownership Boundary

The control plane owns **management-account governance prerequisites**. The security-operations account owns **delegated administrator-side security configuration**.

```text
control-plane / organizations
    |
    +--> AWS Organizations structure
    +--> trusted service access
    +--> delegated administrator registration
    +--> SECURITYHUB_POLICY prerequisites
    |
    v
security-operations / security_services
    |
    +--> Security Hub CSPM central configuration
    +--> GuardDuty organization configuration and protection plans
    +--> Security Hub V2 workload organization policy
```

This boundary keeps AWS Organizations authority in the management account while placing operational security-service administration in the dedicated security-operations account.

---

## Design Principles

- **Centralized governance, decentralized workloads**
  - The control plane defines organization structure and human access.
  - Workload stacks deploy environment infrastructure.
  - The security-operations stack administers centralized security services.

- **No circular Terraform dependencies**
  - Identity Center references workload-created customer-managed IAM policies by name rather than consuming workload remote state.
  - Optional roles that require those policies are enabled only after the policies exist.

- **Bootstrap before automation**
  - State and OIDC execution roles are established before CI/CD depends on them.

- **Multi-account by default**
  - Governance, security administration, and workloads are separated across `control-plane`, `security-operations`, `dev`, `staging`, and `prod` accounts.

---

## Validation

Control-plane validation owns the complete AWS Organizations topology and management-account prerequisite checks, including:

- organization and OU structure;
- expected workload and security-operations account placement;
- Security Hub and GuardDuty trusted access;
- delegated-administrator registration;
- Security Hub V2 `SECURITYHUB_POLICY` prerequisites;
- required IAM Identity Center groups, permission sets, and assignments.

Use:

```bash
./scripts/validation/validate-control-plane.sh
```

For generated evidence, use the **Export Control Plane Evidence** workflow.

---

## Summary

The control plane provides the stable governance foundation for `tf-secure-baseline`: protected Terraform state, CI/CD identities, AWS Organizations structure, centralized-security prerequisites, and IAM Identity Center access. Workload and security-service implementation remain in their respective accounts so foundational governance is isolated from day-to-day infrastructure changes.