# Security Module

## Overview

The `security` module provisions core AWS security services, encryption keys, and security control integrations for the workload environments.

This includes:

- SSM document public sharing protection
- Amazon GuardDuty
- GuardDuty detector features
- AWS Security Hub
- Security Hub standards subscriptions
- Amazon Inspector v2
- Security Hub integration with Inspector
- KMS customer-managed keys for baseline services
- KMS aliases
- AWS Config baseline child module
- Tamper detection child module

This module provides the main security service foundation for the environment.

---

## Purpose

The purpose of this module is to enable AWS-native security monitoring, vulnerability detection, compliance evaluation, and encryption support.

It supports:

- Threat detection through GuardDuty
- Security posture management through Security Hub
- Vulnerability scanning through Inspector
- SSM document sharing hardening
- KMS-backed encryption for logs, Lambda, EBS, Secrets Manager, and AWS Backup
- AWS Config baseline deployment through the `config_baseline` child module
- Security service tamper detection through the `tamper_detection` child module

This module is a foundational part of the security baseline. Other modules depend on its outputs, especially the KMS CMK ARNs and tamper detection rule outputs.

---

## Resources Created

### SSM Document Public Sharing Protection

Disables public sharing for SSM documents:

```hcl
resource "aws_ssm_service_setting" "block_ssm_doc_public_sharing"
```

Setting ID:

```text
/ssm/documents/console/public-sharing-permission
```

Configured value:

```text
Disable
```

This helps prevent accidental public sharing of SSM documents from the account.

---

### GuardDuty Detector

Enables GuardDuty in the target region:

```hcl
resource "aws_guardduty_detector" "main"
```

Configuration:

| Setting | Value |
|---|---|
| Enabled | `true` |
| Finding publishing frequency | `FIFTEEN_MINUTES` |
| Region | `var.primary_region` |

GuardDuty provides threat detection for AWS account activity, workloads, and supported data sources.

---

### GuardDuty Detector Features

Enables GuardDuty detector features from the `guardduty_features` variable:

```hcl
resource "aws_guardduty_detector_feature" "main"
```

The module loops through:

```hcl
var.guardduty_features
```

This allows the baseline to enable supported GuardDuty features in a configurable way.

The resource also ignores changes to:

```hcl
additional_configuration
status
```

This helps avoid unnecessary Terraform drift for feature settings that AWS may manage or report differently over time.

---

### Security Hub Account

Enables Security Hub:

```hcl
resource "aws_securityhub_account" "main"
```

Security Hub depends on GuardDuty being enabled first:

```hcl
depends_on = [aws_guardduty_detector.main]
```

Security Hub centralizes findings from AWS security services and enabled standards.

---

### Security Hub Standards

Subscribes Security Hub to the standards defined in:

```hcl
local.securityhub_standards
```

Current active standard:

| Key | Standard |
|---|---|
| `aws_fsbp` | AWS Foundational Security Best Practices v1.0.0 |

The module also includes commented options for additional standards:

```text
AWS Resource Tagging Standard
CIS AWS Foundations Benchmark v5.0.0
NIST 800-53 v5.0.0
PCI DSS v4.0.1
```

Only uncommented standards in `local.securityhub_standards` are subscribed. If you wish to enable any additional features, simply uncomment them in the `securityhub_standards` local variable.

---

### Amazon Inspector v2

Enables Amazon Inspector v2 for the account:

```hcl
resource "aws_inspector2_enabler" "main"
```

Enabled resource types:

```text
EC2
LAMBDA
LAMBDA_CODE
```

Inspector provides vulnerability and code scanning coverage for supported EC2 and Lambda resources.

---

### Security Hub Inspector Product Subscription

Subscribes Security Hub to the Amazon Inspector product integration:

```hcl
resource "aws_securityhub_product_subscription" "inspector"
```

Product ARN:

```text
arn:aws:securityhub:<region>::product/aws/inspector
```

This allows Inspector findings to flow into Security Hub.

---

## KMS Keys

This module creates several purpose-specific customer-managed KMS keys.

The current key set includes:

| Key | Purpose |
|---|---|
| Logs CMK | CloudTrail, AWS Config, CloudWatch Logs, VPC Flow Logs, SNS/SQS, Firehose, and logging-related services |
| EBS CMK | EBS volume and snapshot encryption |
| Lambda CMK | Lambda environment variable encryption |
| Secrets Manager CMK | Secrets Manager secret encryption |
| Backup Vault CMK | AWS Backup vault encryption |

Each key has rotation enabled.

Several keys currently include:

```hcl
prevent_destroy = false # CHANGE THIS IN PROD
```

This is to promote simplicity during initial deployment testing/demo operations.

For production, review whether `prevent_destroy` should be set to `true`.

---

### Logs CMK

Creates the logs KMS key:

```hcl
resource "aws_kms_key" "logs"
```

Alias:

```hcl
resource "aws_kms_alias" "logs"
```

Alias name:

```text
alias/<name_prefix>/logs-cmk
```

The logs CMK is used broadly across the baseline for logging and notification encryption.

Allowed service usage includes:

- CloudTrail
- AWS Config
- CloudWatch Logs
- S3
- SNS
- SQS
- CloudWatch
- Kinesis Firehose
- Amazon Inspector
- AWS log delivery
- EventBridge

The logs CMK is consumed by other modules such as:

- `storage`
- `logging`
- `monitoring`
- `config_baseline`

---

### EBS CMK

Creates the EBS KMS key:

```hcl
resource "aws_kms_key" "ebs"
```

Alias:

```hcl
resource "aws_kms_alias" "ebs"
```

Alias name:

```text
alias/<name_prefix>/ebs-cmk
```

This key is intended for EBS volumes and snapshots.

The key policy allows EC2/EBS service usage.

---

### Lambda CMK

Creates the Lambda KMS key:

```hcl
resource "aws_kms_key" "lambda"
```

Alias:

```hcl
resource "aws_kms_alias" "lambda"
```

Alias name:

```text
alias/<name_prefix>/lambda-cmk
```

This key is intended to encrypt Lambda environment variables.

The key policy allows Lambda service usage and includes Amazon Inspector permissions for Lambda scanning support.

---

### Secrets Manager CMK

Creates the Secrets Manager KMS key:

```hcl
resource "aws_kms_key" "secrets_manager"
```

Alias:

```hcl
resource "aws_kms_alias" "secrets_manager"
```

Alias name:

```text
alias/<name_prefix>/secrets-cmk
```

This key is intended to encrypt Secrets Manager secrets, including secrets created by other modules such as database credentials or threat intelligence API keys.

---

### Backup Vault CMK

Creates the AWS Backup vault KMS key:

```hcl
resource "aws_kms_key" "backup_vault"
```

Alias:

```hcl
resource "aws_kms_alias" "backup_vault"
```

Alias name:

```text
alias/<name_prefix>/backup-cmk
```

This key is intended for AWS Backup vault encryption.

The key policy allows the AWS Backup service to use the key for backup vault operations.

---

## Child Modules

This module calls two child modules:

```text
modules/security/config_baseline
modules/security/tamper_detection
```

These child modules have their own README files, so this parent README only covers them at a high level.

---

### Config Baseline Child Module

The Config baseline child module is called as:

```hcl
module "config_baseline"
```

It receives:

- Environment naming values
- Config enablement flag
- Config IAM role ARN
- Compliance SNS topic ARN
- Config remediation role ARN
- Centralized logs bucket name
- Logs CMK ARN
- Enabled rule toggles

The child module handles AWS Config recorder, delivery, rules, and remediation-related configuration.

Refer to the child module README for detailed behavior.

---

### Tamper Detection Child Module

The tamper detection child module is called as:

```hcl
module "tamper_detection"
```

It receives:

- Name prefix
- Cloud name
- Environment
- SecOps alert topic ARN

The child module creates tamper detection logic for critical security services and routes alerts to the SecOps SNS topic.

Refer to the child module README for detailed detection coverage.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `cloud_name` | Cloud or project name used by the broader baseline | Yes |
| `name_prefix` | Prefix used for resource naming | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `primary_region` | Primary AWS region for regional security services | Yes |
| `config_role_arn` | IAM role ARN used by AWS Config | Yes |
| `centralized_logs_bucket_name` | Name of the centralized logs bucket used by AWS Config | Yes |
| `current_region` | Current AWS region, used in service-specific KMS policy statements | Yes |
| `account_id` | AWS account ID | Yes |
| `compliance_topic_arn` | SNS topic ARN used for compliance notifications | Yes |
| `guardduty_features` | List of GuardDuty detector features to enable | Yes |
| `config_remediation_role_arn` | IAM role ARN used by AWS Config remediation actions | Yes |
| `secops_event_bus_name` | Name of the SecOps EventBridge event bus | Yes |
| `secops_topic_arn` | SNS topic ARN used for SecOps alerts | Yes |
| `config_enabled` | Whether AWS Config baseline resources are enabled | Yes |
| `enable_rules` | Object controlling which Config baseline rule groups are enabled | No |

---

