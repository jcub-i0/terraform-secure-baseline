# IAM Module

## Overview

The `iam` module provisions IAM roles, instance profiles, and policies required by the baseline’s AWS services and automation workflows.

This module includes IAM resources for:

- EC2 instance management
- Lambda security automation
- CloudTrail delivery to CloudWatch Logs
- VPC Flow Logs delivery to CloudWatch Logs
- CloudWatch Logs forwarding to Firehose
- Firehose delivery to S3
- AWS Config service and remediation
- AWS Backup
- SSM Patch Manager
- Access Analyzer
- EventBridge integration with the SecOps event bus
- Shared read-only log access policies
- Emergency break-glass administration

This module does **not** manage IAM Identity Center users, groups, permission sets, or account assignments. Those resources are managed in `bootstrap/control_plane/identity_center` sub-stack.

---

## File Layout

| File | Purpose |
|---|---|
| `ec2.tf` | EC2 instance role and instance profile |
| `lambda.tf` | Lambda execution roles and policies |
| `logging.tf` | CloudTrail, VPC Flow Logs, Firehose, and CloudWatch Logs delivery roles |
| `config.tf` | AWS Config service-linked role and remediation role |
| `backup.tf` | AWS Backup service role |
| `patch_management.tf` | SSM Patch Manager maintenance window role |
| `security_integrations.tf` | Access Analyzer and EventBridge/SecOps integration role |
| `shared_policies.tf` | Shared log read-only and KMS decrypt policies |
| `break_glass.tf` | Emergency break-glass administrator role |
| `variables.tf` | Input variables consumed by the IAM module |
| `outputs.tf` | IAM role, policy, and instance profile outputs consumed by other modules |

---

## `ec2.tf`

The `ec2.tf` file creates the IAM resources required by EC2 compute instances.

Resources include:

- EC2 IAM role
- EC2 instance profile
- AWS-managed SSM policy attachment
- AWS-managed CloudWatch Agent policy attachment

The EC2 role is trusted by:

```text
ec2.amazonaws.com
```

Attached AWS-managed policies:

| Policy | Purpose |
|---|---|
| `AmazonSSMManagedInstanceCore` | Allows EC2 instances to register with and be managed by Systems Manager |
| `CloudWatchAgentServerPolicy` | Allows the CloudWatch Agent to publish logs and metrics |

The instance profile output is consumed by the `compute` module so EC2 instances can inherit the role.

---

## `lambda.tf`

The `lambda.tf` file creates execution roles and permissions for security automation Lambda functions.

Lambda roles include:

| Role | Purpose |
|---|---|
| EC2 Isolation Lambda role | Allows automated isolation of EC2 instances after high/critical findings |
| EC2 Rollback Lambda role | Allows approved rollback of isolated EC2 instances |
| IP Enrichment Lambda role | Allows enrichment of findings using threat intelligence data |

Common AWS-managed policy attachments include:

| Policy | Purpose |
|---|---|
| `AWSLambdaVPCAccessExecutionRole` | Allows VPC-attached Lambda ENI operations |
| `AWSLambdaBasicExecutionRole` | Allows Lambda logging to CloudWatch Logs |
| `AWSXRayDaemonWriteAccess` | Allows Lambda X-Ray trace publishing |

### EC2 Isolation Lambda Permissions

The EC2 Isolation Lambda policy allows selected EC2 response actions such as:

- Describe instances
- Modify instance attributes
- Describe security groups
- Create tags
- Create snapshots
- Publish alerts to the SecOps SNS topic
- Use the logs CMK for SNS-related encryption operations

### EC2 Rollback Lambda Permissions

The EC2 Rollback Lambda policy allows selected EC2 rollback actions such as:

- Describe instances
- Modify instance attributes
- Describe security groups
- Create tags
- Publish alerts to the SecOps SNS topic
- Use the logs CMK for SNS-related encryption operations

### IP Enrichment Lambda Permissions

