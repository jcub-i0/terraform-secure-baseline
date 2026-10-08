# Logging Module

## Overview

The `logging` module provisions the core logging resources for the workload environment.

This includes:

- CloudWatch Log Group for CloudTrail events
- CloudWatch Log Group for VPC Flow Logs
- Multi-region CloudTrail
- CloudTrail log delivery to S3 and CloudWatch Logs
- CloudTrail log file validation
- CloudTrail Insights
- VPC Flow Logs
- Kinesis Data Firehose delivery stream for VPC Flow Logs archival to S3
- CloudWatch Logs subscription filter from VPC Flow Logs to Firehose

This module provides the baseline’s primary audit logging and network visibility foundation.

---

## Purpose

The purpose of this module is to centralize AWS account and VPC activity logs.

It supports:

- AWS API activity auditing
- Multi-region CloudTrail visibility
- Global service event logging
- CloudTrail delivery to centralized S3 storage
- CloudTrail delivery to CloudWatch Logs for detection and alerting
- VPC network traffic visibility
- VPC Flow Logs delivery to CloudWatch Logs
- Long-term VPC Flow Logs archival to S3 through Firehose
- Encrypted log storage using the logs CMK

This module is required by other security and monitoring components that depend on CloudTrail and VPC Flow Log data.

The child module does not accept `deployment_profile` or resolve profile defaults.
Its required `cloudwatch_retention_days` input is applied to both log groups.
The [baseline composition](../../baseline/main.tf) supplies its resolved
`local.effective_cloudwatch_retention_days`; the workload exposes
`effective_cloudwatch_retention_days` for comparison with live resources.

The S3 bucket, lifecycle policy, KMS key, and IAM roles are owned by other
modules. “Centralized” here describes the supplied workload log destination,
not an organization trail or an independently protected cross-account archive.
See the [storage reference](../storage/README.md) for deletion and retention
limits. This logging module provides no Object Lock or immutable-retention
control of its own.

---

## Resources Created

### CloudTrail CloudWatch Log Group

Creates a CloudWatch Log Group for CloudTrail events:

```hcl
resource "aws_cloudwatch_log_group" "cloudtrail"
```

Log group name format:

```text
/aws/cloudtrail/<name_prefix>
```

Configuration:

| Setting | Value |
|---|---|
| Retention | `var.cloudwatch_retention_days` |
| Encryption | Logs CMK |
| Purpose | CloudTrail event delivery and detection source |

This log group is used by CloudTrail and by monitoring detections that inspect CloudTrail events.

Examples of downstream detections include:

- Root account usage
- Unauthorized API calls
- CloudTrail tampering
- IAM policy changes

---

### VPC Flow Logs CloudWatch Log Group

Creates a CloudWatch Log Group for VPC Flow Logs:

```hcl
resource "aws_cloudwatch_log_group" "flowlogs"
```

Log group name format:

```text
/aws/flowlogs/<name_prefix>
```

Configuration:

| Setting | Value |
|---|---|
| Retention | `var.cloudwatch_retention_days` |
| Encryption | Logs CMK |
| Purpose | VPC Flow Logs delivery and Firehose forwarding source |

This log group receives VPC Flow Logs for the workload VPC.

---

### CloudTrail

Creates the environment CloudTrail:

```hcl
resource "aws_cloudtrail" "cloudtrail"
```

CloudTrail configuration:

| Setting | Value |
|---|---|
| Name | `<name_prefix>-CloudTrail` |
| S3 bucket | Centralized logs bucket |
| S3 key prefix | `CloudTrail` |
| KMS key | Logs CMK |
| Multi-region trail | Enabled |
| Logging | Enabled |
| Log file validation | Enabled |
| Global service events | Included |
| CloudWatch Logs delivery | Enabled |
| Management events | Included |
| Read/write type | All |

CloudTrail writes to both:

```text
Centralized Logs S3 Bucket
CloudTrail CloudWatch Log Group
```

