# LAMBDA FUNCTION TESTS - EC2 ROLLBACK

## Purpose

This document provides manual tests used to validate the **EC2 Rollback Lambda** behavior before and after changes.

The EC2 Rollback Lambda restores an EC2 instance from the `Quarantine` security group back to its original security group configuration after an approved rollback event is submitted.

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

It can submit rollback events, but it does not directly modify EC2 security groups or invoke Lambda functions.

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
- Your `IAM Identity Center` user is assigned to the correct `SecOps-Operator` group for the target environment.

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
- `events:PutEvents` on the environment-specific SecOps event bus

This is the minimum access required to manually inject rollback events onto the SecOps event bus.

---

## Environment Variables

Set these values before running the CLI-based tests.

Update the values for the environment you are testing.

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ENVIRONMENT="dev"
export ACCOUNT_ID="<TARGET-ACCOUNT-ID>"
export INSTANCE_ID="<QUARANTINED-EC2-INSTANCE-ID>"
export PROFILE_NAME="operator"
export EVENT_BUS_NAME="${CLOUD_NAME}-${ENVIRONMENT}-secops-bus"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-rollback"
export APPROVED_BY="secops@company.com"
export TICKET_ID="t-abc123"
export ROLLBACK_REASON="Test rollback"
```

For staging:

```bash
export ENVIRONMENT="staging"
export EVENT_BUS_NAME="${CLOUD_NAME}-${ENVIRONMENT}-secops-bus"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-rollback"
```

For prod:

```bash
export ENVIRONMENT="prod"
export EVENT_BUS_NAME="${CLOUD_NAME}-${ENVIRONMENT}-secops-bus"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-rollback"
```

---

## Sign In via AWS Access Portal

Use the AWS access portal URL configured for IAM Identity Center in the bootstrap/control-plane account.

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

If you want to run the rollback test from a local terminal, configure an AWS CLI SSO profile.

```bash
aws configure sso --use-device-code
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
aws sts get-caller-identity --profile "${PROFILE_NAME}"
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

Before running these commands, make sure your AWS CLI is authenticated to the target environment using the `SecOps-Operator` SSO profile or another authorized role.

### Check Current Security Groups

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --profile "${PROFILE_NAME}"
```

Before rollback, the instance should be attached to the quarantine security group.

After rollback, the instance should be restored to its original security group or groups.

---

### Check Instance Tags

```bash
aws ec2 describe-tags \
  --region "${AWS_REGION}" \
  --filters "Name=resource-id,Values=${INSTANCE_ID}" \
  --profile "${PROFILE_NAME}"
```

Use this to confirm whether isolation and rollback metadata is present or updated.

---

### Check Lambda Logs

This may require a broader analyst, engineer, administrator, or CI/CD role because the `SecOps-Operator` permission set is intentionally limited.

```bash
aws logs tail "/aws/lambda/${FUNCTION_NAME}" \
  --region "${AWS_REGION}" \
  --since 15m
```

---

# EC2 ROLLBACK LAMBDA TESTS

## Test 1 - Manual Rollback Event from EventBridge Console

### Purpose

Validate that a user assigned to the environment-specific `SecOps-Operator` role can submit a rollback event through the AWS Console.

This test is performed entirely from the AWS Console.

### Steps

Sign in through the AWS access portal, open the target AWS account using the correct `SecOps-Operator` role, and navigate to:

```text
Amazon EventBridge -> Event buses -> <event-bus-name> -> Send events
```

Use:

| Field | Value |
|------|-------|
| Event source | `custom.rollback` |
| Detail type | `Ec2Rollback` |
| Event bus | `<cloud_name>-<environment>-secops-bus` |

Use this JSON in the **Detail** field:

```json
{
  "instance_id": "<QUARANTINED-EC2-INSTANCE-ID>",
  "approved_by": "secops@company.com",
  "ticket_id": "t-abc123",
  "reason": "Test rollback"
}
```

### Expected Outcome

- EventBridge shows `Event(s) sent successfully.`
- Rollback Lambda executes successfully.
- Instance rolls back from the quarantine security group to its original security group or groups.
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

Send the rollback event:

```bash
aws events put-events \
  --region "${AWS_REGION}" \
  --entries "[
    {
      \"Source\": \"custom.rollback\",
      \"DetailType\": \"Ec2Rollback\",
      \"Detail\": \"{\\\"instance_id\\\":\\\"${INSTANCE_ID}\\\",\\\"approved_by\\\":\\\"${APPROVED_BY}\\\",\\\"ticket_id\\\":\\\"${TICKET_ID}\\\",\\\"reason\\\":\\\"${ROLLBACK_REASON}\\\"}\",
      \"EventBusName\": \"${EVENT_BUS_NAME}\"
    }
  ]" \
  --profile "${PROFILE_NAME}"
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
- SNS notification is sent to the configured SecOps SNS topic.
- No errors appear in the Lambda function CloudWatch log group.

