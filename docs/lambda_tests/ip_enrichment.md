# LAMBDA FUNCTION TESTS - IP ENRICHMENT

## Purpose

This document provides manual tests used to validate the **IP Enrichment Lambda** behavior before and after changes.

The IP Enrichment Lambda processes Security Hub findings, extracts public IP addresses, enriches them using threat intelligence data, and sends the results to the configured SecOps SNS topic.

Depending on configuration, the Lambda can also write enrichment notes back to Security Hub findings.

This test validates the `IP Enrichment` workflow in the context of the full `tf-secure-baseline` architecture, including:

- Multi-account environments: `dev`, `staging`, and `prod`
- Security Hub finding ingestion
- EventBridge-driven Lambda execution
- Secrets Manager-based AbuseIPDB API key retrieval
- SNS-based SecOps notification
- Optional Security Hub finding note writeback

---

## Testing Approach

This document includes **direct Lambda invocation tests** used for development and debugging.

These tests:

- Bypass EventBridge
- Bypass real Security Hub event generation
- Invoke the IP Enrichment Lambda directly
- Validate IP extraction, enrichment, SNS notification, and optional Security Hub writeback behavior

In production, this Lambda is triggered by:

- Security Hub findings
- EventBridge rules

Direct invocation tests the handler, not the EventBridge pattern or the
provenance of a real finding. The handler does not revalidate top-level source,
detail type, severity, or workflow status as authorization controls. The
deployed event rule matches HIGH/CRITICAL, NEW Security Hub imports without a
GuardDuty-only or ACTIVE-record filter.

These tests can make external AbuseIPDB requests, publish notifications, and,
when deliberately enabled with real identifiers, replace finding notes. Use an
approved test account and approved indicator data. IP addresses in examples
are test inputs, not assertions about reputation or authorization to contact a
host; the function queries the reputation service, not those hosts directly.

---

## Prerequisites

Before running these tests, confirm:

- The target environment has been deployed.
- Security Hub is enabled in the target account.
- The IP Enrichment Lambda exists.
- The SecOps SNS topic exists.
- The threat intelligence secret exists in Secrets Manager.
- The secret contains a valid AbuseIPDB API key.
- The Lambda execution role can read the secret.
- The Lambda execution role can publish to SNS.
- The Lambda execution role can use the required KMS keys.
- If Security Hub writeback is enabled, the Lambda execution role can call `securityhub:BatchUpdateFindings`.
- The invoking principal has explicit `lambda:InvokeFunction` plus the required observer permissions. Role names alone do not prove these permissions.
- Retain test input, code hash, invocation metadata, handler result, and before/after evidence in a restricted directory.
- Prefer synthetic finding identifiers. Real writeback uses a dedicated approved test finding and an independently retained original note; do not use operational incident findings merely to test formatting.

---

## Lambda Environment Variables

The IP Enrichment Lambda should have the following environment variables configured:

```text
CLOUD_NAME
SNS_TOPIC_ARN
THREAT_INTEL_SECRET_ARN
WRITE_TO_SECURITYHUB
MAX_IPS_PER_EVENT
ABUSEIPDB_MAX_AGE_DAYS
MAX_IPS_EXTRACTED
```

### Writeback Behavior

If:

```text
WRITE_TO_SECURITYHUB=true
```

then full writeback validation requires:

- A real Security Hub finding ID
- The real ProductArn associated with that finding

The handler accepts a finding ID for writeback only when it starts with `arn:`
and contains `/finding/`, and a ProductArn only when it starts with `arn:` and
contains `:product/`. These are structural predicates, not a lookup proving a
finding exists. Synthetic non-ARN identifiers skip writeback while still
allowing enrichment and SNS publication. Syntactically valid but nonexistent
identifiers can instead reach the Security Hub API.

A single assembled note is supplied to all valid finding identifier pairs in
an event, truncated to 1,024 characters. It is not merged with each existing
note. API exceptions are logged and caught; the code does not inspect returned
`UnprocessedFindings` before logging writeback success. Verify the actual exact
finding afterward, not just the log message or `WRITE_TO_SECURITYHUB` flag.

---

## Access Requirements

Direct Lambda invocation requires a principal with permission to invoke the function.

Use a separately authorized test principal with narrowly approved invocation
and inspection rights. Emergency break-glass administration is not the default
way to perform routine tests, and the standard Engineer/Plan role name does
not imply direct invocation authority.

Security Hub writeback verification requires read access to Security Hub findings.

