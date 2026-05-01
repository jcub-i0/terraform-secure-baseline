# LAMBDA FUNCTION TESTS - EC2 ISOLATION

## Purpose

This document provides manual tests used to validate the **EC2 Isolation Lambda** behavior before and after changes.

The EC2 Isolation Lambda is responsible for isolating EC2 instances and snapshotting their EBS volumes when qualifying Security Hub findings are detected.

It is designed to support the broader `tf-secure-baseline` architecture, including:

- Multi-account environments: `dev`, `staging`, and `prod`
- Centralized control plane
- IAM Identity Center access model
- Security Hub and EventBridge-driven security workflows
- SNS-based SecOps notifications
- Follow-on rollback using the SecOps-Operator Identity Center role

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

In production, this Lambda is triggered by:

- Security Hub findings
- EventBridge rules

Direct invocation is useful for validating Lambda behavior without waiting for a real Security Hub finding.

---

## Identity and Access Context

This project uses a centralized IAM Identity Center model.

For this test document:

- **EC2 Isolation** is automated and triggered by Security Hub/EventBridge.
- **EC2 Rollback** is manually triggered by a user assigned to the environment-specific `SecOps-Operator` group.
- The `SecOps-Operator` role does **not** directly invoke this Lambda.
- Direct Lambda invocation tests should be run by an administrator, engineer, or CI/CD role with `lambda:InvokeFunction`.

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
- Security Hub is enabled in the target account.
- EventBridge rules for Security Hub findings are deployed.
- The EC2 Isolation Lambda exists.
- The `Quarantine` security group exists.
- The SecOps SNS topic exists.
- A test EC2 instance exists in the target environment.
- Your principal has permission to invoke the Lambda directly.
- You know the AWS account ID and region for the target environment.

---

## Environment Variables

Set these values before running the examples.

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export ENVIRONMENT="dev"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<YOUR-ACCOUNT-ID>"
export INSTANCE_ID="<EC2-INSTANCE-ID>"
export INSTANCE_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-isolation"
```
> If any of the following tests fail, ensure that the above environment variables are correctly set.

For other environments, update:

```bash
export ENVIRONMENT="staging"
```

or:

```bash
export ENVIRONMENT="prod"
```

The Lambda function name is dynamically generated from:

```text
${cloud_name}-${environment}-ec2-isolation
```

Example:

```text
tf-secure-baseline-dev-ec2-isolation
```

---

## Verification Commands

- Specify that this should be done AFTER configuring the AWS CLI with either the role you assume or the IAM admin user.

Use the following commands to confirm the target instance state before and after isolation.

### Check Current Security Groups

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```
> Ensure that the instance is not attached to the `Quarantine` security group.

### Check Instance Tags

```bash
aws ec2 describe-tags \
  --region "${AWS_REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}"
```
> Ensure that the instance's `IsolationAllowed` tag is set to `true` and the `Isolated` tag either does not exist or is set to `false`.

### Check Lambda Logs

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --since 15m
```
> If this returns nothing, that's fine; but you do not want to see errors.

---

# EC2 ISOLATION LAMBDA TESTS

## Test 1 - HIGH EC2 Security Hub Finding

### Purpose

Validate that a `HIGH` severity Security Hub finding for an EC2 instance causes the instance to be isolated.

### Expected Outcome

- Lambda executes successfully.
- A snapshot is taken of the instance's EBS volume
- Instance is moved into the quarantine security group.
- Isolation tags are applied to the instance.
- SNS notification is sent to the configured SecOps topic.
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
  "id": "test-high-ec2-isolation",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-high-ec2-001",
        "Title": "Manual test HIGH EC2 finding",
        "Description": "Manual test event used to validate EC2 isolation behavior.",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 2 - CRITICAL EC2 Security Hub Finding

### Purpose

Validate that a `CRITICAL` severity Security Hub finding for an EC2 instance causes the instance to be isolated.

### Expected Outcome

- Lambda executes successfully.
- A snapshot is taken of the instance's EBS volume
- Instance is moved into the quarantine security group.
- Isolation tags are applied to the instance.
- SNS notification is sent to the configured SecOps topic.
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
  "id": "test-critical-ec2-isolation",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-critical-ec2-001",
        "Title": "Manual test CRITICAL EC2 finding",
        "Description": "Manual test event used to validate EC2 isolation behavior.",
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 3 - HIGH Non-EC2 Finding

### Purpose

Validate that a `HIGH` severity finding for a non-EC2 resource does not trigger EC2 isolation.

### Expected Outcome

- Lambda executes successfully.
- No EC2 instances are modified.
- No security groups are changed.
- No isolation tags are applied.
- No isolation SNS notification is sent.
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
  "id": "test-high-non-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-high-non-ec2-001",
        "Title": "Manual test HIGH non-EC2 finding",
        "Description": "Manual test event used to validate non-EC2 findings are ignored.",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsS3Bucket",
            "Id": "arn:aws:s3:::example-test-bucket"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 4 - MEDIUM EC2 Finding

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-medium-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-medium-ec2-001",
        "Title": "Manual test MEDIUM EC2 finding",
        "Description": "Manual test event used to validate MEDIUM findings are ignored.",
        "Severity": {
          "Label": "MEDIUM"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 5 - LOW EC2 Finding

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-low-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-low-ec2-001",
        "Title": "Manual test LOW EC2 finding",
        "Description": "Manual test event used to validate LOW findings are ignored.",
        "Severity": {
          "Label": "LOW"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 6 - RESOLVED EC2 Finding

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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-resolved-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-resolved-ec2-001",
        "Title": "Manual test RESOLVED EC2 finding",
        "Description": "Manual test event used to validate resolved findings are ignored.",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "RESOLVED"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected CLI Output

```json
{
  "StatusCode": 200,
  "ExecutedVersion": "$LATEST"
}
```

---

## Test 7 - Multi-Account Environment Naming Validation

### Purpose

Validate that the function naming convention works consistently across environments.

This does not require changing the payload. It validates that the same test pattern can be used in `dev`, `staging`, or `prod` by changing the `ENVIRONMENT` variable.

### Example

```bash
export ENVIRONMENT="staging"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-isolation"

aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-staging-high-ec2-isolation",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-staging-high-ec2-001",
        "Title": "Manual staging test HIGH EC2 finding",
        "Description": "Manual test event used to validate environment-specific Lambda naming.",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "${INSTANCE_ARN}"
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

### Expected Outcome

- The environment-specific Lambda function is invoked.
- The finding is processed according to the same isolation rules.
- Only the target account/environment is affected.

---

## Test 8 - Post-Isolation Rollback Readiness Check

### Purpose

Validate that the isolation function leaves the instance in a state that can later be restored by the `EC2 Rollback` workflow.

This test does not invoke the rollback Lambda directly. It confirms that isolation has completed and that the required metadata exists for follow-on rollback validation.

### Expected Outcome

After running one of the `EC2 Isolation` tests that results in an isolated instance (Test 1 or 2), ensure the following: 

- Instance is isolated
- Snapshot is taken of EBS volume(s) associated with the instance
- Original security group information is preserved according to the Lambda implementation
- Isolation tags are present
- The instance can be targeted by the EC2 Rollback test workflow
- A user assigned to the correct `SecOps-Operator-<Env>` group can trigger rollback through EventBridge

### Verification Commands

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups'
```

```bash
aws ec2 describe-tags \
  --region "${AWS_REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}"
```

### Follow-On Test

After this check passes, proceed to:

```text
docs/lambda_tests/ec2_rollback.md
```

The rollback workflow should be tested using the Identity Center `SecOps-Operator` role for the target environment.

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
EC2 Isolation Lambda
    |
    v
EC2 Security Group Replacement + SNS Alert
```

## Expected Integration Behavior

When a qualifying Security Hub finding is imported:

- EventBridge matches the finding.
- The EC2 Isolation Lambda is invoked.
- The target EC2 instance is isolated.
- An SNS notification is sent.
- CloudWatch Logs show successful execution.

---

# Cleanup

After testing, restore the test EC2 instance using the EC2 rollback workflow.

Do not manually reattach security groups unless rollback testing is not being performed.

Preferred cleanup path:

1. Confirm isolation occurred.
2. Assume the correct SecOps-Operator role through IAM Identity Center.
3. Send the approved rollback event to the environment-specific security operations EventBridge bus.
4. Confirm original security groups are restored.
5. Confirm rollback notification is sent.

---

# Troubleshooting

Errors associated with these tests are often the result of an invalid environment variable.

Ensure that all environment variables are correctly set prior to following the troubleshooting steps outlined below. 

## Lambda invocation succeeds but instance is not isolated

Check:

- Finding severity is `HIGH` or `CRITICAL`.
- Resource type is `AwsEc2Instance`.
- Resource ID is a valid EC2 instance ARN.
- Lambda execution role has required EC2 permissions.
- Quarantine security group exists.
- Instance is in the expected VPC.

---

## AccessDenied when invoking Lambda directly

Direct invocation requires `lambda:InvokeFunction`.

Use an administrator, engineer role, or authorized CI/CD role.

The `SecOps-Operator` Identity Center role is intended for rollback EventBridge actions, not direct Lambda invocation.

---

## SNS notification not received

Check:

- SNS topic exists.
- Lambda has `sns:Publish`.
- SNS topic policy allows publish from the Lambda role.
- Email subscription is confirmed.
- SNS topic uses the correct KMS key permissions.

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

They confirm that:

- High and critical EC2 findings trigger isolation.
- Medium and low findings are ignored.
- Non-EC2 findings are ignored.
- Environment-specific naming works across accounts.
- Isolation supports the controlled rollback workflow.
- The function fits into the broader Identity Center, EventBridge, Security Hub, and multi-account architecture.