# Tamper Detection Module

## Overview

The `tamper_detection` module creates an EventBridge-based alerting control for detecting attempts to disable, delete, or modify core AWS security services.

It configures a regional default-bus EventBridge rule and an SNS target with
retry/DLQ settings. Successful delivery and human receipt require separate
evidence. The module does not prevent the API call or recover the changed
control. See [main.tf](main.tf) for the authoritative pattern and transformer.

---

## Purpose

This module helps detect suspicious changes to security controls such as:

- CloudTrail
- GuardDuty
- Security Hub
- KMS
- AWS Config

These events may also be authorized administration or failed requests. No
success-status, approval, or intended-resource test is included in the pattern.

---

## Architecture

```text
AWS API Call
    |
    v
CloudTrail Event
    |
    v
EventBridge Rule
    |
    v
SNS Topic
    |
    v
SecOps Notification
```

---

## Detected Actions

The pattern requires `detail-type = "AWS API Call via CloudTrail"`, one of the
five service `detail.eventSource` values, and one action from a flat name list.
The grouping below explains the catalog; the JSON does not pair each action
exclusively with its displayed service. `DisassociateFromMasterAccount` appears
twice in the source list, yielding 25 entries but 24 unique names.

There is no top-level `source`, account, resource ARN, or successful-response
filter. No event-bus name is supplied, so the rule uses the default bus. The
naming prefix does not scope affected resources. A multi-Region CloudTrail
trail elsewhere does not turn this into a cross-Region or organization-wide
EventBridge forwarding system. These are the configured action names:

### CloudTrail

- `StopLogging`
- `DeleteTrail`
- `UpdateTrail`
- `PutEventSelectors`
- `PutInsightSelectors`

### GuardDuty

- `DeleteDetector`
- `UpdateDetector`
- `DisassociateFromMasterAccount`
- `DisassociateMembers`

### Security Hub

- `DisableSecurityHub`
- `DeleteMembers`
- `DisassociateFromMasterAccount`

### KMS

- `ScheduleKeyDeletion`
- `DisableKey`
- `PutKeyPolicy`
- `UpdateKeyDescription`

---

### AWS Config

- `StopConfigurationRecorder`
- `DeleteConfigurationRecorder`
- `PutConfigurationRecorder`
- `DeleteDeliveryChannel`
- `PutDeliveryChannel`
- `DeleteConfigRule`
- `PutConfigRule`
- `DeleteRemediationConfiguration`
- `PutRemediationConfigurations`

---

## Alert Behavior

The target `TamperAlertsToSNS` points to the supplied `secops_topic_arn` and
uses the supplied shared notification DLQ:

| Target setting | Value |
|---|---|
| Maximum event age | 3,600 seconds |
| Maximum retry attempts | 3 |
| Dead-letter ARN | `var.sec_notifs_eventbridge_dlq_arn` |

These settings concern EventBridge delivery to SNS, not downstream subscriber
receipt. The child does not create the topic, queue, queue policy, KMS key,
subscriptions, or an independent fallback alert channel. Their authorization
and failure handling are composed in [monitoring](../../monitoring/README.md).
It has no enable toggle and is always called by the parent security module.

The alert includes:

- Action
- Service
- Time
- AWS account
- Region
- Actor ARN
- Source IP
- MFA status, when the source event contains that session attribute

Missing actor/MFA fields are not evidence of failed MFA or an unauthorized
caller. The message omits the original request parameters, response/error
details, and full affected-resource context. Inspect the source CloudTrail
event before deciding that an API call succeeded or that a control was weakened.
The rule is a selected API-name detector, not complete tamper coverage.

---

## Usage

This complete integration call belongs in `modules/security/`, with its
variables already declared. It is not an independently runnable root.

```hcl
module "tamper_detection" {
  source = "./tamper_detection"

  name_prefix                    = var.name_prefix
  cloud_name                     = var.cloud_name
  environment                    = var.environment
  secops_topic_arn               = var.secops_topic_arn
  sec_notifs_eventbridge_dlq_arn = var.sec_notifs_eventbridge_dlq_arn
}
```

---

## Inputs