The IP Enrichment Lambda policy allows:

- Read access to the threat intelligence API keys secret
- Publish enriched alerts to the SecOps SNS topic
- Use the logs CMK for SNS-related encryption operations
- Update Security Hub findings with enrichment notes
- Use the Secrets Manager CMK to decrypt the threat intelligence secret

The Lambda role ARNs are consumed by automation and monitoring resources.

---

## `logging.tf`

The `logging.tf` file creates IAM roles and policies required for log delivery and forwarding.

Resources include:

| Role | Trusted Service | Purpose |
|---|---|---|
| CloudTrail CloudWatch role | `cloudtrail.amazonaws.com` | Allows CloudTrail to write to CloudWatch Logs |
| VPC Flow Logs role | `vpc-flow-logs.amazonaws.com` | Allows VPC Flow Logs to write to CloudWatch Logs |
| CloudWatch Logs to Firehose role | `logs.amazonaws.com` | Allows CloudWatch Logs subscription filters to send records to Firehose |
| Firehose Flow Logs role | `firehose.amazonaws.com` | Allows Firehose to deliver VPC Flow Logs to S3 |

### CloudTrail Role

Allows CloudTrail to write events to the CloudTrail CloudWatch Log Group.

Primary actions:

- `logs:CreateLogStream`
- `logs:PutLogEvents`

### VPC Flow Logs Role

Allows VPC Flow Logs to publish to the Flow Logs CloudWatch Log Group.

Primary actions include:

- `logs:CreateLogGroup`
- `logs:CreateLogStream`
- `logs:PutLogEvents`
- `logs:DescribeLogGroups`
- `logs:DescribeLogStreams`

### CloudWatch Logs to Firehose Role

Allows CloudWatch Logs subscription filters to send VPC Flow Log events into the Firehose delivery stream.

Primary actions:

- `firehose:PutRecord`
- `firehose:PutRecordBatch`

### Firehose Flow Logs Role

Allows Firehose to deliver archived VPC Flow Logs to the centralized logs bucket.

Primary permissions include:

- S3 write/list/location access to the centralized logs bucket
- KMS encrypt/decrypt/data key permissions on the logs CMK

---

## `config.tf`

The `config.tf` file creates IAM resources for AWS Config and remediation workflows.

Resources include:

- AWS Config service-linked role
- AWS Config remediation role
- SSM Automation managed policy attachment
- S3 public access block remediation policy

### AWS Config Service-Linked Role

Creates the AWS Config service-linked role for:

```text
config.amazonaws.com
```

This role allows AWS Config to perform its service functions in the account.

### Config Remediation Role

Creates a remediation role trusted by:

```text
ssm.amazonaws.com
```

The role includes a source account condition using:

```hcl
"aws:SourceAccount" = var.account_id
```

The role is attached to the AWS-managed:

```text
AmazonSSMAutomationRole
```

It also includes an inline policy for S3 public access block remediation.

---

## `backup.tf`

The `backup.tf` file creates the IAM role used by AWS Backup.

Resources include:

- AWS Backup service role
- AWS-managed backup policy attachment
- AWS-managed restore policy attachment

The backup role is trusted by:

```text
backup.amazonaws.com
```

Attached AWS-managed policies:

| Policy | Purpose |
|---|---|
| `AWSBackupServiceRolePolicyForBackup` | Allows AWS Backup to create and manage backups |
| `AWSBackupServiceRolePolicyForRestores` | Allows AWS Backup to perform restores |

The role ARN is consumed by the backup module.

---

## `patch_management.tf`

The `patch_management.tf` file creates the IAM role used by SSM Patch Manager maintenance windows.

Resources include:

- Patch maintenance window IAM role
- AWS-managed maintenance window policy attachment

The role is trusted by:

```text
ssm.amazonaws.com
```

Attached AWS-managed policy:

```text
AmazonSSMMaintenanceWindowRole
```

