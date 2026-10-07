# IAM Module

## Overview

The `iam` module provisions IAM roles, instance profiles, and policies required by the baseline’s AWS services and automation workflows.

This module includes IAM resources for:

- EC2 instance management
- Per-service ECS task execution and application task role scaffolding
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

This module does **not** manage GitHub OIDC identities or IAM Identity Center personas. GitHub roles belong to the separate account stacks through [github_oidc](../github_oidc/README.md); Identity Center groups, permission sets, and assignments belong to the [control-plane Identity Center root](../../bootstrap/control_plane/identity_center/README.md). Users and group membership are not created by either this module or that root.

The caller composes these resources through [baseline/main.tf](../../baseline/main.tf). Except for the per-service ECS collections, the roles and policies here are not gated by a deployment profile, backup schedule, or Config enablement flag. A retained service role does not prove its associated service is enabled. This module does not configure permissions boundaries or provide a general application-task policy extension interface.

---

## File Layout

| File | Purpose |
|---|---|
| `ec2.tf` | EC2 instance role and instance profile |
| `ecs.tf` | Per-service ECS task execution roles, task roles, and execution policies |
| `lambda.tf` | Lambda execution roles and policies |
| `logging.tf` | CloudTrail, VPC Flow Logs, Firehose, and CloudWatch Logs delivery roles |
| `config.tf` | Expected Config service-linked-role ARN and the managed remediation role |
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

The instance profile output is consumed by the `compute` module so EC2 instances can inherit the role. The trust document contains the EC2 service principal without additional source-account/source-ARN conditions. These two managed-policy attachments are not a database login or a general application AWS-access policy.

---

## `ecs.tf`

The `ecs.tf` file creates separate ECS task execution and application task roles for every key in `var.ecs_iam_services`:

- `aws_iam_role.ecs_task_execution_roles`
- `aws_iam_role.ecs_task_roles`
- `data.aws_iam_policy_document.ecs_task_execution_policies`
- An inline `aws_iam_role_policy` attaching each custom execution policy

Both role types trust `ecs-tasks.amazonaws.com`. The shared trust document also requires the configured account through `aws:SourceAccount` and restricts `aws:SourceArn` to ECS resources in the configured Region and account.

Role pairs are keyed by the ECS service key. Their AWS names are:

```text
<name_prefix>-<service-key>-ecs-execution
<name_prefix>-<service-key>-ecs-task
```

The custom execution policy permits:

- `ecr:GetAuthorizationToken` against `*`, as required by that ECR API
- `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchGetImage` against only the service's declared application repository ARNs
- the same three pull actions against exactly the supplied GuardDuty agent repository ARN set when Runtime Monitoring is enabled
- `logs:CreateLogStream` and `logs:PutLogEvents` against stream ARNs beneath only the service's declared log-group ARNs

The module does not attach the AWS-managed `AmazonECSTaskExecutionRolePolicy`. It grants neither role `iam:PassRole` and does not automatically add the ECR encryption CMK to execution-role permissions. Explicitly supplied `task_execution_kms_key_arns` still determine any added decrypt grant. The application task role is created without policies; this is not a permissions boundary preventing later attachments or every possible resource-policy grant.

The common trust condition covers ECS resources throughout the configured account and Region (`...:ecs:<region>:<account>:*`), not a single service ARN or task definition. Separate role names do not themselves narrow that trust pattern.

The optional execution secret, SSM parameter, and KMS ARN sets are consumed by dynamic resource-scoped statements. When non-empty they grant, respectively, `secretsmanager:GetSecretValue`, `ssm:GetParameters`, or `kms:Decrypt` against only the declared ARNs. `task_execution_kms_key_arns` applies to task-startup authority on the execution role, not application authority on the task role. An empty set creates no `kms:Decrypt` statement; a populated set grants exactly the declared keys. The SSM field is `execution_ssm_parameter_arns`, and the inline policy resource is `aws_iam_role_policy.ecs_task_execution_policies`.

