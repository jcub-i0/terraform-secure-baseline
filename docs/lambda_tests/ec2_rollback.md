# LAMBDA FUNCTION TESTS - EC2 ROLLBACK

## Purpose

This document provides manual tests used to validate the **EC2 Rollback Lambda** behavior before and after changes.

The EC2 Rollback Lambda restores an EC2 instance from the `Quarantine` security group back to its original security group configuration after a rollback event is submitted. Approval is an operational prerequisite:
the handler checks that `approved_by` and `ticket_id` are present, but does not
authenticate the named approver or consult a ticket/approval system.

This test validates the rollback workflow in the context of the full `tf-secure-baseline` architecture, including:

- Multi-account environments: `dev`, `staging`, and `prod`
- Centralized IAM Identity Center access
- Environment-specific `SecOps-Operator` groups
- Custom EventBridge security operations bus
- Controlled manual rollback workflow
- SNS-based SecOps notifications

---

## Testing Approach

The `EC2 Rollback` Lambda is not intended to be invoked directly during normal operations.

Instead, rollback is triggered by sending an approved custom event to the environment-specific `secops` EventBridge bus.

This document includes two test methods:

1. **Manual rollback event from the AWS Console**
   - Uses the EventBridge console
   - Requires signing in through IAM Identity Center

2. **Manual rollback event from the AWS CLI**
   - Uses a locally configured AWS CLI SSO profile
   - Sends an event to the SecOps event bus using `events:PutEvents`

---

## Workflow Context

The rollback workflow is designed to happen after EC2 isolation.

Expected flow:

```text
Security Hub Finding
    |
    v
EC2 Isolation Lambda
    |
    v
Instance moved to Quarantine Security Group
    |
    v
SecOps review / approval
    |
    v
SecOps-Operator sends rollback event to EventBridge
    |
    v
EC2 Rollback Lambda
    |
    v
Original security groups restored
```

The `SecOps-Operator` role is intentionally limited.

Its module-defined permissions contain EventBridge discovery and submission,
not direct EC2 modification or Lambda invocation. The Identity Center caller
constructs the same prefixed bus ARN used by workload automation. The bus
resource policy allows `custom.rollback` from matching
`AWSReservedSSO_SecOps-Operator-<environment>_*` IAM roles and explicitly
denies other publishers while retaining separate `aws.securityhub` forwarding.

Verify actual group membership, effective bus access, and positive/negative
submission evidence. Acceptance does not establish independently authenticated
approval or completed EC2 recovery. Do not use administrator submission as
evidence that the intended Operator identity works.

---

## Prerequisites

Before running these tests, confirm:

- The target environment has been deployed.
- The `EC2 Isolation` Lambda has already isolated a test instance.
- The target EC2 instance is currently attached to the `Quarantine` security group.
- The `EC2 Rollback` Lambda exists.
- The environment-specific SecOps event bus exists.
- The rollback EventBridge rule exists.
- The SecOps SNS topic exists.
- Your `IAM Identity Center` user is assigned to the intended `SecOps-Operator` group for the target environment; independently verify effective bus access.
- Use a disposable or specifically approved test instance, with an independently retained pre-isolation SG record and an authorized recovery procedure.
- The live `Isolated` tag is exactly `true`, and `OriginalSecurityGroups` matches that independent record. The handler does not verify the provenance of these tags.
- Supply a non-empty string `reason` as well as `instance_id`, `approved_by`, and `ticket_id`. Although the handler's initial check omits `reason`, it later passes that value to EC2 tag creation.
- Keep a separate observer profile with the required read permissions. Do not assume Operator can read EC2, Lambda, or CloudWatch Logs.
- Snapshot retention and application-health recovery are separate from restoring SG attachments.

Example groups:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

---

## Access Requirements

The EC2 Rollback workflow is tested through **AWS IAM Identity Center**.

The user performing the test must:

- Exist as a user in IAM Identity Center
- Be assigned to the correct environment-specific `SecOps-Operator` group
- Have access to the target AWS account through the `SecOps-Operator` permission set

The `SecOps-Operator` permission set allows:

- `events:ListEventBuses`
- `events:DescribeEventBus`
- `events:PutEvents` on the derived prefixed workload bus ARN; the separate bus policy enforces Operator-role identity for `custom.rollback` publication.

