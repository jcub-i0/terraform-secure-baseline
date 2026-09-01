# Security Module

## Overview

The `security` module provisions core AWS security services, encryption keys, and security control integrations for the workload environments.

This includes:

- SSM document public sharing protection
- Amazon GuardDuty detector and features when GuardDuty is workload-managed
- AWS Security Hub CSPM and standards when CSPM is workload-managed
- AWS Security Hub V2 when V2 is workload-managed
- Amazon Inspector v2
- Security Hub integration with Inspector
- KMS customer-managed keys for baseline services
- KMS aliases
- AWS Config baseline child module
- Tamper detection child module

This module provides the main security service foundation for the environment.

---

## Purpose

The purpose of this module is to provide workload-local security controls and encryption support while allowing organization-level services to be owned centrally when the workload is part of the managed multi-account platform.

It supports:

- Threat detection through GuardDuty, either locally or through centralized organization governance
- Security posture management through Security Hub CSPM, either locally or through centralized configuration policies
- Security Hub V2 enablement either locally or through an inherited Organizations policy
- Vulnerability scanning through Inspector
- SSM document sharing hardening
- KMS-backed encryption for logs, Lambda, EBS, Secrets Manager, ECR, and AWS Backup
- AWS Config baseline deployment through the `config_baseline` child module
- Security service tamper detection through the `tamper_detection` child module

This module is a foundational part of the security baseline. Other modules depend on its outputs, especially the KMS CMK ARNs and tamper detection rule outputs.

---

## Security-Service Ownership Model

This module supports both standalone workload deployments and centrally governed workload accounts.

| Capability | Local ownership variable | Module default | Managed platform setting |
|---|---|---:|---:|
| Security Hub CSPM account/standards | `manage_securityhub_cspm_locally` | `true` | `false` |
| Security Hub V2 account enablement | `manage_securityhub_v2_locally` | `true` | `false` |
| GuardDuty detector/features | `manage_guardduty_locally` | `true` | `false` |

The reusable module defaults to local ownership so it can operate independently. In the repository's centrally governed `dev`, `staging`, and `prod` environments, these values are set to `false`; the `security-operations` delegated administrator owns Security Hub CSPM policies, GuardDuty organization configuration, and the Security Hub V2 Organizations policy.

Workload-local controls remain here regardless of centralization, including AWS Config, Inspector, KMS keys, SSM document-sharing protection, and tamper detection.

This ownership split avoids competing Terraform resources in workload accounts while preserving standalone use of the module.

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

### GuardDuty Detector and Features

GuardDuty resources are created only when:

```hcl
manage_guardduty_locally = true
```

The detector uses:

```hcl
resource "aws_guardduty_detector" "main"
```

with a finding publishing frequency of `FIFTEEN_MINUTES`. Configured detector features are created with:

```hcl
resource "aws_guardduty_detector_feature" "main"
```

from `var.guardduty_features`.

When `manage_guardduty_locally = false`, this module creates neither the detector nor its feature resources. That is the normal setting for the centrally governed workload environments, where the `security-operations` delegated administrator manages organization enrollment and protection plans.

The local detector-feature resource intentionally ignores provider-reported changes to `additional_configuration` and `status`. Centralized Runtime Monitoring configuration is not managed through this workload resource.

---

### Security Hub CSPM

Security Hub CSPM account enablement and local standards are created only when:

```hcl
manage_securityhub_cspm_locally = true
```

The local resources are:

```hcl
resource "aws_securityhub_account" "main"
resource "aws_securityhub_standards_subscription" "main"
```

The current local standards map includes:

| Key | Standard |
|---|---|
| `aws_fsbp` | AWS Foundational Security Best Practices v1.0.0 |
| `cis` | CIS AWS Foundations Benchmark v5.0.0 |

Additional standards are present as commented options in `main.tf`.

When `manage_securityhub_cspm_locally = false`, this module does not own the workload account's CSPM account resource or standards subscriptions. In the centrally governed platform, those settings are inherited from Security Hub configuration policies managed by `bootstrap/security_operations/security_services`.

### Security Hub V2

Security Hub V2 is enabled locally only when:

```hcl
manage_securityhub_v2_locally = true
```

using:

```hcl
resource "aws_securityhub_account_v2" "main"
```

When the value is `false`, the workload defers V2 enablement to the centrally managed `SECURITYHUB_POLICY` attached to the `Workloads` OU.

---

### Amazon Inspector v2

Conditionally enables Amazon Inspector v2 for the account:

```hcl
resource "aws_inspector2_enabler" "main"
```

Enabled Inspector resource types are controlled by:

```text
var.inspector_resource_types
```

Default enabled resource types:

```text
EC2
```

At the baseline integration layer, `local.effective_inspector_resource_types`
adds `ECR` whenever the effective ECR repository set is non-empty. With no
explicit or ECS-derived repositories, the default remains `EC2` only.
`validate-security-workload.sh` compares live Inspector state with the
effective workload-root output rather than reconstructing this policy.

Lambda scan types are disabled by default.

This baseline encrypts Lambda environment variables with a customer-managed KMS key. Amazon Inspector Lambda standard scanning and Lambda code scanning do not support Lambda functions encrypted with customer-managed keys. Enabling Lambda scan types in this baseline can also generate expected `kms:Decrypt` `AccessDenied` events from the Inspector service-linked role against the Lambda CMK.

Clients that intentionally want Lambda scanning and accept the KMS/encryption tradeoff can override:

```hcl
inspector_resource_types = ["EC2", "LAMBDA", "LAMBDA_CODE"]
```

Supported values:

```text
EC2
ECR
LAMBDA
LAMBDA_CODE
CODE_REPOSITORY
```

`LAMBDA_CODE` requires `LAMBDA` to also be included.

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

This allows Inspector findings to flow into Security Hub. The product subscription remains workload-local even when Security Hub account enablement and standards are centrally governed.

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
| ECR CMK | ECR repository encryption |
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

The key policy allows Lambda service usage for the baseline automation functions.

Amazon Inspector decrypt access is not granted to this key by default. Lambda Inspector scan types are disabled by default because this baseline uses customer-managed KMS encryption for Lambda resources, and Inspector Lambda scanning does not support Lambda functions encrypted with customer-managed keys.

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

### ECR CMK

Creates the ECR KMS key:

```hcl
resource "aws_kms_key" "ecr"
```

Alias:

```hcl
resource "aws_kms_alias" "ecr"
```

Alias name:

```text
alias/<name_prefix>/ecr-cmk
```

The baseline passes `ecr_cmk_arn`, the actual key ARN, to `modules/ecr` for
repository encryption. The alias ARN is exported as metadata but is not used
as the ECR repository encryption key reference. The key has rotation enabled
and currently uses `prevent_destroy = false # CHANGE THIS IN PROD` for the
repository's ephemeral development/test teardown model. Persistent production
usage must reconsider that destruction posture.

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
| `account_id` | AWS account ID | Yes |
| `compliance_topic_arn` | SNS topic ARN used for compliance notifications | Yes |
| `guardduty_features` | List of GuardDuty detector features to enable | Yes |
| `config_remediation_role_arn` | IAM role ARN used by AWS Config remediation actions | Yes |
| `secops_event_bus_name` | Name of the SecOps EventBridge event bus | Yes |
| `secops_topic_arn` | SNS topic ARN used for SecOps alerts | Yes |
| `enable_config` | Whether AWS Config baseline resources are enabled | Yes |
| `enable_rules` | Object controlling which Config baseline rule groups are enabled | No |
| `inspector_enabled` | Whether Amazon Inspector is enabled for the selected resource types | Yes |
| `inspector_resource_types` | Amazon Inspector resource types to enable. Defaults to `["EC2"]`; Lambda scan types are disabled by default | No |
| `sec_notifs_eventbridge_dlq_arn` | ARN of the `security_notifications_eventbridge_dlq` DLQ | Yes |
| `manage_securityhub_cspm_locally` | Whether this module owns Security Hub CSPM enablement and standards in the workload account. Defaults to `true`; centrally governed workload roots set it to `false` | No |
| `manage_securityhub_v2_locally` | Whether this module enables Security Hub V2 directly in the workload account. Defaults to `true`; centrally governed workload roots set it to `false` | No |
| `manage_guardduty_locally` | Whether this module owns the GuardDuty detector and detector features. Defaults to `true`; centrally governed workload roots set it to `false` | No |

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
| `ecr_cmk_arn` | ARN of the ECR repository KMS CMK |
| `ecr_cmk_alias_arn` | ARN of the ECR KMS alias |
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
  account_id                   = var.account_id
  primary_region               = var.primary_region
  centralized_logs_bucket_name = module.storage.centralized_logs_bucket_name

  manage_securityhub_cspm_locally = var.manage_securityhub_cspm_locally
  manage_securityhub_v2_locally   = var.manage_securityhub_v2_locally
  manage_guardduty_locally        = var.manage_guardduty_locally
  guardduty_features              = var.guardduty_features
  enable_rules                    = local.effective_enable_rules
  inspector_enabled               = local.effective_inspector_enabled
  inspector_resource_types        = local.effective_inspector_resource_types

  enable_config               = local.effective_enable_config
  config_role_arn             = module.iam.config_role_arn
  config_remediation_role_arn = module.iam.config_remediation_role_arn

  compliance_topic_arn           = module.monitoring.compliance_topic_arn
  secops_topic_arn               = module.monitoring.secops_topic_arn
  secops_event_bus_name          = module.automation.secops_event_bus_name
  sec_notifs_eventbridge_dlq_arn = module.monitoring.sec_notifs_eventbridge_dlq_arn
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
| `ecr_cmk_arn` | ECR module |
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