This supports both long-term audit retention and near-real-time detection.

---

### CloudTrail Event Selector

The CloudTrail event selector is configured as:

```hcl
event_selector {
  read_write_type           = "All"
  include_management_events = true
}
```

This configures both read and write management events. No data-resource selector
or advanced event selector is declared here: do not infer S3 object access,
Lambda invocation data-event logging, or complete application audit coverage.
`is_multi_region_trail` is an audit-collection setting, not a multi-Region
workload, recovery mechanism, or organization-trail setting. This resource does
not declare `is_organization_trail = true`.

Management events include AWS control-plane API calls such as:

- IAM changes
- EC2 API calls
- S3 control-plane actions
- KMS API calls
- Security service configuration changes
- STS role assumptions

---

### CloudTrail Insights

CloudTrail Insights are enabled for:

```text
ApiCallRateInsight
ApiErrorRateInsight
```

These help detect unusual API call volume or unusual API error rates.

This can provide additional visibility into anomalous activity such as:

- API spikes
- Misconfigured automation
- Failed permission attempts
- Suspicious enumeration
- Unexpected error rate increases

---

### VPC Flow Logs

Creates VPC Flow Logs for the workload VPC:

```hcl
resource "aws_flow_log" "flowlogs"
```

Configuration:

| Setting | Value |
|---|---|
| Resource | VPC |
| Destination type | CloudWatch Logs |
| Log destination | Flow Logs CloudWatch Log Group |
| Traffic type | `ALL` |
| IAM role | Flow Logs role ARN |

Traffic type `ALL` requests records for:

- Accepted traffic
- Rejected traffic

This provides network-flow metadata for investigation, not packet contents or
an assurance that every possible network event is recorded. The resource does
not specify a custom record format or aggregation interval. Configuration and
fresh delivered records must be checked separately.

---

### Kinesis Data Firehose Delivery Stream

Creates a Firehose delivery stream for archiving VPC Flow Logs to S3:

```hcl
resource "aws_kinesis_firehose_delivery_stream" "flowlogs"
```

Delivery stream name format:

```text
<name_prefix>-flowlogs-to-s3
```

Configuration:

| Setting | Value |
|---|---|
| Destination | Extended S3 |
| Bucket | Centralized logs bucket |
| KMS key | Logs CMK |
| Compression | GZIP |
| Buffering interval | 300 seconds |
| Buffering size | 5 MB |

Successful delivery prefix:

```text
vpc-flow-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/
```

Error delivery prefix:

```text
errors/vpc-flow-logs/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/hour=!{timestamp:HH}/!{firehose:error-output-type}/
```

This configures an S3 archival path in addition to caller-selected CloudWatch
retention. The `kms_key_arn` above belongs to the extended-S3 destination; the
resource does not explicitly configure a separate delivery-stream
`server_side_encryption` block. It also declares no record transformation,
decompression, or format-conversion processor. Inspect a delivered object
before assuming its decoded contents are plain flow-log lines.

The error prefix is a configured destination, not a guarantee that every failure
will produce an object there. No separate Firehose diagnostic log group or
failure alarm is created by this module.

---

### CloudWatch Logs Subscription Filter

Creates a CloudWatch Logs subscription filter for VPC Flow Logs:

```hcl
resource "aws_cloudwatch_log_subscription_filter" "flowlogs"
```

Configuration:

| Setting | Value |
|---|---|
| Source log group | VPC Flow Logs CloudWatch Log Group |
| Destination | VPC Flow Logs Firehose delivery stream |
| Filter pattern | Empty string |
| IAM role | CloudWatch Logs to Firehose role ARN |

The empty filter pattern means all flow log events from the log group are forwarded to Firehose.

---

## Log Flow

### CloudTrail Log Flow

CloudTrail logs follow this path:

```text
AWS Account API Activity
    |
    v
CloudTrail
    |
    +--> CloudWatch Logs: /aws/cloudtrail/<name_prefix>
    |
    +--> Centralized Logs S3 Bucket: CloudTrail/
```