The role ARN is consumed by the patch management module.

---

## `security_integrations.tf`

The `security_integrations.tf` file creates security integration resources used by the baseline.

Resources include:

- IAM Access Analyzer account analyzer
- EventBridge role for forwarding events to the SecOps event bus

### Access Analyzer

Creates an account-level IAM Access Analyzer:

```hcl
resource "aws_accessanalyzer_analyzer" "main"
```

Analyzer type:

```text
ACCOUNT
```

This helps identify external access to supported resources.

### EventBridge to SecOps Bus Role

Creates a role trusted by:

```text
events.amazonaws.com
```

The role allows EventBridge to call:

```text
events:PutEvents
```

against the SecOps event bus ARN provided by:

```hcl
var.secops_event_bus_arn
```

---

## `shared_policies.tf`

The `shared_policies.tf` file creates reusable IAM customer-managed policies that can be attached by other access-management layers.

Shared policies include:

| Policy | Purpose |
|---|---|
| `<name_prefix>-CentralizedLogsS3ReadOnly` | Read-only access to the centralized logs S3 bucket |
| `<name_prefix>-LogsKmsDecrypt` | KMS decrypt and describe access for the logs CMK |

This file is intended to grow as more resources depend on the same IAM roles/policies.

### Centralized Logs S3 Read-Only Policy

Allows read-only access to the centralized logs bucket.

Allowed bucket-level actions:

- `s3:ListBucket`
- `s3:GetBucketLocation`

Allowed object-level actions:

- `s3:GetObject`
- `s3:GetObjectVersion`
- `s3:GetObjectTagging`
- `s3:GetObjectVersionTagging`

This policy does not allow object writes or deletes.

### Logs CMK Decrypt Policy

Allows:

- `kms:Decrypt`
- `kms:DescribeKey`

against the logs CMK.

These shared policies are useful for IAM Identity Center customer-managed policy attachments or other controlled read-only operational access patterns.

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

> ⚠️ This file does NOT create the break-glass IAM user. This is intentional and must be managed by the deploying organization.

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
| `name_prefix` | Prefix used for resource naming | Yes |
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
| `threat_intel_api_keys_arn` | ARN of the Secrets Manager secret containing threat intelligence API keys | Yes |
| `lambda_ip_enrichment_log_group_arn` | ARN of the IP Enrichment Lambda CloudWatch Log Group | Yes |
| `break_glass_trusted_principal_arns` | List of trusted IAM principal ARNs allowed to assume the break-glass role with MFA | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `instance_profile_name` | Name of the EC2 IAM instance profile |
| `cloudtrail_role_arn` | ARN of the CloudTrail CloudWatch Logs delivery role |
| `flowlogs_role_arn` | ARN of the VPC Flow Logs delivery role |
| `config_role_arn` | ARN of the AWS Config service-linked role |
| `lambda_ec2_isolation_role_arn` | ARN of the EC2 Isolation Lambda execution role |
| `lambda_ec2_rollback_role_arn` | ARN of the EC2 Rollback Lambda execution role |
| `lambda_ip_enrichment_role_arn` | ARN of the IP Enrichment Lambda execution role |
| `config_remediation_role_arn` | ARN of the AWS Config remediation role |
| `firehose_flow_logs_role_arn` | ARN of the Firehose Flow Logs delivery role |
| `cw_to_firehose_role_arn` | ARN of the CloudWatch Logs to Firehose role |
| `eventbridge_putevents_to_secops_role_arn` | ARN of the EventBridge role allowed to put events to the SecOps event bus |
| `patch_maintenance_window_role_arn` | ARN of the SSM Patch Manager maintenance window role |
| `backup_service_role_arn` | ARN of the AWS Backup service role |
| `logs_s3_readonly_policy_name` | Name of the centralized logs S3 read-only policy |
| `logs_cmk_decrypt_policy_name` | Name of the logs CMK decrypt policy |
| `break_glass_admin_role_arn` | ARN of the break-glass administrator role |

