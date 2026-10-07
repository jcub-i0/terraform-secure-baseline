# Identity Center Module

## Overview

The `modules/identity_center` module creates IAM Identity Center groups, permission sets, policy attachments, and account assignments for one target AWS account.

It is a reusable persona module: the caller decides which SecOps personas are enabled, supplies their group names, and identifies the account that receives each assignment.

See [main.tf](main.tf), [variables.tf](variables.tf), and [outputs.tf](outputs.tf). The target `account_id` is an assignment destination; it does not switch AWS provider credentials into that account.

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

The module discovers the existing IAM Identity Center instance and identity store with `aws_ssoadmin_instances`, using the caller's AWS provider context. It selects element `[0]` from each returned ARN/identity-store collection. There is no configurable instance selector or explicit exactly-one-instance guard in this module. Establish the intended existing organization instance and its Region before deployment; do not assume an arbitrary multi-instance response is unambiguous.

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
| `SecOps-Engineer` | Disabled | 4 hours | Analyst-style visibility plus the six listed response actions on `Resource = "*"` |

The caller supplies the actual Identity Center group display names. This module does not impose fixed default group names. Permission-set names use the persona and `environment`, not the group display name. For example, a `SecOps-Operator-Dev` group can be assigned `SecOps-Operator-dev`.

The persona flags are independent: enabling Administrator does not disable the default-enabled Operator. Administrator-only callers must explicitly set `enable_secops_operator = false`. Session durations are fixed in the resource definitions, not exposed as module inputs.

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

The Operator persona is intended for controlled event submission rather than direct EC2 or Lambda administration. Its inline grant has no condition on `events:source`, detail type, payload, approval record, or workflow identity. The configured bus ARN limits the `DescribeEventBus` / `PutEvents` identity-policy grant to that resource; it is not proof that a submitted event was approved or that other resource policies enforce Operator-only access.

