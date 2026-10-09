# LAMBDA FUNCTION TESTS - EC2 ISOLATION

## Purpose

This document provides manual tests used to validate the **EC2 Isolation Lambda** behavior before and after changes.

The EC2 Isolation Lambda is responsible for isolating EC2 instances and requesting pre-isolation EBS snapshots when qualifying GuardDuty findings are imported through Security Hub.

It is designed to support the broader `tf-secure-baseline` architecture, including:

- Multi-account environments: `dev`, `staging`, and `prod`
- Centralized control plane
- IAM Identity Center access model
- Security Hub and EventBridge-driven security workflows
- SNS-based SecOps notifications
- Follow-on recovery with separately verified rollback authorization

---

## Testing Approach

This document includes two categories of tests:

1. **Direct Lambda invocation tests**
   - Used for development and debugging
   - Bypass EventBridge and Security Hub
   - Require direct permission to invoke the Lambda function

2. **Security workflow validation tests**
   - Validate that the isolation workflow fits into the larger platform design
   - Confirm that isolated instances can later be restored through the controlled rollback workflow

In the deployed workflow, this Lambda is triggered by the dedicated EC2-isolation EventBridge rule when a qualifying GuardDuty finding is imported through Security Hub.

The EventBridge rule prefilters for:

- `source = aws.securityhub`
- `detail-type = Security Hub Findings - Imported`
- GuardDuty `ProductArn`
- `HIGH` or `CRITICAL` severity
- `AwsEc2Instance` resources
- `Workflow.Status = NEW`
- `RecordState = ACTIVE`

The Lambda independently revalidates the GuardDuty product, configured severity, workflow status, record state, resource type, instance state, instance authorization tag, and already-isolated state before containment.

Direct invocation is useful for validating Lambda-side gates without waiting for a real Security Hub finding. Direct invocation bypasses the EventBridge pattern, so negative tests can deliberately submit payloads that EventBridge would normally reject.

The Lambda does not use the top-level EventBridge `source` or `detail-type`
fields as authorization gates. They are retained in the payloads to mirror the
event shape; the handler evaluates `detail.findings`. Direct invocation can
supply a synthetic GuardDuty-looking `ProductArn`; it does not prove a finding
originated in GuardDuty. The handler extracts the instance-ID suffix rather
than validating the full resource ARN's account/Region. Actual EC2 calls use
the Lambda execution context, so test account/Region preflight is essential.

---

## Identity and Access Context

This project uses a centralized IAM Identity Center model.

For this test document:

- **EC2 Isolation** is automated and triggered by qualifying GuardDuty findings imported through Security Hub and matched by the dedicated EventBridge rule.
- **EC2 Rollback** uses the environment-specific `SecOps-Operator` persona and matching prefixed bus identity. The [rollback guide](ec2_rollback.md) covers effective-role verification, non-Operator denial, and authorized workflow qualification. Human approval remains an operational prerequisite.
- The `SecOps-Operator` role does **not** directly invoke this Lambda.
- Use a separately authorized test principal with explicit `lambda:InvokeFunction` and the necessary inspection rights; a role name alone does not establish them.

Example Identity Center groups:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

The operator workflow is primarily validated in the EC2 rollback test document, but isolation should be tested first so there is an instance available for rollback validation.

---

## Prerequisites

Before running these tests, confirm:

- The target environment has been deployed.
- Security Hub is enabled for the target account and receives GuardDuty findings.
- The dedicated EC2-isolation EventBridge rule is deployed.
- The EC2 Isolation Lambda exists.
- The `Quarantine` security group exists.
- The SecOps SNS topic exists.
- A test EC2 instance exists in the target environment.
- Use development for destructive isolation tests unless another environment has been explicitly approved and enabled.
- For the positive isolation case, the approved test instance has `IsolationAllowed=true`. All supplied workload roots default this input to `true`; do not assume staging/production is disabled. The reusable compute module's `false` default is not the effective root setting.
- The Lambda role can describe instances, create and tag snapshots, modify instance security groups, create tags, and publish to SNS.
- Your principal has permission to invoke the Lambda directly.
- You know the AWS account ID and region for the target environment.
- Record the exact pre-test instance ID, VPC, subnet, security-group IDs, policy tag, and attached volume IDs before any mutation.
- Confirm an independently authorized recovery path before the positive case; the intended Operator path is not assumed to work.
- Avoid overlapping patch runs, other response tests, or unrelated changes to the target while comparing before/after state.