CloudWatch Logs enables near-real-time monitoring.

S3 provides longer-term storage for audit, investigation, and evidence retention.

---

### VPC Flow Logs Flow

VPC Flow Logs follow this path:

```text
VPC Network Traffic Metadata
    |
    v
VPC Flow Logs
    |
    v
CloudWatch Logs: /aws/flowlogs/<name_prefix>
    |
    v
CloudWatch Logs Subscription Filter
    |
    v
Kinesis Data Firehose
    |
    v
Centralized Logs S3 Bucket: vpc-flow-logs/
```

CloudWatch Logs provides short-term operational access.

Firehose archives the logs to S3 for longer-term retention and lower-cost storage.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming | Yes |
| `vpc_id` | VPC ID where VPC Flow Logs are enabled | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `cloud_name` | Cloud or project name used by the broader baseline | Yes |
| `centralized_logs_bucket_id` | Name or ID of the centralized logs S3 bucket used by CloudTrail | Yes |
| `logs_cmk_arn` | KMS CMK ARN used by log groups, CloudTrail, and the Firehose S3 destination | Yes |
| `cloudwatch_retention_days` | Required retention value applied to both CloudWatch log groups; caller resolves profile defaults | Yes |
| `cloudtrail_role_arn` | IAM role ARN used by CloudTrail to write to CloudWatch Logs | Yes |
| `flowlogs_role_arn` | IAM role ARN used by VPC Flow Logs to write to CloudWatch Logs | Yes |
| `account_id` | AWS account ID | Yes |
| `firehose_flow_logs_role_arn` | IAM role ARN used by Firehose to deliver VPC Flow Logs to S3 | Yes |
| `centralized_logs_bucket_arn` | ARN of the centralized logs S3 bucket used by Firehose | Yes |
| `cw_to_firehose_role_arn` | IAM role ARN used by CloudWatch Logs to send log events to Firehose | Yes |

All 13 inputs are declared as `string` and have no defaults in
[variables.tf](variables.tf). `cloud_name` and `account_id` remain required
interface fields but are not referenced by this module's `main.tf`; supplying
an account ID does not independently verify the active provider identity.

---

## Outputs

These are child-module outputs from [outputs.tf](outputs.tf), not a promise that
every value is forwarded unchanged by each workload root.

| Name | Description |
|---|---|
| `cloudtrail_log_group_arn` | ARN of the CloudTrail CloudWatch Log Group |
| `cloudtrail_logs_group_name` | Name of the CloudTrail CloudWatch Log Group |
| `flowlogs_firehose_delivery_stream_arn` | ARN of the VPC Flow Logs Firehose delivery stream |
| `flowlogs_log_group_arn` | ARN of the VPC Flow Logs CloudWatch Log Group |
| `cloudtrail_arn` | ARN of the CloudTrail trail |

---

## Usage Example

This complete call belongs in the existing `baseline/` composition, alongside
the referenced modules and locals; it is not an independent Terraform root.

```hcl
module "logging" {
  source = "../modules/logging"

  cloud_name                  = var.cloud_name
  environment                 = var.environment
  name_prefix                 = local.name_prefix

  vpc_id                      = module.networking.vpc_id
  account_id                  = var.account_id

  centralized_logs_bucket_id  = module.storage.centralized_logs_bucket_id
  centralized_logs_bucket_arn = module.storage.centralized_logs_bucket_arn
  logs_cmk_arn                = module.security.logs_cmk_arn
  cloudwatch_retention_days   = local.effective_cloudwatch_retention_days

  cloudtrail_role_arn         = module.iam.cloudtrail_role_arn
  flowlogs_role_arn           = module.iam.flowlogs_role_arn
  firehose_flow_logs_role_arn = module.iam.firehose_flow_logs_role_arn
  cw_to_firehose_role_arn     = module.iam.cw_to_firehose_role_arn
}
```