CloudWatch log verification requires read access to CloudWatch Logs.

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

Select the function and default synthetic identifiers:

```bash
export FUNCTION_NAME="${NAME_PREFIX}-ip-enrichment"
export TEST_FINDING_ID="manual-enrichment-${TEST_RUN_ID}"
export TEST_PRODUCT_ARN="synthetic-product-not-an-arn"
export ALLOW_TEST_FINDING_WRITEBACK="false"
```

The positive-IP cases can still query AbuseIPDB and notify SNS, but these
identifiers fail the handler's writeback predicates. Test 5 supplies its own
invalid ID. The default does not change the deployed function or remove its
IAM write authority; it avoids valid identifier pairs in this test payload.

For a separately approved writeback test only, set real identifiers and the
independent approval values below. Use a dedicated disposable test finding:

```bash
export TEST_FINDING_ID="<APPROVED-TEST-FINDING-ARN>"
export TEST_PRODUCT_ARN="<MATCHING-PRODUCT-ARN>"
export APPROVED_TEST_FINDING_ID="<INDEPENDENTLY-APPROVED-TEST-FINDING-ARN>"
export APPROVED_TEST_PRODUCT_ARN="<INDEPENDENTLY-APPROVED-PRODUCT-ARN>"
export ALLOW_TEST_FINDING_WRITEBACK="true"
```

These variables guard the local example; they are not a new application or IAM
approval mechanism. The deployed `WRITE_TO_SECURITYHUB` setting must also allow
writeback. Reset the synthetic identifiers afterward. Merely adding a real ID
does not turn a synthetic invocation into an authentic Security Hub event.

---

## Verify AWS CLI Identity

Before running the tests, confirm your AWS CLI is authenticated to the target environment.

```bash
assert_test_context && aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}"
```

Confirm the returned account ID matches the environment being tested.

---

## Verification Commands

Use the following commands to verify Lambda behavior after running tests.

These commands require read access to Lambda, CloudWatch Logs, SNS, and optionally Security Hub.

