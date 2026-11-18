# IAM Module

## Overview

The `iam` module provisions IAM roles, instance profiles, and policies required by the baseline’s remaining foundation and governance capabilities.

This module includes IAM resources for:

- EC2 instance management
- AWS Config service and remediation
- Access Analyzer
- Shared read-only log access policies
- Emergency break-glass administration

ECS task execution and application task roles are not part of this module. Since v1.15.0 they belong to the reusable [ecs_workload_iam](../ecs_workload_iam/README.md) module, which the baseline calls separately and application-owned states can call directly.

This module does **not** manage GitHub OIDC identities or IAM Identity Center personas. GitHub roles belong to the separate account stacks through [github_oidc](../github_oidc/README.md); Identity Center groups, permission sets, and assignments belong to the [control-plane Identity Center root](../../bootstrap/control_plane/identity_center/README.md). Users and group membership are not created by either this module or that root.

The caller composes these resources through [baseline/main.tf](../../baseline/main.tf). The roles and policies here are not gated by a deployment profile, backup schedule, or Config enablement flag. A retained service role does not prove its associated service is enabled. This module does not configure permissions boundaries or author application policy documents.

---

## File Layout

| File | Purpose |
|---|---|
| `ec2.tf` | EC2 instance role and instance profile |
| `config.tf` | Expected Config service-linked-role ARN and the managed remediation role |
| `security_integrations.tf` | Account-level Access Analyzer |
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

## ECS Workload IAM

Per-workload ECS task execution roles, application task roles, execution policies, and task-role managed-policy attachments moved to [ecs_workload_iam](../ecs_workload_iam/README.md) in v1.15.0 (R1-A). That README documents the trust conditions, execution-policy scope, inputs, outputs, and the baseline resource-address mapping.

---

## Automation IAM