## Config Rule Toggle Object

The `enable_rules` variable controls which AWS Config baseline rule groups are enabled in the `config_baseline` child module.

Default values:

```hcl
enable_rules = {
  s3_baseline         = true
  cloudtrail_baseline = true
  rds_baseline        = true
  ebs_baseline        = true
  sg_baseline         = true
  iam_baseline        = false
  ec2_baseline        = true
  kms_baseline        = true
}
```

The IAM baseline is disabled by default.

This is because IAM/global resource recording can require additional AWS Config behavior and should be enabled intentionally. The `iam_policy_changes` Log Metric Filter resource, defined in the `monitoring` module, also does a great job at notifying upon suspicious actions relating to IAM policies (see `modules/monitoring/README.md`).

---

## Outputs

| Name | Description |
|---|---|
| `logs_cmk_arn` | ARN of the logs KMS CMK |
| `ebs_cmk_arn` | ARN of the EBS KMS CMK |
| `ebs_cmk_alias_arn` | ARN of the EBS KMS alias |
| `lambda_cmk_arn` | ARN of the Lambda KMS CMK |
| `secrets_manager_cmk_arn` | ARN of the Secrets Manager KMS CMK |
| `secrets_manager_cmk_alias_arn` | ARN of the Secrets Manager KMS alias |
| `backup_vault_cmk_arn` | ARN of the AWS Backup vault KMS CMK |
| `backup_vault_cmk_alias_arn` | ARN of the AWS Backup vault KMS alias |
| `tamper_detection_rule_name` | Name of the tamper detection EventBridge rule from the child module |
| `tamper_detection_rule_arn` | ARN of the tamper detection EventBridge rule from the child module |

---

## Usage Example

```hcl
module "security" {
  source = "../modules/security"

  name_prefix                  = local.name_prefix
  cloud_name                   = var.cloud_name
  environment                  = var.environment
  account_id                   = data.aws_caller_identity.current.account_id
  primary_region               = var.primary_region
  current_region               = data.aws_region.current.region
  centralized_logs_bucket_name = module.storage.centralized_logs_bucket_name

  guardduty_features = var.guardduty_features
  enable_rules       = var.enable_rules

  config_enabled              = var.config_enabled
  config_role_arn             = module.iam.config_role_arn
  config_remediation_role_arn = module.iam.config_remediation_role_arn

  compliance_topic_arn  = module.monitoring.compliance_topic_arn
  secops_topic_arn      = module.monitoring.secops_topic_arn
  secops_event_bus_name = module.automation.secops_event_bus_name
}
```

---

## Dependency Notes

This module has important relationships with other modules.

### Consumed by Other Modules

Outputs from this module are used by:

| Output | Typical Consumer |
|---|---|
| `logs_cmk_arn` | Logging, storage, monitoring, Config, CloudWatch Logs, SNS/SQS |
| `ebs_cmk_arn` | Compute and EC2 storage resources |
| `lambda_cmk_arn` | Automation Lambda functions |
| `secrets_manager_cmk_arn` | Storage and automation secrets |
| `backup_vault_cmk_arn` | Backup module |
| `tamper_detection_rule_arn` | Monitoring module SNS topic policy |

### Inputs from Other Modules

This module expects some resources to already exist or be passed in:

| Input | Source |
|---|---|
| `config_role_arn` | IAM module |
| `config_remediation_role_arn` | IAM module |
| `centralized_logs_bucket_name` | Storage module |
| `compliance_topic_arn` | Monitoring module |
| `secops_topic_arn` | Monitoring module |
| `secops_event_bus_name` | Automation module |

Because of these relationships, deployment order should be handled carefully in the root environment stack.

---

## Validation

### Confirm SSM Document Public Sharing Is Disabled

```bash
aws ssm get-service-setting \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --setting-id "/ssm/documents/console/public-sharing-permission" \
  --query 'ServiceSetting.[SettingId,SettingValue,Status]' \
  --output table
```

Expected:

- Setting value is `Disable`

---

### Confirm GuardDuty Detector

```bash
aws guardduty list-detectors \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- One GuardDuty detector ID is returned

Then describe it:

```bash
aws guardduty get-detector \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --detector-id "${GUARDDUTY_DETECTOR_ID}" \
  --query '{Status:Status,FindingPublishingFrequency:FindingPublishingFrequency,CreatedAt:CreatedAt,UpdatedAt:UpdatedAt}' \
  --output table
```

Expected:

- Status is enabled
- Finding publishing frequency is `FIFTEEN_MINUTES`

---

### Confirm GuardDuty Features

```bash
aws guardduty get-detector \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --detector-id "${GUARDDUTY_DETECTOR_ID}" \
  --query 'Features[].[Name,Status]' \
  --output table
