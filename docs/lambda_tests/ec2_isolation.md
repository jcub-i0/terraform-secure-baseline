# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace `<YOUR-ACCOUNT-ID>` with your AWS account ID
* Replace `<ARN-OF-EC2-INSTANCE-TO-ISOLATE>` with the ARN of the to-be-isolated EC2 instance
* Run the test
* Confirm Expected Outcome based on 'Expected Outcome' section of each test

## TESTING APPROACH

This document contains **direct Lambda invocation tests** used for validation and debugging.

These tests:
- Bypass EventBridge and Security Hub
- Require permissions to invoke the Lambda function directly
- Are intended for development and validation purposes

In a production workflow, this Lambda is triggered by:
- Security Hub findings
- EventBridge rules

> Note:
> The name of the EC2 Isolation Lambda function is dynamically generated using `var.name_prefix`, which is composed of `var.cloud_name` and `var.environment` (e.g., `nanonexus-prod-ec2-isolation`). By default, `var.cloud_name` is `tf-secure-baseline` and `var.environment` is `dev`.

## EC2 ISOLATION LAMBDA TESTS

### TEST 1 -- HIGH EC2 SECURITY HUB FINDING
#### Expected Outcome:
* Lambda executes
* Instance isolated in Quarantine Security Group
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --region us-east-1 \
  --function-name tf-secure-baseline-dev-ec2-isolation \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "abcd-1234",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "<YOUR-ACCOUNT-ID>",
  "time": "2026-01-22T03:45:49Z",
  "region": "us-east-1",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE-TO-ISOLATE>"
          }
        ]
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```

### TEST 2 -- CRITICAL EC2 SECURITY HUB FINDING
#### Expected Outcome:
* Lambda executes
* Instance isolated in Quarantine Security Group
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name tf-secure-baseline-dev-ec2-isolation \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "abcd-1234",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "<YOUR-ACCOUNT-ID>",
  "time": "2026-01-22T03:45:49Z",
  "region": "us-east-1",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE-TO-ISOLATE>"
          }
        ]
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```

### TEST 3 -- HIGH NON-EC2 FINDING (i.e. S3, Config, etc.)
#### Expected Outcome:
* Lambda executes
* No EC2 instances modified
* No SNS message sent
* No Security Groups modified
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name tf-secure-baseline-dev-ec2-isolation \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "abcd-1234",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "<YOUR-ACCOUNT-ID>",
  "time": "2026-01-22T03:45:49Z",
  "region": "us-east-1",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2SecurityGroup",
            "Id": "<ARN-OF-SECURITY-GROUP>"
          }
        ]
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```

### TEST 4 -- MEDIUM EC2 FINDING
#### Expected Outcome:
* Lambda executes
* No EC2 instances modified
* No SNS message sent
* No Security Groups modified
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name tf-secure-baseline-dev-ec2-isolation \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "abcd-1234",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "<YOUR-ACCOUNT-ID>",
  "time": "2026-01-22T03:45:49Z",
  "region": "us-east-1",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "MEDIUM"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE>"
          }
        ]
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
```