---

## Example Module Call

The IAM module is called from the environment or baseline root module and receives context from the shared naming variables, account metadata, logging, monitoring, storage, automation, and security modules.

```hcl
module "iam" {
  source = "../modules/iam"

  cloud_name     = var.cloud_name
  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = data.aws_caller_identity.current.account_id
  primary_region = var.primary_region

  cloudtrail_log_group_arn = module.logging.cloudtrail_log_group_arn
  secops_topic_arn         = module.monitoring.secops_topic_arn
  logs_cmk_arn             = module.security.logs_cmk_arn

  centralized_logs_bucket_arn           = module.storage.centralized_logs_bucket_arn
  flowlogs_firehose_delivery_stream_arn = module.logging.flowlogs_firehose_delivery_stream_arn
  flowlogs_log_group_arn                = module.logging.flowlogs_log_group_arn
  secops_event_bus_arn                  = module.automation.secops_event_bus_arn

  threat_intel_api_keys_arn          = module.automation.threat_intel_api_keys_arn
  lambda_ip_enrichment_log_group_arn = module.automation.lambda_ip_enrichment_log_group_arn
  secrets_manager_cmk_arn            = module.security.secrets_manager_cmk_arn
  break_glass_trusted_principal_arns = var.break_glass_trusted_principal_arns
}
```

This module call wires IAM roles and policies to the rest of the baseline, including CloudTrail logging, VPC Flow Logs delivery, Security Operations notifications, EventBridge automation, Secrets Manager access, and break-glass access controls.

---

## Validation

### Confirm IAM Roles Exist

```bash
aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query 'Roles[?contains(RoleName, `'"${NAME_PREFIX}"'`)].[RoleName,Arn]' \
  --output table
```

Expected:


- EC2 compute role exists:
  - `${NAME_PREFIX}-ec2_compute_role`
- Lambda automation roles exist:
  - `${NAME_PREFIX}-lambda-ec2-isolation-role`
  - `${NAME_PREFIX}-lambda-ec2-rollback`
  - `${NAME_PREFIX}-lambda-ip-enrichment`
- Logging delivery roles exist:
  - `${NAME_PREFIX}-cloudtrail-cloudwatch-role`
  - `${NAME_PREFIX}-VpcFlowLogsRole`
  - `${NAME_PREFIX}-CloudWatchLogsToFirehose`
  - `${NAME_PREFIX}-FirehoseFlowLogsRole`
- Config remediation role exists:
  - `${NAME_PREFIX}-ConfigRemediationRole`
- Backup role exists:
  - `${NAME_PREFIX}-backup-role`
- Patch maintenance window role exists:
  - `${NAME_PREFIX}-patch-mw-role`
- EventBridge SecOps role exists:
  - `${NAME_PREFIX}-EventBridgePutEventsToSecopsBus`
- Break-glass admin role exists:
  - `${NAME_PREFIX}-BreakGlass-Admin`
- GitHub OIDC roles may also appear if the environment account bootstrap stack has been deployed:
  - `${NAME_PREFIX}-github-plan-role`
  - `${NAME_PREFIX}-github-apply-role`

---

### Confirm EC2 Instance Profile

```bash
aws iam get-instance-profile \
  --profile "${AWS_PROFILE}" \
  --instance-profile-name "${NAME_PREFIX}-ec2_compute_instance_profile" \
  --query 'InstanceProfile.[InstanceProfileName,Arn,Roles[0].RoleName]' \
  --output table
```

Expected:

- Instance profile exists
- EC2 compute role is attached

---

### Confirm Lambda Role Policy Attachments

```bash
aws iam list-attached-role-policies \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-lambda-ec2-isolation-role" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' \
  --output table
```

Expected:

- Lambda VPC access policy is attached
- Lambda basic execution policy is attached
- X-Ray write policy is attached
- Custom EC2 isolation policy is attached