| Name | Description |
|------|-------------|
| `cloud_name` | Name of the cloud environment |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` |
| `name_prefix` | Naming prefix used for created resources |
| `secops_topic_arn` | SNS topic ARN used for tamper alerts |
| `sec_notifs_eventbridge_dlq_arn` | Existing shared notification EventBridge DLQ ARN |

All five inputs in [variables.tf](variables.tf) are required `string` values,
without defaults. `cloud_name` is retained in the interface but unused by
`main.tf`. Provider account/Region selection is inherited; this module has no
independent account/Region guard or validation of ARN ownership.

---

## Outputs

| Name | Description |
|------|-------------|
| `tamper_detection_rule_name` | Name of the EventBridge tamper detection rule |
| `tamper_detection_rule_arn` | ARN of the EventBridge tamper detection rule |

---

## Validation

Read the exact live rule and target before interpreting notifications. These
examples do not disable a security service, publish an event, or invoke a
response function.

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
TAMPER_RULE_NAME="${NAME_PREFIX}-tamper-detection"
RULE_JSON="$(aws events describe-rule --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --event-bus-name default --name "$TAMPER_RULE_NAME" --output json)"
jq -e --arg name "$TAMPER_RULE_NAME" '
  if .Name == $name and .State == "ENABLED" then
    {Name,Arn,State,EventBusName,Pattern:(.EventPattern | fromjson)}
  else error("Unexpected or disabled rule") end
' <<< "$RULE_JSON"
aws events list-targets-by-rule --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --event-bus-name default --rule "$TAMPER_RULE_NAME" --output json
```

Check target `TamperAlertsToSNS`, exact destination/DLQ ARNs, retry values, and
transformer against Terraform. Then test the live pattern without submitting an
event to a bus. `test-event-pattern` only evaluates the provided pattern/event;
it does not test SNS delivery, authorization, or actual CloudTrail emission.

```bash
PATTERN_TEST_DIR="$(mktemp -d)"
chmod 700 "$PATTERN_TEST_DIR"
jq -er '.EventPattern' <<< "$RULE_JSON" > "$PATTERN_TEST_DIR/pattern.json"
TEST_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq -n --arg account "$ACCOUNT_ID" --arg region "$AWS_REGION" --arg time "$TEST_TIME" '
  {version:"0",id:"documentation-pattern-check",account:$account,region:$region,
   source:"aws.config",time:$time,resources:[],
   "detail-type":"AWS API Call via CloudTrail",
   detail:{eventSource:"config.amazonaws.com",eventName:"PutConfigRule"}}
' > "$PATTERN_TEST_DIR/matching.json"
jq '.detail.errorCode = "AccessDenied"' "$PATTERN_TEST_DIR/matching.json" \
  > "$PATTERN_TEST_DIR/failed-attempt.json"
jq '.detail.eventName = "DescribeConfigRules"' "$PATTERN_TEST_DIR/matching.json" \
  > "$PATTERN_TEST_DIR/nonmatching.json"
for CASE in matching failed-attempt nonmatching; do
  aws events test-event-pattern --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --event-pattern "file://${PATTERN_TEST_DIR}/pattern.json" \
    --event "file://${PATTERN_TEST_DIR}/${CASE}.json" --output json \
    > "$PATTERN_TEST_DIR/${CASE}-result.json"
done
jq -e '.Result == true' "$PATTERN_TEST_DIR/matching-result.json"
jq -e '.Result == true' "$PATTERN_TEST_DIR/failed-attempt-result.json"
jq -e '.Result == false' "$PATTERN_TEST_DIR/nonmatching-result.json"
printf 'Retained pattern-test evidence: %s\n' "$PATTERN_TEST_DIR"
```

The failed-attempt match is intentional evidence of the pattern's lack of a
success filter, not a detector defect fixed by this document. Retain the
source commit, inspected account/Region, rule JSON, and results separately from
live notification tests. [AWS CLI pattern-test reference](https://docs.aws.amazon.com/cli/latest/reference/events/test-event-pattern.html).

---

## Important Notes

- This module depends on CloudTrail events being available in EventBridge.
- This module does not prevent tampering; it detects and alerts on suspicious activity.
- Alerts should be reviewed by SecOps or platform administrators.
- The SNS topic should be monitored by the appropriate security response team.

---

## Summary

The `tamper_detection` module provides a lightweight but important detection layer for security control changes.

It configures selected API-change notifications for investigation. Rule
presence, a synthetic pattern match, or absence of alerts does not establish
complete coverage, successful control protection, or notification delivery.