Lambda execution roles, their policies and attachments, and the EventBridge
SecOps role are owned by [automation/iam.tf](../automation/iam.tf). See the
[automation IAM contract](../automation/README.md#execution-iam) for permissions
and the preserved attachment-order limitations. Access Analyzer remains here.

---

## Logging Delivery IAM

The four logging delivery roles and their inline policies belong to
[logging/iam.tf](../logging/iam.tf). The [logging module](../logging/README.md#delivery-iam)
owns their trust, permissions, and delivery-service policy-readiness dependencies.
Shared S3 log-reader and logs-key decrypt policies remain in this IAM module.

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

The inline policy grants only `s3:GetBucketPublicAccessBlock` and `s3:PutBucketPublicAccessBlock` on `arn:<partition>:s3:::*`, constrained by `s3:ResourceAccount` to the workload account. This can affect account-owned buckets beyond the baseline, but does not grant bucket-policy editing. The broad `AmazonSSMAutomationRole` attachment has been removed.

---

## Backup IAM

The AWS Backup service role and both AWS-managed policy attachments are owned by
[backup/iam.tf](../backup/iam.tf). They remain unconditional when scheduled Backup
or Restore Testing is disabled. See the [Backup IAM contract](../backup/README.md#service-iam)
for trust, permissions and the preserved attachment-readiness limitation.

---

## Patch Management IAM

The maintenance-window role and AWS-managed policy attachment are owned by
[patch_management/iam.tf](../patch_management/iam.tf). They remain unconditional
when the maintenance window is disabled. See the
[Patch Management IAM contract](../patch_management/README.md#service-iam) for
trust, permissions, tags and the preserved attachment-readiness limitation.
Creating this role does not prove patch scan, installation, reboot, or
maintenance-window execution.

---

## `security_integrations.tf`

The `security_integrations.tf` file creates security integration resources used by the baseline.

Resources include:

- IAM Access Analyzer account analyzer

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

The EventBridge SecOps role and policy are owned by
[automation](../automation/README.md#eventbridge-to-secops-bus-role).

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
| `logs_cmk_arn` | `string` | ARN of the logs KMS CMK | Yes |
| `account_id` | `string` | AWS account ID | Yes |
| `primary_region` | `string` | Primary AWS region | Yes |
| `centralized_logs_bucket_arn` | `string` | ARN of the centralized logs S3 bucket | Yes |
| `break_glass_trusted_principal_arns` | `list(string)` | List of trusted IAM principal ARNs allowed to assume the break-glass role with MFA | Yes |

None of the listed inputs has a declared default. `cloud_name` remains a required but unused context input; it does not create additional permissions.

---

## Outputs

| Name | Description |
|---|---|
| `instance_profile_name` | Name of the EC2 IAM instance profile |
| `config_role_arn` | Constructed AWS-managed Config service-linked-role ARN; not proof of role creation |
| `config_remediation_role_arn` | ARN of the AWS Config remediation role |
| `logs_s3_readonly_policy_name` | Name of the centralized logs S3 read-only policy |
| `logs_cmk_decrypt_policy_name` | Name of the logs CMK decrypt policy |
| `break_glass_admin_role_arn` | ARN of the break-glass administrator role |

---

## Example Module Call

The shipped workload roots call `baseline`, which calls this child module. The integration below receives naming/account context and resource references from storage and security. It is not a standalone root or a reason to apply the IAM directory separately.

```hcl
module "iam" {
  source = "../modules/iam"

  cloud_name     = var.cloud_name
  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  logs_cmk_arn             = module.security.logs_cmk_arn

  centralized_logs_bucket_arn           = module.storage.centralized_logs_bucket_arn

  break_glass_trusted_principal_arns = var.break_glass_trusted_principal_arns

}
```

This module call wires IAM roles and policies to the rest of the baseline, including shared log access and break-glass access controls.

---

## Validation

The workload baseline derives `ecs_iam_services` from the canonical service map and passes it to [ecs_workload_iam](../ecs_workload_iam/README.md) as `workloads`. `validate-iam.sh` validates each configured execution/task role pair, ECS trust restrictions, custom execution policy scope, optional ARN-identifiable secret/parameter permissions, absence of execution-role managed-policy attachments and generated `iam:PassRole`, exact configured application task-role managed-policy attachments, and absence of task-role inline policies. It compares the live `kms:Decrypt` resource set exactly with `ecs_service_configuration[*].task_execution_kms_key_arns` and rejects decrypt permission when that set is empty. It also derives the Runtime Monitoring expectation from `deployment_profile`, requires exactly the Terraform-declared GuardDuty agent repository pull scope when enabled, requires no GuardDuty repository scope when disabled, and rejects broad or unexpected ECR authority. Runtime identity relationships are also checked through resource-backed workload outputs by `validate-ecs-runtime.sh`.

The following manual listings are spot checks. They do not compare every
attached/inline policy, simulate all authorization paths, or reject all extra
roles. A passing ECS policy check does not certify the wildcard grants on the
unrelated Lambda/remediation roles. Application-managed policy contents and later
default-version changes are outside the attachment validator's scope. Review
effective permissions separately; no permission boundary is created here.

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

Confirm the AWS Backup role, owned by [backup](../backup/README.md#service-iam), exists:

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

Confirm the Patch Maintenance Window role, owned by [patch_management](../patch_management/README.md#service-iam), exists:

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
- CloudTrail log group ARN matches the logging module's `cloudtrail_log_group_arn` output

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
- Inline remediation policy permits the required bucket public-access-block operations
- The target bucket belongs to the workload account required by `s3:ResourceAccount`

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
- ECS workload roles and policies are provisioned by [ecs_workload_iam](../ecs_workload_iam/README.md); see its security notes.
- Lambda automation roles and EventBridge SecOps IAM are owned by [automation](../automation/README.md#execution-iam).
- Logging delivery roles and policies are owned by [logging](../logging/README.md#delivery-iam).
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
- The `backup` module owns its AWS Backup role and both managed-policy attachments.
- The `patch_management` module owns its maintenance-window role and policy attachment.
- Shared policy names may be passed to IAM Identity Center for customer-managed policy attachment.
- Review [variables.tf](variables.tf), [outputs.tf](outputs.tf), and each policy file when changing interfaces or permissions; role names and prose are not an effective-authorization test.