The built-in control-plane caller constructs `event-bus/secops-bus`, whereas RC1 workload automation creates `<name_prefix>-secops-bus`. See the [root's exact bus-identity boundary](../../bootstrap/control_plane/identity_center/README.md#operator-bus-identity). This module accepts the supplied ARN; it neither discovers nor repairs that mismatch.

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

All six actions share one unconditional `Allow` statement with `Resource = "*"`. The module does not restrict them by instance ID, resource tag, environment prefix, or approval state, and does not set a permission-set permissions boundary. `iam:PassRole` is not granted by this inline policy. Do not infer that every profile-association action will therefore succeed, or describe the persona as narrowly resource-scoped; effective access depends on all applicable policies and AWS requirements.

Both customer-managed policy names are required when Engineer access is enabled. Analyst and Engineer also attach AWS-managed policies by ARN rather than freezing their policy documents in this repository; inspect their effective deployed contents during access review.

---

## Customer-Managed Policy References

Analyst and Engineer roles reference existing IAM policies by **name and path** through IAM Identity Center customer-managed policy attachments.

The module does not create these IAM policies. The referenced policy must already exist in the target account before AWS can successfully provision an enabled permission set attachment.

The default policy path is:

```text
/
```

This design avoids a Terraform dependency from the control plane into workload remote state while still allowing workload-specific policies to be attached centrally. Matching names/paths do not establish equivalent policy contents across accounts. Review the actual policy documents in each target account; these attachments are additive grants, not a boundary limiting the AWS-managed policies.

AWS requires the matching policy name/path in each assigned target account; see [CustomerManagedPolicyReference](https://docs.aws.amazon.com/singlesignon/latest/APIReference/API_CustomerManagedPolicyReference.html). The module does not copy or create the referenced policies.

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

The module validates role-dependent inputs, but its `environment` and `account_id` variables have no name/12-digit validation. Enabled persona group names must be nonblank. The bus ARN and required log-policy-name validations reject `null`; they do not prove ARN syntax, existence, ownership, or nonblank policy content. The path check rejects an empty string, not every invalid IAM path. The control-plane caller adds its own input checks; AWS/provider validation can reject additional invalid values.

All fourteen inputs are listed above. Operator defaults to enabled but its group name and bus ARN default to `null`, so a bare module call with only `environment` and `account_id` is not a complete valid configuration.

---

## Usage

### Workload Operator example

These are caller examples placed at `bootstrap/control_plane/identity_center`, which explains the relative `source` path. The IDs are synthetic 12-digit examples. Supply the existing Identity Center provider context and actual target account/ARN. This standalone example supplies the **prefixed workload bus**; it is not a claim that the frozen root already constructs that value.

```hcl
module "identity_center_workload" {
  source = "../../../modules/identity_center"

  account_id  = "333333333333"
  environment = "dev"

  enable_secops_operator     = true
  secops_operator_group_name = "SecOps-Operator-Dev"
  secops_event_bus_arn       = "arn:aws:events:us-east-1:333333333333:event-bus/tf-secure-baseline-dev-secops-bus"

  enable_secops_analyst  = false
  enable_secops_engineer = false
}
```

### Security-operations Administrator example

```hcl
module "identity_center_secops" {
  source = "../../../modules/identity_center"

  account_id  = "222222222222"
  environment = "secops"

  enable_secops_administrator     = true
  secops_administrator_group_name = "SecOps-Administrator"

  enable_secops_operator = false
}
```

---

## Outputs

### `permission_set_arns`

Returns only the permission sets that are enabled for the module instance. Disabled keys are absent, not present with `null`. This is the sole module output; it does not return the instance ID, group IDs, account-assignment principals, or policy documents:

Illustrative map value:

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

The assignment resources have explicit dependencies on AWS-managed attachments and, for Operator/Engineer, the respective inline policy. Analyst/Engineer assignment dependencies do **not** explicitly include the customer-managed log-policy attachments. Do not describe the graph as a universal “all attachments complete before assignment” barrier. Review provisioning errors and the resulting live permission set/assignment before accepting access.

Disabling a persona or removing the calling module plans removal of its group, permission set, policy attachments, and assignment. User/group-membership management remains external. For workload retirement, coordinate optional role/attachment removal through the [production retirement procedure](../../docs/production-retirement.md); do not tear down the entire Identity Center root while other workloads still depend on it.

---

## Validation

The module itself does not perform an end-user login test. The [control-plane validator](../../scripts/validation/validate-control-plane.sh) checks named groups, describes permission-set ARNs returned by the root outputs, and checks that each queried account/permission-set pair has at least one assignment. It does not compare the assignment's principal ID/type to the Terraform-created group or reject all unexpected assignments. A group-presence check is likewise not membership validation.

That validator does not compare the complete inline/managed/customer-managed policy contents, configured session durations, or exact Operator bus ARN as part of its Identity Center checks. `STRICT_IDENTITY_CENTER_ASSIGNMENTS=true` makes a missing assignment a failure; it does not turn the count check into exact principal/policy validation. Optional group checks additionally require `CHECK_OPTIONAL_SECOPS_GROUPS=true` when desired.

Effective human access should still be verified through an IAM Identity Center login and role-assumption test when performing release or client-readiness validation.

---

## Security Considerations

- Identity Center provides short-lived federated AWS sessions rather than requiring long-lived IAM user credentials for these personas.
- Personas have distinct policies. Operator is enabled by default; Administrator, Analyst, and Engineer require opt-in.
- The Operator inline grant scopes Describe/Put actions to the supplied EventBridge bus ARN, without an approval or event-payload condition.
- Analyst and Engineer customer-managed policies are resolved in the target account by name and path.
- Administrator access is intentionally opt-in and should be limited to accounts where full administrative access is required.

---

## Limitations

- The module does not provision or synchronize users.
- The module does not manage external IdP federation, SCIM, or conditional-access policy.
- The module does not create the customer-managed policies used by Analyst or Engineer roles.
- The module does not validate that an EventBridge bus exists before creating an Operator policy that references its ARN.
- Account-specific naming and persona policy are determined by the calling stack.
- Permission sets and policy references are not proof of approved group membership, effective access, or successful rollback.
- Commercial-partition `arn:aws:` policy ARNs are hard-coded in this module; it is not a partition-generic implementation.
- The module does not configure MFA requirements, a permission boundary, approval enforcement, or a universal resource-tag restriction for these personas.
