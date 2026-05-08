# IAM Module

## Overview

The `iam` module provisions IAM roles, instance profiles, service roles, and shared policies used across the baseline.

This module supports:

- EC2 instance access to SSM and CloudWatch
- Lambda execution roles for security automation
- CloudTrail delivery to CloudWatch Logs
- VPC Flow Logs delivery to CloudWatch Logs
- CloudWatch Logs delivery to Kinesis Firehose
- Firehose delivery to centralized S3 logs
- AWS Config service and remediation roles
- AWS Backup service role
- SSM Patch Manager maintenance window role
- EventBridge role for SecOps event bus publishing
- IAM Access Analyzer
- Shared read-only log access policies
- Break-glass administrator access

This module is intentionally broad because many other modules depend on IAM roles and policies before they can function correctly.

---

## Purpose

The purpose of this module is to provide least-privilege service roles and shared access policies required by the secure baseline.

It supports:

- Secure EC2 instance management
- Security automation Lambda execution
- Centralized logging delivery
- AWS Config recording and remediation
- Backup and restore operations
- Patch management operations
- Security event routing
- Emergency administrative access
- Read-only access to centralized logs
- KMS decrypt access for logs analysis

This module does not manage IAM Identity Center permission sets. Identity Center access is managed separately in the control-plane Identity Center stack.

---

## Resources Created

### EC2 Instance Role and Instance Profile

Creates an EC2 IAM role:

```hcl
resource "aws_iam_role" "ec2_role"
```

Creates an EC2 instance profile:

```hcl
resource "aws_iam_instance_profile" "ec2_profile"
```

Attached AWS-managed policies:

| Policy | Purpose |
|---|---|
| `AmazonSSMManagedInstanceCore` | Allows EC2 instances to register with Systems Manager |
| `CloudWatchAgentServerPolicy` | Allows EC2 instances to publish logs and metrics to CloudWatch |

The instance profile is consumed by the `compute` module.

---

### Lambda Execution Roles

Creates execution roles and custom policies for the baseline automation Lambdas.

Lambda roles include:

| Role | Purpose |
|---|---|
| EC2 Isolation Lambda role | Allows automated EC2 isolation actions |
| EC2 Rollback Lambda role | Allows manual rollback of isolated EC2 instances |
| IP Enrichment Lambda role | Allows Security Hub finding enrichment with threat intelligence |

The Lambda roles use AWS-managed policies for:

- Lambda basic execution logging
- Lambda VPC ENI access
- AWS X-Ray write access

Custom Lambda policies allow the functions to perform only the baseline-specific actions they need.

---

### EC2 Isolation Lambda Permissions

The EC2 Isolation Lambda policy allows:

- Describing EC2 instances
- Modifying EC2 instance security group attachments
- Describing security groups
- Creating tags
- Creating snapshots
- Publishing alerts to the SecOps SNS topic
- Using the logs CMK for encrypted SNS publishing

This role is used by the EC2 isolation automation workflow.

---

### EC2 Rollback Lambda Permissions

The EC2 Rollback Lambda policy allows:

- Describing EC2 instances
- Modifying EC2 instance security group attachments
- Describing security groups
- Creating tags
- Publishing alerts to the SecOps SNS topic
- Using the logs CMK for encrypted SNS publishing

This role is used to restore original instance security groups after an approved rollback event.

---

### IP Enrichment Lambda Permissions

The IP Enrichment Lambda policy allows:

- Reading the threat intelligence API key secret from Secrets Manager
- Decrypting the secret with the Secrets Manager CMK
- Publishing enriched alerts to the SecOps SNS topic
- Using the logs CMK for encrypted SNS publishing
- Updating Security Hub findings with enrichment notes

This role is used by the Security Hub finding enrichment workflow.

---

### CloudTrail Role

Creates a CloudTrail role:

```hcl
resource "aws_iam_role" "cloudtrail"
```

This role allows CloudTrail to write events to the CloudTrail CloudWatch Log Group.

Allowed CloudWatch Logs actions include:

- `logs:CreateLogStream`
- `logs:PutLogEvents`

The logging module consumes this role ARN.

---

