# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace `<INSTANCE_ID>` with the ID of the EC2 instance in the Quarantine Security Group
* Replace `<ACCOUNT_ID>` with your AWS account ID
* Run the test from a terminal authenticated to your AWS account
* Confirm expected outcome based on 'Expected Outcome' section of each test

## EC2 ROLLBACK LAMBDA TESTS

### PREREQUISITES:

#### Configure SecOps-Operator Trust (Required)
Before testing this Lambda function, you must configure which IAM principals in your AWS account are allowed to assume the SecOps-Operator role.

This is done by updating the `secops_operator_trusted_principal_arns` variable.

Add the ARN of the IAM role that administrators in your account will use to access this environment.

**Example:**

If your organization uses an IAM role named `client-admin-role`, update the variable by running the following:


```bash
export TF_VAR_secops_operator_trusted_principal_arns='["arn:aws:iam::<ACCOUNT_ID>:role/client-admin-role"]'
```

To determine the ARN of the IAM role you are currently using, run the following:
```bash
aws sts get-caller-identity
```
Example output:
```json
{
  "Arn": "arn:aws:sts::123456789012:assumed-role/client-admin-role/session-name"
}
```
The corresponding IAM role ARN is:
```text
arn:aws:iam::123456789012:role/client-admin-role
```

##### Apply the Configuration

After updating the `secops_operator_trusted_principal_arns` variable, deploy the environment from the same terminal used to set the `secops_operator_trusted_principal_arns` variable by running the following:
```bash
terraform apply
```
> Once the infrastructure is deployed, any IAM role whose ARN is included in `secops_operator_trusted_principal_arns` will be able to assume the `SecOps-Operator` role to trigger rollback operations.

#### Assume the SecOps-Operator Role

> The following commands require 'jq' to be installed on your machine.
> Install 'jq' on Debian:
> ```bash
> sudo apt-get install -y jq
> ```

Run the following to assume the 'SecOps-Operator' IAM role:
```bash
export AWS_ACCOUNT_ID="<ACCOUNT_ID>"
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/SecOps-Operator"
SESSION_NAME="secops-$(date +%Y%m%d-%H%M%S)"
CREDS=$(aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name "$SESSION_NAME")
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')
aws sts get-caller-identity
```
You should see '/SecOps-Operator/*' in the last 'Arn' line of the output.
> To 'unassume' this role / go back to the principal you were using before, run:
> ```bash
> unset AWS_ACCESS_KEY_ID
> unset AWS_SECRET_ACCESS_KEY
> unset AWS_SESSION_TOKEN
> ```

### TEST 1 -- MANUAL ROLLBACK EVENT FROM AWS CLI
#### Expected Outcome:
* Lambda executes
* Instance rolls back from the Quarantine SG to its original SG
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs
#### Manual Event from AWS CLI:
Run the following:
```bash
aws events put-events --entries '[
  {
    "Source": "custom.rollback",
    "DetailType": "Ec2Rollback",
    "Detail": "{\"instance_id\":\"<INSTANCE_ID>\",\"approved_by\":\"secops@company.com\", \"ticket_id\":\"t-abc123\", \"reason\":\"Test rollback\"}",
    "EventBusName": "security-operations-bus"
  }
]'
```