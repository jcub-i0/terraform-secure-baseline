# AWS Config Baseline Module

## Overview

The `config_baseline` module configures an AWS Config recorder and delivery
channel, a selectable AWS-managed rule catalog, and one automatic S3
remediation. It evaluates supported resource configuration; it is not a
preventive enforcement layer for every listed control.

The parent security module always calls this child. `enable_config` controls
recorder status and rule/remediation creation, not whether the whole child or
its recorder/channel exists:

| Setting | Recorder/channel/fixed delay | Recorder status | Catalog rules | S3 remediation rule/configuration |
|---|---|---|---|---|
| `enable_config = false` | Retained | Disabled | Absent | Absent |
| `enable_config = true` | Retained | Enabled | Selected by family flags | Created independently of family flags |

Turning off `s3_baseline` alone does **not** disable S3 automatic remediation.
Applying that remediation can affect intentionally public buckets; this module
does not guarantee that workloads will remain unaffected.

Implementation: [main.tf](main.tf), [rules.tf](rules.tf),
[remediations.tf](remediations.tf), and [variables.tf](variables.tf).

---

## What This Module Deploys

### AWS Config Recorder

The recorder uses `ALL_SUPPORTED_RESOURCE_TYPES`, with
`all_supported = true` and `include_global_resource_types = true`. This
includes current and future AWS Config-supported resource types in the
selected Region, including `AWS::KMS::Key`. The global IAM switch adds
`AWS::IAM::User`, `AWS::IAM::Group`, `AWS::IAM::Role`, and
`AWS::IAM::Policy`, independently of the `iam_baseline` rule-family toggle.

**Region boundary:** The platform currently uses `us-east-1`, which supports
legacy global IAM recording. IAM types cannot be recorded in Regions added to
AWS Config after February 2022. Deployments in other Regions must review
global-resource support and choose one supported Region for global IAM to avoid
duplicate configuration items. Other global resource types have separate
home-Region behavior.

**Operational impact:** All-supported recording increases resource coverage,
configuration-item volume, AWS Config charges, and potentially rule evaluations.
It can increase costs sharply during initial discovery or with short-lived
resources. Verify actual recorded resources, regional support, rule results,
and costs; a configuration setting alone does not prove that every item was
recorded or evaluated.

The delivery channel uses the supplied S3 bucket, `Config` prefix, logs CMK, and
compliance SNS topic. The module waits a fixed 20 seconds after channel creation
before setting recorder status. This is not a retrying delivery-health poll.
It does not create the bucket, key, role, topic, or a Config aggregator.

---

### Auto-Remediation

When Config is enabled, a separate rule named
`<name_prefix>-s3-bucket-public-read-block` uses
`S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`. Its remediation invokes
`AWSConfigRemediation-ConfigureS3BucketPublicAccessBlock` automatically with:

| Setting | Declared value |
|---|---|
| Resource type | `AWS::S3::Bucket` |
| Target type | `SSM_DOCUMENT` |
| Automatic attempts | `3` |
| Retry interval | `60` seconds |
| `AutomationAssumeRole` parameter | `var.config_remediation_role_arn` |
| `BucketName` parameter | Evaluated `RESOURCE_ID` |

Only those two document parameters are explicitly supplied. The resource does
not pin a document target version or define separate block-public-access
boolean parameters; inspect the applicable AWS-managed document and actual
execution result rather than inventing defaults in this reference.

There is no independent remediation-enable input, approval lookup, or
workload-prefix/tag scope on the rule. Its name prefix labels the rule; it does
not limit evaluation/remediation to similarly named buckets. Review affected
bucket scope and role authority before enablement. A successful configuration
Apply does not prove remediation succeeded or that exposure never occurred.

The separate rule is present even when `enable_rules.s3_baseline = false` or
all catalog families are disabled. It is the **only Terraform-managed rule**
using `S3_BUCKET_LEVEL_PUBLIC_ACCESS_PROHIBITED`, regardless of family flags.
Its existing name, Terraform resource address, and remediation binding remain
unchanged.

---

### Managed Rule Pack

The module has 21 catalog entries in eight families. With Config enabled and
the default family object, it creates 19 catalog rules (the two IAM rules are
omitted) plus the separate S3 remediation rule. Enabling every family creates
21 catalog rules plus that separate rule. These counts are configuration
inventory, not counts of passing evaluations.

Each catalog rule uses the AWS-owned identifier below. No custom rule scope,
input parameters, or maximum evaluation frequency is set on the catalog
resource. The parent does not independently verify a rule's AWS-managed
implementation, resource applicability, or evaluation freshness.