The resource-specific permission must match the actual target bus. Console
navigation can additionally depend on read permissions; a console error alone
is not a reason to grant broad authority. The CLI test and observer inspections
below keep submission and inspection identities separate.

---

## Environment Variables

Use Bash from the repository root, with the selected workload backend already
initialized. These examples require local named profiles; they are not GitHub
OIDC job configuration. Fill in the expected account independently of the
credentials, and stop on any preflight failure.

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ENVIRONMENT="dev"
export EXPECTED_ACCOUNT_ID="<TARGET-ACCOUNT-ID>"
export ACCOUNT_ID="$EXPECTED_ACCOUNT_ID"
export INSTANCE_ID="<APPROVED-QUARANTINED-INSTANCE-ID>"
export APPROVED_INSTANCE_ID="<SAME-INDEPENDENTLY-APPROVED-INSTANCE-ID>"
export PROFILE_NAME="operator"
export READ_PROFILE="dev-observer"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
export EVENT_BUS_NAME="${NAME_PREFIX}-secops-bus"
export FUNCTION_NAME="${NAME_PREFIX}-ec2-rollback"
export APPROVED_BY="<ACTUAL-APPROVER>"
export TICKET_ID="<ACTUAL-APPROVAL-RECORD>"
export ROLLBACK_REASON="Approved disposable-instance rollback test"
export PRE_ISOLATION_RECORD="/path/to/retained/instance-before.json"

assert_rollback_context() (
  set -euo pipefail
  : "${PROFILE_NAME:?Set the submission profile}"
  : "${READ_PROFILE:?Set the observer profile}"
  : "${AWS_REGION:?Set the service Region}"
  [[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]
  [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]
  case "$ENVIRONMENT" in dev|staging|prod) ;; *) exit 1 ;; esac
  for profile in "$PROFILE_NAME" "$READ_PROFILE"; do
    caller="$(aws sts get-caller-identity --profile "$profile" \
      --region "$AWS_REGION" --query Account --output text)"
    [[ "$caller" == "$EXPECTED_ACCOUNT_ID" ]]
  done
  outputs="$(AWS_PROFILE="$READ_PROFILE" terraform \
    -chdir="environments/${ENVIRONMENT}" output -json)"
  jq -e --arg region "$AWS_REGION" --arg prefix "$NAME_PREFIX" '
    .primary_region.value == $region and .name_prefix.value == $prefix
  ' <<< "$outputs" >/dev/null
  [[ "$EVENT_BUS_NAME" == "${NAME_PREFIX}-secops-bus" ]]
  [[ "$FUNCTION_NAME" == "${NAME_PREFIX}-ec2-rollback" ]]
)
assert_rollback_context

# Only continue after successful preflight. Retain this directory for review.
EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/rollback-check.XXXXXX")"
export EVIDENCE_DIR
chmod 700 "$EVIDENCE_DIR"
printf 'Evidence directory: %s\n' "$EVIDENCE_DIR"
```

`${VAR:?message}` requires a non-empty value, not a particular permission.
Re-run the complete setup when switching accounts or environments; changing
only `ENVIRONMENT` leaves stale derived values. The pre-isolation JSON must be
the independent EC2 record captured before containment, not a copy of the
current `OriginalSecurityGroups` tag.

---

## Sign In via AWS Access Portal

Use the AWS access portal URL configured for IAM Identity Center in the `bootstrap/control_plane` account.

Valid access portal URL formats include:

```text
https://d-xxxxxxxxxx.awsapps.com/start
https://ssoins-xxxxxxxxxxxxxxxx.portal.us-east-1.app.aws
```

A custom AWS access portal URL may also be used if configured.

Sign in using a user assigned to the correct environment-specific `SecOps-Operator` group.

After opening the AWS account, confirm the active role in the top-right console header.

Expected role name pattern:

```text
SecOps-Operator-<env>/<username>
```

or:

```text
AWSReservedSSO_SecOps-Operator-<env>_<random>/<username>
```

Examples:

```text
AWSReservedSSO_SecOps-Operator-dev_<random>/<username>
AWSReservedSSO_SecOps-Operator-staging_<random>/<username>
AWSReservedSSO_SecOps-Operator-prod_<random>/<username>
```

---

## Configure Local AWS CLI SSO Profile

For the local rollback test, configure an AWS CLI SSO profile.

```bash
aws configure sso --profile "${PROFILE_NAME}" --use-device-code
```

For the prompts, use values similar to the following:

```text
SSO session name (Recommended): test
SSO start URL [None]: <AWS access portal URL>
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: sso:account:access
```

The CLI may print output similar to:

```text
Attempting to automatically open the SSO authorization page in your default browser.
If the browser does not open or you wish to use a different device to authorize this request, open the following URL:

https://d-xxxxxxxxxx.awsapps.com/start/#/device

Then enter the code:

XXXX-XXXX
```

If the browser does not open automatically, open the provided URL manually and enter the code.

Use the Region where IAM Identity Center is enabled for the SSO configuration;
that is not necessarily the workload service Region or state-backend Region.
After authorization, select the target account and the `SecOps-Operator` role.

If prompted for a profile name, use:

```text
operator
```

Then set:

```bash
export PROFILE_NAME="operator"
```

---

## Confirm CLI Identity

Before running rollback tests from the CLI, confirm your AWS CLI is authenticated to the correct account and role.

```bash
aws sts get-caller-identity --profile "${PROFILE_NAME}" --region "${AWS_REGION}"
```

Expected output pattern:

```json
{
  "UserId": "<id-string>:<sso-user>",
  "Account": "<target-account-id>",
  "Arn": "arn:aws:sts::<target-account-id>:assumed-role/AWSReservedSSO_SecOps-Operator-<env>_<random>/<sso-user>"
}
```

Confirm:

- The `Account` value matches the target environment account.
- The `Arn` contains `AWSReservedSSO_SecOps-Operator`.
- The role corresponds to the environment being tested.

---

## Verification Commands

Use the following commands to confirm the target instance state before and after rollback.

These verification commands require read access to EC2 and CloudWatch Logs. The `SecOps-Operator` role is intentionally limited to EventBridge actions and should not be expected to run these commands.

Run these verification commands from a terminal in a separate window authenticated as one of the following:

- An independently approved read/inspection role
- A dedicated observer role with the necessary EC2, Lambda configuration, EventBridge, and CloudWatch Logs read permissions

Before continuing, confirm your AWS CLI is authenticated to the correct target account.

```bash
aws sts get-caller-identity --profile "${READ_PROFILE}" --region "${AWS_REGION}"
```

Confirm the returned account ID matches the independent expectation. The
observer commands below do not submit an event, assume the Operator role, or
establish who can publish to the bus.

---

### Check Current Security Groups

```bash
aws ec2 describe-instances \
  --profile "${READ_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```

Before rollback, the instance should be attached to the quarantine security group.

After rollback, the instance should be restored to its original security group or groups.

---

### Check Instance Tags

Inspect structured tag data rather than grepping JSON:

```bash
aws ec2 describe-instances \
  --profile "${READ_PROFILE}" --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`Isolated` || Key==`OriginalSecurityGroups` || Key==`IsolationAllowed` || starts_with(Key, `Release`) || Key==`IsolationReleased`]' \
  --output json
```

Before rollback, verify `Isolated=true` and the original SG IDs against the
independent pre-isolation record. On the successful path, the handler writes
`Isolated=false`, release metadata, and **`IsolationAllowed=true`**. It does not
restore an earlier authorization value or remove every isolation metadata tag.

---

### Check Lambda Logs

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --profile "${READ_PROFILE}" \
  --region "${AWS_REGION}" \
  --since 15m
