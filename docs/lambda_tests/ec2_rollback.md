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

#### QUARANTINED EC2 INSTANCE

You must have an EC2 instance that exists in the Quarantine Security Group.

#### ACCESS REQUIREMENTS

The EC2 Rollback workflow is tested through **AWS IAM Identity Center** and the `SecOps-Operator` permission set.

To test this Lambda function, the user performing the test must:

- Exist as a user in IAM Identity Center
- Be assigned to the `SecOps-Operators` group
- Have access to the AWS account using the `SecOps-Operator` permission set

The `SecOps-Operator` permission set allows:

- `events:ListEventBuses`
- `events:DescribeEventBus`
- `events:PutEvents` on the `security-operations-bus`

This is the minimum access required to manually inject rollback events onto the SecOps event bus.

---

### SIGN IN VIA THE AWS ACCESS PORTAL (FOR TEST 1)

Use the exact AWS access portal URL configured for your IAM Identity Center instance.

Examples of valid access portal URL formats include:

- `https://d-xxxxxxxxxx.awsapps.com/start`
- `https://ssoins-xxxxxxxxxxxxxxxx.portal.us-east-1.app.aws`
- A custom AWS access portal URL, if configured

For this environment, use one of the working access portal URLs shown under `AWS access portal URLs` in the IAM Identity Center console's `Dashboard` page.

> Example:
> https://ssoins-72238b162a9546df.portal.us-east-1.app.aws

Sign in using a user assigned to the `SecOps-Operators` group, then open the AWS account using `SecOps-Operator`

#### Confirm the correct role in the browser

After opening the AWS account, confirm the active role in the top-right of the console header.

Expected role name pattern:

`SecOps-Operator/<username>`

or:

`AWSReservedSSO_SecOps-Operator_<random>/<username>`

---

### CONFIGURE LOCAL AWS CLI SSO PROFILE (FOR TEST 2)

If you want to run the rollback test from a local terminal, first configure an AWS CLI SSO profile:

```bash
aws configure sso --use-device-code
```

For the following prompts, enter the following:

```bash
SSO session name (Recommended): test
SSO start URL [None]: One of the AWS access portal URLs from the IAM Identity Center console (Dashboard page)
SSO region [None]: us-east-1
SSO registration scopes [sso:account:access]: sso:account:access
```

Note the following output:

```bash
Attempting to automatically open the SSO authorization page in your default browser.
If the browser does not open or you wish to use a different device to authorize this request, open the following URL:

https://d-xxxxxxxxxx.awsapps.com/start/#/device

Then enter the code:

XXXX-XXXX
```

If you are unable to authenticate into your SSO user from the automatically-opened default browser, try a different browser, using the URL and code provided in the output above.

To validate your AWS identity, run:

```bash
aws sts get-caller-identity --profile <profile-name>
```

Expected output:

```json
{
    "UserId": "<id-string>:<sso-user>",
    "Account": "<account-id>",
    "Arn": "arn:aws:sts::<account-id>:assumed-role/AWSReservedSSO_SecOps-Operator_<random-string>/<sso-user>"
}
```

---

### TEST 1 - MANUAL ROLLBACK EVENT FROM EVENTBRIDGE CONSOLE

This test is performed entirely from the AWS console (no CLI required).

Sign in through the AWS access portal, open the AWS account using `SecOps-Operator`, and navigate to:

`Amazon EventBridge` ➔ `Event buses` ➔ `security-operations-bus` ➔ `Send events`

Use:

- **Event source**: `custom.rollback`
- **Detail type**: `Ec2Rollback`

And use this JSON in the **Detail** field:

```json
{
  "instance_id": "<INSTANCE_ID>",
  "approved_by": "secops@company.com",
  "ticket_id": "t-abc123",
  "reason": "Test rollback"
}
```

Expected outcome:

- `Event(s) sent successfully.` green banner at top of EventBridge UI
- Lambda executes successfully
- Instance rolls back from the Quarantine Security Group to its original Security Group(s)
- SNS notification is sent to the configured SecOps SNS topic
- No errors appear in the Lambda function's CloudWatch log group

---

### TEST 2 - MANUAL ROLLBACK EVENT FROM AWS CLI

This test requires a locally-configured AWS CLI SSO profile.

#### Manual Event from AWS CLI

Run the following from a terminal authenticated with the `SecOps-Operator` SSO profile:

```bash
aws events put-events --entries '[
  {
    "Source": "custom.rollback",
    "DetailType": "Ec2Rollback",
    "Detail": "{\"instance_id\":\"<INSTANCE_ID>\",\"approved_by\":\"secops@company.com\",\"ticket_id\":\"t-abc123\",\"reason\":\"Test rollback\"}",
    "EventBusName": "security-operations-bus"
  }
]' --profile <profile-name>
```

Expected output:

```bash
{
    "FailedEntryCount": 0,
    "Entries": [
        {
            "EventId": "<id-string>"
        }
    ]
}
```

#### Expected Outcome

- Lambda executes successfully
- Instance rolls back from the Quarantine Security Group to its original Security Group(s)
- SNS notification is sent to the configured SecOps SNS topic
- No errors appear in the Lambda function's CloudWatch log group