---

## Environment Variables

Use Bash from the repository root. Select one approved test account and a
named profile with the required permissions. The account below is an
independent expectation, not a value copied from whichever credentials happen
to be active. Stop on a failed preflight. Do not run this as a production test
without separate approval.

```bash
export AWS_PAGER=""
export AWS_PROFILE="dev"
export AWS_REGION="us-east-1"
export ENVIRONMENT="dev"
export EXPECTED_ACCOUNT_ID="<WORKLOAD-ACCOUNT-ID>"
export ACCOUNT_ID="$EXPECTED_ACCOUNT_ID"
export CLOUD_NAME="tf-secure-baseline"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
export TEST_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
export TEST_RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

assert_test_context() (
  set -euo pipefail
  : "${AWS_PROFILE:?Set the test profile}"
  : "${AWS_REGION:?Set the service Region}"
  [[ "${EXPECTED_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]]
  [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]
  case "$ENVIRONMENT" in dev|staging|prod) ;; *) exit 1 ;; esac
  caller="$(aws sts get-caller-identity --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --query Account --output text)"
  [[ "$caller" == "$EXPECTED_ACCOUNT_ID" ]]
  outputs="$(terraform -chdir="environments/${ENVIRONMENT}" output -json)"
  jq -e --arg region "$AWS_REGION" --arg prefix "$NAME_PREFIX" '
    .primary_region.value == $region and .name_prefix.value == $prefix
  ' <<< "$outputs" >/dev/null
)
assert_test_context

# Use the authenticated caller's partition for test payloads and expected ARNs.
TEST_CALLER_ARN="$(aws sts get-caller-identity \
  --profile "$AWS_PROFILE" --region "$AWS_REGION" \
  --query Arn --output text)"
if [[ "$TEST_CALLER_ARN" =~ ^arn:([a-z0-9-]+):(iam|sts)::${EXPECTED_ACCOUNT_ID}:.+ ]]; then
  export AWS_PARTITION="${BASH_REMATCH[1]}"
else
  printf 'Unable to resolve partition from caller ARN: %s\n' "$TEST_CALLER_ARN" >&2
  exit 1
fi

# Run this only after the preflight succeeds. The directory is not auto-deleted.
EVIDENCE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lambda-check.XXXXXX")"
export EVIDENCE_DIR
chmod 700 "$EVIDENCE_DIR"
printf 'Evidence directory: %s\n' "$EVIDENCE_DIR"
```

Re-run the complete setup when switching environments, including the profile,
expected account, Region, derived identifiers, and evidence directory. Changing
only `ENVIRONMENT` is insufficient. `${VAR:?message}` stops a command when a
required value is unset or empty; it does not validate permissions.

Set the exact selected instance and function identities. The approval value is
an operator assertion for this test, not a control implemented by the Lambda.

```bash
export INSTANCE_ID="<APPROVED-EC2-INSTANCE-ID>"
export APPROVED_INSTANCE_ID="<SAME-INDEPENDENTLY-APPROVED-INSTANCE-ID>"
export INSTANCE_ARN="arn:${AWS_PARTITION}:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"
export FUNCTION_NAME="${NAME_PREFIX}-ec2-isolation"
export ISOLATION_RULE_NAME="${NAME_PREFIX}-securityhub-ec2-high-critical"
export GUARDDUTY_PRODUCT_ARN="arn:${AWS_PARTITION}:securityhub:${AWS_REGION}::product/aws/guardduty"
```

The cases below assume the deployed automatic severity set is exactly
`CRITICAL`. An expanded set changes the expectations and can turn a negative
case into a destructive one. Do not change production settings to fit a test.

### Confirm Deployed Lambda Configuration

Before running the behavior tests, inspect the deployed environment variables:

```bash
aws lambda get-function-configuration \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --query 'Environment.Variables.{QUARANTINE_SG_ID:QUARANTINE_SG_ID,SNS_TOPIC_ARN:SNS_TOPIC_ARN,AUTO_ISOLATION_SEVERITIES:AUTO_ISOLATION_SEVERITIES,AWS_PARTITION:AWS_PARTITION}' \
  --output json
```

Expected:

- `QUARANTINE_SG_ID` is populated.
- `AWS_PARTITION` matches the partition derived from the active STS caller ARN.
- `SNS_TOPIC_ARN` is populated for the normal baseline deployment.
- `AUTO_ISOLATION_SEVERITIES` reflects the Terraform-configured severity set.