For the repository's centrally governed workload environments, use `scripts/validation/validate-security-workload.sh` as the primary workload-level check. Organization-level ownership and policy correctness are validated separately by `validate-security-operations.sh`.

The direct AWS CLI checks below are still useful for troubleshooting. Interpret GuardDuty and Security Hub results according to the ownership mode: centrally governed services should exist and be effective in the workload account even though this module does not own their account-level resources.

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

- One GuardDuty detector ID is returned.
- If `manage_guardduty_locally = false`, the detector is centrally governed rather than owned by this module.

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

- Status is enabled.
- For locally managed GuardDuty, the configured finding publishing frequency is `FIFTEEN_MINUTES`.
- For centrally governed GuardDuty, organization enrollment and protection-plan configuration should be validated from the security-operations layer.

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

- Effective GuardDuty features are listed.
- For local ownership, enabled `var.guardduty_features` entries show `ENABLED`.
- For central ownership, compare effective workload state with the organization configuration validated by the security-operations evidence path.

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

- Security Hub is effective in the workload account.
- Local ownership uses the standards configured in `local.securityhub_standards`.
- The centrally governed platform currently applies AWS Foundational Security Best Practices and CIS AWS Foundations Benchmark v5.0.0 through account configuration policies.

---

### Confirm Inspector Is Enabled

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}" \
  --query 'accounts[0].{AccountStatus:state.status,EC2:resourceState.ec2.status,ECR:resourceState.ecr.status,Lambda:resourceState.lambda.status,LambdaCode:resourceState.lambdaCode.status}' \
  --output table