### Check Lambda Logs

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --since 15m
```

### Confirm Security Hub Finding Note

Use this only for the explicitly approved real-finding case. Query both the
finding ID and ProductArn; require exactly one finding instead of treating an
empty `Note` projection as proof of absence or success.

```bash
inspect_test_finding() (
  set -euo pipefail
  assert_test_context
  [[ "${ALLOW_TEST_FINDING_WRITEBACK:-false}" == "true" ]]
  [[ "$TEST_FINDING_ID" == "${APPROVED_TEST_FINDING_ID:?Approve the finding}" ]]
  [[ "$TEST_PRODUCT_ARN" == "${APPROVED_TEST_PRODUCT_ARN:?Approve the product}" ]]
  filters="$(jq -n --arg id "$TEST_FINDING_ID" --arg product "$TEST_PRODUCT_ARN" '
    {Id:[{Value:$id,Comparison:"EQUALS"}],
     ProductArn:[{Value:$product,Comparison:"EQUALS"}]}
  ')"
  findings="$(aws securityhub get-findings --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "$filters" --output json)"
  jq -e --arg id "$TEST_FINDING_ID" --arg product "$TEST_PRODUCT_ARN" '
    (.Findings | length) == 1 and .Findings[0].Id == $id and .Findings[0].ProductArn == $product
  ' <<< "$findings" >/dev/null
  jq '.Findings[0] | {Id,ProductArn,UpdatedAt,Note}' <<< "$findings"
)
```

Capture this result before invocation and again afterward in separate files.
Compare `Note.Text`, `Note.UpdatedBy`, and `Note.UpdatedAt` with the retained
baseline, the selected test interval, and the actual IPs returned. An old note
can already exist, and another process can update it concurrently. A non-empty
note alone does not prove this invocation wrote it. For a no-write case,
unchanged before/after data is evidence; it is not a universal assertion that
every note list must be empty.

---

# IP ENRICHMENT LAMBDA TESTS

Define the invocation helper after the setup above. It records function
configuration without reading the API-key value, retains separate request and
response files, and checks both Lambda invocation metadata and handler status.
Each call is synchronous and does not test asynchronous retry/destination behavior.

```bash
invoke_enrichment_case() (
  set -euo pipefail
  label="$1"; expected_status="$2"; payload="$3"
  assert_test_context
  [[ "$FUNCTION_NAME" == "${NAME_PREFIX}-ip-enrichment" ]]
  : "${EVIDENCE_DIR:?Create the evidence directory}"
  umask 077
  run_dir="$(mktemp -d "${EVIDENCE_DIR}/${label}.XXXXXX")"
  printf 'Review evidence: %s\n' "$run_dir"
  printf '%s\n' "$payload" | jq -e . > "$run_dir/event.json"
  git rev-parse HEAD > "$run_dir/checkout-commit.txt"
  aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --output json > "$run_dir/caller.json"
  aws lambda get-function-configuration --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" \
    --query '{FunctionArn:FunctionArn,CodeSha256:CodeSha256,State:State,LastModified:LastModified,Writeback:Environment.Variables.WRITE_TO_SECURITYHUB,ExtractionLimit:Environment.Variables.MAX_IPS_EXTRACTED,QueryLimit:Environment.Variables.MAX_IPS_PER_EVENT,Subnets:VpcConfig.SubnetIds}' \
    --output json > "$run_dir/function.json"
  jq -e '.State == "Active"' "$run_dir/function.json" >/dev/null
  valid_pairs="$(jq '[.detail.findings[]? |
    select((.Id | type) == "string" and (.ProductArn | type) == "string") |
    select((.Id | startswith("arn:") and contains("/finding/")) and
           (.ProductArn | startswith("arn:") and contains(":product/"))) |
    {Id,ProductArn}]' "$run_dir/event.json")"
  if [[ "$(jq length <<< "$valid_pairs")" -gt 0 ]]; then
    [[ "${ALLOW_TEST_FINDING_WRITEBACK:-false}" == "true" ]]
    jq -e --arg id "${APPROVED_TEST_FINDING_ID:?Approve the finding}" \
      --arg product "${APPROVED_TEST_PRODUCT_ARN:?Approve the product}" '
      all(.[]; .Id == $id and .ProductArn == $product)
    ' <<< "$valid_pairs" >/dev/null
    inspect_test_finding > "$run_dir/finding-before.json"
  fi
  aws lambda invoke --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --function-name "$FUNCTION_NAME" --invocation-type RequestResponse \
    --cli-read-timeout 120 --payload "fileb://${run_dir}/event.json" \
    --output json "$run_dir/response.json" > "$run_dir/invocation.json"
  jq . "$run_dir/invocation.json" "$run_dir/response.json"
  jq -e '.StatusCode == 200 and (has("FunctionError") | not)' "$run_dir/invocation.json" >/dev/null
  jq -e --argjson expected "$expected_status" '
    .statusCode == $expected and (.body | fromjson | type == "object")
  ' "$run_dir/response.json" >/dev/null
  jq '.body | fromjson' "$run_dir/response.json" > "$run_dir/body.json"
  if [[ "$(jq length <<< "$valid_pairs")" -gt 0 ]]; then
    inspect_test_finding > "$run_dir/finding-after.json"
  fi
)
```

Stop when a helper fails, inspect retained evidence, and do not rerun blindly:
SNS or finding updates may already have happened. The helper's status check is
only one part of acceptance. Independently compare the case's expected body,
actual result count, provider errors, notification receipt, and any real-finding
change. A handler `statusCode=400` or `500` is payload data, not necessarily a
Lambda `FunctionError`. Even handler `200` can accompany caught SNS or writeback
failures; see [Lambda invocation semantics](https://docs.aws.amazon.com/cli/latest/reference/lambda/invoke.html).

Under the default synthetic IDs, successful enrichment with deployed writeback
enabled can return `No valid identifers for Security Hub writeback` rather than
`Processing complete`. That spelling is the handler's actual message. It can
omit `resultCount` even after sending a notification. The illustrative
`Processing complete` bodies below apply when writeback is disabled or a valid
approved identifier path reaches the final return. A zero-result response does
not satisfy a positive-IP test merely because the status is `200`.

Public-IP result counts depend on valid API credentials, configured positive
limits, extraction/classification, incoming-note deduplication, and successful
external responses. Illustrative counts are not fixed reputation-service
promises. Missing credentials cause a handled `500` even for non-empty findings
without public IPs, because secret retrieval happens before filtering.

## Test 1 - CRITICAL Finding with Public IPv4 Addresses

### Purpose

Validate that the Lambda extracts public IPv4 addresses from a Security Hub finding, enriches them, sends an SNS notification, and optionally writes a note back to Security Hub.

### Expected Outcome

- Lambda executes successfully.
- Public IPv4 addresses are extracted.
- IP reputation data is retrieved from AbuseIPDB.
- SNS notification is sent to the configured SecOps topic.
- If valid Security Hub identifiers are supplied and `WRITE_TO_SECURITYHUB=true`, a note is written back to the finding.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-critical-ipv4" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-critical-ipv4-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test CRITICAL finding with public IPv4 addresses",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV4": "103.37.6.88"
        },
        "ProductFields": {
          "someField": "connection from 1.1.1.1 observed"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"Processing complete\", \"resultCount\": 2}"
}
```