The Lambda itself falls back to `CRITICAL` if `AUTO_ISOLATION_SEVERITIES` is absent or empty. Tests that specifically expect `HIGH` to be skipped assume `HIGH` is **not** present in the deployed severity set.

### Confirm Dedicated EventBridge Rule

Inspect the EC2-isolation rule:

```bash
aws events describe-rule \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --name "${ISOLATION_RULE_NAME}" \
  --query EventPattern \
  --output text | jq .
```

The deployed pattern should require all of the following under `detail.findings`:

```text
ProductArn   = arn:<partition>:securityhub:<region>::product/aws/guardduty
Severity     = HIGH or CRITICAL
Resources    = AwsEc2Instance
Workflow     = NEW
RecordState  = ACTIVE
```

The EC2-isolation rule is distinct from the broader `${CLOUD_NAME}-${ENVIRONMENT}-securityhub-high-critical` rule used by the IP-enrichment/security-notification path.

Confirm the dedicated rule targets the EC2-isolation Lambda and uses the workflow DLQ/retry policy:

```bash
aws events list-targets-by-rule \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --rule "${ISOLATION_RULE_NAME}" \
  --query 'Targets[?Id==`Ec2IsolationLambda`].{Id:Id,Arn:Arn,DLQ:DeadLetterConfig.Arn,MaxAttempts:RetryPolicy.MaximumRetryAttempts,MaxAge:RetryPolicy.MaximumEventAgeInSeconds}' \
  --output json
```

Expected for the `Ec2IsolationLambda` target:

```text
DLQ suffix   = -ec2-isolation-dlq
MaxAttempts  = 3
MaxAge       = 3600
```

Terraform also configures the Lambda's asynchronous failure destination to the same workflow DLQ with a 3600-second maximum event age and two Lambda retry attempts.

---

## Verification Commands

Use the following commands to confirm the target instance state before and after isolation.

Before running these commands, make sure your AWS CLI is authenticated to the target environment using either:

- The appropriate assumed role for that environment
- An authorized IAM administrator user

For example:

```bash
aws sts get-caller-identity
```

Confirm the returned account ID matches the environment you are testing before continuing.

### Check Current Security Groups

```bash
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```
Before the positive case, require the intended normal security-group set,
not merely the absence of one quarantine group. Independently retain that set
for recovery; the handler writes `OriginalSecurityGroups` only **after**
replacing the groups.

### Check Instance Tags

```bash
aws ec2 describe-tags \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}"
```
> Ensure that the instance's `IsolationAllowed` tag is set to `true` and the `Isolated` tag either does not exist or is set to `false`.

### Check Pre-Isolation Snapshots

After a successful isolation test, confirm that snapshots were requested for the target instance:

```bash
aws ec2 describe-snapshots \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --owner-ids self \
  --filters "Name=tag:InstanceId,Values=${INSTANCE_ID}" \
  --query 'Snapshots[].[SnapshotId,VolumeId,State,StartTime,Tags[?Key==`IsolationFinding`].Value|[0]]' \
  --output table
```

Match snapshot `IsolationFinding` tags to the unique finding ID in the saved
test event, and compare their volume IDs with the pre-test attachment list.
Older snapshots for the same instance do not count as this run's evidence.
The handler requests snapshots but does not wait for completion or verify
restorability. Record completion separately when it is part of acceptance.