The GuardDuty Fargate agent scope is intentionally separate from application image scope. Baseline supplies `guardduty_agent_ecr_repository_arns` only for protected `production` and `development` services. The resolved ARN has the exact regional shape:

```text
arn:<partition>:ecr:<region>:<guardduty-agent-account-id>:repository/aws-guardduty-agent-fargate
```

For `minimal`, the set is empty and the `AllowGuardDutyAgentImagePulls` statement is omitted. The generated GuardDuty statement contains pull actions, not push or repository-administration actions. The integrated baseline supplies the exact agent repository; this reusable module consumes caller-supplied ARN sets without independently validating their format, rejecting wildcards, or discovering the GuardDuty account. Do not treat its string/set input types as an ARN-scope security check.

`ecs_iam_services` defaults to `{}`. Baseline derives and passes one entry per deployable canonical service. A registered service with `image_digest = null` does not receive a role pair until an exact digest is selected.

---

## `lambda.tf`

The `lambda.tf` file creates execution roles and permissions for security automation Lambda functions.

Lambda roles include:

| Role | Purpose |
|---|---|
| EC2 Isolation Lambda role | Supplies EC2 mutation authority used after the handler's GuardDuty eligibility checks |
| EC2 Rollback Lambda role | Supplies EC2 mutation authority for rollback; the IAM policy does not verify an approval |
| IP Enrichment Lambda role | Allows enrichment of findings using threat intelligence data |

AWS-managed policy attachments are function-specific:

| Policy | Isolation | Rollback | IP Enrichment |
|---|---|---|---|
| `AWSLambdaVPCAccessExecutionRole` | Attached | Attached | Not attached |
| `AWSLambdaBasicExecutionRole` | Attached | Attached | Attached |
| `AWSXRayDaemonWriteAccess` | Attached | Attached | Attached |

All three roles use the same Lambda service-principal trust document with no source-account/source-ARN conditions. The custom statements below supplement the managed attachments; they are not a ceiling on their permissions. See [lambda.tf](lambda.tf).

### EC2 Isolation Lambda Permissions

The custom policy grants `ec2:DescribeInstances`, `ec2:ModifyInstanceAttribute`, `ec2:DescribeSecurityGroups`, `ec2:CreateTags`, and `ec2:CreateSnapshot` on `Resource = "*"`, without instance/tag conditions. The handler's `IsolationAllowed`, product, severity, and state checks are application logic, not IAM-enforced restrictions on this role.

The policy supports:

- Describe instances
- Modify instance attributes
- Describe security groups
- Create tags
- Create snapshots
- Publish alerts to the SecOps SNS topic
- Use the logs CMK for SNS-related encryption operations

### EC2 Rollback Lambda Permissions

The custom policy grants `ec2:DescribeInstances`, `ec2:ModifyInstanceAttribute`, `ec2:DescribeSecurityGroups`, and `ec2:CreateTags` on `Resource = "*"`. It contains no caller-approval, ticket, environment-tag, or quarantined-instance condition.

The policy supports:

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

Each custom Lambda policy also grants `sqs:SendMessage` to that workflow's supplied DLQ ARN. The three DLQ ARN inputs are required.

IP Enrichment receives `secretsmanager:GetSecretValue` and `DescribeSecret` for the supplied secret and `kms:Decrypt`/`DescribeKey` for the supplied Secrets Manager key. Its `securityhub:BatchUpdateFindings` grant uses `Resource = "*"` and is present regardless of the runtime `WRITE_TO_SECURITYHUB` setting. Disabling writeback changes handler behavior, not this role policy.

All three custom policies grant `sns:Publish` on the supplied topic and logs-key `kms:GenerateDataKey*`, `Decrypt`, and `DescribeKey`. Review key and resource policies separately. The Lambda role ARNs are consumed by automation and monitoring resources; role existence alone does not prove policy propagation, event authorization, or successful execution.

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