Repeat for:

- `${NAME_PREFIX}-lambda-ec2-rollback`
- `${NAME_PREFIX}-lambda-ip-enrichment`

---
### Confirm CloudTrail Role

Confirm the CloudTrail delivery role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-cloudtrail-cloudwatch-role" \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- CloudTrail delivery role exists
- Role ARN is returned

Then confirm the trust policy allows CloudTrail to assume the role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-cloudtrail-cloudwatch-role" \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the CloudTrail service principal:

```text
cloudtrail.amazonaws.com
```

---

### Confirm VPC Flow Logs Role

Confirm the VPC Flow Logs role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-VpcFlowLogsRole" \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- VPC Flow Logs role exists
- Role ARN is returned

Then confirm the trust policy allows VPC Flow Logs to assume the role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-VpcFlowLogsRole" \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the VPC Flow Logs service principal:

```text
vpc-flow-logs.amazonaws.com
```

---

### Confirm Firehose Role

Confirm the Firehose delivery role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-FirehoseFlowLogsRole" \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- Firehose delivery role exists
- Role ARN is returned

Then confirm the trust policy allows Firehose to assume the role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-FirehoseFlowLogsRole" \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the Firehose service principal:

```text
firehose.amazonaws.com
```

---

### Confirm AWS Config Service-Linked Role

Confirm the AWS Config service-linked role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name AWSServiceRoleForConfig \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- AWS Config service-linked role exists
- Role ARN is returned

Optional: confirm the trust policy is for AWS Config:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name AWSServiceRoleForConfig \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the AWS Config service principal:

```text
config.amazonaws.com
```

---

### Confirm Backup Role

Confirm the AWS Backup role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-backup-role" \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- Backup role exists
- Role ARN is returned

Then confirm the trust policy allows AWS Backup to assume the role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-backup-role" \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the AWS Backup service principal:

```text
backup.amazonaws.com
```

---

### Confirm Patch Maintenance Window Role

Confirm the Patch Maintenance Window role exists:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-patch-mw-role" \
  --query 'Role.[RoleName,Arn]' \
  --output table
```

Expected:

- Patch Maintenance Window role exists
- Role ARN is returned

Then confirm the trust policy allows SSM to assume the role:

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-patch-mw-role" \
  --query 'Role.AssumeRolePolicyDocument.Statement'
```

Expected:

- Trust policy allows the SSM service principal:

```text
ssm.amazonaws.com
```

---

### Confirm Shared Policies

```bash
aws iam list-policies \
  --profile "${AWS_PROFILE}" \
  --scope Local \
  --query 'Policies[?contains(PolicyName, `CentralizedLogsS3ReadOnly`) || contains(PolicyName, `LogsKmsDecrypt`)].[PolicyName,Arn]' \
  --output table
```

Expected:

- Centralized logs S3 read-only policy exists
- Logs CMK decrypt policy exists

---

### Confirm Break-Glass Role MFA Requirement

```bash
aws iam get-role \
  --profile "${AWS_PROFILE}" \
  --role-name "${NAME_PREFIX}-BreakGlass-Admin" \
  --query 'Role.AssumeRolePolicyDocument'
```

Expected:

- Trusted principals match `break_glass_trusted_principal_arns`
- Trust policy includes MFA enforcement using `aws:MultiFactorAuthPresent`

---

### Confirm Access Analyzer

```bash
aws accessanalyzer list-analyzers \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'analyzers[?contains(name, `'"${NAME_PREFIX}"'`)].[name,arn,status,type]' \
  --output table
```

Expected:

- Account analyzer exists
- Analyzer status is active
- Analyzer type is `ACCOUNT`

---

## Troubleshooting

### EC2 Instances Do Not Register with SSM

Check:

- EC2 instance profile is attached to the instance
- EC2 role has `AmazonSSMManagedInstanceCore`
- Instance has outbound access to SSM through VPC endpoints or controlled egress
- SSM Agent is installed and running