```

Use this to confirm whether the rollback Lambda executed successfully.
No logs is not proof that a submitted event was safely rejected. Correlate the
specific test time, instance, and ticket with the invocation and actual resource
state; log-delivery delay or missing read rights can also obscure results.

---

# EC2 ROLLBACK LAMBDA TESTS

For CLI cases, define this helper once after setup. It serializes `Detail`
with `jq`, retains the exact submission, and checks per-entry acceptance. The
positive case also compares the rollback metadata with an independent
pre-isolation record before publishing.

```bash
send_rollback_case() (
  set -euo pipefail
  label="$1"; detail="$2"
  assert_rollback_context
  : "${EVIDENCE_DIR:?Create the evidence directory}"
  umask 077
  run_dir="$(mktemp -d "${EVIDENCE_DIR}/${label}.XXXXXX")"
  printf 'Review evidence: %s\n' "$run_dir"
  jq -e 'if type == "object" then . else error("Expected detail object") end' <<< "$detail" > "$run_dir/detail.json"
  test_id="$(jq -r '.instance_id // empty' "$run_dir/detail.json")"
  if [[ -n "$test_id" && "$test_id" != "invalid-instance-id" ]]; then
    [[ "$test_id" =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]]
    [[ "$test_id" == "$INSTANCE_ID" && "$test_id" == "$APPROVED_INSTANCE_ID" ]]
    jq -e 'all(.instance_id, .approved_by, .ticket_id, .reason; type == "string" and length > 0)' \
      "$run_dir/detail.json" >/dev/null
    : "${PRE_ISOLATION_RECORD:?Supply the independent pre-isolation record}"
    cp "$PRE_ISOLATION_RECORD" "$run_dir/pre-isolation.json"
    jq -e --arg id "$test_id" '
      [.Reservations[].Instances[]] as $i |
      ($i | length) == 1 and $i[0].InstanceId == $id and
      ($i[0].SecurityGroups | length) > 0
    ' "$run_dir/pre-isolation.json" >/dev/null
    aws ec2 describe-instances --profile "$READ_PROFILE" --region "$AWS_REGION" \
      --instance-ids "$test_id" --output json > "$run_dir/instance-before.json"
    vpc_id="$(AWS_PROFILE="$READ_PROFILE" terraform -chdir="environments/${ENVIRONMENT}" output -raw vpc_id)"
    jq -e --arg vpc "$vpc_id" --slurpfile before "$run_dir/pre-isolation.json" '
      [.Reservations[].Instances[]] as $i |
      ($i | length) == 1 and $i[0].VpcId == $vpc and
      $i[0].VpcId == $before[0].Reservations[0].Instances[0].VpcId and
      ([$i[0].Tags[]? | select(.Key == "Isolated") | .Value] == ["true"]) and
      (([$i[0].Tags[]? | select(.Key == "OriginalSecurityGroups") | .Value][0] | split(",") | sort) ==
       ($before[0].Reservations[0].Instances[0].SecurityGroups | map(.GroupId) | sort))
    ' "$run_dir/instance-before.json" >/dev/null
  fi
  aws sts get-caller-identity --profile "$PROFILE_NAME" --region "$AWS_REGION" \
    --output json > "$run_dir/submission-caller.json"
  aws events describe-event-bus --profile "$READ_PROFILE" --region "$AWS_REGION" \
    --name "$EVENT_BUS_NAME" --output json > "$run_dir/bus.json"
  jq -e --arg name "$EVENT_BUS_NAME" --arg account "$EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" '
    (.Arn | split(":")) as $arn |
    .Name == $name and $arn[3] == $region and $arn[4] == $account
  ' "$run_dir/bus.json" >/dev/null
  jq -n --arg bus "$EVENT_BUS_NAME" --slurpfile detail "$run_dir/detail.json" '
    [{Source:"custom.rollback", DetailType:"Ec2Rollback",
      EventBusName:$bus, Detail:($detail[0] | tojson)}]
  ' > "$run_dir/entries.json"
  aws events put-events --profile "$PROFILE_NAME" --region "$AWS_REGION" \
    --entries "file://${run_dir}/entries.json" --output json > "$run_dir/submission.json"
  jq . "$run_dir/submission.json"
  jq -e '.FailedEntryCount == 0 and (.Entries | length) == 1 and
    (.Entries[0].EventId | type == "string" and length > 0) and
    (.Entries[0] | has("ErrorCode") | not)' "$run_dir/submission.json" >/dev/null
)
```

A successful return means the preflight and event acceptance checks passed,
not that rollback completed. EventBridge acceptance does not prove rule match,
Lambda execution, EC2 changes, or notification delivery; a nonexistent bus can
also produce an apparently successful `PutEvents` response. Verify the live
bus and correlate downstream results. See the
[PutEvents behavior](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-putevents.html).

Do not repeat a submission after a timeout without inspecting the target. The
handler replaces SGs before writing release tags and notifying SNS. Partial
failure can therefore change the instance even if the test reports failure.
Caught lookup errors and malformed-input returns may produce no asynchronous
failure message. After tags set `Isolated=false`, a retried event can skip the
remaining work, including a failed earlier notification.

## Test 1 - Manual Rollback Event from EventBridge Console

### Purpose

Validate that a user assigned to the environment-specific `SecOps-Operator` role can submit a rollback event through the AWS Console.

Submit through the AWS Console only after the same account, live bus, approved
instance, and independent pre-isolation checks described above. Replace the
placeholder in the sample JSON; do not reuse a resource ID from a prior test.
Use the separate observer for before/after verification.

### Steps

Sign in through the AWS access portal, open the target AWS account using the correct `SecOps-Operator` role, and navigate to:

```text
Amazon EventBridge -> Event buses -> <secops-bus-name> -> Send events
```

Use:

| Field | Value |
|------|-------|
| Event bus | `<cloud_name>-<environment>-secops-bus` |
| Event source | `custom.rollback` |
| Detail type | `Ec2Rollback` |

Use this JSON in the **Detail** field:

```json
{
  "instance_id": "<APPROVED-QUARANTINED-INSTANCE-ID>",
  "approved_by": "secops@company.com",
  "ticket_id": "t-abc123",
  "reason": "Test rollback"
}
```

### Expected Outcome

- EventBridge reports submission acceptance; verify the selected bus and downstream execution separately
- Rollback Lambda executes successfully.
- Instance rolls back from the quarantine security group to its original security group or groups.
- Instance tags are added/updated
- SNS notification is sent to the configured SecOps SNS topic.
- No errors appear in the Lambda function CloudWatch log group.

---

## Test 2 - Manual Rollback Event from AWS CLI

### Purpose

Validate that a locally configured AWS CLI SSO profile can submit a rollback event to the SecOps event bus.

### Manual Event from AWS CLI

Confirm the AWS CLI is configured for the correct region:

```bash
aws configure get region --profile "${PROFILE_NAME}"
```

Send the approved rollback event:

```bash
send_rollback_case "approved-rollback" "$(jq -n \
  --arg instance "$INSTANCE_ID" --arg approver "$APPROVED_BY" \
  --arg ticket "$TICKET_ID" --arg reason "$ROLLBACK_REASON" \
  '{instance_id:$instance, approved_by:$approver, ticket_id:$ticket, reason:$reason}')"