The CloudWatch-to-Firehose trust constrains `aws:SourceArn` to Logs resources in
the configured account and Region, not one log group. The CloudTrail, VPC Flow
Logs, and Firehose trust documents contain their service principal without an
additional source-account/source-ARN condition. Permissions remain separately
scoped by the supplied destination ARNs.

The four logging role outputs include `depends_on` for their inline delivery
policies. That is a Terraform dependency boundary, not a live delivery test or
a guarantee of IAM propagation. Lambda, Backup, instance-profile, and other role
outputs do not all provide the same explicit policy-attachment barrier; inspect
[outputs.tf](outputs.tf) instead of generalizing from the logging pattern.

---

## `config.tf`

The `config.tf` file creates IAM resources for AWS Config and remediation workflows.

The file defines:

- A locally constructed AWS Config service-linked-role ARN
- AWS Config remediation role
- SSM Automation managed policy attachment
- S3 public access block remediation policy

### AWS Config Service-Linked Role

`config.tf` constructs the expected ARN:

```text
arn:<partition>:iam::<account_id>:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig
```

It exports that string as `config_role_arn`. It does **not** declare an
`aws_iam_service_linked_role` resource or look up that role's existence here.
The AWS-managed role must exist when the consuming Config resources need it;
an ARN string or successful IAM-module evaluation is not proof of existence.

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

It also includes an inline policy granting `s3:GetBucketPublicAccessBlock`, `PutBucketPublicAccessBlock`, `GetBucketPolicy`, and `PutBucketPolicy` on `Resource = "*"`. This is broader than a single baseline bucket and can modify bucket policies, not just inspect them. The source-account trust condition does not scope those S3 resources.

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

The role ARN is consumed by the backup module for scheduled selections and, when enabled, Restore Testing. The role and both managed attachments are created even when scheduled backup is disabled. This file does not add a source-ARN/source-account trust condition, a custom vault/key policy, or an application-level restore-validation policy. An attached restore policy is not proof that a restore job or application test completed.

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

The role ARN is consumed by the patch management module. The trust is the SSM service principal without a source-account/source-ARN condition. Creating this role does not prove patch scan, installation, reboot, or maintenance-window execution.

---

## `security_integrations.tf`

The `security_integrations.tf` file creates security integration resources used by the baseline.

Resources include:

- IAM Access Analyzer account analyzer
- EventBridge role for forwarding events to the SecOps event bus

### Access Analyzer

Creates an account-level IAM Access Analyzer:

```text
aws_accessanalyzer_analyzer.main
```

Analyzer type:

```text
ACCOUNT
```

This is a configured `ACCOUNT` analyzer, not an organization-wide analyzer, a zero-finding assertion, or a complete effective-access review. Review its live status and findings independently.

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

```text
var.secops_event_bus_arn
```

The role is for the EventBridge service, not a human Operator identity. Its trust has no source-ARN/source-account condition; its permission is scoped to the supplied bus. Creating the role or passing its ARN to another module does not create a forwarding target. In the automation implementation, the declared `eventbridge_putevents_to_secops_role_arn` input is not consumed by a target resource.

The Identity Center Operator policy and the workload bus resource policy are different authorization surfaces. Their recorded bus-name/principal discrepancy remains unresolved; see [automation](../automation/README.md) and the [Identity Center caller](../../bootstrap/control_plane/identity_center/README.md).

---

## `shared_policies.tf`

The `shared_policies.tf` file creates reusable IAM customer-managed policies that can be attached by other access-management layers.

Shared policies include:

| Policy | Purpose |
|---|---|
| `<name_prefix>-CentralizedLogsS3ReadOnly` | Read-only access to the centralized logs S3 bucket |
| `<name_prefix>-LogsKmsDecrypt` | KMS decrypt and describe access for the logs CMK |