### Optional Security Hub Writeback Check

```bash
# Run only for the explicitly approved real-finding case.
inspect_test_finding
```

---

## Test 2 - HIGH Finding with Public IPv6 Addresses

### Purpose

Validate that the Lambda extracts public IPv6 addresses from a Security Hub finding and enriches them.

### Expected Outcome

- Lambda executes successfully.
- Public IPv6 addresses are extracted.
- IP reputation data is retrieved from AbuseIPDB.
- SNS notification is sent to the configured SecOps topic.
- If valid Security Hub identifiers are supplied and `WRITE_TO_SECURITYHUB=true`, a note is written back to the finding.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-high-ipv6" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-high-ipv6-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test HIGH finding with public IPv6 addresses",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV6": "2600:1f1a:4d5e:c202:c650:7b48:85af:a5c5"
        },
        "ProductFields": {
          "someField": "connection from 2600:4040:251a:7200:d278:1c82:12a7:b782 observed"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"Processing complete\", \"resultCount\": 2}"
}
```

---

## Test 3 - Finding with Private IP Addresses Only

### Purpose

Validate that private, non-public IP addresses are ignored and not enriched.

### Expected Outcome

- Lambda executes successfully.
- No public IP addresses are enriched.
- No SNS message is sent.
- No Security Hub writeback is performed.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-private-only" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-private-only-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with private IP addresses only",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV4": "10.0.1.15"
        },
        "ProductFields": {
          "someField": "internal service connection from 172.16.5.10 observed"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"No IPs enriched\", \"resultCount\": 0}"
}
```

### Confirm Absence of Security Hub Writeback

```bash
# Run only for the explicitly approved real-finding case.
inspect_test_finding
```

For the synthetic case there is no real finding to inspect. For an approved
real finding, compare its note with the retained pre-test note and require no
new change attributable to this invocation. An earlier note can remain; an
empty projection is not the acceptance criterion. The handler reads previous
`EnrichedIPs` only from a note present in the incoming payload, not by fetching
the current finding. These examples do not automatically include that note.

---

## Test 4 - HIGH Finding with No IP Data

### Purpose

Validate that a finding with no IP data is handled safely.

### Expected Outcome

- Lambda executes successfully.
- No IP addresses are enriched.
- No SNS message is sent.
- No Security Hub writeback is performed.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-no-ip-data" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-no-ip-data-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test HIGH finding with no IP data",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"No IPs enriched\", \"resultCount\": 0}"
}
```

---

## Test 5 - Finding with Invalid Security Hub Identifiers

### Purpose

Validate that enrichment still executes when public IPs are present, but Security Hub writeback fails safely or is skipped when finding identifiers are invalid.

### Expected Outcome

- Lambda executes.
- Public IPs may still be enriched.
- SNS notification may still be sent if enrichment succeeds.
- Security Hub writeback should fail safely or be skipped.
- No unhandled Lambda failure occurs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-invalid-securityhub-identifiers" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-invalid-securityhub-identifiers-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with invalid Security Hub identifiers",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "invalid-finding-id",
        "ProductArn": "arn:aws:securityhub:\($AWS_REGION)::product/aws/securityhub",
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV4": "103.37.6.88"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"No valid identifers for Security Hub writeback\"}"
}
```

Acceptance depends on which path was actually reached:

- With successful enrichment and writeback enabled, the deliberately non-ARN ID is skipped and no writeback API call should be made for it.
- With writeback disabled, successful enrichment can return `Processing complete` with a result count.
- A provider/secret failure that prevents enrichment does not qualify the intended successful-enrichment-plus-invalid-ID path; record it as failed or not exercised.
- Inspect the response and logs; do not infer that all syntactically valid but nonexistent identifiers behave like this deliberately invalid identifier.

---

## Test 6 - Empty Findings Array

### Purpose

Validate that the Lambda handles an event with no findings safely.

### Expected Outcome