### VPC Flow Logs Role

Creates a VPC Flow Logs role:

```hcl
resource "aws_iam_role" "flowlogs"
```

This role allows VPC Flow Logs to write to the VPC Flow Logs CloudWatch Log Group.

Allowed CloudWatch Logs actions include:

- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`
- `logs:DescribeLogGroups`
- `logs:DescribeLogStreams`

The logging module consumes this role ARN.

---

### CloudWatch Logs to Firehose Role

Creates a role for CloudWatch Logs subscription delivery to Firehose:

```hcl
resource "aws_iam_role" "cw_to_firehose"
```

This role allows CloudWatch Logs to send VPC Flow Log records to the Firehose delivery stream.

Allowed Firehose actions include:

- `firehose:PutRecord`
- `firehose:PutRecordBatch`

---

### Firehose Flow Logs Role

Creates a Firehose delivery role:

```hcl
resource "aws_iam_role" "firehose_flow_logs"
```

This role allows Kinesis Data Firehose to deliver VPC Flow Logs to the centralized logs S3 bucket.

Allowed actions include:

- S3 write and multipart upload operations
- S3 bucket location/list operations
- KMS encrypt/decrypt/data key operations using the logs CMK

---

### AWS Config Role

Creates the AWS Config service-linked role:

```hcl
resource "aws_iam_service_linked_role" "config"
```

This role is used by AWS Config.

---

### AWS Config Remediation Role

Creates an AWS Config remediation role:

```hcl
resource "aws_iam_role" "config_remediation"
```

This role is assumed by SSM Automation and is used for remediation actions.

Attached AWS-managed policy:

```text
AmazonSSMAutomationRole
```

The module also creates a custom remediation policy for S3 public access block remediation.

Allowed actions include:

- `s3:GetBucketPublicAccessBlock`
- `s3:PutBucketPublicAccessBlock`
- `s3:GetBucketPolicy`
- `s3:PutBucketPolicy`

---

### AWS Backup Service Role

Creates an AWS Backup service role:

```hcl
resource "aws_iam_role" "backup"
```

Attached AWS-managed policies:

| Policy | Purpose |
|---|---|
| `AWSBackupServiceRolePolicyForBackup` | Allows AWS Backup to create backups |
| `AWSBackupServiceRolePolicyForRestores` | Allows AWS Backup to restore backups |

The backup module consumes this role ARN.

---

### Patch Maintenance Window Role

Creates a Patch Manager maintenance window role:

```hcl
resource "aws_iam_role" "patch_maintenance_window"
```

Attached AWS-managed policy:

```text
AmazonSSMMaintenanceWindowRole
```

This role is consumed by the patch management module.

---

### EventBridge SecOps Bus Role

Creates an EventBridge role:

```hcl
resource "aws_iam_role" "eventbridge_putevents_to_secops"
```

This role allows EventBridge to put events onto the SecOps event bus.

Allowed action:

```text
events:PutEvents
```

Allowed resource:

```hcl
var.secops_event_bus_arn
```

---

### IAM Access Analyzer

Creates an account-level IAM Access Analyzer:

```hcl
resource "aws_accessanalyzer_analyzer" "main"
```

Analyzer name format:

```text
<name_prefix>-account-access-analyzer
```

This helps identify resources shared outside the account.

---

### Shared Centralized Logs Read-Only Policy

Creates a shared IAM policy for read-only access to the centralized logs bucket:

```hcl
resource "aws_iam_policy" "logs_s3_readonly"
```

Policy name format:

```text
<name_prefix>-CentralizedLogsS3ReadOnly
```

This policy allows:

- Listing the centralized logs bucket
- Reading centralized log objects
- Reading object versions
- Reading object tags

It does not allow write or delete access.

This policy can be attached through IAM Identity Center customer-managed policy attachments.

---

### Shared Logs CMK Decrypt Policy

Creates a shared IAM policy for decrypting logs encrypted with the logs CMK:

```hcl
resource "aws_iam_policy" "logs_cmk_decrypt"
```

Policy name format:

```text
<name_prefix>-LogsKmsDecrypt
```

This policy allows:

- `kms:Decrypt`
- `kms:DescribeKey`

Only against the logs CMK.

This policy is commonly paired with centralized logs S3 read-only access.

---

## Break-Glass Access

The `BreakGlass-Admin` role provides emergency administration access in the event that IAM Identity Center (SSO) is unavailable.

This role is:

- Restricted to a small set of trusted principals
- Protected by MFA enforcement
- Intended for emergency use only
- Monitored via logging and alerting

### Trusted Principal

The role is assumed by one or more IAM principals provided via:

```text
break_glass_trusted_principal_arns
```

In production environments, this should reference a dedicated emergency IAM user with:

- MFA enabled
- No routine use
- Credentials stored securely

> ⚠️ This module does NOT create the break-glass IAM user. This is intentional and must be managed by the deploying organization.

### How to Use

The `BreakGlass-Admin` role is intended for **emergency use only** when IAM Identity Center (SSO) is unavailable or misconfigured.

### Prerequisites

- A trusted IAM user, such as `baseline-admin`, is configured in:
  - `break_glass_trusted_principal_arns`
- MFA is enabled on the trusted IAM user
- The user has permission to call `sts:AssumeRole` on `BreakGlass-Admin`

---

### Console Usage

1. Sign in to the AWS Console using the trusted IAM user
2. In the top-right menu, select **Switch Role**
3. Enter:
   - **Account ID**: `<your-account-id>`
   - **Role name**: `<name_prefix>-BreakGlass-Admin`
4. Complete MFA when prompted

You will now have administrative access via the break-glass role.

---

### CLI Usage

Run the following command using the trusted IAM user credentials:

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::<account-id>:role/<name_prefix>-BreakGlass-Admin \
  --role-session-name breakglass-session \
  --serial-number arn:aws:iam::<account-id>:mfa/<name-of-auth-device> \
  --token-code <MFA-CODE>
```