### Check Lambda Logs

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --since 15m
```
No output is not evidence of success: establish that the exact test invocation
ran and that logs are available in the expected account/Region. Retain its
request ID and correlate the unique finding ID with the observed mutations.

### Interpret Direct-Invocation Results

The helper below stores each payload, invocation metadata, response, function
code identity, and before/after instance state in a new restricted subdirectory.
It invokes the deployed handler synchronously; it does not edit the function,
its permissions, the event rule, or the instance's authorization tag.

Define it once in the same Bash session. It is a documentation helper, not a
new baseline validator. It enforces the assumptions of the eight single-finding
cases below; adapt expected counts deliberately for additional safety tests.

```bash
invoke_isolation_case() (
  set -euo pipefail
  label="$1"; expected_evaluated="$2"; expected_isolated="$3"; payload="$4"
  assert_test_context
  : "${EVIDENCE_DIR:?Create the evidence directory}"
  [[ "$INSTANCE_ID" =~ ^i-([0-9a-f]{8}|[0-9a-f]{17})$ ]]
  [[ "$INSTANCE_ID" == "${APPROVED_INSTANCE_ID:?Approve the exact instance}" ]]
  [[ "$FUNCTION_NAME" == "${NAME_PREFIX}-ec2-isolation" ]]
  [[ "$INSTANCE_ARN" == "arn:${AWS_PARTITION}:ec2:${AWS_REGION}:${EXPECTED_ACCOUNT_ID}:instance/${INSTANCE_ID}" ]]
  umask 077
  run_dir="$(mktemp -d "${EVIDENCE_DIR}/${label}.XXXXXX")"
  printf 'Review evidence: %s\n' "$run_dir"
  printf '%s\n' "$payload" | jq -e . > "$run_dir/event.json"
  jq -e --arg arn "$INSTANCE_ARN" '
    all(.detail.findings[]?.Resources[]?;
        .Type != "AwsEc2Instance" or .Id == $arn)
  ' "$run_dir/event.json" >/dev/null
  git rev-parse HEAD > "$run_dir/checkout-commit.txt"
  aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json > "$run_dir/caller.json"
  aws lambda get-function-configuration --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --query '{FunctionArn:FunctionArn,CodeSha256:CodeSha256,LastModified:LastModified,State:State,Isolation:Environment.Variables.AUTO_ISOLATION_SEVERITIES,Quarantine:Environment.Variables.QUARANTINE_SG_ID,Partition:Environment.Variables.AWS_PARTITION}' \
    --output json > "$run_dir/function.json"
  jq -e --arg partition "$AWS_PARTITION" '.State == "Active" and .Isolation == "CRITICAL" and .Partition == $partition' "$run_dir/function.json" >/dev/null
  aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" --output json > "$run_dir/instance-before.json"
  vpc_id="$(terraform -chdir="environments/${ENVIRONMENT}" output -raw vpc_id)"
  jq -e --arg id "$INSTANCE_ID" --arg vpc "$vpc_id" '
    [.Reservations[].Instances[]] as $instances |
    ($instances | length) == 1 and
    $instances[0].InstanceId == $id and $instances[0].VpcId == $vpc
  ' "$run_dir/instance-before.json" >/dev/null
  aws lambda invoke --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" --invocation-type RequestResponse \
    --cli-read-timeout 120 --payload "fileb://${run_dir}/event.json" \
    --output json "$run_dir/response.json" > "$run_dir/invocation.json"
  aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --instance-ids "$INSTANCE_ID" --output json > "$run_dir/instance-after.json"
  jq . "$run_dir/invocation.json" "$run_dir/response.json"
  jq -e '.StatusCode == 200 and (has("FunctionError") | not)' "$run_dir/invocation.json" >/dev/null
  jq -e --argjson evaluated "$expected_evaluated" --argjson isolated "$expected_isolated" '
    .findings_received == 1 and .instances_evaluated == $evaluated and
    .instances_isolated == $isolated and .instances_skipped == 0 and .errors == 0
  ' "$run_dir/response.json" >/dev/null
)
```

A transport error or timeout can occur after a mutation. Do not rerun blindly;
inspect the same target and retained evidence first. The count assertions do
not verify snapshot completion, exact final SGs, notification delivery, or
absence of all side effects; complete those checks independently. A code hash
records which deployment was inspected, but must be compared with the intended
package before treating it as source provenance.

[Lambda invocation status](https://docs.aws.amazon.com/cli/latest/reference/lambda/invoke.html)
is not the handler's result. `StatusCode=200` can include `FunctionError`;
handled processing exceptions can instead appear only as `.errors > 0` in the
returned summary. Such handled errors do not necessarily activate asynchronous
retry/failure destinations. These synchronous tests do not exercise those
asynchronous mechanisms, and an empty DLQ is not proof of response success.

The handler returns a summary with:

```json
{
  "findings_received": 0,
  "instances_evaluated": 0,
  "instances_isolated": 0,
  "instances_skipped": 0,
  "errors": 0
}
```

Important counting behavior:

- A finding rejected by the GuardDuty product, severity, workflow, or record-state gate is skipped **before** EC2 resource evaluation. It does not increment `instances_evaluated` or `instances_skipped`.
- An EC2 instance that reaches instance evaluation but fails instance-state, `IsolationAllowed`, or already-isolated checks increments `instances_skipped`.
- A successfully quarantined instance increments `instances_isolated`.
- AWS API or unexpected processing exceptions increment `errors`.

---

# EC2 ISOLATION LAMBDA TESTS

## Test 1 - HIGH GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate the Lambda-side severity gate using a `HIGH` GuardDuty EC2 finding. Under a `CRITICAL`-only deployed severity set, the finding must be skipped.

### Expected Outcome

- Lambda executes successfully.
- The GuardDuty product, workflow, record-state, and EC2-resource fields are valid.
- The finding is logged and skipped because `HIGH` is not in the deployed configured severity set.
- No snapshots, security-group changes, isolation tags, or isolation SNS notification are created.
- No unexpected errors appear in CloudWatch Logs.

If `AUTO_ISOLATION_SEVERITIES` intentionally includes `HIGH`, this test is no longer a negative severity test; an otherwise eligible instance can be isolated.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-high-ec2-isolation" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-high-ec2-isolation-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-high-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test HIGH EC2 finding",
        "Description": "Manual test event used to validate EC2 isolation behavior.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

The AWS CLI invocation metadata should report success. Because the finding is rejected before EC2 evaluation, `response.json` should contain a handler summary equivalent to:

```json
{
  "findings_received": 1,
  "instances_evaluated": 0,
  "instances_isolated": 0,
  "instances_skipped": 0,
  "errors": 0
}
```

---

## Test 2 - CRITICAL GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate that a `CRITICAL`, `NEW`, `ACTIVE` GuardDuty finding for an authorized EC2 instance causes the instance to be isolated.

### Expected Outcome

- Lambda executes successfully.
- Tagged snapshots are requested for every attached EBS volume before the security-group change.
- The instance is moved into the quarantine security group.
- Isolation evidence tags are applied while `IsolationAllowed` remains `true`.
- SNS notification is sent to the configured SecOps topic.
- The returned handler summary reports one evaluated and isolated instance with zero processing errors.
- No unexpected errors appear in CloudWatch Logs.

The Lambda does not roll back an already-successful isolation if SNS publication later fails. A notification failure is logged and should be treated as an operational alerting failure, not as proof that the instance was not quarantined.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-critical-ec2-isolation" 1 1 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-critical-ec2-isolation-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-critical-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test CRITICAL EC2 finding",
        "Description": "Manual test event used to validate EC2 isolation behavior.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

The AWS CLI invocation metadata should report success, and `response.json` should contain a handler summary equivalent to:

```json
{
  "findings_received": 1,
  "instances_evaluated": 1,
  "instances_isolated": 1,
  "instances_skipped": 0,
  "errors": 0
}
```

---

## Test 2A - CRITICAL Non-GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate the Lambda's product gate. A `CRITICAL`, `NEW`, `ACTIVE` EC2 finding from another Security Hub product must not isolate the instance even when every other finding field is eligible.

This test intentionally bypasses EventBridge. The deployed EventBridge rule would reject this finding before Lambda invocation because its `ProductArn` is not GuardDuty.

### Expected Outcome

- Lambda executes successfully.
- The finding is logged and skipped because `ProductArn` does not equal the GuardDuty Security Hub product ARN.
- `instances_evaluated` remains `0`.
- No snapshots, security-group changes, isolation tags, or isolation SNS notification are created.
- No unexpected errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-critical-non-guardduty-ec2" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg AWS_PARTITION "${AWS_PARTITION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-critical-non-guardduty-ec2-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-critical-non-guardduty-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test CRITICAL non-GuardDuty EC2 finding",
        "Description": "Manual test event used to validate the GuardDuty product gate.",
        "ProductArn": "arn:\($AWS_PARTITION):securityhub:\($AWS_REGION)::product/aws/inspector",
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

---

## Test 2B - CRITICAL GuardDuty EC2 Finding Missing RecordState (Direct Invocation)

### Purpose

Validate fail-closed handling when `RecordState` is absent.

The Lambda reads a missing `RecordState` as an empty value, not as `ACTIVE`. The deployed EventBridge rule also requires `RecordState = ACTIVE`, so this condition is independently enforced at both layers.

### Expected Outcome

- Lambda executes successfully.
- The finding is logged and skipped because `RecordState` is missing.
- `instances_evaluated` remains `0`.
- No snapshots, security-group changes, isolation tags, or isolation SNS notification are created.
- No unexpected errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-critical-missing-record-state" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-critical-missing-record-state-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-critical-missing-record-state-001-" + $TEST_RUN_ID),
        "Title": "Manual test CRITICAL GuardDuty EC2 finding without RecordState",
        "Description": "Manual test event used to validate fail-closed RecordState handling.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

---

## Test 3 - CRITICAL GuardDuty Non-EC2 Finding (Direct Invocation)

### Purpose

Validate that a configured `CRITICAL` GuardDuty finding for a non-EC2 resource does not trigger EC2 isolation.

### Expected Outcome

- Lambda executes successfully.
- No EC2 instances are modified.
- No security groups are changed.
- No isolation tags are applied.
- No isolation SNS notification is sent.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-critical-non-ec2" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-critical-non-ec2-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-critical-non-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test CRITICAL non-EC2 finding",
        "Description": "Manual test event used to validate non-EC2 findings are ignored.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsS3Bucket",
            "Id": "arn:aws:s3:::example-test-bucket"
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 4 - MEDIUM GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate that a `MEDIUM` severity EC2 finding does not trigger isolation.

### Expected Outcome

- Lambda executes successfully.
- No EC2 instances are modified.
- No security groups are changed.
- No isolation tags are applied.
- No isolation SNS notification is sent.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-medium-ec2" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-medium-ec2-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-medium-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test MEDIUM EC2 finding",
        "Description": "Manual test event used to validate MEDIUM findings are ignored.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "MEDIUM"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 5 - LOW GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate that a `LOW` severity EC2 finding does not trigger isolation.

### Expected Outcome

- Lambda executes successfully.
- No EC2 instances are modified.
- No security groups are changed.
- No isolation tags are applied.
- No isolation SNS notification is sent.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-low-ec2" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-low-ec2-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-low-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test LOW EC2 finding",
        "Description": "Manual test event used to validate LOW findings are ignored.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "LOW"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 6 - RESOLVED GuardDuty EC2 Finding (Direct Invocation)

### Purpose

Validate that an EC2 finding with a non-actionable workflow status does not trigger isolation.

### Expected Outcome

- Lambda executes successfully.
- No EC2 instances are modified.
- No security groups are changed.
- No isolation tags are applied.
- No isolation SNS notification is sent.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_isolation_case "test-resolved-ec2" 0 0 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg INSTANCE_ARN "${INSTANCE_ARN}" \
    --arg GUARDDUTY_PRODUCT_ARN "${GUARDDUTY_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-resolved-ec2-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": ("test-finding-resolved-ec2-001-" + $TEST_RUN_ID),
        "Title": "Manual test RESOLVED EC2 finding",
        "Description": "Manual test event used to validate resolved findings are ignored.",
        "ProductArn": $GUARDDUTY_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "RESOLVED"
        },
        "RecordState": "ACTIVE",
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": $INSTANCE_ARN
          }
        ]
      }
    ]
  }
}')"
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Additional Safety-Gate Checks

Use the Test 2 `CRITICAL` payload and change one condition at a time.

| Condition | Expected result |
|---|---|
| `ProductArn` is missing or is not the GuardDuty Security Hub product ARN | Finding is skipped before instance evaluation |
| `IsolationAllowed` is missing or `false` | Invocation succeeds; instance is skipped |
| `RecordState` is missing | Finding is skipped before instance evaluation |
| `RecordState` is `ARCHIVED` | Finding is skipped |
| Workflow status is not `NEW` | Finding is skipped |
| Instance state is not `running` or `stopped` | Instance is skipped |
| Instance already has `Isolated=true` or only the quarantine security group | Instance is skipped without another snapshot |
| The same instance appears more than once in one invocation | It is evaluated once |
| Snapshot creation returns an error | The affected finding's processing stops before SG replacement; `.errors` increases. Earlier snapshots or earlier processed findings can already have effects |

Run snapshot-failure testing only in an isolated development test using mocks or a deliberately scoped test role. Do not remove production permissions to induce this failure.

Do not change an authorization tag merely to make a test pass. Any live
state/tag changes require separate approval and a retained pre-test value.
Additional cases must use fresh eligible fixtures or adjusted expected counts;
running every negative test on an already-quarantined instance can mask a
broken earlier gate. Keep fault injection in mocks or a disposable test stack,
not by weakening the live response role.

---

## Test 7 - Multi-Account Environment Naming and Account-Boundary Validation

### Purpose

Validate that the same Lambda naming and eligibility model works across workload accounts without accidentally reusing another environment's account or instance identifiers.

For `staging` or `prod`, use credentials for the target account and recompute all account-specific values. Changing only `ENVIRONMENT` is not sufficient.

### Example

Use the same independently checked setup for the newly selected account.
Recompute every derived identifier before this read-only inspection:

```bash
assert_test_context && aws lambda get-function-configuration \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --query '{FunctionName:FunctionName,FunctionArn:FunctionArn,State:State,CodeSha256:CodeSha256}' \
  --output json
