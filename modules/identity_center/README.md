# Identity Center Module

## Purpose and ownership boundary

The `modules/identity_center` module manages only the IAM Identity Center access needed by the baseline's operational contracts: workload `SecOps-Operator` and security-operations `SecOps-Administrator`. A caller enables the appropriate persona, supplies the group display name, and selects the target AWS account.

**Customer workforce identities and permissions are customer-managed.** This module does not create generic security-analyst or security-engineer groups, permission sets, attachments, or account assignments. Organizations should grant investigative and response access through their own identity governance and access reviews.

The control-plane caller in [`bootstrap/control_plane/identity_center`](../../bootstrap/control_plane/identity_center/README.md) creates Operator access for `dev`, `staging`, and `prod`, and Administrator access for the dedicated `security-operations` account.

## Resources and prerequisites

For enabled personas, this module manages Identity Center groups (`aws_identitystore_group`), permission sets (`aws_ssoadmin_permission_set`), policy attachments/inline policy, and account assignments (`aws_ssoadmin_account_assignment`). It does not manage users, group membership, external IdP/SCIM configuration, the Identity Center instance, Organizations, AWS accounts, workload EventBridge buses, or customer workforce roles.

The module discovers an existing Identity Center instance through `aws_ssoadmin_instances` and selects the first ARN and identity-store ID. It does not provide an instance selector or reject multiple results; verify the administrative account and Identity Center Region before deployment. `account_id` identifies the assignment destination, not an AWS provider role switch.

## Baseline-managed personas

| Persona | Default | Session | Managed authority |
|---|---|---|---|
| `SecOps-Operator` | Enabled | 2 hours | EventBridge bus discovery and event publication on the configured workload SecOps bus |
| `SecOps-Administrator` | Disabled | 2 hours | AWS-managed `AdministratorAccess` for the security-operations account |

### SecOps-Operator

When enabled, the module creates the supplied Operator group, a `SecOps-Operator-${environment}` permission set, its inline policy, and an account assignment.

The inline policy permits `events:ListEventBuses` with `Resource = "*"` and scopes `events:DescribeEventBus` / `events:PutEvents` to the supplied `secops_event_bus_arn`. The bus ARN is required for Operator access. The module accepts this ARN without verifying its existence or matching the workload bus resource policy.

The control-plane root constructs the bus ARN using the provider's AWS partition, the workload account ID, Region, `cloud_name`, and environment. The workload bus policy separately restricts `custom.rollback` publication to matching Identity Center Operator role ARNs and explicitly denies nonmatching publishers. Neither the Operator policy nor the Lambda independently authenticates caller-supplied approver/ticket metadata. Validate both successful authorized publication and denied unauthorized publication before relying on rollback.

### SecOps-Administrator

When enabled, the module creates the supplied Administrator group, a `SecOps-Administrator-${environment}` permission set, an `AdministratorAccess` attachment, and an account assignment. The control-plane root enables it for the dedicated security-operations account only and sets `enable_secops_operator = false` there.

Administrator access is broad, including delegated-administration consequences. Assignment and group membership must be separately reviewed.

## Inputs

| Input | Type | Default | Meaning |
|---|---|---|---|
| `environment` | `string` | required | Permission-set naming suffix |
| `account_id` | `string` | required | Target account receiving the assignment |
| `secops_event_bus_arn` | `string` | `null` | Required if Operator is enabled |
| `enable_secops_operator` | `bool` | `true` | Manage the workload rollback Operator persona |
| `secops_operator_group_name` | `string` | `null` | Required, nonblank if Operator is enabled |
| `enable_secops_administrator` | `bool` | `false` | Manage Administrator access |
| `secops_administrator_group_name` | `string` | `null` | Required, nonblank if Administrator is enabled |

The two persona flags are independent; an Administrator-only caller must explicitly disable Operator. The module validates the dependent group-name and bus-ARN inputs but does not validate the account ID's length, the environment's spelling, or existence/ownership of the event bus. A bare call with only `environment` and `account_id` is insufficient because Operator defaults to enabled.

## Example usage

A workload caller:

```hcl
module "identity_center_workload" {
  source = "../../../modules/identity_center"

  account_id  = "333333333333"
  environment = "dev"

  enable_secops_operator     = true
  secops_operator_group_name = "SecOps-Operator-Dev"
  secops_event_bus_arn       = "arn:aws:events:us-east-1:333333333333:event-bus/tf-secure-baseline-dev-secops-bus"
}
```

A security-operations caller:

```hcl
module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = "222222222222"
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"
  enable_secops_operator          = false
}
```

## Outputs and validation

`permission_set_arns` is the sole module output. It contains `secops-operator` and/or `secops-administrator` keys only when enabled. It does not return group principals, membership, policies, assignment principal IDs, or session evidence.

The [control-plane validator](../../scripts/validation/validate-control-plane.sh) checks named baseline groups, output-backed permission-set existence, and the presence of account assignments. It does not check group membership, exact assignment principals, complete effective permissions, user login, or the live bus ARN/policy pairing. `STRICT_IDENTITY_CENTER_ASSIGNMENTS=true` makes absent assignments a failure but is not a full authorization audit.

Workload Operator permission sets can be deployed before the actual workload EventBridge buses because the ARN is used as a policy resource without live lookup. Verify the deployed bus and actual authorized session afterward. Access should not be represented as operationally qualified solely because Terraform provisioned a permission set.

## Breaking-change and migration boundary

Previous module versions optionally managed `SecOps-Analyst` and `SecOps-Engineer` workforce personas. Their Terraform resources, configuration inputs, and output keys have been removed. If those personas were enabled in an existing state, a normal Terraform plan will propose removing their groups, assignments, and permission sets. This is **access revocation**, not a documentation-only change.

Before applying a removal plan, inventory live assignments and principals, arrange replacement customer-owned access if required, and review the complete control-plane plan. Do not destroy the shared Identity Center root when retiring one workload. Workload-created centralized-log read and decrypt IAM policies remain available for separately governed customer access; they are no longer attached here.

This module does not enforce MFA, privileged session approval, conditional access, or membership provisioning. Identity Center configuration does not replace the organization's access-governance procedures.