| Family | AWS-managed identifiers |
|---|---|
| S3 | `S3_BUCKET_PUBLIC_READ_PROHIBITED`, `S3_BUCKET_PUBLIC_WRITE_PROHIBITED`, `S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED`, `S3_BUCKET_VERSIONING_ENABLED` |
| CloudTrail | `CLOUD_TRAIL_ENABLED`, `MULTI_REGION_CLOUD_TRAIL_ENABLED`, `CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED` |
| RDS | `RDS_STORAGE_ENCRYPTED`, `RDS_INSTANCE_PUBLIC_ACCESS_CHECK` |
| EBS | `ENCRYPTED_VOLUMES` |
| Security groups | `INCOMING_SSH_DISABLED` |
| IAM | `ROOT_ACCOUNT_MFA_ENABLED`, `IAM_PASSWORD_POLICY` |
| EC2 | `EBS_OPTIMIZED_INSTANCE`, `EC2_IMDSV2_CHECK`, `EC2_VOLUME_INUSE_CHECK`, `EC2_INSTANCE_NO_PUBLIC_IP` |
| KMS | `CMK_BACKING_KEY_ROTATION_ENABLED`, `KMS_CMK_NOT_SCHEDULED_FOR_DELETION`, `KMS_KEY_POLICY_NO_PUBLIC_ACCESS`, `KMS_KEY_TAGGED` |

---

## Existing-State Transition

For environments where the S3 rule family was previously applied, Terraform
must destroy only the **redundant catalog rule**
`aws_config_config_rule.managed["s3_bucket_level_public_access_prohibited"]`.
The existing `aws_config_config_rule.s3_public_access_block[0]` and
`aws_config_remediation_configuration.s3_public_access_block[0]` remain
unchanged, including the live Config rule name
`<name_prefix>-s3-bucket-public-read-block`. No Terraform `moved` block,
state removal, import, or replacement of the remediation rule is appropriate.

Review the complete environment plan before applying: the expected intentional
destruction is the redundant Config rule, along with its historical evaluation
results. Verify the remediation rule and configuration remain present afterward.
Do not apply if the plan would delete or replace either remediation resource.
AWS Config rule deletion is asynchronous and may affect Config recording costs
temporarily; this change does not disable the recorder or its remediation.

---

## Rule Families

### S3 Baseline

Evaluates selected S3 exposure and storage settings.

Includes:

- Public access prohibited
- Public read prohibited
- Public write prohibited
- Server-side encryption required
- Versioning enabled

---

### CloudTrail Baseline

Evaluates selected CloudTrail settings; it does not restart a stopped trail.

Includes:

- CloudTrail enabled
- Multi-region trails enabled
- Log file validation enabled

---

### RDS Baseline

Evaluates encryption and public accessibility, not failover, retention, or recovery.

Includes:

- Storage encryption required
- Public accessibility prohibited

---

### EBS Baseline

Evaluates EBS encryption configuration.

Includes:

- EBS volumes must be encrypted

---

### Security Group Baseline

Evaluates SSH exposure; it does not change security-group rules.

Includes:

- SSH from 0.0.0.0/0 prohibited

---

### IAM Baseline

Evaluates the two cataloged identity settings when enabled.

Includes:

- Root MFA required
- Password policy enforcement

The family defaults to disabled. Global IAM resources remain in the recorder
scope independently of the IAM rule-family toggle. Verify recording support,
policy applicability, and evidence independently of whether users are federated.

---

### EC2 Baseline

Evaluates the four cataloged compute settings; it does not patch or replace instances.

Includes:

- IMDSv2 required
- EBS optimization required
- Orphaned volume detection
- Public IP assignment prohibited

---

### KMS Baseline

Evaluates the four KMS catalog entries listed above. The all-supported
recorder includes KMS key configuration items when Config is enabled, but rule
creation alone does not prove evaluation results, key-policy safety, or
recoverability of data under a retained key.

---

## Rule Family Toggles

Each rule family can be enabled or disabled via:

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

## Inputs

All inputs are declared in [variables.tf](variables.tf). The parent resolves
workload profile defaults before calling this module.

| Name | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | Required | Recorder/rule naming prefix, not evaluated-resource scope |
| `environment` | `string` | Required | Tags on the separate remediation rule |
| `enable_config` | `bool` | `false` | Recorder status and catalog/remediation creation |
| `enable_rules` | Eight-boolean object | Above | Catalog selection; independent of recorder resource types and separate remediation |
| `tags` | `map(string)` | `{ Terraform = "true" }` | Catalog rule tags, not remediation-rule or recorder scope |
| `config_role_arn` | `string` | Required | Existing recorder IAM role |
| `centralized_logs_bucket_name` | `string` | Required | Existing destination bucket |
| `compliance_topic_arn` | `string` | Required | Existing Config notification topic |
| `config_remediation_role_arn` | `string` | Required | SSM automation role |
| `logs_cmk_arn` | `string` | Required | Delivery-channel encryption key |

