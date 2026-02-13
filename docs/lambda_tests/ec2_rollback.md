# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace "<INSTANCE_ID> with the ID of the EC2 instance in the Quarantine Security Group
* Run the test from a terminal connected to your AWS account
* Confirm expected outcome based on 'Expected Outcome' section of each test

## EC2 ROLLBACK LAMBDA TESTS

### PREQUESITES:
You must assume the 'SecOps-Operator' IAM role in order to trigger the EC2 Rollback Lambda function. In the commands below, replace '<ACCOUNT_ID>' with your AWS account ID.

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
> To 'unassume' this role / go back to the principle you were using before, run:
> ```bash
> unset AWS_ACCESS_KEY_ID
> unset AWS_SECRET_ACCESS_KEY
> unset AWS_SESSION_TOKEN
> ```

### TEST 1 -- MANUAL ROLLBACK EVENT FROM AWS CLI
#### Expected Outcome:
* Lambda executes
* Instance rollbacks from the Quarantine SG to its original SG
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs
#### Manual Event from AWS CLI:
```json
$ aws events put-events --entries '[
  {
    "Source": "custom.rollback",
    "DetailType": "Ec2Rollback",
    "Detail": "{\"instance_id\":\"<INSTANCE_ID>\",\"approved_by\":\"secops@company.com\", \"ticket_id\":\"t-abc123\", \"reason\":\"Test rollback\"}",
    "EventBusName": "security-operations-bus"
  }
]'
```