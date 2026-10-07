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

The flags select which resources this module owns; they do not establish central
services or transfer existing Terraform ownership automatically. Changing a
local-ownership flag from true to false can plan deletion of locally owned
resources. Review the state/ownership migration and central realization before
applying that change, rather than toggling it as a repair shortcut.

The six KMS keys, SSM setting, Inspector product subscription, and two child
module calls are unconditional. Inspector enablement and Config recording have
their own flags. The reusable module has no `deployment_profile` or
`production_retirement_mode` input and cannot infer those controls itself.
Keep the inherited AWS provider Region consistent with `primary_region` and
verify the caller account independently of `account_id`.

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

The local detector-feature resource initializes `status = "ENABLED"` but ignores
subsequent changes to `additional_configuration` and `status`. An unchanged
Terraform plan therefore does not demonstrate reconciliation of those live
feature settings. Central Runtime Monitoring configuration and live coverage
must be inspected through their own ownership/evidence paths.

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
| `aws_fsbp` | AWS Foundational Security Best Practices; exact ARN in `main.tf` |
| `cis` | CIS AWS Foundations Benchmark; exact ARN in `main.tf` |

These are the explicit subscriptions. The local `aws_securityhub_account` also
sets `enable_default_standards = true`, so the map must not be described as an
exclusive two-standard allowlist. Commented standards are not deployed.
Inspect the complete live subscription inventory against the intended local
configuration. Centralized CSPM policies have separate standards controls.

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

