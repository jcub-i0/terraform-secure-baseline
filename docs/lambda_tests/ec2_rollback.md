# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace "<INSTANCE_ID> with the ID of the EC2 instance in the Quarantine Security Group
* Run the test from a terminal connected to your AWS account
* Confirm expected outcome based on 'Expected Outcome' section of each test

## EC2 ROLLBACK LAMBDA TESTS

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