- Lambda executes.
- Lambda returns a response indicating no findings were present.
- No SNS message is sent.
- No Security Hub writeback is performed.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-empty-findings" 400 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-empty-findings-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": []
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 400,
  "body": "{\"message\": \"No findings in event\"}"
}
```

---

## Test 7 - Multiple Public IPs in Product Fields

### Purpose

Validate that the Lambda can extract and enrich public IP addresses embedded in provider-specific finding fields, such as `ProductFields`.

Security Hub findings are not always consistent about where network indicators appear. Some findings place IP addresses in normalized fields like `Network.SourceIpV4`, while others include them only in text-heavy or provider-specific fields.

Use the observed result to assess indicators outside dedicated network fields.
The recursive scanner excludes selected fields such as `Note` and
`UserDefinedFields`. The extraction threshold is checked after processing a
whole finding, so `MAX_IPS_EXTRACTED` is not a strict per-string or memory bound.
The final sorted public-IP query list is sliced by `MAX_IPS_PER_EVENT`.

### Expected Outcome

- Lambda executes successfully.
- Public IP addresses are extracted from `ProductFields`.
- IP reputation data is retrieved.
- SNS notification is sent.
- Result count reflects the number of unique enriched public IPs, subject to configured limits.
- If valid Security Hub identifiers are supplied and `WRITE_TO_SECURITYHUB=true`, a note is written back to the finding.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-multiple-productfield-ips" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-multiple-productfield-ips-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with multiple public IPs in product fields",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "ProductFields": {
          "source": "connection observed from 8.8.8.8",
          "destination": "secondary connection observed from 1.1.1.1",
          "other": "additional activity from 103.37.6.88"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"Processing complete\", \"resultCount\": 3}"
}
```

---

## Test 8 - Duplicate IP Addresses

### Purpose

Validate that duplicate public IP addresses do not cause duplicate enrichment results beyond the Lambda's intended behavior.

### Expected Outcome

- Lambda executes successfully.
- Repeated identical IP strings are deduplicated by the handler's set. Alternate text representations and cross-invocation deduplication are different cases.
- SNS notification is sent if enrichment succeeds.
- No unhandled errors appear in CloudWatch Logs; independently inspect handled provider, SNS, and writeback errors.

### Manual Event via AWS CLI

```bash
invoke_enrichment_case "test-ip-enrichment-duplicate-ips" 200 \
  "$(jq -n \
    --arg ACCOUNT_ID "${ACCOUNT_ID}" \
    --arg AWS_REGION "${AWS_REGION}" \
    --arg TEST_FINDING_ID "${TEST_FINDING_ID}" \
    --arg TEST_PRODUCT_ARN "${TEST_PRODUCT_ARN}" \
    --arg TEST_TIME "${TEST_TIME}" \
    --arg TEST_RUN_ID "${TEST_RUN_ID}" \
    '{
  "version": "0",
  "id": ("test-ip-enrichment-duplicate-ips-" + $TEST_RUN_ID),
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": $ACCOUNT_ID,
  "time": $TEST_TIME,
  "region": $AWS_REGION,
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with duplicate public IPs",
        "AwsAccountId": $ACCOUNT_ID,
        "Region": $AWS_REGION,
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": $TEST_FINDING_ID,
        "ProductArn": $TEST_PRODUCT_ARN,
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV4": "8.8.8.8"
        },
        "ProductFields": {
          "source": "duplicate connection from 8.8.8.8 observed"
        }
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

Expected Lambda response body pattern:

```json
{
  "statusCode": 200,
  "body": "{\"message\": \"Processing complete\", \"resultCount\": 1}"
}
```

---

# EventBridge / Security Hub Integration Validation

Direct Lambda invocation confirms function behavior, but it does not validate the full production event path.

Use this section to validate the event-driven workflow.

## Integration Path

```text
Security Hub Finding
    |
    v
Default EventBridge Bus
    |
    v
EventBridge Rule
    |
    v
IP Enrichment Lambda
    |
    v
AbuseIPDB Lookup
    |
    +--> SNS Notification
    |
    +--> Optional Security Hub Note Writeback