```

If an approved direct-invocation test is required, reuse the Test 2 payload only after confirming the target account, target instance, and `IsolationAllowed` policy for that environment.

### Expected Outcome

- The environment-specific Lambda resolves in the active AWS account.
- The active AWS account ID matches the account encoded in `INSTANCE_ARN`.
- The same Lambda-side eligibility checks apply in each workload account.
- An instance with `IsolationAllowed` missing or not equal to `true` is skipped even for an otherwise eligible GuardDuty finding.
- EC2 lookups occur in the Lambda execution account/Region. A supplied resource ARN's account text is not independently validated by the handler; this inspection does not prove a general cross-account authorization boundary.

---

## Test 8 - Post-Isolation Rollback Readiness Check

### Purpose

Validate that the isolation function leaves the instance in a state that can later be restored by the `EC2 Rollback` workflow.

This test does not invoke the rollback Lambda directly. It confirms that isolation has completed and that the required metadata exists for follow-on rollback validation.

### Expected Outcome

After running Test 2 against an approved development instance, ensure the following:

- Instance is isolated
- Snapshot requests exist for attached EBS volume(s) associated with the instance; snapshot completion may still be pending
- Original security group information is preserved according to the Lambda implementation
- Isolation tags are present
- The instance can be targeted by the EC2 Rollback test workflow
- The intended recovery identity and exact bus authorization have been independently checked; assignment presence alone is insufficient

### Verification Commands

```bash
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```

```bash
aws ec2 describe-tags \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}"
```

### Follow-On Test

After this check passes, proceed to:

```text
docs/lambda_tests/ec2_rollback.md
```

Qualify the intended Operator path separately using the rollback guide. A
privileged recovery action must not be reported as successful Operator-role
qualification.

---

# EventBridge / Security Hub Integration Validation

Direct Lambda invocation confirms function behavior, but it does not validate the full production event path.

Use this section to validate the event-driven workflow.

## Integration Path

```text
GuardDuty finding
    |
    v