```

### Expected CLI Output

```json
{
  "FailedEntryCount": 0,
  "Entries": [
    {
      "EventId": "<id-string>"
    }
  ]
}
```

### Expected Outcome

- Rollback Lambda executes successfully.
- Instance rolls back from the quarantine security group to its original security group or groups.
- Instance tags are added/updated
- SNS notification is sent to the configured SecOps SNS topic.
- No errors appear in the Lambda function CloudWatch log group.

---

## Test 3 - Verify Rollback Completion

### Purpose

Confirm that the EC2 instance was restored to its pre-isolation security group configuration.

Run these from a terminal authenticated as one of the identities defined in the `Verification Commands` section of this guide.

### Check Security Groups

```bash
aws ec2 describe-instances \
  --profile "${READ_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```

### Expected Outcome

- The instance is no longer attached only to the quarantine security group.
- The exact sorted SG set matches the independent pre-isolation record, not merely the current `OriginalSecurityGroups` tag.
- No unexpected security groups are attached.

For an explicit SG comparison after the asynchronous operation finishes:

```bash
(
  set -euo pipefail
  assert_rollback_context
  [[ "$INSTANCE_ID" == "$APPROVED_INSTANCE_ID" ]]
  : "${PRE_ISOLATION_RECORD:?Supply the original record}"
  after="$(aws ec2 describe-instances --profile "$READ_PROFILE" --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" --output json)"
  jq -e --arg id "$INSTANCE_ID" --slurpfile before "$PRE_ISOLATION_RECORD" '
    [.Reservations[].Instances[]] as $i |
    ($i | length) == 1 and $i[0].InstanceId == $id and
    $before[0].Reservations[0].Instances[0].InstanceId == $id and
    (($i[0].SecurityGroups | map(.GroupId) | sort) ==
     ($before[0].Reservations[0].Instances[0].SecurityGroups | map(.GroupId) | sort))
  ' <<< "$after" >/dev/null
)
```