The automation functions use a customer-managed key for their environment
variables. [AWS documents a customer-managed-key limitation for Lambda
scanning](https://docs.aws.amazon.com/inspector/latest/user/scanning-lambda.html).
Changing the Inspector resource-type list alone does not change function
configuration, key permissions, or scanning eligibility. Do not interpret an
account-level ENABLED status as proof that those functions were scanned.
Any different scanning/encryption design needs separate implementation and
live-coverage review, not just a documentation input example.

Supported values:

```text
EC2
ECR
LAMBDA
LAMBDA_CODE
CODE_REPOSITORY
```

The supplied workload/baseline validation paths require `LAMBDA_CODE` to be
accompanied by `LAMBDA`. This reusable child validates the allowed names but
does not implement that combination check itself. Its Inspector resource has a
separate nonempty-list precondition when enabled. An accepted input does not
prove per-resource scanning coverage or support in every Region.

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

The subscription is created regardless of `inspector_enabled` and regardless of
local CSPM ownership. It configures an import path, not Inspector scan coverage
or evidence that a finding arrived. When local CSPM ownership is disabled, its
`depends_on` list contains no local hub instance to establish central-policy
readiness; ensure Security Hub is effective in the target account first.

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

All six keys have rotation enabled and a 30-day deletion window. Logs, EBS,
Secrets Manager, ECR, and Backup keys explicitly have `prevent_destroy = false`;
the Lambda key has no `prevent_destroy` guard. These settings do not change with
the workload profile or retirement mode. Source comments are not protection.

The Terraform state CMK is owned by the separate state stack, not this module.
Do not conflate the logs or Secrets Manager key with RDS storage encryption;
inspect the [storage resource](../storage/main.tf) for that separate boundary.
Key rotation and aliases do not preserve a key scheduled for deletion or make
its encrypted data immutable.

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

The logs CMK is shared across logging and notification resources. Its key policy
is not uniformly restricted to individual baseline resource ARNs:

| Grant | Declared restriction |
|---|---|
| Account principal | Account-root IAM delegation with `kms:*` |
| CloudTrail service | Source account plus an encryption-context pattern for that account's trails across Regions |
| Config service-linked role | Constructed exact role principal; role existence is a prerequisite, not created here |
| Config service | Source account |
| Regional CloudWatch Logs service | No log-group encryption-context restriction in this statement |
| S3, SNS, SQS, CloudWatch, EventBridge, log-delivery services | Service-specific actions, but no source-resource condition on these respective statements |
| Firehose service | Source account and regional/account delivery-stream wildcard |
| Inspector service-linked role | Constructed role principal plus source account |

The Config and Inspector role principals remain in this policy even when their
corresponding feature flags are disabled. Do not assume that disabling a feature
removes all key-policy dependencies. In a key policy, `Resource = "*"` identifies
this key; it must not be misreported as a grant over every key in the account.
Full effective access still depends on the applicable identity policies, key
policy, grants, and external restrictions.

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

The key policy includes account-root delegation and an EC2 service grant without
source-account or source-resource conditions on that service statement. It is
not a per-volume authorization inventory.

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

The Lambda service statement uses source-account and regional `kms:ViaService`
conditions, not an explicit function-ARN allowlist. The resource configures
Lambda environment-variable encryption; that does not assert that every form
of function code, deployment artifact, or runtime data uses this key.

No explicit Inspector principal grant is added to this key policy. That fact is
not a complete effective-access evaluation, since account IAM delegation also
exists. Keep the Lambda scanning limitation described above separate from a
claim that adding a key-policy grant alone would make scanning supported.

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

This key encrypts secrets created by consumers such as storage and automation.
Its policy includes account-root delegation and a Secrets Manager service grant
without a secret-ARN or source-account condition on that statement. Secret
access policies and decryption permission must be reviewed separately.

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

The Backup service statement includes a source-account condition, not an exact
vault ARN. Retained recovery data and its actual required encryption keys must
be inventoried together; a vault ARN or protection flag alone is not recovery
proof.

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
as the ECR repository encryption key reference. The key policy contains
account-root IAM delegation; it does not add direct ECR-CMK decrypt grants to
ECS task execution roles. Repository-service access and grants are a separate
part of effective authorization. Its destruction posture is unchanged by the
production profile, as described above.

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

The child is always instantiated. `enable_config=false` disables recorder
status and omits managed rules/remediation; it does not remove the recorder,
delivery channel, or the fixed-delay resource. Rule-family toggles do not alter
the recorder's fixed resource-type list.

The S3 automatic-remediation rule is independent of `enable_rules.s3_baseline`:
it follows `enable_config` alone. See the [Config reference](config_baseline/README.md)
for exact recording scope, catalog, mutation risk, and validation limits.

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
- Shared security-notifications EventBridge DLQ ARN

The child module creates tamper detection logic for critical security services and routes alerts to the SecOps SNS topic.

See the [tamper reference](tamper_detection/README.md). It covers a finite list
of CloudTrail, GuardDuty, Security Hub, KMS, and Config API names, not every
security change. Matching events can be authorized changes or failed attempts;
a notification is not proof that a control was successfully disabled.

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
| `secops_event_bus_name` | Retained compatibility input; not consumed by this module's `main.tf` | Yes |
| `secops_topic_arn` | SNS topic ARN used for SecOps alerts | Yes |
| `enable_config` | Enables recorder status and Config rules/remediation; does not omit recorder/channel resources | Yes |
| `enable_rules` | Object controlling which Config baseline rule groups are enabled | No |
| `inspector_enabled` | Whether Amazon Inspector is enabled for the selected resource types | Yes |
| `inspector_resource_types` | Amazon Inspector resource types to enable. Defaults to `["EC2"]`; Lambda scan types are disabled by default | No |
| `sec_notifs_eventbridge_dlq_arn` | ARN of the `security_notifications_eventbridge_dlq` DLQ | Yes |
| `manage_securityhub_cspm_locally` | Whether this module owns Security Hub CSPM enablement and standards in the workload account. Defaults to `true`; centrally governed workload roots set it to `false` | No |
| `manage_securityhub_v2_locally` | Whether this module enables Security Hub V2 directly in the workload account. Defaults to `true`; centrally governed workload roots set it to `false` | No |
| `manage_guardduty_locally` | Whether this module owns the GuardDuty detector and detector features. Defaults to `true`; centrally governed workload roots set it to `false` | No |

[variables.tf](variables.tf) declares 20 inputs. The 12 required scalar
identifier/naming fields above are `string`; `guardduty_features` is a required
`list(string)`, and `enable_config` / `inspector_enabled` are required `bool`.
`enable_rules` is the eight-boolean object below. Optional ownership flags are
`bool` with default `true`; `inspector_resource_types` is `list(string)` with
default `["EC2"]`. Supplying an empty or incorrectly scoped ARN is not made safe
by the presence of the required field.

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

The IAM **rule family** is disabled by default, but the recorder's inclusion
list still contains four IAM resource types. Disabling these rules does not
shrink that list or establish global-IAM recording suitability in every Region.
The separate IAM log metric filter observes a limited API-name set; it is not a
replacement for Config evaluations or a full identity-control assessment.

KMS rules are enabled in the default family object although `AWS::KMS::Key` is
not in the recorder list. Verify each rule's evaluation/recording requirements
and actual results before claiming KMS coverage; the catalog alone is not
proof of coverage. This observation does not assert that all periodic KMS
rules must fail or never evaluate.

---

## Outputs

The 12 outputs below are defined in [outputs.tf](outputs.tf). Config child outputs
are not forwarded here; nor are state-CMK or Logs/Lambda alias-ARN outputs.
A caller must explicitly expose a child output before `terraform output` can
read it at a workload root.

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

Complete integration excerpt for `baseline/`; the referenced locals and sibling
modules must already exist. Profile resolution occurs in the caller.

```hcl
module "security" {
  source = "../modules/security"

  name_prefix                  = local.name_prefix
  cloud_name                   = var.cloud_name
  environment                  = var.environment
  account_id                   = var.account_id
  primary_region               = data.aws_region.current.region
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

These references are composed in one workload graph, not a requirement to apply
each child module separately. Broad module-level dependencies can introduce
cycles between logging, IAM, storage, monitoring, and security. Preserve the
resource-level references. A dependency on an empty locally owned Security Hub
resource collection does not wait for external centralized enablement.

---

## Validation

Use [validate-security-workload.sh](../../scripts/validation/validate-security-workload.sh)
for workload service state, [validate-kms.sh](../../scripts/validation/validate-kms.sh)
for its key checks, and the separate administrative validators for central
configuration. None of these names establishes exhaustive policy verification.

The workload security validator checks enabled services and active central
administrator relationships. It does not independently consume
`EXPECTED_ACCOUNT_ID`; the explicit preflight below supplies that boundary.
Its Config checks are recorder/channel/rule inventory and recorder-state checks,
not exact recording-type, rule-catalog, remediation, or compliance-result
comparisons. Disabled Config/Inspector paths skip their service checks rather
than proving absence. It does not audit the six Security Hub insight filters.

Run these local examples from the repository root with an initialized, applied
workload root and Bash, AWS CLI, Terraform, and `jq` available. Set a named
workload `AWS_PROFILE`, the intended service `AWS_REGION`, and an independently
known `EXPECTED_ACCOUNT_ID` first. `ENVIRONMENT` defaults to `dev`; select it
explicitly when inspecting another workload. The `${VAR:?message}` expressions
stop on missing values; their messages are not replacement placeholders.

These examples require a named local profile. That is not a requirement to add
`AWS_PROFILE` to GitHub OIDC jobs or other default-credential-chain executions.
The service Region is checked against applied Terraform output; it does not
change the independently configured state-backend Region.

```bash
set -euo pipefail
: "${AWS_PROFILE:?Set the local workload profile}"
: "${AWS_REGION:?Set the intended service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the independently known workload account ID}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
case "$ENVIRONMENT" in dev|staging|prod) ;; *) echo "Invalid workload" >&2; exit 1 ;; esac
[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || { echo "Invalid account ID" >&2; exit 1; }
export AWS_PROFILE AWS_REGION EXPECTED_ACCOUNT_ID
export AWS_DEFAULT_REGION="$AWS_REGION" AWS_PAGER=""

CALLER_ACCOUNT_ID="$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --query Account --output text)"
[[ "$CALLER_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] || {
  echo "Unexpected AWS account; stopping" >&2; exit 1;
}
ACCOUNT_ID="$CALLER_ACCOUNT_ID"
ENV_DIR="environments/${ENVIRONMENT}"
OUTPUTS_JSON="$(terraform -chdir="$ENV_DIR" output -json)"
read_output_string() {
  jq -er --arg key "$1" '
    .[$key].value | if type == "string" and length > 0
    then . else error("Missing or invalid string output: " + $key) end
  ' <<< "$OUTPUTS_JSON"
}
APPLIED_REGION="$(read_output_string primary_region)"
[[ "$AWS_REGION" == "$APPLIED_REGION" ]] || {
  echo "Service Region differs from applied primary_region; stopping" >&2; exit 1;
}
NAME_PREFIX="$(read_output_string name_prefix)"
export NAME_PREFIX
```

This preflight confirms selected context, not every permission, resource, or
configuration. Do not treat a successful API read as proof of delivery or
operating effectiveness.

```bash
LOGS_CMK_ARN="$(read_output_string logs_cmk_arn)"
TAMPER_DETECTION_RULE_NAME="${NAME_PREFIX}-tamper-detection"
./scripts/validation/validate-security-workload.sh "$ENVIRONMENT"
./scripts/validation/validate-kms.sh "$ENVIRONMENT"
```

Interpret the direct reads below against the intended ownership mode, complete
applied input set, and observed results. Script PASS, configured standards,
and absence of findings do not establish compliance or effective protection.

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
DETECTORS_JSON="$(aws guardduty list-detectors \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" --output json)"
GUARDDUTY_DETECTOR_ID="$(jq -er '
  .DetectorIds | if length == 1 then .[0]
  else error("Expected exactly one detector") end
' <<< "$DETECTORS_JSON")"
printf '%s\n' "$GUARDDUTY_DETECTOR_ID"
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
- For local ownership, compare requested features with live state; ignored status drift may require separately reviewed remediation.
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
- Local ownership includes explicit subscriptions and AWS default standards; inventory both.
- For central ownership, compare the live inventory with the actual account configuration policy, not a presumed universal standards list.

---

### Confirm Inspector Is Enabled

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}" \
  --query '{Accounts:accounts,FailedAccounts:failedAccounts}' \
  --output table
```

Expected:

- If Inspector is enabled, account status is `ENABLED`.
- Review `failedAccounts` and the response identity before interpreting statuses.
- Compare all resource statuses with `effective_inspector_resource_types` and
  `effective_inspector_enabled`, not solely the child default or account status.
- When Inspector is disabled, the workload validator skips this comparison;
  inspect live state separately when proving disabled-state posture matters.
- Account-level enablement is not per-image, per-instance, or per-function coverage.

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
  --output json | jq --arg prefix "alias/${NAME_PREFIX}/" \
  '[.Aliases[]? | select(.AliasName | startswith($prefix)) | {AliasName,TargetKeyId}]'
```

Expected aliases include:

- `alias/<name_prefix>/logs-cmk`
- `alias/<name_prefix>/ebs-cmk`
- `alias/<name_prefix>/lambda-cmk`
- `alias/<name_prefix>/secrets-cmk`
- `alias/<name_prefix>/backup-cmk`
- `alias/<name_prefix>/ecr-cmk`

---

### Confirm KMS Key Rotation

The state-key alias belongs to bootstrap, potentially in another Region. Alias
matching does not verify target-key identity, policy, state, or retention.

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

Do not disable or schedule key deletion merely because workload destruction is
approved. First identify retained objects, snapshots, secrets, backups, and
other data still requiring each key, and verify an independently usable copy
where preservation is required. [Pending-deletion keys cannot perform KMS
cryptographic operations](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html);
the waiting period is not continued service availability.

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

There is no profile-derived KMS destruction guard in this module. Five keys
explicitly permit Terraform destruction; the Lambda key has no such guard.
The configured 30-day window delays final key deletion, not the loss of
cryptographic availability. RDS/ALB/Backup-vault protection elsewhere does not
change these key settings.

Any stronger retention or key-lifecycle control requires a separately reviewed
implementation and ownership decision. A documentation statement or source
comment cannot make the keys persistent. Preserve necessary data and keys
before applying an approved teardown, and retain evidence of recoverability.

---

### Security Hub Standards Are Intentionally Selective

The local fallback explicitly subscribes to AWS Foundational Security Best
Practices and CIS AWS Foundations Benchmark, with exact identifiers in
`main.tf`. Local account enablement also enables default standards. This is
not an exclusive approved-standards list; comments create no subscriptions.

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

The fixed recorder list already includes IAM types and excludes KMS keys.
Rule-family selection and recorder scope are separate. Verify actual rule
applicability/results, and review the always-on-with-Config S3 remediation
before treating the rule-family map as an authorization switch.

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
- For local ownership, compare requested features with live state; ignored status drift may require separately reviewed remediation.
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

> Lambda scan types are omitted by default. Verify actual resource eligibility and scan coverage; adding types or decryption permission alone does not resolve the documented customer-managed-key limitation.

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
- Local CSPM has explicit subscriptions plus default standards; central policies must be inspected separately.
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
- Explicit key-policy grants whose actual condition scope must be reviewed
- Caller-resolved workload settings, distinct from this module's fixed KMS lifecycle

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