Export the returned credentials:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

#### Verify access:

```bash
aws sts get-caller-identity
```

Expected output:

```json
{
    "UserId": "<AWS_ACCESS_KEY_ID>:breakglass-session",
    "Account": "<ACCOUNT-ID>",
    "Arn": "arn:aws:sts::<ACCOUNT-ID>:assumed-role/<name_prefix>-BreakGlass-Admin/breakglass-session"
}
```

#### Validation

- Confirm the role was assumed successfully
- Verify administrative actions can be performed
- Confirm an alert was sent to the SecOps SNS topic

---

### Important Notes

- This role is **NOT intended for daily use**
- All usage should be considered **highly sensitive and audited**
- Access should be revoked **immediately after the emergency is resolved**

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `cloud_name` | Cloud or project name used by the broader baseline | Yes |
| `name_prefix` | Prefix used for IAM resource naming | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `cloudtrail_log_group_arn` | ARN of the CloudTrail CloudWatch Log Group | Yes |
| `secops_topic_arn` | ARN of the SecOps SNS topic | Yes |
| `logs_cmk_arn` | ARN of the logs KMS CMK | Yes |
| `secrets_manager_cmk_arn` | ARN of the Secrets Manager KMS CMK | Yes |
| `account_id` | AWS account ID | Yes |
| `primary_region` | Primary AWS region | Yes |
| `centralized_logs_bucket_arn` | ARN of the centralized logs S3 bucket | Yes |
| `flowlogs_firehose_delivery_stream_arn` | ARN of the VPC Flow Logs Firehose delivery stream | Yes |
| `flowlogs_log_group_arn` | ARN of the VPC Flow Logs CloudWatch Log Group | Yes |
| `secops_event_bus_arn` | ARN of the SecOps EventBridge event bus | Yes |
| `threat_intel_api_keys_arn` | ARN of the threat intelligence API keys secret | Yes |
| `lambda_ip_enrichment_log_group_arn` | ARN of the IP Enrichment Lambda log group | Yes |
| `break_glass_trusted_principal_arns` | List of IAM principal ARNs allowed to assume the break-glass role with MFA | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `instance_profile_name` | Name of the EC2 IAM instance profile |
| `cloudtrail_role_arn` | ARN of the CloudTrail CloudWatch Logs role |
| `flowlogs_role_arn` | ARN of the VPC Flow Logs role |
| `config_role_arn` | ARN of the AWS Config service-linked role |
| `lambda_ec2_isolation_role_arn` | ARN of the EC2 Isolation Lambda role |
| `lambda_ec2_rollback_role_arn` | ARN of the EC2 Rollback Lambda role |
| `lambda_ip_enrichment_role_arn` | ARN of the IP Enrichment Lambda role |
| `config_remediation_role_arn` | ARN of the AWS Config remediation role |
| `firehose_flow_logs_role_arn` | ARN of the Firehose Flow Logs delivery role |
| `cw_to_firehose_role_arn` | ARN of the CloudWatch Logs to Firehose role |
| `eventbridge_putevents_to_secops_role_arn` | ARN of the EventBridge role that can publish to the SecOps event bus |
| `patch_maintenance_window_role_arn` | ARN of the SSM Patch Manager maintenance window role |
| `backup_service_role_arn` | ARN of the AWS Backup service role |
| `logs_s3_readonly_policy_name` | Name of the centralized logs S3 read-only policy |
| `logs_cmk_decrypt_policy_name` | Name of the logs CMK decrypt policy |
| `break_glass_admin_role_arn` | ARN of the break-glass administrator role |