---

## Dependencies

This module should be deployed after the following resources exist:

- VPC
- Centralized logs S3 bucket
- Logs KMS CMK
- CloudTrail IAM role
- VPC Flow Logs IAM role
- Firehose delivery IAM role
- CloudWatch Logs to Firehose IAM role

The composition uses resource references for ordering, not a required sequence
of separately applying each child module. The IAM module's four logging-role
outputs carry inline-policy dependencies. Avoid adding broad module-level
`depends_on` relationships that would conflict with the existing bidirectional
log-group/role wiring. These dependencies do not poll live delivery readiness.

The module depends heavily on IAM roles created outside this module.

If any of the logging delivery roles are missing or under-permissioned, log delivery may fail.

---

## Validation

Use [validate-logging.sh](../../scripts/validation/validate-logging.sh) for its
implemented checks, then review the additional reads below. The validator
selects the first prefix-matching trail and requires at least one matching
multi-Region trail and one active VPC flow log. Several S3/CW delivery problems,
missing CloudWatch integration, and absent retention values are warnings. It
does not inspect Firehose, subscription filters, fresh S3 objects, event/Insight
selectors, or the CloudTrail digest chain. Its PASS is not an end-to-end logging
or exact-inventory certification.

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
VPC_ID="$(read_output_string vpc_id)"
CENTRALIZED_LOGS_BUCKET_NAME="$(read_output_string centralized_logs_bucket_name)"
LOGS_CMK_ARN="$(read_output_string logs_cmk_arn)"
EXPECTED_RETENTION="$(jq -er '.effective_cloudwatch_retention_days.value |
  if type == "number" and . >= 0 then . else error("Invalid retention output") end' \
  <<< "$OUTPUTS_JSON")"
CLOUDTRAIL_NAME="${NAME_PREFIX}-CloudTrail"
./scripts/validation/validate-logging.sh "$ENVIRONMENT"
```

A failed validator is not made acceptable by a later successful inspection.
Preserve the warnings and command outputs with account, Region, timestamp,
checked-out commit, and deployment provenance.

### Confirm CloudWatch Log Groups

Inspect each exact log-group name rather than all account-wide trail/flow groups:

```bash
for LOG_GROUP_NAME in "/aws/cloudtrail/${NAME_PREFIX}" "/aws/flowlogs/${NAME_PREFIX}"; do
  GROUPS_JSON="$(aws logs describe-log-groups \
    --region "$AWS_REGION" --profile "$AWS_PROFILE" \
    --log-group-name-prefix "$LOG_GROUP_NAME" --output json)"
  jq -e --arg name "$LOG_GROUP_NAME" --arg key "$LOGS_CMK_ARN" \
    --argjson retention "$EXPECTED_RETENTION" '
    [.logGroups[]? | select(.logGroupName == $name)] |
    if length != 1 then error("Expected exactly one log group") else .[0] end |
    if .kmsKeyId != $key then error("Unexpected log key")
    elif $retention == 0 and .retentionInDays != null then error("Unexpected retention")
    elif $retention != 0 and .retentionInDays != $retention then error("Unexpected retention")
    else {logGroupName, retentionInDays, kmsKeyId} end
  ' <<< "$GROUPS_JSON"
done
```

A missing `retentionInDays` is accepted here only when the configured value is
zero (no expiration), not when finite retention is intended. Matching metadata
does not demonstrate recent ingestion.

---

### Confirm CloudTrail Exists

```bash
aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --trail-name-list "${CLOUDTRAIL_NAME}" --no-include-shadow-trails \
  --query 'trailList[].[Name,TrailARN,HomeRegion,LogFileValidationEnabled,IsMultiRegionTrail]' \
  --output table