```

## Expected Integration Behavior

When a qualifying Security Hub finding is imported:

- EventBridge matches the finding.
- The IP Enrichment Lambda is invoked.
- Public IPs are extracted from the finding.
- Public IPs are enriched.
- SNS notification is sent.
- If enabled, Security Hub note writeback occurs.
- CloudWatch Logs show successful execution.

---

# Post-Test Validation

After each independently recorded case, confirm:

- Lambda invocation succeeded.
- CloudWatch Logs show expected behavior.
- SNS notification was received when public IPs were enriched.
- Security Hub note writeback occurred only when expected.
- Private IPs were ignored.
- Empty findings were handled safely.
- Invalid Security Hub identifiers did not cause uncontrolled failures.
- The actual case path ran: a handled missing-secret or zero-result path is not a positive enrichment pass.
- Any original real-finding note and approved test disposition were retained. Do not blindly restore an old note over a concurrent update.
- Local evidence contains no API-key value and is retained only in approved storage. Synchronous tests do not prove EventBridge delivery, asynchronous retries, or DLQ behavior.

---

# Troubleshooting

Errors associated with these tests are often the result of an invalid environment variable.

Ensure that all environment variables are correctly set prior to following the troubleshooting steps outlined below.

## Lambda invocation fails

Check:

- Function name is correct.
- AWS CLI is authenticated to the target account.
- Region is correct.
- Caller has `lambda:InvokeFunction`.
- Lambda exists in the selected environment.

---

## No IPs are enriched

Check:

- The event contains public IP addresses.
- IPs pass the handler's explicit `ipaddress` predicate: not private, loopback, link-local, multicast, or reserved. Do not treat that predicate as a comprehensive authorization to query any address.
- IP extraction logic supports the field where the IP appears.
- Limits are valid positive numeric values suitable for the test; several module inputs are strings and the Python code converts them with `int`.
- The supplied finding note has not suppressed the tested IP strings. Deduplication uses the incoming note only; repeating a synthetic payload without that note can repeat notifications and writes.

---

## AbuseIPDB lookup fails

Check:

- `THREAT_INTEL_SECRET_ARN` is configured.
- The secret exists in Secrets Manager.
- The secret contains a valid AbuseIPDB API key.
- Lambda execution role can read the secret.
- Lambda has network egress to reach AbuseIPDB.
- The deployed enrichment Lambda has no VPC configuration. Workload NAT/firewall routes are not its outbound path. Inspect those only if the function was separately changed to VPC attachment.
- A warm execution environment caches the API key without a TTL; changing the secret does not guarantee immediate use of the new value in every warm environment.

---

## SNS notification is not received

Check:

- `SNS_TOPIC_ARN` is configured.
- SNS topic exists.
- Lambda execution role has `sns:Publish`.
- Email subscription is confirmed.
- SNS topic KMS permissions allow Lambda usage.

---

## Security Hub writeback does not occur

Check:

- `WRITE_TO_SECURITYHUB=true`.
- The test uses a real Security Hub finding ID.
- The test uses the correct ProductArn.
- Lambda execution role has `securityhub:BatchUpdateFindings`.
- Security Hub is enabled in the target account and region.
- Finding belongs to the intended account and region being tested, and the exact ID/ProductArn query returns it.
- The recorded before/after note actually changed as expected. The handler ignores partial `UnprocessedFindings` results, so a logged successful API call is not exact writeback proof.

---

## KMS AccessDenied

Check:

- Lambda execution role has access to the required KMS key.
- KMS key policy allows IAM delegation.
- Secrets Manager secret encryption allows Lambda access.
- SNS topic encryption allows Lambda access.
- The relevant CMK ARNs were passed into the IAM policy module.

---

## Lambda times out

Check:

- Lambda has outbound internet access if calling AbuseIPDB.
- The actual function attachment matches expectations: the supplied enrichment function is outside the workload VPC, so its outbound calls do not traverse the workload NAT or Network Firewall.
- Requests are sequential with a per-request timeout; the configured query limit does not guarantee completion within the Lambda invocation timeout.
- DNS resolution is working.
- Lambda timeout is long enough for external API calls.

---

# Summary

These tests validate the IP Enrichment Lambda in the context of the full `tf-secure-baseline` platform.

Record which of the following were observed; do not report unexecuted cases as passed:

- Public IPv4 addresses are extracted and enriched.
- Public IPv6 addresses are extracted and enriched.
- Private IP addresses are ignored.
- Findings without IP data are handled safely.
- Empty findings are handled safely.
- Actual writeback was independently observed for explicitly approved valid test identifiers; synthetic cases only exercise skip behavior.
- Notification receipt was verified separately from enrichment and invocation status.
- The function fits into the broader Security Hub, EventBridge, SNS, KMS, Secrets Manager, and multi-account architecture.

Implementation references: [handler](../../modules/automation/lambda/ip_enrichment.py),
[event rule, environment, and destinations](../../modules/automation/main.tf),
[execution role](../../modules/iam/lambda.tf), and
[automation reference](../../modules/automation/README.md).