---

## Usage Example

```hcl
module "iam" {
  source = "../../modules/iam"

  cloud_name  = var.cloud_name
  name_prefix = local.name_prefix
  environment = var.environment

  account_id     = var.account_id
  primary_region = var.primary_region

  cloudtrail_log_group_arn              = module.logging.cloudtrail_log_group_arn
  flowlogs_log_group_arn                = module.logging.flowlogs_log_group_arn
  flowlogs_firehose_delivery_stream_arn = module.logging.flowlogs_firehose_delivery_stream_arn

  centralized_logs_bucket_arn = module.storage.centralized_logs_bucket_arn

  secops_topic_arn    = module.monitoring.secops_topic_arn
  secops_event_bus_arn = module.automation.secops_event_bus_arn

  logs_cmk_arn            = module.security.logs_cmk_arn
  secrets_manager_cmk_arn = module.security.secrets_manager_cmk_arn

  threat_intel_api_keys_arn        = module.automation.threat_intel_api_keys_arn
  lambda_ip_enrichment_log_group_arn = module.automation.lambda_ip_enrichment_log_group_arn

  break_glass_trusted_principal_arns = var.break_glass_trusted_principal_arns
}
```

---

## Dependency Notes

This module is consumed by many other modules.

| IAM Output | Typical Consumer |
|---|---|
| `instance_profile_name` | Compute module |
| `cloudtrail_role_arn` | Logging module |
| `flowlogs_role_arn` | Logging module |
| `firehose_flow_logs_role_arn` | Logging module |
| `cw_to_firehose_role_arn` | Logging module |
| `config_role_arn` | Security / Config baseline module |
| `config_remediation_role_arn` | Security / Config baseline module |
| `lambda_ec2_isolation_role_arn` | Automation module and monitoring SNS policy |
| `lambda_ec2_rollback_role_arn` | Automation module and monitoring SNS policy |
| `lambda_ip_enrichment_role_arn` | Automation module and monitoring SNS policy |
| `patch_maintenance_window_role_arn` | Patch management module |
| `backup_service_role_arn` | Backup module |
| `logs_s3_readonly_policy_name` | IAM Identity Center customer-managed policy attachment |
| `logs_cmk_decrypt_policy_name` | IAM Identity Center customer-managed policy attachment |
| `break_glass_admin_role_arn` | Monitoring module break-glass detection |

Because of these dependencies, IAM is usually deployed early in the baseline.

Some IAM policies reference resources created by other modules, so the root stack must handle dependency ordering carefully.

---

## Validation

### Confirm EC2 Instance Profile

```bash
aws iam get-instance-profile \
  --profile "${AWS_PROFILE}" \
  --instance-profile-name "${NAME_PREFIX}-ec2_compute_instance_profile"
```

Expected:

- Instance profile exists
- EC2 compute role is attached

