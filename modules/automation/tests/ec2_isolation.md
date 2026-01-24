# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace "<YOUR-ACCOUNT-ID>" with your AWS account ID
* From AWS Security Hub, copy a real Security Hub finding JSON in accordance with the title of the test (i.e. HIGH EC2 SECURITY HUB FINDING)
* Replace "<SECURITY-HUB-FINDING>" with the finding JSON you copied
* Run the test
* Confirm Expected Outcome based on 'Expected Outcome' section of each test

## EC2 ISOLATION LAMBDA TESTS

### TEST 1 -- HIGH EC2 SECURITY HUB FINDING
#### Expected Outcome:
* Lambda executes
* Instance isolated in Quarantine Security Group
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs
#### Event JSON
```json
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
      <SECURITY-HUB-FINDING-JSON>
    ]
  }
}
```

### TEST 2 -- CRITICAL EC2 SECURITY HUB FINDING
#### Expected Outcome:
* Lambda executes
* Instance isolated in Quarantine Security Group
* Tags applied to instance
* SNS notification sent to configured SNS topic
* No errors in logs
#### Event JSON
```json
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
      <SECURITY-HUB-FINDING-JSON>
    ]
  }
}
```

### TEST 3 -- HIGH NON-EC2 FINDING (i.e. S3, Config, etc.)
#### Expected Outcome:
* Lambda executes
* No EC2 instances modified
* No SNS message sent
* No Security Groups modified
* No errors in logs
#### Event JSON
```json
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
      <SECURITY-HUB-FINDING-JSON>
    ]
  }
}
```

### TEST 4 -- MEDIUM EC2 FINDING (i.e. S3, Config, etc.)
#### Expected Outcome:
* Lambda executes
* No EC2 instances modified
* No SNS message sent
* No Security Groups modified
* No errors in logs
#### Event JSON
```json
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
      <SECURITY-HUB-FINDING-JSON>
    ]
  }
}
```