Also verify release tags, the independently authorized approval record,
application recovery, and notification receipt. Restoring SGs is not evidence
that an instance is uncompromised or that every earlier operation succeeded.

---

## Test 4 - Invalid Instance ID

### Purpose

Validate that a deliberately malformed instance ID produces a handled lookup
failure without reaching mutation. Do not use a syntactically plausible ID that
could name a real instance. The handler catches lookup exceptions and returns;
Lambda invocation failure or a DLQ entry is not the expected acceptance signal.

### Manual Event from AWS CLI

```bash
send_rollback_case "invalid-instance" "$(jq -n --arg approver "$APPROVED_BY" --arg ticket "$TICKET_ID" \
  '{instance_id:"invalid-instance-id", approved_by:$approver, ticket_id:$ticket,
    reason:"Approved malformed-ID test"}')"
```

### Expected CLI Output

```json
{
  "FailedEntryCount": 0,
  "Entries": [
    {
      "EventId": "<id-string>"
    }
  ]
}
```

### Expected Outcome

- EventBridge accepts the event.
- Lambda handles the invalid instance ID safely.
- No EC2 instances are modified.
- Error or warning appears in the Lambda logs.
- No rollback success notification should be sent.

---

## Test 5 - Missing Required Field

### Purpose

Validate that the rollback workflow handles malformed rollback events safely.

### Manual Event from AWS CLI

This event omits the required `instance_id` field. The handler logs the missing
field and returns normally; verify the specific invocation rather than expecting
a DLQ entry. Test each missing required field separately in mocks before adding
other live malformed cases.

```bash
send_rollback_case "missing-instance" "$(jq -n --arg approver "$APPROVED_BY" --arg ticket "$TICKET_ID" \
  '{approved_by:$approver, ticket_id:$ticket, reason:"Approved missing-field test"}')"
```

### Expected CLI Output

```json
{
  "FailedEntryCount": 0,
  "Entries": [
    {
      "EventId": "<id-string>"
    }
  ]
}
```

### Expected Outcome

- EventBridge accepts the event.
- Lambda handles the malformed payload safely.
- No EC2 instances are modified.
- Error or warning appears in the Lambda logs.
- No rollback success notification should be sent.

---

## Test 6 - Wrong Detail Type

### Purpose

Demonstrate the actual filtering boundary without publishing a rollback event.
The deployed rollback rule filters only `source = custom.rollback`; it does
not require `detail-type = Ec2Rollback`. The handler also ignores detail type.
An otherwise valid live event with a different detail type could still restore
a quarantined instance. This is not a safe live negative test.

### Manual Event from AWS CLI

This uses the read-only pattern-testing API. It describes the rule and tests a
synthetic event locally against the returned pattern through AWS; it does not
call `PutEvents` or invoke Lambda.

```bash
(
  set -euo pipefail
  assert_rollback_context
  umask 077
  case_dir="$(mktemp -d "${EVIDENCE_DIR:?Create evidence directory}/pattern.XXXXXX")"
  aws events describe-rule --profile "$READ_PROFILE" --region "$AWS_REGION" \
    --event-bus-name "$EVENT_BUS_NAME" --name "${NAME_PREFIX}-ec2-rollback" \
    --query EventPattern --output text > "$case_dir/pattern.json"
  jq -e . "$case_dir/pattern.json" >/dev/null
  jq -n --arg account "$EXPECTED_ACCOUNT_ID" --arg region "$AWS_REGION" \
    --arg time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    {version:"0", id:"read-only-rollback-pattern-test", account:$account,
     source:"custom.rollback", time:$time, region:$region, resources:[],
     "detail-type":"InvalidRollbackType", detail:{}}
  ' > "$case_dir/event.json"
  aws events test-event-pattern --profile "$READ_PROFILE" --region "$AWS_REGION" \
    --event-pattern "file://${case_dir}/pattern.json" \
    --event "file://${case_dir}/event.json" --output json > "$case_dir/result.json"
  jq . "$case_dir/result.json"
  jq -e '.Result == true' "$case_dir/result.json" >/dev/null
)
```