```

Expected:

- If Inspector is enabled, account status is `ENABLED`.
- Resource types included in inspector_resource_types should show `ENABLED`.
- Resource types not included in inspector_resource_types may show `DISABLED`.
- By default, EC2 scanning is `ENABLED`.
- By default, Lambda and Lambda code scanning are `DISABLED`.
- If Inspector is disabled by deployment profile or explicit override, Inspector resource states may be disabled.
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

- `alias/<name_prefix>/state-cmk`
- `alias/<name_prefix>/logs-cmk`
- `alias/<name_prefix>/ebs-cmk`
- `alias/<name_prefix>/lambda-cmk`
- `alias/<name_prefix>/secrets-cmk`
- `alias/<name_prefix>/backup-cmk`
- `alias/<name_prefix>/ecr-cmk`

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
- ECR CMK

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
- ECR repository access

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

The local fallback configuration currently includes AWS Foundational Security Best Practices and CIS AWS Foundations Benchmark v5.0.0. Additional standards remain commented out.

For the managed multi-account platform, the authoritative workload standards are the centralized Security Hub CSPM configuration policies in `bootstrap/security_operations/security_services`, not this module's local fallback map.

Before enabling more standards, consider:

- Additional finding volume
- Operational maturity
- Remediation ownership
- False positive handling
- Compliance requirements
- Cost and alert fatigue

---

### GuardDuty Feature Selection

`var.guardduty_features` applies only when GuardDuty is managed locally. In the centrally governed platform, organization protection plans and Runtime Monitoring configuration are owned by `bootstrap/security_operations/security_services`.

For standalone/local ownership, enable only features supported in the target Region and account configuration. Unsupported features may be rejected by AWS.

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

First determine the intended ownership mode.

For local ownership, check:

- `manage_securityhub_cspm_locally = true`
- AWS Region is correct
- the account is not already governed by a conflicting organization configuration
- Terraform has permissions for Security Hub account and standards resources

For centralized ownership, do not try to repair the workload by creating competing local account/standards resources. Validate the central configuration policy association and workload-local AWS Config state instead.

Useful command:

```bash
aws securityhub describe-hub \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

---

### Security Hub Standard Subscription Fails

For local ownership, check:

- The standard ARN matches the Region.
- Security Hub is enabled first.
- The standard is supported in the Region.
- The account has permission to subscribe to standards.

For centralized ownership, standards subscriptions are controlled by the Security Hub CSPM configuration policy. Troubleshoot the policy association from the security-operations layer rather than adding workload-local subscriptions.

Current active standard ARN pattern:

```text
arn:aws:securityhub:<region>::standards/aws-foundational-security-best-practices/v/1.0.0
```

---

### GuardDuty Feature Fails to Enable

If GuardDuty is centrally governed, troubleshoot the organization protection plan in the security-operations stack. For local ownership, check:

- The feature name is valid
- The feature is supported in the selected region
- GuardDuty is enabled
- The account has the required GuardDuty permissions
- Organization-level GuardDuty settings are not overriding account-level behavior

Useful command:

```bash
aws guardduty get-detector \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --detector-id "${GUARDDUTY_DETECTOR_ID}" \
  --query 'Features[].[Name,Status]' \
  --output table
```

Expected:

- Effective GuardDuty features are listed.
- For local ownership, enabled `var.guardduty_features` entries show `ENABLED`.
- For central ownership, compare effective workload state with the organization configuration validated by the security-operations evidence path.

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

> If Lambda scan types are enabled and Lambda functions use customer-managed KMS keys, Inspector may generate kms:Decrypt AccessDenied events against the Lambda CMK. The baseline disables Lambda scan types by default to avoid unsupported scanner behavior and alert noise.

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
- GuardDuty and Security Hub account-level ownership is selectable so centrally governed workload accounts do not create competing resources.
- The managed workload environments defer GuardDuty, Security Hub CSPM, and Security Hub V2 account-level governance to the security-operations layer.
- The local fallback Security Hub standards map includes AWS Foundational Security Best Practices and CIS AWS Foundations Benchmark v5.0.0.
- Inspector v2 is enabled conditionally and defaults to EC2 scanning only.
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
- Centralized security governance with workload-local control realization
- Configurable vulnerability detection for supported workloads
- Security control evaluation through AWS Config
- Event-driven tamper detection
- Least privilege KMS service usage
- Production-aligned security defaults

---

## Notes

- Deploy this module before modules that need its KMS outputs. For centrally governed workloads, deploy the central security governance layer before relying on inherited GuardDuty/Security Hub behavior.
- The logs CMK is consumed heavily by logging, storage, monitoring, and Config resources.
- The Lambda CMK is consumed by automation Lambda functions.
- The Secrets Manager CMK is consumed by secrets created outside this module.
- The Backup Vault CMK is consumed by the backup module.
- The ECR CMK key ARN is consumed by the ECR module; the alias ARN is not used
  for repository encryption.
- The tamper detection rule ARN should be passed to the monitoring module so SNS publishing can be permitted.
- The `config_baseline` and `tamper_detection` child modules have their own README files and should be referenced for detailed behavior.