---

### Confirm EC2 Role Policies

```bash
aws iam list-attached-role-policies \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-ec2_compute_role" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' \
  --output table
```

Expected attached policies:

- `AmazonSSMManagedInstanceCore`
- `CloudWatchAgentServerPolicy`

---

### Confirm Lambda Roles

```bash
aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query 'Roles[?contains(RoleName, `lambda`) && contains(RoleName, `'"${NAME_PREFIX}"'`)].[RoleName,Arn]' \
  --output table
```

Expected roles include:

- EC2 Isolation Lambda role
- EC2 Rollback Lambda role
- IP Enrichment Lambda role

---

### Confirm Logging Roles

```bash
aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query 'Roles[?contains(RoleName, `'"${NAME_PREFIX}"'`) && (contains(RoleName, `cloudtrail`) || contains(RoleName, `VpcFlowLogs`) || contains(RoleName, `FirehoseFlowLogs`) || contains(RoleName, `CloudWatchLogsToFirehose`))].[RoleName,Arn]' \
  --output table
```

Expected roles include:

- CloudTrail role
- VPC Flow Logs role
- Firehose Flow Logs role
- CloudWatch Logs to Firehose role

---

### Confirm Config Roles

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name AWSServiceRoleForConfig
```

Expected:

- AWS Config service-linked role exists

Then confirm the remediation role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-ConfigRemediationRole"
```

Expected:

- Config remediation role exists
- Trust policy allows SSM to assume the role

---

### Confirm Backup Role

```bash
aws iam list-attached-role-policies \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-backup-role" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' \
  --output table
```

Expected attached policies:

- `AWSBackupServiceRolePolicyForBackup`
- `AWSBackupServiceRolePolicyForRestores`

---

### Confirm Patch Maintenance Window Role

```bash
aws iam list-attached-role-policies \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-patch-mw-role" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' \
  --output table
```

Expected:

- `AmazonSSMMaintenanceWindowRole` is attached

---

### Confirm Shared Log Access Policies

```bash
aws iam list-policies \
  --scope Local \
  --profile "${AWS_PROFILE}" \
  --query 'Policies[?contains(PolicyName, `CentralizedLogsS3ReadOnly`) || contains(PolicyName, `LogsKmsDecrypt`)].[PolicyName,Arn]' \
  --output table
```

Expected policies:

- `<name_prefix>-CentralizedLogsS3ReadOnly`
- `<name_prefix>-LogsKmsDecrypt`

---

### Confirm Access Analyzer

```bash
aws accessanalyzer list-analyzers \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'analyzers[].[name,type,status]' \
  --output table
```

Expected:

- Account-level analyzer exists
- Analyzer status is `ACTIVE`

---

### Confirm Break-Glass Role

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-BreakGlass-Admin" \
  --query 'Role.[RoleName,Arn,Description]' \
  --output table
```

Expected:

- Break-glass role exists
- Role description indicates emergency-only administrator access

---

### Confirm Break-Glass MFA Requirement

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-BreakGlass-Admin" \
  --query 'Role.AssumeRolePolicyDocument'
```

Expected:

- Trust policy includes `aws:MultiFactorAuthPresent`
- MFA condition is set to `true`
- Trusted principals match `break_glass_trusted_principal_arns`

---

## Operational Considerations

### IAM Identity Center Is Separate

This module does not create IAM Identity Center groups, permission sets, or account assignments.

Those are managed by the control-plane Identity Center stack.

This module only creates IAM roles and policies inside the workload account.

---

### Shared Policies Support Identity Center Attachments

The shared policies:

```text
<name_prefix>-CentralizedLogsS3ReadOnly
<name_prefix>-LogsKmsDecrypt
```

are intended to support controlled read-only access to centralized logs.

They can be attached to IAM Identity Center permission sets by name/path after the workload baseline has created them.

---

### Break-Glass Access Should Be Rare

The break-glass role has administrator access and should be treated as highly sensitive.

Usage should be:

- Rare
- Time-bound
- Logged
- Alerted
- Reviewed after use

Routine administration should happen through IAM Identity Center, not break-glass access.

---

