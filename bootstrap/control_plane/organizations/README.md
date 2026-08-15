# 🏢 AWS Organizations (`bootstrap/control_plane/organizations`)

## Purpose

This Terraform root manages the AWS Organizations structure used by `tf-secure-baseline` and the management-account prerequisites required for centralized Security Hub and GuardDuty administration.

It runs in the AWS Organizations management (`control-plane`) account.

---

## Scope

### This stack manages

- The AWS Organization in `ALL` features mode.
- Organizational Units:
  - `Workloads`
  - `NonProd` under `Workloads`
  - `Prod` under `Workloads`
  - `Security` at the organization root
- Security Hub trusted service access when delegated administration is enabled.
- The `security-operations` account as Security Hub delegated administrator when enabled.
- GuardDuty trusted service access when delegated administration is enabled.
- GuardDuty Malware Protection trusted service access.
- The `security-operations` account as GuardDuty delegated administrator when enabled.
- Security Hub V2 organization-management prerequisites when enabled:
  - the `SECURITYHUB_POLICY` organization policy type;
  - the `securityhubv2.amazonaws.com` service-linked role;
  - an AWS Organizations resource policy allowing the security-operations account to manage Security Hub organization policies.

### This stack does not manage

- AWS account creation or account invitations.
- Workload or security-operations account placement operations.
- Service Control Policies (SCPs).
- Security Hub CSPM configuration policies or workload associations.
- GuardDuty organization protection-plan settings.
- The Security Hub V2 workload organization policy itself.
- Workload infrastructure.

Delegated administrator-side security configuration belongs to:

```text
bootstrap/security_operations/security_services
```

---

## Organization Structure

The managed OU hierarchy is:

```text
Root
├── Workloads
│   ├── NonProd
│   └── Prod
└── Security
```

The expected account placement is:

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

The OU resources are Terraform-managed. Account creation and placement are intentionally outside this stack; control-plane validation verifies the expected live placement.

---

## AWS Organization Ownership

The organization is represented by:

```hcl
resource "aws_organizations_organization" "main" {
  feature_set = "ALL"

  lifecycle {
    prevent_destroy = true
  }
}
```

`prevent_destroy` protects the organization from accidental Terraform destruction.

The resource also ignores direct drift in `aws_service_access_principals` because trusted service access is managed through dedicated `aws_organizations_aws_service_access` resources rather than the aggregate organization attribute.

If adopting this stack into an AWS Organization that already exists outside Terraform state, import the existing organization before applying changes. Do not attempt to create a duplicate organization.

---

## Centralized Security Prerequisites

### Security Hub CSPM

When `enable_securityhub_delegated_administrator = true`, this stack:

1. enables AWS Organizations trusted access for `securityhub.amazonaws.com`;
2. designates the existing `security-operations` account as the Security Hub delegated administrator.

The Security Hub CSPM organization configuration and per-workload configuration policies are managed from the security-operations account, not here.

### GuardDuty

When `enable_guardduty_delegated_administrator = true`, this stack:

1. enables AWS Organizations trusted access for `guardduty.amazonaws.com`;
2. designates the existing `security-operations` account as GuardDuty delegated administrator.

Trusted service access for:

```text
malware-protection.guardduty.amazonaws.com
```

is also enabled to support centralized GuardDuty EBS Malware Protection.

GuardDuty organization enrollment and protection-plan configuration are managed from the security-operations account.

### Security Hub V2

When `enable_securityhub_v2_organization_management = true`, this stack enables the management-account prerequisites for Security Hub V2 organization policy management:

- `SECURITYHUB_POLICY` is enabled as an Organizations policy type;
- the Security Hub V2 service-linked role is created;
- an Organizations resource policy grants the security-operations account the read and policy-management permissions required for `SECURITYHUB_POLICY` resources.

The Security Hub V2 organization policy attached to the `Workloads` OU is created by `bootstrap/security_operations/security_services`.

---

## Security-Operations Account Requirement

The delegated-administrator resources resolve an existing AWS Organizations account named:

```text
security-operations
```

The name can be changed with `security_operations_account_name`, but the target account must already exist in the organization before centralized security administration is enabled.

This stack does not create that account.

---

## Inputs

| Variable | Type | Default | Purpose |
|---|---|---:|---|
| `enable_securityhub_delegated_administrator` | `bool` | `false` | Enables Security Hub trusted access and delegated-administrator registration. |
| `security_operations_account_name` | `string` | `security-operations` | Organization account name used for centralized security administration. |
| `enable_guardduty_delegated_administrator` | `bool` | `false` | Enables GuardDuty trusted access and delegated-administrator registration. |
| `enable_securityhub_v2_organization_management` | `bool` | `false` | Enables the Organizations prerequisites for centralized Security Hub V2 policy management. |

The feature flags default to `false` so the organization can be adopted and the delegated administrator account prepared before centralized security governance is enabled.

---

## Outputs

| Output | Purpose |
|---|---|
| `organization_id` | AWS Organizations organization ID. |
| `organization_root_id` | Organization root ID. |
| `organizational_unit_ids` | IDs for `Workloads`, `NonProd`, `Prod`, and `Security`. |
| `security_operations_account_id` | Resolved account ID for the security-operations account. |
| `central_security_features_enabled` | Effective centralized-security prerequisite feature flags. |
| `delegated_administrator_account_ids` | Security Hub and GuardDuty delegated-administrator account IDs when configured. |

---

## Validation

The control-plane validator owns validation of this layer, including:

- AWS Organizations `ALL` features mode;
- root and OU topology;
- expected account identity and placement;
- Security Hub and GuardDuty trusted service access;
- delegated-administrator registration;
- `SECURITYHUB_POLICY` enablement when Security Hub V2 organization management is enabled.

Run:

```bash
./scripts/validation/validate-control-plane.sh
```

The **Export Control Plane Evidence** workflow produces the corresponding read-only evidence package.

---

## Future Enhancements

Potential future governance extensions include:

- Service Control Policies (SCPs);
- automated account vending or placement;
- additional organization policy types;
- broader centralized governance controls.