---

### Lambda Cannot Create ENIs

Check:

- Lambda role has `AWSLambdaVPCAccessExecutionRole`
- Lambda subnets and security groups are valid
- Account has available ENI capacity
- VPC endpoint/security group rules allow required AWS API access

---

### Lambda Cannot Publish to SNS

Check:

- Lambda role allows `sns:Publish` to the SecOps topic
- SecOps SNS topic policy allows the Lambda role to publish
- Logs CMK permissions allow SNS encryption operations
- The Lambda is using the expected role

---

### IP Enrichment Lambda Cannot Read Threat Intel Secret

Check:

- Lambda role allows `secretsmanager:GetSecretValue`
- Lambda role allows `kms:Decrypt` on the Secrets Manager CMK
- Secret ARN matches `threat_intel_api_keys_arn`
- Secret is not scheduled for deletion

---

### CloudTrail Is Not Writing to CloudWatch Logs

Check:

- CloudTrail role exists
- CloudTrail role trust policy allows `cloudtrail.amazonaws.com`
- Inline policy allows `logs:CreateLogStream` and `logs:PutLogEvents`
- CloudTrail is configured with the correct role ARN
- CloudTrail log group ARN matches `cloudtrail_log_group_arn`

---

### VPC Flow Logs Are Not Writing to CloudWatch Logs

Check:

- Flow Logs role exists
- Trust policy allows `vpc-flow-logs.amazonaws.com`
- Inline policy allows writes to the Flow Logs log group
- Flow Log configuration references the correct role ARN

---

### Firehose Cannot Deliver to S3

Check:

- Firehose role exists
- Trust policy allows `firehose.amazonaws.com`
- Role has S3 permissions on the centralized logs bucket
- Role has KMS permissions on the logs CMK
- Centralized logs bucket policy allows delivery

---

### Config Remediation Fails

Check:

- Config remediation role exists
- Trust policy allows `ssm.amazonaws.com`
- Source account condition matches the workload account
- `AmazonSSMAutomationRole` is attached
- Inline remediation policy includes the required service actions

---

### Break-Glass AssumeRole Fails

Check:

- Caller is listed in `break_glass_trusted_principal_arns`
- Caller has MFA enabled
- Caller provided MFA in the `assume-role` command
- Caller has permission to call `sts:AssumeRole`
- Role name includes the configured `name_prefix`

---

## Security Notes

- EC2 instances use IAM instance profiles instead of static credentials.
- Lambda automation roles are separated by function.
- Lambda roles use AWS-managed baseline execution policies plus focused custom permissions.
- Logging delivery roles are service-specific.
- Firehose delivery is scoped to the centralized logs bucket and logs CMK.
- Config remediation uses a dedicated remediation role.
- Backup and patch management use dedicated service roles.
- Access Analyzer is enabled at the account level.
- Shared log access policies provide read-only log access and KMS decrypt access without write/delete permissions.
- Break-glass access requires MFA and should be used only during emergencies.
- Break-glass role usage should be monitored through CloudTrail/EventBridge/SecOps alerts.
- This module does not create the emergency IAM user used to assume the break-glass role.

---

## Notes

- Deploy this module before modules that require IAM role ARNs.
- The `compute` module consumes the EC2 instance profile name.
- The `logging` module consumes CloudTrail, VPC Flow Logs, Firehose, and CloudWatch Logs role ARNs.
- The `security` module consumes Config role and remediation role ARNs.
- The `automation` module consumes Lambda execution role ARNs.
- The `backup` module consumes the AWS Backup role ARN.
- The `patch_management` module consumes the maintenance window role ARN.
- Shared policy names may be passed to IAM Identity Center for customer-managed policy attachment.
- The existing Break-Glass section was preserved closely and adjusted only for the module’s current role naming pattern. :contentReference[oaicite:0]{index=0}