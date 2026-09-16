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

The Lambda does not use the top-level EventBridge `source` or `detail-type` fields as authorization gates. They are retained in the direct-invocation payloads to mirror the production event shape; the Lambda's own finding gates are evaluated from `detail.findings`.

---

## Identity and Access Context

This project uses a centralized IAM Identity Center model.

For this test document:

- **EC2 Isolation** is automated and triggered by qualifying GuardDuty findings imported through Security Hub and matched by the dedicated EventBridge rule.
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
- Security Hub is enabled for the target account and receives GuardDuty findings.
- The dedicated EC2-isolation EventBridge rule is deployed.
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
export ISOLATION_RULE_NAME="${CLOUD_NAME}-${ENVIRONMENT}-securityhub-ec2-high-critical"
export GUARDDUTY_PRODUCT_ARN="arn:aws:securityhub:${AWS_REGION}::product/aws/guardduty"
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

### Confirm Deployed Lambda Configuration

Before running the behavior tests, inspect the deployed environment variables:

```bash
aws lambda get-function-configuration \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --query 'Environment.Variables.{QUARANTINE_SG_ID:QUARANTINE_SG_ID,SNS_TOPIC_ARN:SNS_TOPIC_ARN,AUTO_ISOLATION_SEVERITIES:AUTO_ISOLATION_SEVERITIES}' \
  --output json
```

Expected:

- `QUARANTINE_SG_ID` is populated.
- `SNS_TOPIC_ARN` is populated for the normal baseline deployment.
- `AUTO_ISOLATION_SEVERITIES` reflects the Terraform-configured severity set.

The Lambda itself falls back to `CRITICAL` if `AUTO_ISOLATION_SEVERITIES` is absent or empty. Tests that specifically expect `HIGH` to be skipped assume `HIGH` is **not** present in the deployed severity set.

### Confirm Dedicated EventBridge Rule

Inspect the EC2-isolation rule:

```bash
aws events describe-rule \
  --region "${AWS_REGION}" \
  --name "${ISOLATION_RULE_NAME}" \
  --query EventPattern \
  --output text | jq .
```

The deployed pattern should require all of the following under `detail.findings`:

```text
ProductArn   = arn:aws:securityhub:<region>::product/aws/guardduty
Severity     = HIGH or CRITICAL
Resources    = AwsEc2Instance
Workflow     = NEW
RecordState  = ACTIVE
```

The EC2-isolation rule is distinct from the broader `${CLOUD_NAME}-${ENVIRONMENT}-securityhub-high-critical` rule used by the IP-enrichment/security-notification path.

Confirm the dedicated rule targets the EC2-isolation Lambda and uses the workflow DLQ/retry policy:

```bash
aws events list-targets-by-rule \
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
> If this returns nothing, that's fine; but you do not want to see unexpected errors.

### Interpret Direct-Invocation Results

`aws lambda invoke` prints invocation metadata to the terminal and writes the handler return value to `response.json`.

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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-critical-non-guardduty-ec2",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-critical-non-guardduty-ec2-001",
        "Title": "Manual test CRITICAL non-GuardDuty EC2 finding",
        "Description": "Manual test event used to validate the GuardDuty product gate.",
        "ProductArn": "arn:aws:securityhub:${AWS_REGION}::product/aws/inspector",
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
aws lambda invoke \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-critical-missing-record-state",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "${ACCOUNT_ID}",
  "time": "2026-01-22T03:45:49Z",
  "region": "${AWS_REGION}",
  "resources": [],
  "detail": {
    "findings": [
      {
        "Id": "test-finding-critical-missing-record-state-001",
        "Title": "Manual test CRITICAL GuardDuty EC2 finding without RecordState",
        "Description": "Manual test event used to validate fail-closed RecordState handling.",
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
        "ProductArn": "${GUARDDUTY_PRODUCT_ARN}",
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
| `ProductArn` is missing or is not the GuardDuty Security Hub product ARN | Finding is skipped before instance evaluation |
| `IsolationAllowed` is missing or `false` | Invocation succeeds; instance is skipped |
| `RecordState` is missing | Finding is skipped before instance evaluation |
| `RecordState` is `ARCHIVED` | Finding is skipped |
| Workflow status is not `NEW` | Finding is skipped |
| Instance state is not `running` or `stopped` | Instance is skipped |
| Instance already has `Isolated=true` or only the quarantine security group | Instance is skipped without another snapshot |
| The same instance appears more than once in one invocation | It is evaluated once |
| Snapshot creation returns an error | Isolation fails closed and security groups are unchanged |

Run snapshot-failure testing only in an isolated development test using mocks or a deliberately scoped test role. Do not remove production permissions to induce this failure.

Before continuing, restore `IsolationAllowed=true` on the approved development test instance.

---

## Test 7 - Multi-Account Environment Naming and Account-Boundary Validation

### Purpose

Validate that the same Lambda naming and eligibility model works across workload accounts without accidentally reusing another environment's account or instance identifiers.

For `staging` or `prod`, use credentials for the target account and recompute all account-specific values. Changing only `ENVIRONMENT` is not sufficient.

### Example

```bash
export ENVIRONMENT="staging"
export FUNCTION_NAME="${CLOUD_NAME}-${ENVIRONMENT}-ec2-isolation"
export ISOLATION_RULE_NAME="${CLOUD_NAME}-${ENVIRONMENT}-securityhub-ec2-high-critical"

export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export INSTANCE_ID="<STAGING-EC2-INSTANCE-ID>"
export INSTANCE_ARN="arn:aws:ec2:${AWS_REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"

aws lambda get-function \
  --region "${AWS_REGION}" \
  --function-name "${FUNCTION_NAME}" \
  --query 'Configuration.[FunctionName,FunctionArn,State]' \
  --output table
```

If an approved direct-invocation test is required, reuse the Test 2 payload only after confirming the target account, target instance, and `IsolationAllowed` policy for that environment.

### Expected Outcome

- The environment-specific Lambda resolves in the active AWS account.
- The active AWS account ID matches the account encoded in `INSTANCE_ARN`.
- The same Lambda-side eligibility checks apply in each workload account.
- An instance with `IsolationAllowed` missing or not equal to `true` is skipped even for an otherwise eligible GuardDuty finding.
- Only resources in the active target account are evaluated.

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

The deployed EC2-isolation EventBridge rule only forwards findings that already match:

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

- `ProductArn` exactly matches `arn:aws:securityhub:${AWS_REGION}::product/aws/guardduty`.
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

They confirm that:

- Automatic EC2 isolation is restricted to GuardDuty findings imported through Security Hub.
- CRITICAL GuardDuty EC2 findings isolate only explicitly authorized, eligible instances when `CRITICAL` is configured.
- HIGH GuardDuty findings are skipped unless the configured severity set includes `HIGH`.
- Non-GuardDuty, non-EC2, inactive, missing-state, non-NEW, ineligible, duplicate, and already-isolated targets are skipped.
- Snapshot failure prevents quarantine.
- Environment-specific naming and authorization work across accounts.
- Isolation preserves the controlled rollback workflow.
- The function fits into the broader Identity Center, EventBridge, Security Hub, and multi-account architecture.