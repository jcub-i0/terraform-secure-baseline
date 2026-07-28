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
- Use development for destructive isolation tests unless another environment has been explicitly approved and enabled.
- The target instance has `IsolationAllowed=true`; staging and production default to `false`.
- The Lambda role can describe instances, create and tag snapshots, modify instance security groups, create tags, and publish to SNS.
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

### Check Pre-Isolation Snapshots

After a successful isolation test, confirm that snapshots were requested for the target instance:

```bash
aws ec2 describe-snapshots \
  --region "${AWS_REGION}" \
  --owner-ids self \
  --filters "Name=tag:InstanceId,Values=${INSTANCE_ID}" \
  --query 'Snapshots[].[SnapshotId,VolumeId,State,StartTime,Tags[?Key==`IsolationFinding`].Value|[0]]' \
  --output table
```

The snapshots should include the test instance ID and isolation finding tag.

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

Validate that a `HIGH` severity EC2 finding is skipped by the default `CRITICAL`-only automatic-isolation policy.

### Expected Outcome

- Lambda executes successfully.
- The finding is logged and skipped because `HIGH` is not in the default configured severity set.
- No snapshots, security-group changes, isolation tags, or isolation SNS notification are created.
- No unexpected errors appear in CloudWatch Logs.

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
        "RecordState": "ACTIVE",
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
- Tagged snapshots are requested for every attached EBS volume before the security-group change.
- The instance is moved into the quarantine security group.
- Isolation evidence tags are applied while `IsolationAllowed` remains `true`.
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
        "RecordState": "ACTIVE",
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

## Test 3 - CRITICAL Non-EC2 Finding

### Purpose

Validate that a configured `CRITICAL` finding for a non-EC2 resource does not trigger EC2 isolation.

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
  "id": "test-critical-non-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-critical-non-ec2-001",
        "Title": "Manual test CRITICAL non-EC2 finding",
        "Description": "Manual test event used to validate non-EC2 findings are ignored.",
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
        "RecordState": "ACTIVE",
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
        "RecordState": "ACTIVE",
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
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "RESOLVED"
        },
        "RecordState": "ACTIVE",
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

## Additional Safety-Gate Checks

Use the Test 2 `CRITICAL` payload and change one condition at a time.

| Condition | Expected result |
|---|---|
| `IsolationAllowed` is missing or `false` | Invocation succeeds; instance is skipped |
| `RecordState` is `ARCHIVED` | Finding is skipped |
| Workflow status is not `NEW` | Finding is skipped |
| Instance state is not `running` or `stopped` | Instance is skipped |
| Instance already has `Isolated=true` or only the quarantine security group | Instance is skipped without another snapshot |
| The same instance appears more than once in one invocation | It is evaluated once |
| Snapshot creation returns an error | Isolation fails closed and security groups are unchanged |

Run snapshot-failure testing only in an isolated development test using mocks or a deliberately scoped test role. Do not remove production permissions to induce this failure.

Before continuing, restore `IsolationAllowed=true` on the approved development test instance.

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
  "id": "test-staging-critical-ec2-isolation",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-staging-critical-ec2-001",
        "Title": "Manual staging test CRITICAL EC2 finding",
        "Description": "Manual test event used to validate environment-specific Lambda naming.",
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
- The same eligibility checks are applied in that account.
- Staging and production skip isolation by default because their instances have `IsolationAllowed=false`.
- Only the target account/environment is evaluated.

---

## Test 8 - Post-Isolation Rollback Readiness Check

### Purpose

Validate that the isolation function leaves the instance in a state that can later be restored by the `EC2 Rollback` workflow.

This test does not invoke the rollback Lambda directly. It confirms that isolation has completed and that the required metadata exists for follow-on rollback validation.

### Expected Outcome

After running Test 2 against an approved development instance, ensure the following:

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

When a HIGH or CRITICAL EC2 finding is imported, EventBridge invokes the Lambda. Isolation occurs only when the runtime severity configuration and all finding, instance, authorization, and snapshot checks pass. With the default configuration, a `CRITICAL`, `NEW`, `ACTIVE` finding against a development instance with `IsolationAllowed=true` should result in quarantine, evidence tags, and an SNS notification.

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

- Finding severity is included in `AUTO_ISOLATION_SEVERITIES`; the deployed default is `CRITICAL`.
- Workflow status is `NEW` and record state is `ACTIVE`.
- Resource type is `AwsEc2Instance` and the resource ID is valid.
- Instance state is `running` or `stopped`.
- Instance has `IsolationAllowed=true` and is not already isolated.
- Snapshot creation succeeded before the security-group change.
- Lambda execution role has the required EC2 and SNS permissions.
- Quarantine security group exists in the expected VPC.

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

- CRITICAL EC2 findings isolate only explicitly authorized, eligible instances by default.
- HIGH findings are skipped unless the configured severity set is expanded.
- Non-EC2, inactive, non-NEW, ineligible, duplicate, and already-isolated targets are skipped.
- Snapshot failure prevents quarantine.
- Environment-specific naming and authorization work across accounts.
- Isolation preserves the controlled rollback workflow.
- The function fits into the broader Identity Center, EventBridge, Security Hub, and multi-account architecture.