### Expected CLI Output

```json
{
  "Result": true
}
```

### Expected Outcome

- The wrong-detail-type event still matches the source-only deployed pattern.
- No event is published and no EC2 mutation is requested by this test.
- This is pattern evidence only, not invocation, approval, or IAM authorization evidence.
- A false result requires investigating the fetched rule and its drift rather than assuming the source-only implementation rejects detail types.

The [pattern-testing API](https://docs.aws.amazon.com/cli/latest/reference/events/test-event-pattern.html)
compares the supplied pattern and event; it is separate from event delivery.

---

# Post-Test Validation

After running a successful rollback test, confirm:

- The instance is no longer isolated.
- Original security groups are restored.
- SNS notification was received.
- Lambda logs show successful rollback.
- Retained caller identity and submission evidence identify the actual test principal; the payload's `approved_by` field is not identity proof.
- The test account and environment match the intended target.
- Review the handler's `IsolationAllowed=true` change against the intended Terraform policy before any further response test. Reconcile through an approved change, not an automatic Apply.
- Keep each test independent. A second positive test against an already released instance should be skipped by the handler, not counted as another successful rollback.
- Retain evidence and test snapshot IDs. Rollback does not delete snapshots or fully clear all incident tags.

---

# Troubleshooting

Errors associated with these tests are often the result of an invalid environment variable.

Ensure that all environment variables are correctly set prior to following the troubleshooting steps outlined below.

## EventBridge returns FailedEntryCount greater than 0

Check:

- Event bus name is correct.
- The authenticated role has `events:PutEvents`.
- The event bus exists in the target account and region.
- The `SecOps-Operator` permission set is assigned to the correct account.

---

## AccessDenied when running put-events

Check:

- You are using the correct SSO profile.
- You are assuming the correct `SecOps-Operator` role.
- Your Identity Center user is assigned to the correct environment-specific group.
- The permission set allows `events:PutEvents` on the environment-specific event bus.
- The event bus ARN matches the account and region being tested.
- Confirm the Identity Center caller and workload bus names match, and review both the Operator permission set and the bus's role-scoped `custom.rollback` Allow/explicit non-Operator Deny. Administrator submission is not Operator qualification.

---

## Event is accepted but Lambda does not run

Check:

- The EventBridge rule exists.
- The rule pattern matches `source = custom.rollback`; detail type is not filtered by this rule.
- The rule target points to the rollback Lambda.
- The Lambda permission allows EventBridge to invoke it.
- The event was sent to the correct event bus.

---

## Lambda runs but instance is not restored

Check:

- The instance ID is correct.
- The instance was previously isolated by the EC2 Isolation Lambda.
- Original security group metadata exists.
- The original security groups still exist.
- The Lambda execution role has required EC2 permissions.
- The instance is in the expected account and region.

---

## SNS notification is not received

Check:

- SNS topic exists.
- Lambda has `sns:Publish`.
- Email subscription is confirmed.
- SNS topic policy allows publish from the Lambda role.
- SNS topic KMS permissions allow Lambda usage.

---

## KMS AccessDenied

Check:

- Lambda execution role has access to the required KMS key.
- KMS key policy allows IAM delegation.
- SNS topic encryption uses the expected CMK.
- The relevant CMK ARN was passed into the IAM policy module.

---

# Summary

These tests validate the EC2 Rollback Lambda in the context of the full `tf-secure-baseline` platform.

Record the results actually observed, including unexecuted or failed cases:

- Rollback is performed through a controlled EventBridge workflow.
- The intended Operator submission path was tested separately from privileged recovery and its policy discrepancy was recorded.
- The rollback Lambda restores original EC2 security groups.
- Invalid or malformed events are handled safely.
- The configured source-only rule does not reject a different detail type; the read-only pattern case demonstrates that limit.
- Account/Region selection, actual access policies, and downstream effects were reviewed without equating event acceptance with successful recovery.

Implementation references: [rollback handler](../../modules/automation/lambda/ec2_rollback.py),
[bus policy and rule](../../modules/automation/main.tf),
[Identity Center caller](../../bootstrap/control_plane/identity_center/main.tf),
[persona policy](../../modules/identity_center/main.tf), and
[automation reference](../../modules/automation/README.md).
