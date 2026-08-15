# Identity Center Module

## Overview

The `modules/identity_center` module creates IAM Identity Center groups, permission sets, policy attachments, and account assignments for one target AWS account.

It is a reusable persona module: the caller decides which SecOps personas are enabled, supplies their group names, and identifies the account that receives each assignment.

The control-plane Identity Center stack currently uses this module for:

- workload `SecOps-Operator` access in `dev`, `staging`, and `prod`;
- optional workload Analyst and Engineer access;
- required `SecOps-Administrator` access in the security-operations account;
- optional security-operations Analyst and Engineer access.

---

## What the Module Manages

When the corresponding persona is enabled, the module can create:

- `aws_identitystore_group`
- `aws_ssoadmin_permission_set`
- AWS-managed permission-set policy attachments
- customer-managed permission-set policy attachments
- inline permission-set policies
- `aws_ssoadmin_account_assignment`

The module discovers the existing IAM Identity Center instance and identity store with `aws_ssoadmin_instances`.

It does **not** create:

- the IAM Identity Center instance;
- users or group membership;
- customer-managed IAM policies referenced by permission sets;
- workload EventBridge buses;
- AWS accounts or Organizations structure.

---

## Persona Model

| Persona | Default | Session | Primary permissions |
|---|---:|---:|---|
| `SecOps-Administrator` | Disabled | 2 hours | AWS-managed `AdministratorAccess` |
| `SecOps-Operator` | Enabled | 2 hours | EventBridge discovery plus `DescribeEventBus` / `PutEvents` on the configured SecOps bus |
| `SecOps-Analyst` | Disabled | 4 hours | `SecurityAudit`, `ReadOnlyAccess`, and configured log-read policies |
| `SecOps-Engineer` | Disabled | 4 hours | Analyst-style visibility plus limited Security Hub and EC2 response actions |

The caller supplies the actual Identity Center group display names. This module does not impose fixed default group names.

### SecOps-Administrator

When enabled, the module creates:

- the configured Administrator group;
- permission set `SecOps-Administrator-${environment}`;
- AWS-managed `AdministratorAccess` attachment;
- an account assignment for the configured `account_id`.

This persona is disabled by default and is enabled explicitly by the control-plane stack for the dedicated security-operations account.

### SecOps-Operator

When enabled, the module creates permission set:

```text
SecOps-Operator-${environment}
```

Its inline policy allows:

- `events:ListEventBuses` across EventBridge;
- `events:DescribeEventBus` and `events:PutEvents` on the configured `secops_event_bus_arn`.

`secops_event_bus_arn` is required whenever Operator access is enabled.

The Operator persona is intended for controlled event submission rather than direct EC2 or Lambda administration.

### SecOps-Analyst

When enabled, the Analyst permission set receives:

- AWS-managed `SecurityAudit`;
- AWS-managed `ReadOnlyAccess`;
- the configured centralized-logs S3 read-only customer-managed policy;
- the configured logs KMS decrypt customer-managed policy.

Both customer-managed policy names are required when Analyst access is enabled.

### SecOps-Engineer

When enabled, the Engineer permission set receives:

- AWS-managed `SecurityAudit`;
- AWS-managed `ReadOnlyAccess`;
- the configured centralized-logs S3 read-only customer-managed policy;
- the configured logs KMS decrypt customer-managed policy;
- an inline response policy.

The inline policy currently permits:

```text
securityhub:BatchUpdateFindings
ec2:CreateTags
ec2:ModifyInstanceAttribute
ec2:ReplaceIamInstanceProfileAssociation
ec2:AssociateIamInstanceProfile
ec2:DisassociateIamInstanceProfile
```

Both customer-managed policy names are required when Engineer access is enabled.

---

## Customer-Managed Policy References

Analyst and Engineer roles reference existing IAM policies by **name and path** through IAM Identity Center customer-managed policy attachments.

The module does not create these IAM policies. The referenced policy must already exist in the target account before AWS can successfully provision an enabled permission set attachment.

The default policy path is:

```text
/
```

This design avoids a Terraform dependency from the control plane into workload remote state while still allowing workload-specific policies to be attached centrally.

---

## Inputs

| Name | Type | Default | Requirement |
|---|---|---|---|
| `environment` | `string` | required | Suffix used in permission-set names. |
| `account_id` | `string` | required | Target AWS account for assignments. |
| `secops_event_bus_arn` | `string` | `null` | Required when `enable_secops_operator = true`. |
| `enable_secops_analyst` | `bool` | `false` | Enables Analyst resources. |
| `enable_secops_engineer` | `bool` | `false` | Enables Engineer resources. |
| `enable_secops_operator` | `bool` | `true` | Enables Operator resources. |
| `enable_secops_administrator` | `bool` | `false` | Enables Administrator resources. |
| `secops_analyst_group_name` | `string` | `null` | Required when Analyst is enabled. |
| `secops_engineer_group_name` | `string` | `null` | Required when Engineer is enabled. |
| `secops_operator_group_name` | `string` | `null` | Required when Operator is enabled. |
| `secops_administrator_group_name` | `string` | `null` | Required when Administrator is enabled. |
| `logs_s3_readonly_policy_name` | `string` | `null` | Required when Analyst or Engineer is enabled. |
| `logs_cmk_decrypt_policy_name` | `string` | `null` | Required when Analyst or Engineer is enabled. |
| `customer_managed_policy_path` | `string` | `/` | Path used for customer-managed policy references. |

The module validates role-dependent inputs, but environment names and account-ID formats are intentionally left to the calling stack. The control-plane Identity Center stack adds stricter validation for its workload and security-operations inputs.

---

## Usage

### Workload Operator example

```hcl
module "identity_center_workload" {
  source = "../../../modules/identity_center"

  account_id  = "0123456789012"
  environment = "dev"

  enable_secops_operator     = true
  secops_operator_group_name = "SecOps-Operator-Dev"
  secops_event_bus_arn       = "arn:aws:events:us-east-1:0123456789012:event-bus/secops-bus"

  enable_secops_analyst  = false
  enable_secops_engineer = false
}
```

### Security-operations Administrator example

```hcl
module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = "0123456789012"
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"

  enable_secops_operator = false
}
```

---

## Outputs

### `permission_set_arns`

Returns only the permission sets that are enabled for the module instance:

```hcl
{
  "secops-administrator" = "..." # when enabled
  "secops-operator"      = "..." # when enabled
  "secops-analyst"       = "..." # when enabled
  "secops-engineer"      = "..." # when enabled
}
```

---

## Deployment Dependencies

IAM Identity Center must already be enabled and accessible from the account running this module.

For workload deployments:

- Operator access can be created before the actual SecOps EventBridge bus exists because the ARN is used to scope the inline policy.
- Analyst and Engineer roles should remain disabled until their referenced customer-managed log-access policies exist in the target account.

For the security-operations deployment, the current control-plane stack enables Administrator access and disables Operator access.

---

## Validation

The module itself does not perform an end-user login test. The control-plane validator checks the expected Identity Center groups, permission sets, and account assignments created through the control-plane stack.

Effective human access should still be verified through an IAM Identity Center login and role-assumption test when performing release or client-readiness validation.

---

## Security Considerations

- Identity Center provides short-lived federated AWS sessions rather than requiring long-lived IAM user credentials for these personas.
- Permissions are separated by persona and enabled explicitly.
- The Operator role is scoped to an EventBridge workflow rather than direct infrastructure modification.
- Analyst and Engineer customer-managed policies are resolved in the target account by name and path.
- Administrator access is intentionally opt-in and should be limited to accounts where full administrative access is required.

---

## Limitations

- The module does not provision or synchronize users.
- The module does not manage external IdP federation, SCIM, or conditional-access policy.
- The module does not create the customer-managed policies used by Analyst or Engineer roles.
- The module does not validate that an EventBridge bus exists before creating an Operator policy that references its ARN.
- Account-specific naming and persona policy are determined by the calling stack.