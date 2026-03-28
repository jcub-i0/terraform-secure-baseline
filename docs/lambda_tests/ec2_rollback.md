# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace `<INSTANCE_ID>` with the ID of the EC2 instance in the Quarantine Security Group
* Replace `<ACCOUNT_ID>` with your AWS account ID
* Authenticate using IAM Identity Center (SSO)
* Confirm expected outcome based on the **Expected Outcome** section of each test

---

## EC2 ROLLBACK LAMBDA TESTS

### PREREQUISITES:

#### IAM Identity Center Access is Required

The EC2 Rollback workflow is now tested through **AWS IAM Identity Center**, not by assuming the legacy `SecOps-Operator` IAM role.

To test this Lambda function, the user performing the test must:

- Exist as a user in IAM Identity Center
- Be assigned to the `SecOps-Operators` group
- Sign into the AWS access portal
- Access the AWS accoutn using the `SecOps-Operator` permission set

The `SecOps-Operator` permission set allows:

- `events:ListEventBuses`
- `events:DescribeEventBus`
- `events:PutEvents` on the `security-operations-bus`

This is the minimum access required to manually inject rollback events onto the SecOps event bus.

---

### SIGN IN WITH IAM IDENTITY CENTER

1. Sign into the AWS access portal:

```text
https://<your-org>.awsapps.com/start
```

2. Open the AWS account using `SecOps-Operator`

3. Confirm you are in the correct role by running:

```bash
aws sts get-caller-identity --profile <profile-name>
```

Example:

```bash
aws sts get-caller-identity --profile operator
```

Expected Result:

- The returned ARN should reference an assumed IAM Identity Center role similar to:

```text
arn:aws:sts::<AWS_ACCOUNT_ID>:assumed-role/AWSReservedSSO_SecOps-Operator_<random>/<username>
```

> `<profile-name>` refers to your local AWS CLI profile configured via `aws configure sso`.

---

### CONFIGURE LOCAL AWS CLI SSO PROFILE (IF NEEDED)

If you have not already configured a local CLI profile for the `SecOps-Operator` permission set, run:

```bash
aws configure sso
```

Use the profile to select:

- The AWS account hosting this environment
- The `SecOps-Operator` permission set

Example local profile name:

`operator`

Then authenticate:

```bash
aws sso login --profile operator
```

---

### TEST 1 - MANUAL ROLLBACK EVENT FROM AWS CLI

#### Expected Outcome

- Lambda executes successfully
- Instance rolls back from the Quarantine Security Group to its original Security Group(s)
- SNS notification is sent to the configured SecOps SNS topic
- No errors appear in the Lambda function's CloudWatch log group

#### Manual Event from AWS CLI

Run the following from a terminal authenticated with the `SecOps-Operator` permission set:

```bash
aws events put-events --entries '[
  {
    "Source": "custom.rollback",
    "DetailType": "Ec2Rollback",
    "Detail": "{\"instance_id\":\"<INSTANCE_ID>\",\"approved_by\":\"secops@company.com\",\"ticket_id\":\"t-abc123\",\"reason\":\"Test rollback\"}",
    "EventBusName": "security-operations-bus"
  }
]' --profile operator
```

**Example**

```bash
aws events put-events --entries '[
  {
    "Source": "custom.rollback",
    "DetailType": "Ec2Rollback",
    "Detail": "{\"instance_id\":\"i-007c460b960eede84\",\"approved_by\":\"secops@company.com\",\"ticket_id\":\"t-abc123\",\"reason\":\"Test rollback\"}",
    "EventBusName": "security-operations-bus"
  }
]' --profile operator
```

---