### IAM Policies Use `jsonencode`

This module currently defines many IAM policies with Terraform `jsonencode()`.

This is valid and readable.

A future refactor could move policies to `aws_iam_policy_document`, but that is not required for v1.

---

### Some Permissions Are Broad by Design

Some automation roles require broad resource scope for operational reasons.

Examples:

- EC2 isolation needs to inspect and modify EC2 instance attributes
- EC2 rollback needs to restore security group attachments
- Security Hub enrichment may update findings

These permissions should be reviewed during production hardening, but they support the current baseline automation model.

---

## Troubleshooting

### EC2 Instances Do Not Register With SSM

Check:

- EC2 instance profile exists
- EC2 role has `AmazonSSMManagedInstanceCore`
- Instance was launched with the correct instance profile
- VPC endpoints or controlled egress allow SSM connectivity

---

### CloudTrail Cannot Write to CloudWatch Logs

Check:

- CloudTrail role exists
- Trust policy allows `cloudtrail.amazonaws.com`
- Inline policy allows `logs:CreateLogStream` and `logs:PutLogEvents`
- Resource matches the CloudTrail log group ARN pattern

---

### VPC Flow Logs Cannot Write to CloudWatch Logs

Check:

- VPC Flow Logs role exists
- Trust policy allows `vpc-flow-logs.amazonaws.com`
- Inline policy allows required CloudWatch Logs actions
- Resource matches the VPC Flow Logs log group ARN pattern

---

### Firehose Cannot Deliver Logs to S3

Check:

- Firehose role exists
- Trust policy allows `firehose.amazonaws.com`
- Role can write to the centralized logs bucket
- Role can use the logs CMK
- Centralized logs bucket policy allows the delivery path

---

### Lambda Automation Fails With AccessDenied

Check the relevant Lambda role:

- EC2 Isolation Lambda role
- EC2 Rollback Lambda role
- IP Enrichment Lambda role

Then check:

- Custom policy is attached
- AWS-managed Lambda execution policies are attached
- SNS topic ARN matches the SecOps topic
- KMS permissions allow SNS publishing and secret decryption where required
- Secrets Manager secret ARN matches the configured threat intelligence secret

---

### AWS Config Remediation Fails

Check:

- Config remediation role exists
- Trust policy allows SSM to assume the role
- `AmazonSSMAutomationRole` is attached
- Custom S3 public access block remediation policy is attached
- Remediation action is using the expected role ARN

---

### Break-Glass AssumeRole Fails

Check:

- Caller ARN is listed in `break_glass_trusted_principal_arns`
- MFA is enabled for the trusted IAM user
- The `assume-role` command includes `--serial-number`
- The `assume-role` command includes a valid `--token-code`
- Caller has permission to call `sts:AssumeRole`
- Role name includes the expected `name_prefix`

---

## Security Notes

- EC2 instances use an IAM instance profile instead of static credentials.
- Lambda functions use dedicated execution roles.
- Logging services use dedicated delivery roles.
- Firehose can write only to the centralized logs bucket and use the logs CMK.
- AWS Config uses a service-linked role and a separate remediation role.
- AWS Backup uses AWS-managed backup and restore policies.
- Patch Manager uses a dedicated maintenance window role.
- Shared log access policies are read-only and decrypt-only.
- Break-glass access requires MFA.
- Break-glass access is emergency-only and should be monitored.
- IAM Access Analyzer is enabled at the account level.

---

## Design Principles

This module follows:

- Dedicated service roles
- Least privilege where practical
- Separation between automation, logging, backup, patching, and emergency access
- No static credentials for compute or Lambda workloads
- Shared reusable policies for log access
- Emergency access with MFA enforcement
- IAM Identity Center integration through customer-managed policy names
- Operational readability over premature policy abstraction

---

## Notes

- Deploy this module early because many modules require its IAM role outputs.
- The break-glass IAM user is not created by this module.
- The break-glass role name includes `name_prefix`.
- The shared logs policy names are exported for use by Identity Center.
- The module currently uses `jsonencode()` for IAM policy definitions.
- IAM Identity Center permission sets and assignments are managed outside this module.