---

## Test 3 - Verify Rollback Completion

### Purpose

Confirm that the EC2 instance was restored to its pre-isolation security group configuration.

### Check Security Groups

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'Reservations[0].Instances[0].SecurityGroups' \
  --profile "${PROFILE_NAME}"
```

### Expected Outcome

- The instance is no longer attached only to the quarantine security group.
- The original security group or groups are restored.
- No unexpected security groups are attached.

---

## Test 4 - Invalid Instance ID

### Purpose

Validate that the rollback workflow handles an invalid EC2 instance ID without modifying infrastructure.

### Manual Event from AWS CLI

```bash
aws events put-events \
  --region "${AWS_REGION}" \
  --entries "[
    {
      \"Source\": \"custom.rollback\",
      \"DetailType\": \"Ec2Rollback\",
      \"Detail\": \"{\\\"instance_id\\\":\\\"i-00000000000000000\\\",\\\"approved_by\\\":\\\"${APPROVED_BY}\\\",\\\"ticket_id\\\":\\\"${TICKET_ID}\\\",\\\"reason\\\":\\\"Invalid instance test\\\"}\",
      \"EventBusName\": \"${EVENT_BUS_NAME}\"
    }
  ]" \
  --profile "${PROFILE_NAME}"
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

This event omits the required `instance_id` field.

```bash
aws events put-events \
  --region "${AWS_REGION}" \
  --entries "[
    {
      \"Source\": \"custom.rollback\",
      \"DetailType\": \"Ec2Rollback\",
      \"Detail\": \"{\\\"approved_by\\\":\\\"${APPROVED_BY}\\\",\\\"ticket_id\\\":\\\"${TICKET_ID}\\\",\\\"reason\\\":\\\"Missing instance_id test\\\"}\",
      \"EventBusName\": \"${EVENT_BUS_NAME}\"
    }
  ]" \
  --profile "${PROFILE_NAME}"
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

## Test 6 - Wrong Event Source

### Purpose

Validate that events with an incorrect source do not trigger the rollback Lambda.

This test depends on the EventBridge rule pattern.

### Manual Event from AWS CLI

```bash
aws events put-events \
  --region "${AWS_REGION}" \
  --entries "[
    {
      \"Source\": \"custom.invalid\",
      \"DetailType\": \"Ec2Rollback\",
      \"Detail\": \"{\\\"instance_id\\\":\\\"${INSTANCE_ID}\\\",\\\"approved_by\\\":\\\"${APPROVED_BY}\\\",\\\"ticket_id\\\":\\\"${TICKET_ID}\\\",\\\"reason\\\":\\\"Wrong source test\\\"}\",
      \"EventBusName\": \"${EVENT_BUS_NAME}\"
    }
  ]" \
  --profile "${PROFILE_NAME}"
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
- Rollback Lambda should not execute if the rule only matches `custom.rollback`.
- No EC2 instances are modified.
- No rollback SNS notification is sent.

---

## Test 7 - Wrong Detail Type

### Purpose

Validate that events with an incorrect detail type do not trigger the rollback Lambda.

This test depends on the EventBridge rule pattern.

### Manual Event from AWS CLI

```bash
aws events put-events \
  --region "${AWS_REGION}" \
  --entries "[
    {
      \"Source\": \"custom.rollback\",
      \"DetailType\": \"InvalidRollbackType\",
      \"Detail\": \"{\\\"instance_id\\\":\\\"${INSTANCE_ID}\\\",\\\"approved_by\\\":\\\"${APPROVED_BY}\\\",\\\"ticket_id\\\":\\\"${TICKET_ID}\\\",\\\"reason\\\":\\\"Wrong detail type test\\\"}\",
      \"EventBusName\": \"${EVENT_BUS_NAME}\"
    }
  ]" \
  --profile "${PROFILE_NAME}"
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
- Rollback Lambda should not execute if the rule only matches `Ec2Rollback`.
- No EC2 instances are modified.
- No rollback SNS notification is sent.

---

# Post-Test Validation

After running a successful rollback test, confirm:

- The instance is no longer isolated.
- Original security groups are restored.
- SNS notification was received.
- Lambda logs show successful rollback.
- The rollback event was submitted by the expected Identity Center role.
- The test account and environment match the intended target.

---

# Troubleshooting

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

---

## Event is accepted but Lambda does not run

Check:

- The EventBridge rule exists.
- The rule pattern matches the event source and detail type.
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

They confirm that:

- Rollback is performed through a controlled EventBridge workflow.
- IAM Identity Center users assigned to `SecOps-Operator` can submit rollback events.
- The rollback Lambda restores original EC2 security groups.
- Invalid or malformed events are handled safely.
- Incorrect event sources or detail types do not trigger rollback.
- The workflow supports the broader multi-account, least-privilege security model.