```

Expected:

- Configured GuardDuty features are listed
- Enabled features show `ENABLED`

---

### Confirm Security Hub Is Enabled

```bash
aws securityhub describe-hub \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query '{HubArn:HubArn,SubscribedAt:SubscribedAt,AutoEnableControls:AutoEnableControls}' \
  --output table
```

Expected:

- Security Hub returns hub details
- Command succeeds without a not-subscribed error

---

### Confirm Security Hub Standards

```bash
aws securityhub get-enabled-standards \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'StandardsSubscriptions[].[StandardsArn,StandardsStatus]' \
  --output table
```

Expected:

- AWS Foundational Security Best Practices is enabled
- Any additional uncommented standards are listed

---

### Confirm Inspector Is Enabled

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}" \
  --query 'accounts[0].{AccountStatus:state.status,EC2:resourceState.ec2.status,Lambda:resourceState.lambda.status,LambdaCode:resourceState.lambdaCode.status}' \
  --output table
```

Expected:

- EC2 scanning is enabled
- Lambda scanning is enabled
- Lambda code scanning is enabled

---

### Confirm Inspector Security Hub Product Subscription

```bash
aws securityhub list-enabled-products-for-import \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'ProductSubscriptions[?contains(@, `inspector`)]' \
  --output table
```

Expected:

- Inspector product subscription is listed

---

### Confirm KMS Keys and Aliases

```bash
aws kms list-aliases \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Aliases[?contains(AliasName, `'"${NAME_PREFIX}"'`) == `true`].[AliasName,TargetKeyId]' \
  --output table
```

Expected aliases include:

- `alias/<name_prefix>/logs-cmk`
- `alias/<name_prefix>/ebs-cmk`
- `alias/<name_prefix>/lambda-cmk`
- `alias/<name_prefix>/secrets-cmk`
- `alias/<name_prefix>/backup-cmk`

---

### Confirm KMS Key Rotation

Use the relevant key ID or key ARN:

```bash
aws kms get-key-rotation-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --key-id "${LOGS_CMK_ARN}" \
  --output table
```

Expected:

- Key rotation is enabled

Repeat for:

- EBS CMK
- Lambda CMK
- Secrets Manager CMK
- Backup Vault CMK

---

### Confirm Tamper Detection Rule Output

```bash
aws events describe-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${TAMPER_DETECTION_RULE_NAME}"
```

Expected:

- Rule exists
- Rule is enabled
- Rule is associated with the security tamper detection workflow

For detailed validation, use the `tamper_detection` child module README.

---

## Operational Considerations

### KMS Keys Are Foundational

The KMS keys created by this module are used across the environment.

Do not delete or disable these keys unless intentionally tearing down the environment.

Disabling or scheduling deletion for one of these keys can break:

- CloudTrail delivery
- CloudWatch Logs encryption
- S3 log encryption
- SNS/SQS alerting
- Lambda environment variable decryption
- Secrets Manager secret access
- EBS volume access
- Backup vault recovery

---

### Production Deletion Protection

Several KMS keys currently include:

```hcl
prevent_destroy = false # CHANGE THIS IN PROD
```

For production, consider changing this to:

```hcl
prevent_destroy = true
```

This adds a Terraform-level guardrail against accidental KMS key destruction.

---

### Security Hub Standards Are Intentionally Selective

Only AWS Foundational Security Best Practices is currently active in the parent module.

Additional standards are present but commented out.

Before enabling more standards, consider:

- Additional finding volume
- Operational maturity
- Remediation ownership
- False positive handling
- Compliance requirements
- Cost and alert fatigue

---

### GuardDuty Feature Selection

GuardDuty features are controlled through `var.guardduty_features`.

Only enable features that are supported in the target region and account configuration.

If a feature is unsupported or unavailable, Terraform may fail or AWS may reject the configuration.

---

### AWS Config Scope

The parent module passes configuration into the `config_baseline` child module.

The default `enable_rules` object enables most baseline groups but leaves `iam_baseline` disabled.

If IAM/global Config coverage is enabled later, confirm the child module AWS Config recorder settings support global IAM resource recording as required.

---

### Tamper Detection Alert Routing

Tamper detection alerts are routed to:

```hcl
var.secops_topic_arn
```

The monitoring module must allow the tamper detection EventBridge rule to publish to the SecOps SNS topic.

The parent security module exposes:

```hcl
tamper_detection_rule_arn
```