```

Expected:

- Trail exists
- Trail name matches `<name_prefix>-CloudTrail`
- Log file validation is enabled
- Multi-region trail is enabled

---

### Confirm CloudTrail Logging Status

```bash
aws cloudtrail get-trail-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${CLOUDTRAIL_NAME}"
```

Expected:

- `IsLogging` is `true`
- No recent delivery errors are present

---

### Confirm CloudTrail Event Selectors

```bash
aws cloudtrail get-event-selectors \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --trail-name "${CLOUDTRAIL_NAME}" \
  --query 'EventSelectors'
```

Expected:

- Management events are included
- Read/write type is `All`

---

### Confirm CloudTrail Insights Selectors

```bash
aws cloudtrail get-insight-selectors \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --trail-name "${CLOUDTRAIL_NAME}" \
  --query 'InsightSelectors'
```

Expected:

- `ApiCallRateInsight` is enabled
- `ApiErrorRateInsight` is enabled

---

### Confirm CloudTrail S3 Delivery Location

```bash
aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --trail-name-list "${CLOUDTRAIL_NAME}" --no-include-shadow-trails \
  --query 'trailList[].[Name,S3BucketName,S3KeyPrefix,KmsKeyId]' \
  --output table
```

Expected:

- S3 bucket is the centralized logs bucket
- S3 key prefix is `CloudTrail`
- KMS key is the logs CMK

---

### Confirm VPC Flow Logs

```bash
aws ec2 describe-flow-logs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=resource-id,Values=${VPC_ID}" \
  --query 'FlowLogs[].[FlowLogId,ResourceId,TrafficType,LogDestinationType,LogDestination,FlowLogStatus,DeliverLogsStatus,DeliverLogsErrorMessage]' \
  --output table
```

Expected:

- Flow log exists for the workload VPC
- Traffic type is `ALL`
- Destination type is `cloud-watch-logs`
- Status is `ACTIVE`; delivery status/errors and the exact log destination are reviewed
- Extra flow logs for the same VPC are inventoried rather than silently substituted

---

### Confirm Firehose Delivery Stream

```bash
aws firehose describe-delivery-stream \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --delivery-stream-name "${NAME_PREFIX}-flowlogs-to-s3" \
  --query 'DeliveryStreamDescription.{Name:DeliveryStreamName,Status:DeliveryStreamStatus,Type:DeliveryStreamType,Destinations:Destinations,StreamEncryption:DeliveryStreamEncryptionConfiguration}' \
  --output table
```

Expected:

- Delivery stream exists
- Delivery stream status is `ACTIVE`
- The expected destination has `ExtendedS3DestinationDescription`
- Its bucket, role, `EncryptionConfiguration`, GZIP setting, buffering hints,
  success prefix, and error prefix match the configured destination

`DeliveryStreamType` is not the destination type. Review the destination object;
a stream `ACTIVE` status alone does not prove successful delivery.

---

### Confirm CloudWatch Logs Subscription Filter

```bash
aws logs describe-subscription-filters \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --log-group-name "/aws/flowlogs/${NAME_PREFIX}" \
  --query 'subscriptionFilters[].[filterName,destinationArn,roleArn,filterPattern]' \
  --output table
```

Expected:

- Subscription filter exists
- Destination ARN is the Flow Logs Firehose delivery stream ARN
- Role ARN is the CloudWatch Logs to Firehose role ARN
- Filter name is `<name_prefix>-flowlogs-to-firehose` and pattern is empty
- Any additional subscriptions are accounted for separately

---

### Confirm VPC Flow Logs S3 Archive

After enough traffic and buffering time, list the S3 prefix:

```bash
aws s3 ls "s3://${CENTRALIZED_LOGS_BUCKET_NAME}/vpc-flow-logs/" \
  --recursive \
  --profile "${AWS_PROFILE}"
```

Expected:

- GZIP-compressed VPC Flow Logs are delivered under the `vpc-flow-logs/` prefix
- Objects follow the expected year/month/day/hour prefix structure

Note:

Firehose buffers records before delivery, so new objects may not appear immediately.

---

### Confirm CloudTrail S3 Delivery

After CloudTrail has delivered logs, list the CloudTrail prefix:

```bash
aws s3 ls "s3://${CENTRALIZED_LOGS_BUCKET_NAME}/CloudTrail/" \
  --recursive \
  --profile "${AWS_PROFILE}"