These are reusable grants, not permissions boundaries. Attaching them does not remove authority granted by other policies. The KMS policy has no encryption-context or `kms:ViaService` condition; its scope is the supplied key, not specifically S3 objects in the logs bucket.

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

The trust uses the supplied principal list and `Bool` condition `aws:MultiFactorAuthPresent = true`; [break_glass.tf](break_glass.tf) attaches `AdministratorAccess`. The module does not validate that the principal list is small, detect an Identity Center outage, verify an incident ticket, or automatically revoke access after an emergency. Monitoring is provided by other baseline resources and must be tested separately.

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
4. Ensure the source IAM-user session satisfies MFA before switching, and verify the resulting role identity.

Successful assumption gives the role's administrative permissions subject to applicable AWS restrictions. Merely opening the Switch Role page does not prove access or alert delivery.

---

### CLI Usage

Use a separately approved IAM-user emergency profile; do not use this procedure
as routine CI or SSO access. One supported AWS CLI approach is an MFA role
profile in `~/.aws/config`, with existing source credentials managed separately:

```ini
[profile breakglass-incident]
role_arn = arn:aws:iam::123456789012:role/example-prod-BreakGlass-Admin
source_profile = emergency-user
mfa_serial = arn:aws:iam::123456789012:mfa/emergency-user
role_session_name = breakglass-incident
region = us-east-1
```

These names and the 12-digit account ID are synthetic. Replace them with the
reviewed role, source profile, MFA device, and Region; preserve existing profile
configuration. The CLI prompts for MFA when a new role session is needed.
This avoids printing and manually copying temporary access keys into a shell.
It does not make credential storage disappear: the CLI caches temporary role
credentials under `~/.aws/cli/cache`. Protect the source profile and cache, and
follow the incident process for session cleanup and revocation. See the
[AWS CLI role-profile instructions](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-role.html).

#### Verify access:

```bash
aws sts get-caller-identity \
  --profile breakglass-incident \
  --query '{UserId:UserId,Account:Account,Arn:Arn}' \
  --output json
```

Expected output:

```json
{
    "UserId": "<ROLE-UNIQUE-ID>:breakglass-incident",
    "Account": "<ACCOUNT-ID>",
    "Arn": "arn:aws:sts::<ACCOUNT-ID>:assumed-role/<name_prefix>-BreakGlass-Admin/breakglass-incident"
}
```

#### Validation

- Confirm the role was assumed successfully
- Verify the returned account and role against the approved incident; do not perform arbitrary mutations as an access test
- Confirm an alert was sent to the SecOps SNS topic

---

### Important Notes

- This role is **NOT intended for daily use**
- All usage should be considered **highly sensitive and audited**
- End the emergency session and perform the organization's approved credential/session revocation and cleanup process; closing a shell does not by itself revoke issued credentials

---

## Inputs

| Name | Type | Description | Required |
|---|---|---|---:|
| `cloud_name` | `string` | Cloud or project name used by the broader baseline | Yes |
| `name_prefix` | `string` | Prefix used for resource naming | Yes |
| `environment` | `string` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `cloudtrail_log_group_arn` | `string` | ARN of the CloudTrail CloudWatch Log Group | Yes |
| `secops_topic_arn` | `string` | ARN of the SecOps SNS topic | Yes |
| `logs_cmk_arn` | `string` | ARN of the logs KMS CMK | Yes |
| `secrets_manager_cmk_arn` | `string` | ARN of the Secrets Manager KMS CMK | Yes |
| `account_id` | `string` | AWS account ID | Yes |
| `primary_region` | `string` | Primary AWS region | Yes |
| `centralized_logs_bucket_arn` | `string` | ARN of the centralized logs S3 bucket | Yes |
| `flowlogs_firehose_delivery_stream_arn` | `string` | ARN of the VPC Flow Logs Firehose delivery stream | Yes |
| `flowlogs_log_group_arn` | `string` | ARN of the VPC Flow Logs CloudWatch Log Group | Yes |
| `secops_event_bus_arn` | `string` | ARN of the SecOps EventBridge event bus | Yes |
| `threat_intel_api_keys_arn` | `string` | ARN of the Secrets Manager secret containing threat intelligence API keys | Yes |
| `lambda_ip_enrichment_log_group_arn` | `string` | ARN of the IP Enrichment Lambda CloudWatch Log Group | Yes |
| `break_glass_trusted_principal_arns` | `list(string)` | List of trusted IAM principal ARNs allowed to assume the break-glass role with MFA | Yes |
| `lambda_ec2_isolation_dlq_arn` | `string` | Isolation asynchronous-failure destination ARN | Yes |
| `lambda_ec2_rollback_dlq_arn` | `string` | Rollback asynchronous-failure destination ARN | Yes |
| `lambda_ip_enrichment_dlq_arn` | `string` | IP Enrichment asynchronous-failure destination ARN | Yes |
| `ecs_iam_services` | `map(object(...))` | ECS execution-role inputs keyed by service; defaults to `{}` | No |