This output is intended to support that SNS topic policy wiring.

---

## Troubleshooting

### Security Hub Fails to Enable

Check:

- GuardDuty detector was created successfully
- AWS region is correct
- The account is not already in a conflicting Security Hub organization setup
- Terraform has permissions for Security Hub account and standards resources

Useful command:

```bash
aws securityhub describe-hub \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

---

### Security Hub Standard Subscription Fails

Check:

- The standard ARN matches the region
- Security Hub is enabled first
- The standard is supported in the region
- The account has permission to subscribe to standards

Current active standard ARN pattern:

```text
arn:aws:securityhub:<region>::standards/aws-foundational-security-best-practices/v/1.0.0
```

---

### GuardDuty Feature Fails to Enable

Check:

- The feature name is valid
- The feature is supported in the selected region
- GuardDuty is enabled
- The account has the required GuardDuty permissions
- Organization-level GuardDuty settings are not overriding account-level behavior

Useful command:

```bash
aws guardduty list-detector-features \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --detector-id "${GUARDDUTY_DETECTOR_ID}"
```

---

### Inspector Fails to Enable

Check:

- Inspector v2 is supported in the region
- The account has permissions for `inspector2:Enable`
- Service-linked roles can be created
- Lambda and EC2 scanning are supported in the target account and region

Useful command:

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}"
```

---

### KMS Access Errors

KMS access errors can affect many modules.

Check:

- The correct CMK ARN is being passed to dependent modules
- The key policy allows the expected AWS service principal
- The key policy includes account root delegation
- The caller has IAM permissions to use the key
- The service is using the expected region and source account
- The key is enabled and not pending deletion

Useful command:

```bash
aws kms describe-key \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --key-id "${LOGS_CMK_ARN}"
```

---

### CloudTrail or Logging Delivery Fails After KMS Changes

Check the logs CMK policy.

The logs CMK is used by multiple logging-related services, including:

- CloudTrail
- CloudWatch Logs
- AWS Config
- S3
- Firehose
- SNS/SQS
- EventBridge

If the logs CMK policy is too restrictive, log delivery or alerting can fail.

---

### Secrets Cannot Be Decrypted

Check:

- Secret is encrypted with the Secrets Manager CMK
- Secrets Manager CMK is enabled
- Caller has `kms:Decrypt`
- Caller has `secretsmanager:GetSecretValue`
- Key policy allows Secrets Manager service usage

Useful command:

```bash
aws secretsmanager describe-secret \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --secret-id "${SECRET_ID}"
```

---

### Tamper Detection Alerts Are Not Sent

Check:

- Tamper detection EventBridge rule exists
- Rule is enabled
- Rule target is configured in the child module
- SecOps SNS topic exists
- SecOps SNS topic policy allows the tamper detection rule to publish
- SecOps email subscriptions are confirmed

For detailed troubleshooting, use the `tamper_detection` child module README.

---

## Security Notes

- SSM document public sharing is disabled.
- GuardDuty is enabled with 15-minute finding publishing.
- Security Hub is enabled after GuardDuty.
- AWS Foundational Security Best Practices is enabled by default.
- Inspector v2 is enabled for EC2, Lambda, and Lambda code scanning.
- Inspector findings are imported into Security Hub.
- KMS keys are purpose-specific instead of using one shared key for everything.
- KMS key rotation is enabled.
- Logs CMK supports multiple logging and alerting services.
- Lambda CMK supports Lambda environment variable encryption.
- Secrets Manager CMK supports secret encryption.
- EBS CMK supports EBS volume and snapshot encryption.
- Backup Vault CMK supports backup vault encryption.
- Tamper detection is delegated to the `tamper_detection` child module.
- AWS Config baseline is delegated to the `config_baseline` child module.

---

## Design Principles

This module follows:

- AWS-native security service enablement
- Purpose-specific encryption keys
- Centralized security finding aggregation
- Vulnerability detection for compute and serverless workloads
- Security control evaluation through AWS Config
- Event-driven tamper detection
- Least privilege KMS service usage
- Production-aligned security defaults

---

## Notes

- Deploy this module before modules that need its KMS outputs.
- The logs CMK is consumed heavily by logging, storage, monitoring, and Config resources.
- The Lambda CMK is consumed by automation Lambda functions.
- The Secrets Manager CMK is consumed by secrets created outside this module.
- The Backup Vault CMK is consumed by the backup module.
- The tamper detection rule ARN should be passed to the monitoring module so SNS publishing can be permitted.
- The `config_baseline` and `tamper_detection` child modules have their own README files and should be referenced for detailed behavior.