```

Expected:

- CloudTrail log objects exist under the `CloudTrail/` prefix
- Delivery path includes the intended account and Region
- Recent object timestamps correspond to activity during the inspection window

Listing alone does not prove encryption or digest integrity. For an explicitly
selected delivered object, inspect metadata without printing its contents:

```bash
: "${LOG_OBJECT_KEY:?Set one reviewed object key from the listing}"
aws s3api head-object \
  --region "$AWS_REGION" --profile "$AWS_PROFILE" \
  --bucket "$CENTRALIZED_LOGS_BUCKET_NAME" --key "$LOG_OBJECT_KEY" \
  --query '{LastModified:LastModified,Size:ContentLength,Encryption:ServerSideEncryption,Key:SSEKMSKeyId,Version:VersionId}' \
  --output json
```

Compare the encryption/key metadata with `LOGS_CMK_ARN`. One object's result
establishes neither the encryption of every object nor complete delivery.

---

## Operational Considerations

### CloudTrail Is a Security-Critical Resource

CloudTrail provides the baseline audit record for AWS API activity.

Do not disable CloudTrail unless there is a controlled migration or emergency recovery reason.

Stopping or deleting CloudTrail should trigger monitoring and tamper detection alerts elsewhere in the baseline.

---

### CloudTrail Log File Validation

Log file validation is configured, but enabling it is not the same as verifying
a digest chain for a selected account, Region, and time range. Retain a separate
integrity-verification result when that claim is required. Neither this module
nor `validate-logging.sh` performs that verification. See the
[AWS log-integrity guide](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html)
for the distinction between enabling and validating log integrity.

---

### CloudWatch Retention vs. S3 Retention

CloudWatch Log Groups use the supplied `cloudwatch_retention_days` value.

Longer-term retention is handled by S3 through the centralized logs bucket lifecycle policy.

A lifecycle expiration/transition policy is not an immutability or minimum
preservation guarantee. The baseline's storage reference documents a logs
bucket without Object Lock and with force deletion enabled. Preserve required
logs and their decryption keys independently before workload retirement;
this module does not enforce their survival.

---

### VPC Flow Logs Capture Metadata, Not Packet Contents

VPC Flow Logs capture metadata about network flows.

They do not capture packet payloads.

Flow logs are useful for:

- Traffic troubleshooting
- Rejected connection analysis
- Network investigation
- Unexpected egress review
- Security group and NACL validation

They are not a packet capture replacement.

---

### Firehose Delivery Is Buffered

Firehose does not write every log event to S3 immediately.

Current buffering configuration:

```text
Buffering interval: 300 seconds
Buffering size: 5 MB
```

These are buffering settings, not a maximum end-to-end delivery latency.
Upstream collection, traffic volume, retries, permissions, and service errors
can affect observed delivery. No traffic or an empty error prefix is not proof
that the archival path has been exercised.

---

### IAM Role Dependencies

This module relies on IAM roles passed in through variables.

Required roles include:

- CloudTrail to CloudWatch Logs role
- VPC Flow Logs to CloudWatch Logs role
- Firehose to S3 role
- CloudWatch Logs to Firehose role

If delivery fails, IAM role trust policies and permissions should be checked first.

---

## Troubleshooting

### CloudTrail Is Not Delivering to CloudWatch Logs

Check:

- CloudTrail exists and logging is enabled
- `cloud_watch_logs_group_arn` is configured
- CloudTrail log group exists
- CloudTrail IAM role ARN is correct
- CloudTrail IAM role allows writing to the log group
- Logs CMK allows required CloudTrail and CloudWatch Logs usage

Useful command:

```bash
aws cloudtrail get-trail-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${CLOUDTRAIL_NAME}"
```

---

### CloudTrail Is Not Delivering to S3

Check:

- Centralized logs bucket exists
- CloudTrail bucket policy allows CloudTrail writes
- CloudTrail S3 key prefix is `CloudTrail`
- Logs CMK allows CloudTrail usage
- CloudTrail status does not show S3 delivery errors
- Bucket policy encryption requirements match CloudTrail delivery behavior

Useful command:

```bash
aws cloudtrail get-trail-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --name "${CLOUDTRAIL_NAME}" \
  --query '{IsLogging:IsLogging,LatestDeliveryError:LatestDeliveryError,LatestDeliveryTime:LatestDeliveryTime}'