There is no `config_rule_name_prefix` input. Reusable calls must still supply
required dependencies when recording is disabled. The child inherits its
provider; it has no independent account/Region assertion.

Complete caller example for `modules/security/`, not a standalone root:

```hcl
module "config_baseline" {
  source = "./config_baseline"

  name_prefix                  = var.name_prefix
  environment                  = var.environment
  enable_config                = var.enable_config
  config_role_arn              = var.config_role_arn
  compliance_topic_arn         = var.compliance_topic_arn
  config_remediation_role_arn  = var.config_remediation_role_arn
  centralized_logs_bucket_name = var.centralized_logs_bucket_name
  logs_cmk_arn                 = aws_kms_key.logs.arn
  enable_rules                 = var.enable_rules
}
```

The parent does not pass `tags`, so the catalog uses the child default.

## Outputs

[outputs.tf](outputs.tf) exposes exactly five child outputs:

| Name | Meaning and disabled behavior |
|---|---|
| `managed_config_rule_names` | Catalog rule names only; empty when Config is disabled |
| `managed_config_rule_arns` | Catalog rule ARNs only; excludes the separate remediation rule |
| `s3_public_access_remediation_rule_name` | Separate remediation rule name, or null when disabled |
| `config_recorder_name` | Retained recorder identity even when recording is disabled |
| `enabled_rule_families` | Family input flags, which can remain true even when no catalog rules exist |

The parent security module does not forward these outputs to the workload root.
Do not assume `terraform output managed_config_rule_names` is available there.

---

## Design Philosophy

Configuration assessment and resource mutation are distinct responsibilities.
The managed rule catalog reports evaluations; the separate S3 remediation can
change bucket public-access settings automatically. Neither module naming nor
an audit-oriented purpose makes that mutation universally safe.

Review deployment scope and dependencies before enablement. This module does
not implement application-aware approval, exception management, rollback,
patching, or an assurance that all findings will be remediated.

---

## Compliance Alignment

Recorder configuration, rule inventory, evaluations, and remediation execution
can contribute evidence for logging, encryption, exposure, and identity-control
reviews. They do not establish certification, legal compliance, complete
resource coverage, or sustained operating effectiveness.

For each control claim, retain evaluated resources, applicable rule settings,
result timestamps, exceptions, and any remediation execution outcome. The
presence of a rule or an empty finding list is insufficient.

---

## Validation

The workload security validator checks the named recorder, its all-supported
and global-IAM recording group, live recorder status, and channel/rule presence.
It does not verify actual configuration-item freshness, exact rule evaluations,
or automatic remediation outcomes; it skips enabled-state checks when Config
is disabled. Inspect recorded inventory and evaluations separately.

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
RECORDER_JSON="$(aws configservice describe-configuration-recorders \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --configuration-recorder-names "$NAME_PREFIX" --output json)"
jq -e --arg name "$NAME_PREFIX" '
  [.ConfigurationRecorders[]? | select(.name == $name)] |
  if length == 1 then .[0] else error("Expected exact recorder") end
' <<< "$RECORDER_JSON"
aws configservice describe-configuration-recorder-status \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --configuration-recorder-names "$NAME_PREFIX" --output json
aws configservice describe-delivery-channels \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" --output json
```

Review the exact resource-type list, recording strategy/status, channel bucket,
prefix, KMS key, and topic against applied intent. The delivery channel has no
explicit name in the Terraform resource; do not infer its identity from a
prefix. Recorder presence remains expected when `enable_config=false`.

When Config is enabled, inspect the exact separate remediation rule:

```bash
REMEDIATION_RULE_NAME="${NAME_PREFIX}-s3-bucket-public-read-block"
aws configservice describe-config-rules \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --config-rule-names "$REMEDIATION_RULE_NAME" --output json
aws configservice describe-remediation-configurations \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --config-rule-names "$REMEDIATION_RULE_NAME" --output json
aws configservice describe-remediation-execution-status \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --config-rule-name "$REMEDIATION_RULE_NAME" --output json
```

These reads do not start remediation. Compare the created catalog separately
with `rules.tf` and the effective family object, and examine per-resource
compliance/evaluation timestamps. No execution history means this read has not
proved a successful repair. Do not intentionally expose a live bucket merely
to generate evidence.

---

## Intended Use

This module is designed as a foundational layer for:
- Secure-by-default SaaS infrastructure
- Cloud security consulting engagements
- Continuous compliance monitoring
