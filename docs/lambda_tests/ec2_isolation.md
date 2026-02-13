# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

How to use:
* Replace "<YOUR-ACCOUNT-ID>" with your AWS account ID
* Replace "
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
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE-TO-ISOLATE>"
          }
        ]
      }
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
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "CRITICAL"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE>"
          }
        ]
      }
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
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2SecurityGroup",
            "Id": "<ARN-OF-SECURITY-GROUP>"
          }
        ]
      }
    ]
  }
}
```

### TEST 4 -- MEDIUM EC2 FINDING
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
      {
        "Id": "test-finding-001",
        "Severity": {
          "Label": "MEDIUM"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Resources": [
          {
            "Type": "AwsEc2Instance",
            "Id": "<ARN-OF-EC2-INSTANCE>"
          }
        ]
      }
    ]
  }
}
```