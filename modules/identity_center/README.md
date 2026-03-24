# Identity Center Module

## Overview

The `identity_center` module implements centralized, role-based access control for AWS accounts using AWS IAM Identity Center (SSO).

This module enables:

- Centralized workforce authentication via IAM Identity Center
- Role-based access using permission sets
- Group-based access management
- Least-privilege access aligned with security operations workflows
- Integration with existing IAM policies and security controls

This replaces the use of long-lived IAM users with short-lived, federated access.

---

## Architecture

The access model is structured as follows:

1. IAM Identity Center instance is discovered:
- `aws_ssoadmin_instances`

2. Security groups are created or referenced:
- `aws_identitystore_group`

3. Permission sets define access levels:
- `aws_ssoadmin_permission_set`

4. Policies are attached:
- AWS-managed policies (e.g., `SecurityAudit`, `ReadOnlyAccess`)
- Customer-managed policies (e.g., logs access, rollback trigger)
- Inline policies for specific actions

5. Groups are assigned to AWS accounts:
- `aws_ssoadmin_account_assignment`

6. IAM Identity Center provisions roles automatically:
- `AWSReservedSSO_<PermissionSetName>_<random>`

---

## Features

- **Centralized Authentication**
  - Eliminates IAM users in favor of SSO-based login

- **Role-Based Access Control (RBAC)**
  - Permission sets define access levels per persona

- **Group-Based Access Management**
  - Users are assigned to groups instead of roles directly

- **Least-Privilege Design**
  - Permissions scoped to operational responsibilities

- **Policy Reuse**
  - Integrates with existing customer-managed IAM policies

- **Separation of Duties**
  - Distinct roles for analysts, engineers, and operators

---

## Default Security Groups

This module defines three baseline groups:

- `SecOps-Analysts`
- `SecOps-Engineers`
- `SecOps-Operators`

These represent a **basic starting point** for security operations access control.

> These groups are intentionally simple and should be extended or modified based on organizational needs, team structure, and compliance requirements.

---

## Access Model

### SecOps-Analyst
- Read-only access to security telemetry and logs
- Attached policies:
  - `SecurityAudit`
  - `ReadOnlyAccess`
  - `Centralized Logs` S3 read access
  - `logs` KMS decrypt access

### SecOps-Engineer
- Investigation and response capabilities
- Includes:
  - All Analyst permissions
  - Security Hub updates
  - EC2 response actions (tagging, instance modification, etc.)

### SecOps-Operator
- Limited to operational actions (e.g., rollback trigger)
- Scoped permissions:
  - EventBridge `PutEvents` to security operations bus

---

## Resources Created

- `aws_identitystore_group`
- `aws_ssoadmin_permission_set`
- `aws_ssoadmin_managed_policy_attachment`
- `aws_ssoadmin_customer_managed_policy_attachment`
- `aws_ssoadmin_permission_set_inline_policy`
- `aws_ssoadmin_account_assignment`

---

## Requirements

- IAM Identity Center must be enabled in the AWS account

- The AWS account must be accessible via Identity Center

- Customer-managed IAM policies must already exist in the account:
  - Logs S3 read policy
  - Logs KMS decrypt policy
  - Rollback trigger policy

- Users must be created in Identity Center and assigned to groups after running `terraform apply`
  - This module manages groups and permission sets; it does not provision users

---

## Usage

### Example

```hcl
module "identity_center" {
  source = "./modules/identity_center"

  account_id = data.aws_caller_identity.current.account_id

  secops_analyst_group_name  = "SecOps-Analysts"
  secops_engineer_group_name = "SecOps-Engineers"
  secops_operator_group_name = "SecOps-Operators"

  logs_s3_readonly_policy_name        = module.iam.logs_s3_readonly_policy_name
  logs_cmk_decrypt_policy_name        = module.iam.logs_kms_decrypt_policy_name
  secops_rollback_trigger_policy_name = module.iam.secops_rollback_trigger_policy_name

  customer_managed_policy_path = "/"
  secops_event_bus_arn         = module.automation.secops_event_bus_arn
}
```

---

### Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `account_id` | AWS account ID for assignments | `string` | n/a |
| `secops_analyst_group_name` | SecOps Analyst group display name | `string` | n/a |
| `secops_engineer_group_name` | SecOps Engineer Group display name | `string` | n/a |
| `secops_operator_group_name` | SecOps Operator Group display name | `string` | n/a |
| `logs_s3_readonly_policy_name` | IAM policy name for Centralized Logs S3 read access | `string` | n/a |
| `logs_cmk_decrypt_policy_name` | IAM policy name for 'logs' CMK decrypt | `string` | n/a |
| `secops_rollback_trigger_policy_name` | IAM policy name for rollback trigger | `string` | n/a |
| `customer_managed_policy_path` | Path for IAM policies | `string` | `"/"` |
| `secops_event_bus_arn` | ARN of the Security Operations EventBridge bus | `string` | n/a |

---

### Outputs

| Name | Description |
|------|-------------|
| `permission_set_arns` | ARNs of created permission sets |

---

## Validation

To confirm the module is working:

  1. Log into IAM Identity Center portal:
    - `https://<your-org>.awsapps.com/start
  
  2. Verify access:
    - SecOps-Analyst sees read-only data
    - SecOps-Engineer can perform response actions
    - SecOps-Operator can trigger rollback only

  3. Confirm IAM roles exist:
    - Navigate to `IAM` ➔ `Roles`
    - Locate `AWSReservedSSO_SecOps-*` roles
  
  4. Test access via CLI:
    ```bash
    aws sts get-caller-identity --profile <profile-name>
    ```

    > Example:
      ```bash
      aws sts get-caller-identity --profile analyst
      ```

    > Note:
      - `<profile-name>` is the local AWS CLI profile configured via `aws configure sso`
      - This profile is mapped to the IAM Identity Center permission set (i.e., `SecOps-Analyst`)
  
  5. Validate permissions:
    - SecOps-Analyst:
      - Can view logs and findings
      - Cannot modify resources
    
    - SecOps-Engineer:
      - Can update findings and modify EC2 instances

    - SecOps-Operator:
      - Can publish events to EventBridge Rollback bus only

---

## Security Considerations

- Access is granted via short-lived, federatred sessions (no static access keys)
- Eliminates long-lived IAM user credentials
- Enforces least-privilege access via permission sets
- Uses short-lived credentials via SSO
- Integrates with KMS-encrypted resources securely
- Supports centralized audit and access control

---

## Limitations

- Groups are basic and may not reflect real organizational structure
- No external IdP integration (Okta, Entra ID, etc.) in this module
- No automated user provisioning
- No session tagging or advanced conditional access controls

---

## Future Enhancements

- External IdP federation (Okta / Entra ID)
- Automated user provisioning
- Attribute-based access control (ABAC)
- Session tagging for fine-grained access control
- Cross-account access patterns
- Just-in-Time (JIT) access workflows

---

## Summary

This module provides a centralized, scalable, and secure access control model for AWS environments.

It replaces IAM users with a modern SSO-based approach, enforces the least privilege principle, and establishes a strong foundation for enterprise-grade identity and access management.