All inputs except `ecs_iam_services` have no declared defaults. In particular, an empty runtime does not remove the three required Lambda DLQ inputs. `cloud_name` and `lambda_ip_enrichment_log_group_arn` are declared context inputs but are not referenced by the current IAM resource expressions. They do not create additional permissions.

The intended service object is:

```hcl
map(object({
  ecr_repository_arns                 = set(string)
  guardduty_agent_ecr_repository_arns = optional(set(string), [])
  log_group_arns                      = set(string)
  execution_secret_arns               = optional(set(string), [])
  execution_ssm_parameter_arns        = optional(set(string), [])
  task_execution_kms_key_arns         = optional(set(string), [])
}))
```

All fields are consumed by the generated policy. Application ECR and log-group permissions are always present for each configured service. GuardDuty-agent ECR, secret, SSM parameter, and KMS statements are emitted only when their corresponding sets are non-empty.

---

## Outputs

| Name | Description |
|---|---|
| `instance_profile_name` | Name of the EC2 IAM instance profile |
| `cloudtrail_role_arn` | ARN of the CloudTrail CloudWatch Logs delivery role |
| `flowlogs_role_arn` | ARN of the VPC Flow Logs delivery role |
| `config_role_arn` | Constructed AWS-managed Config service-linked-role ARN; not proof of role creation |
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
| `ecs_task_execution_roles` | Map of ECS task execution role ARN and name objects keyed by service |
| `ecs_task_execution_policy_ids` | Map of inline execution-policy IDs keyed by service for resource-granular launch readiness |
| `ecs_task_roles` | Map of ECS application task role ARN and name objects keyed by service |

---

## Example Module Call

The shipped workload roots call `baseline`, which calls this child module. The integration below receives naming/account context and resource references from logging, monitoring, storage, automation, and security. It is not a standalone root or a reason to apply the IAM directory separately.

```hcl
module "iam" {
  source = "../modules/iam"

  cloud_name     = var.cloud_name
  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = var.account_id
  primary_region = data.aws_region.current.region

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

  lambda_ec2_isolation_dlq_arn = module.automation.lambda_ec2_isolation_dlq_arn
  lambda_ec2_rollback_dlq_arn  = module.automation.lambda_ec2_rollback_dlq_arn
  lambda_ip_enrichment_dlq_arn = module.automation.lambda_ip_enrichment_dlq_arn

  ecs_iam_services = local.ecs_iam_services
}
```

This module call wires IAM roles and policies to the rest of the baseline, including CloudTrail logging, VPC Flow Logs delivery, Security Operations notifications, EventBridge automation, Secrets Manager access, and break-glass access controls.

---

## Validation

