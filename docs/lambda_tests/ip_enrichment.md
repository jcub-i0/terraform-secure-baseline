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

Direct invocation is useful for validating Lambda behavior without waiting for a real Security Hub finding.

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

---

## Lambda Environment Variables

The IP Enrichment Lambda should have the following environment variables configured:

```text
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

If test events use fake finding IDs or fake ProductArns, enrichment and SNS notification may still work, but Security Hub writeback may fail or be skipped depending on the Lambda implementation.

---

## Access Requirements

Direct Lambda invocation requires a principal with permission to invoke the function.

Use one of the following:

- IAM administrator user
- SecOps-Engineer role
- Authorized CI/CD role
- Another role with `lambda:InvokeFunction`

Security Hub writeback verification requires read access to Security Hub findings.

CloudWatch log verification requires read access to CloudWatch Logs.

---

## Environment Variables

Set these values before running the tests.

Update the values for the environment you are testing.

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ENVIRONMENT="dev"
export ACCOUNT_ID="<TARGET-ACCOUNT-ID>"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ip-enrichment"

# Optional: only required for Security Hub writeback validation
export REAL_SECURITY_HUB_FINDING_ID="<REAL-SECURITY-HUB-FINDING-ID>"
export REAL_PRODUCT_ARN="<REAL-PRODUCT-ARN>"
```

For staging:

```bash
export ENVIRONMENT="staging"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ip-enrichment"
```

For prod:

```bash
export ENVIRONMENT="prod"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ip-enrichment"
```

The Lambda function name is dynamically generated from:

```text
${cloud_name}-${environment}-ip-enrichment
```

Example:

```text
tf-secure-baseline-dev-ip-enrichment
```

---

## Verify AWS CLI Identity

Before running the tests, confirm your AWS CLI is authenticated to the target environment.

```bash
aws sts get-caller-identity
```

Confirm the returned account ID matches the environment being tested.

---

## Verification Commands

Use the following commands to verify Lambda behavior after running tests.

These commands require read access to Lambda, CloudWatch Logs, SNS, and optionally Security Hub.

### Check Lambda Logs

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --since 15m
```

### Confirm Security Hub Finding Note

Use this only when testing with a real finding ID and real ProductArn.

```bash
aws securityhub get-findings \
  --region "${AWS_REGION}" \
  --filters "{
    \"Id\": [
      {
        \"Value\": \"${REAL_SECURITY_HUB_FINDING_ID}\",
        \"Comparison\": \"EQUALS\"
      }
    ]
  }" \
  --query 'Findings[].Note'
```

If the `Note` block is returned with `Text`, `UpdatedBy`, and `UpdatedAt`, the Lambda successfully wrote enrichment context back to the Security Hub finding.

You can also confirm this in the AWS Console:

```text
Security Hub -> Findings -> Open finding -> History -> Note Added
```

---

# IP ENRICHMENT LAMBDA TESTS

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-critical-ipv4",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test CRITICAL finding with public IPv4 addresses",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
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
aws securityhub get-findings \
  --region "${AWS_REGION}" \
  --filters "{
    \"Id\": [
      {
        \"Value\": \"${REAL_SECURITY_HUB_FINDING_ID}\",
        \"Comparison\": \"EQUALS\"
      }
    ]
  }" \
  --query 'Findings[].Note'
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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-high-ipv6",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test HIGH finding with public IPv6 addresses",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-private-only",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with private IP addresses only",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
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
aws securityhub get-findings \
  --region "${AWS_REGION}" \
  --filters "{
    \"Id\": [
      {
        \"Value\": \"${REAL_SECURITY_HUB_FINDING_ID}\",
        \"Comparison\": \"EQUALS\"
      }
    ]
  }" \
  --query 'Findings[].Note'
```

Expected output if no previous note exists:

```json
[]
```

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-no-ip-data",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test HIGH finding with no IP data",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        }
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-invalid-securityhub-identifiers",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with invalid Security Hub identifiers",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "invalid-finding-id",
        "ProductArn": "arn:aws:securityhub:${AWS_REGION}::product/aws/securityhub",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

Expected Lambda response depends on implementation.

Acceptable outcomes:

- Enrichment completes and Security Hub writeback is skipped.
- Enrichment completes and Security Hub writeback logs a handled warning.
- Lambda returns a controlled error response without modifying any Security Hub finding.

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-empty-findings",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": []
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
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

Validate that the Lambda can extract multiple public IP addresses embedded in finding fields outside the `Network` object.

### Expected Outcome

- Lambda executes successfully.
- Multiple public IP addresses are extracted.
- IP reputation data is retrieved.
- SNS notification is sent.
- Result count reflects the number of enriched public IPs, subject to configured limits.
- No errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-multiple-productfield-ips",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with multiple public IPs in product fields",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 8 - Duplicate IP Addresses

### Purpose

Validate that duplicate public IP addresses do not cause duplicate enrichment results beyond the Lambda's intended behavior.

### Expected Outcome

- Lambda executes successfully.
- Duplicate IPs are handled safely.
- SNS notification is sent if enrichment succeeds.
- No unhandled errors appear in CloudWatch Logs.

### Manual Event via AWS CLI

```bash
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-ip-enrichment-duplicate-ips",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-03-02T00:00:00Z",
  "region": "${AWS_REGION}",
  "detail": {
    "findings": [
      {
        "Title": "Manual test finding with duplicate public IPs",
        "AwsAccountId": "${ACCOUNT_ID}",
        "Region": "${AWS_REGION}",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "${REAL_SECURITY_HUB_FINDING_ID}",
        "ProductArn": "${REAL_PRODUCT_ARN}",
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
}
EOF
)" \
response.json && cat response.json && rm response.json
```

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
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

After running tests, confirm:

- Lambda invocation succeeded.
- CloudWatch Logs show expected behavior.
- SNS notification was received when public IPs were enriched.
- Security Hub note writeback occurred only when expected.
- Private IPs were ignored.
- Empty findings were handled safely.
- Invalid Security Hub identifiers did not cause uncontrolled failures.

---

# Troubleshooting

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
- IPs are not private, loopback, link-local, or otherwise non-public.
- IP extraction logic supports the field where the IP appears.
- `MAX_IPS_EXTRACTED` and `MAX_IPS_PER_EVENT` are not set too low.

---

## AbuseIPDB lookup fails

Check:

- `THREAT_INTEL_SECRET_ARN` is configured.
- The secret exists in Secrets Manager.
- The secret contains a valid AbuseIPDB API key.
- Lambda execution role can read the secret.
- Lambda has network egress to reach AbuseIPDB.
- Network Firewall, NAT, and route tables allow required outbound connectivity.

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
- Finding belongs to the same account and region being tested.

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
- NAT Gateway and route tables are configured correctly.
- AWS Network Firewall rules allow the required outbound request.
- DNS resolution is working.
- Lambda timeout is long enough for external API calls.

---

# Summary

These tests validate the IP Enrichment Lambda in the context of the full `tf-secure-baseline` platform.

They confirm that:

- Public IPv4 addresses are extracted and enriched.
- Public IPv6 addresses are extracted and enriched.
- Private IP addresses are ignored.
- Findings without IP data are handled safely.
- Empty findings are handled safely.
- Security Hub writeback works when valid identifiers are supplied.
- SNS notifications are sent when enrichment occurs.
- The function fits into the broader Security Hub, EventBridge, SNS, KMS, Secrets Manager, and multi-account architecture.