```

---

### VPC Flow Logs Are Not Appearing in CloudWatch Logs

Check:

- VPC Flow Log resource exists
- Flow log status is `ACTIVE`
- Flow Logs IAM role ARN is correct
- Flow Logs IAM role allows writes to the flow logs log group
- VPC has traffic after the flow log was created
- CloudWatch Log Group exists and uses the correct name

Useful command:

```bash
aws ec2 describe-flow-logs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=resource-id,Values=${VPC_ID}"
```

---

### VPC Flow Logs Are Not Archiving to S3

Check:

- Firehose delivery stream exists and is active
- CloudWatch Logs subscription filter exists
- CloudWatch Logs to Firehose role is correct
- Firehose role can write to the centralized logs bucket
- Logs CMK allows Firehose to encrypt delivered objects
- Centralized logs bucket policy allows Firehose delivery
- Firehose error prefix does not contain failed delivery records

Useful command:

```bash
aws firehose describe-delivery-stream \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --delivery-stream-name "${NAME_PREFIX}-flowlogs-to-s3"
```

---

### Subscription Filter Fails to Create

Check:

- The destination Firehose delivery stream exists
- The CloudWatch Logs to Firehose role trust policy allows CloudWatch Logs
- The role allows the required Firehose put actions
- The log group exists before the subscription filter is created
- The destination and log group are in the same region

---

### KMS Access Errors

Check the logs CMK policy and IAM permissions for:

- CloudTrail
- CloudWatch Logs
- VPC Flow Logs
- Firehose
- S3 log delivery paths
- Terraform execution role

KMS access failures can prevent log encryption, log delivery, or Firehose archival.

---

## Security Notes

- CloudTrail is multi-region.
- CloudTrail includes global service events.
- CloudTrail log file validation is enabled.
- CloudTrail management events include both read and write events.
- CloudTrail Insights are enabled for API call rate and API error rate anomalies.
- CloudTrail logs are delivered to both CloudWatch Logs and S3.
- VPC Flow Logs capture accepted and rejected traffic.
- CloudWatch Log Groups are encrypted with the logs CMK.
- CloudWatch Log Groups use caller-supplied retention; missing finite retention must be investigated.
- Firehose archives VPC Flow Logs to the centralized logs bucket.
- Firehose uses GZIP compression.
- Firehose delivery to S3 is encrypted with the logs CMK.
- Long-term retention is handled by the centralized logs bucket lifecycle policy.

---

## Design Principles

This module follows:

- Centralized audit logging
- Defense-in-depth visibility
- Encrypted log storage
- Multi-region control-plane auditing
- Network traffic metadata collection
- Near-real-time detection support
- Long-term evidence retention
- Separation of log collection and log storage

---

## Notes

- Deploy this module after the centralized logs bucket and logs CMK exist.
- The CloudTrail log group name output is consumed by the monitoring module.
- The CloudTrail ARN output may be consumed by storage, monitoring, or validation workflows.
- The Firehose delivery stream ARN can be used for validation or future integrations.
- Retention, S3 preservation, and key survival must be reviewed together; neither rotation nor a lifecycle policy makes logs immutable.
- Firehose delivery is buffered and may take several minutes to appear in S3.
- CloudTrail and VPC Flow Logs are foundational evidence sources for SOC 2 and ISO 27001 readiness.