The workload baseline derives `ecs_iam_services` from the canonical service map and passes it to this module. `validate-iam.sh` validates each configured execution/task role pair, ECS trust restrictions, custom execution policy scope, optional ARN-identifiable secret/parameter permissions, absence of managed-policy attachments and `iam:PassRole`, and the initially policy-free application task role. It compares the live `kms:Decrypt` resource set exactly with `ecs_service_configuration[*].task_execution_kms_key_arns` and rejects decrypt permission when that set is empty. It also derives the Runtime Monitoring expectation from `deployment_profile`, requires exactly the Terraform-declared GuardDuty agent repository pull scope when enabled, requires no GuardDuty repository scope when disabled, and rejects broad or unexpected ECR authority. Runtime identity relationships are also checked through resource-backed workload outputs by `validate-ecs-runtime.sh`.

The following manual listings are spot checks. They do not compare every
attached/inline policy, simulate all authorization paths, or reject all extra
roles. A passing ECS policy check does not certify the wildcard grants on the
unrelated Lambda/remediation roles. Adding application task policies requires
reconciling that change with the validator's policy-free task-role contract.

From the repository root, first select the initialized workload and credentials
using the [validation checklist](../../docs/validation-checklist.md). The local
examples assume exported `ENVIRONMENT`, `AWS_PROFILE`, `AWS_REGION`,
`EXPECTED_ACCOUNT_ID`, and `NAME_PREFIX` for that workload. They do not infer
account or naming from a directory. In GitHub OIDC jobs, omit named-profile
assumptions and use the supplied credential chain.

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the workload profile}" \
AWS_REGION="${AWS_REGION:?Set the service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the workload account ID}" \
./scripts/validation/validate-iam.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

`${VAR:?message}` refuses an unset or empty local value; it does not validate
that value's meaning. Workload validators resolve the applied `primary_region`
and reject a conflicting supplied service Region. This is independent of the
state backend's Region.

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
  - `${NAME_PREFIX}-lambda-ec2-isolation`
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
  --role-name "${NAME_PREFIX}-lambda-ec2-isolation" \
  --query 'AttachedPolicies[].[PolicyName,PolicyArn]' \
  --output table
```

Expected:

- Lambda VPC access policy is attached
- Lambda basic execution policy is attached
- X-Ray write policy is attached
- Custom EC2 isolation policy is attached

Repeat for `${NAME_PREFIX}-lambda-ec2-rollback`, which has the same managed attachment set and its own custom policy. For `${NAME_PREFIX}-lambda-ip-enrichment`, expect the basic execution and X-Ray policies plus its custom policy, **not** the VPC access policy. Listing attachments does not inspect their policy contents or prove effective access.

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
- ECS task execution and application task roles are separate and keyed per service.
- ECS application task roles initially carry no broad application permissions.
- ECS execution policies are custom and resource-scoped for application repository pulls and log writes; the AWS-managed ECS execution policy is not attached.
- GuardDuty Fargate Runtime Monitoring adds only the exact regional `aws-guardduty-agent-fargate` repository pull scope for protected profiles and adds no GuardDuty-specific ECR scope for `minimal`.
- Lambda automation roles are separated by function.
- Lambda roles use function-specific managed attachments and custom grants; isolation/rollback EC2 actions and IP Enrichment finding updates include wildcard resource scope.
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

- Compose IAM and consumer modules through resource references in the baseline; do not separately deploy this child module or add cyclic whole-module dependencies.
- The `compute` module consumes the EC2 instance profile name.
- The `logging` module consumes CloudTrail, VPC Flow Logs, Firehose, and CloudWatch Logs role ARNs.
- The `security` module consumes Config role and remediation role ARNs.
- The `automation` module consumes Lambda execution role ARNs.
- The `backup` module consumes the AWS Backup role ARN.
- The `patch_management` module consumes the maintenance window role ARN.
- Shared policy names may be passed to IAM Identity Center for customer-managed policy attachment.
- Review [variables.tf](variables.tf), [outputs.tf](outputs.tf), and each policy file when changing interfaces or permissions; role names and prose are not an effective-authorization test.