Security Hub imported finding
    |
    v
Default EventBridge Bus
    |
    v
${CLOUD_NAME}-${ENVIRONMENT}-securityhub-ec2-high-critical
    |
    v
EC2 Isolation Lambda
    |
    +--> request pre-isolation EBS snapshots
    |
    +--> replace instance security groups with quarantine SG
    |
    +--> add isolation evidence tags
    |
    +--> publish SecOps SNS notification
```

## EventBridge Filtering Versus Lambda Filtering

The deployed EC2-isolation EventBridge rule matches event payloads containing
the configured fields. It does not rewrite a multi-finding payload into a list
of individually approved findings; the handler rechecks each finding. The
pattern includes:

```text
ProductArn   = GuardDuty
Severity     = HIGH or CRITICAL
Resource     = AwsEc2Instance
Workflow     = NEW
RecordState  = ACTIVE
```

The Lambda independently revalidates the same product/workflow/state assumptions and then applies the configured automatic-isolation severity set plus runtime EC2 checks.

This distinction matters during testing:

- `MEDIUM`, `LOW`, non-EC2, non-GuardDuty, non-`NEW`, and non-`ACTIVE` payloads are useful **direct Lambda negative tests**, but the production EventBridge rule would normally filter them out first.
- `HIGH` is allowed through EventBridge. Whether it isolates is determined by `AUTO_ISOLATION_SEVERITIES`.
- `CRITICAL` isolates only when the deployed severity set includes `CRITICAL` and all remaining instance/snapshot gates pass.

## Expected Integration Behavior

With a `CRITICAL`-only severity configuration, a GuardDuty `CRITICAL`, `NEW`, `ACTIVE` EC2 finding against an eligible development instance with `IsolationAllowed=true` should result in snapshot requests, quarantine, evidence tags, and an SNS notification.

A GuardDuty `HIGH`, `NEW`, `ACTIVE` EC2 finding still reaches the Lambda through EventBridge, but the Lambda skips it unless `HIGH` is explicitly present in `AUTO_ISOLATION_SEVERITIES`.

---

# Cleanup

Recover only the approved test instance using the independently verified
recovery procedure. Prefer the documented rollback workflow when its access
path works; do not leave an instance stranded while treating a failed Operator
path as a documentation-only issue. If a separate authorized recovery action
is necessary, record it as such rather than counting it as an Operator test.

Confirm the exact original SG set from the independent pre-test record,
rollback tags, and notification result. Rollback sets `IsolationAllowed=true`;
review and restore the approved desired policy through the normal change
process when different. Do not overwrite incomplete forensic metadata simply
to obtain a clean test result.

Retain the payloads, invocation/request IDs, before/after records, and relevant
logs securely. Review each test-created EBS snapshot by exact ID and finding
tag; snapshots are not deleted by rollback. Preserve incident/legal retention
requirements and approve any subsequent deletion separately. No broad snapshot
cleanup command is part of this test. Review a final Terraform plan with the
same inputs, recording any policy-tag or replacement drift rather than
applying it automatically.

# Troubleshooting

Errors associated with these tests are often the result of an invalid environment variable.

Ensure that all environment variables are correctly set prior to following the troubleshooting steps outlined below.

## Lambda invocation succeeds but instance is not isolated

Check:

- `ProductArn` exactly matches `arn:${AWS_PARTITION}:securityhub:${AWS_REGION}::product/aws/guardduty`, and the Lambda's deployed `AWS_PARTITION` matches the active account's partition.
- Finding severity is included in `AUTO_ISOLATION_SEVERITIES`.
- Workflow status is `NEW` and record state is explicitly `ACTIVE`; missing `RecordState` fails closed.
- Resource type is `AwsEc2Instance` and the resource ID is valid.
- Instance state is `running` or `stopped`.
- Instance has `IsolationAllowed=true` and is not already isolated.
- Snapshot creation succeeded before the security-group change.
- Lambda execution role has the required EC2 and SNS permissions.
- Quarantine security group exists in the expected VPC.

If the security group was replaced but isolation tags are incomplete, treat the result as a partial isolation failure requiring investigation. Security-group replacement happens before the isolation tags are written; a later tagging error is not automatically rolled back.

---

## AccessDenied when invoking Lambda directly

Direct invocation requires `lambda:InvokeFunction`.

Use an explicitly authorized test principal; do not assume an Engineer or Plan role grants `lambda:InvokeFunction`.

The `SecOps-Operator` Identity Center role is intended for rollback EventBridge actions, not direct Lambda invocation.

---

## SNS notification not received

Check:

- SNS topic exists.
- Lambda has `sns:Publish`.
- SNS topic policy allows publish from the Lambda role.
- Email subscription is confirmed.
- SNS topic uses the correct KMS key permissions.

A failed SNS publish does not undo a successful quarantine. Verify the instance security groups and isolation tags independently of notification delivery.

---

## KMS AccessDenied

Check:

- Lambda execution role has access to the required KMS key.
- KMS key policy allows IAM delegation.
- The relevant CMK ARN was passed into the IAM policy module.
- The SNS topic and CloudWatch Logs encryption settings match the deployed KMS permissions.

---

## Rollback does not work after isolation

Check:

- The instance has the expected isolation metadata/tags.
- The rollback Lambda exists.
- The environment-specific `secops-bus` exists.
- The operator is assigned to the correct Identity Center group.
- The EventBridge rollback payload uses the correct `instance_id`.
- The rollback event is sent to the correct account and region.

---

# Summary

These tests validate the EC2 Isolation Lambda in the context of the full `tf-secure-baseline` platform.

Record which of the following were actually observed, with unexecuted cases marked separately:

- The deployed event rule is GuardDuty-scoped, while direct synthetic invocation tests only the handler predicates.
- CRITICAL GuardDuty EC2 findings isolate only explicitly authorized, eligible instances when `CRITICAL` is configured.
- HIGH GuardDuty findings are skipped unless the configured severity set includes `HIGH`.
- Non-GuardDuty, non-EC2, inactive, missing-state, non-NEW, ineligible, duplicate, and already-isolated targets are skipped.
- Snapshot failure prevents quarantine.
- Environment-specific naming and authorization work across accounts.
- The successful isolation path records rollback metadata; partial failures and effective recovery access were independently reviewed.
- The function fits into the broader Identity Center, EventBridge, Security Hub, and multi-account architecture.

Implementation references: [handler](../../modules/automation/lambda/ec2_isolation.py),
[event rules and destinations](../../modules/automation/main.tf),
[execution-role grants](../../modules/iam/lambda.tf), and
[automation behavior](../../modules/automation/README.md).
