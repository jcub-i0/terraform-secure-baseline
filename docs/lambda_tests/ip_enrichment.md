# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

## How to Use
* Replace '<YOUR-ACCOUNT-ID>' with your AWS account ID
* Replace '<REAL-SECURITY-HUB-FINDING-ID>' with a valid Security Hub finding ID if you want to test Security Hub writeback
* Replace '<REAL-PRODUCT-ARN>' with the ProductArn associated with that finding
* Ensure the 'THREAT_INTEL_SECRET_ARN' secret exists and contains a valid AbuseIPDB API key
* Confirm expected outcome based on the **Expected Outcome** section of each test

---

# IP ENRICHMENT LAMBDA TESTS

## PREREQUISITES
* Lambda environment variables are configured:
    * 'SNS_TOPIC_ARN'
    * 'THREAT_INTEL_SECRET_ARN'
    * 'WRITE_TO_SECURITYHUB'
* Lambda IAM role has permission to:
    * Read the threat intel secret from Secrets Manager
    * Publish to the configured SNS topic
    * Call 'securityhub:BatchUpdateFindings'
* If 'WRITE_TO_SECURITYHUB=true', use a real Security Hub finding ID and ProductArn for full writeback validation

---

## TEST 1 -- HIGH FINDING WITH PUBLIC IPV4 ADDRESSES

### Expected Outcome
* Lambda executes
* Public IPs extracted from finding
* IP reputation data retrieved from AbuseIPDB
* SNS notification sent to configured SNS topic
* If valid finding identifiers suppleid and 'WRITE_TO_SECURITYHUB=true', note written back to Security Hub finding
* No errors in logs

### Event JSON
```json
{
  "version": "0",
  "id": "test-event-1",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "<YOUR-ACCOUNT-ID>",
  "time": "2026-03-02T00:00:00Z",
  "region": "us-east-1",
  "detail": {
    "findings": [
      {
        "Id": "<REAL-SECURITY-HUB-FINDING-ID>",
        "ProductArn": "<REAL-PRODUCT-ARN>",
        "Severity": {
          "Label": "HIGH"
        },
        "Workflow": {
          "Status": "NEW"
        },
        "Network": {
          "SourceIpV4": "103.37.6.88"
        },
        "ProductFields": {
          "someField": "connection from 1.1.1.1 observed"
        }
      }
    ]
  }
}