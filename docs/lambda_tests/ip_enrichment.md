# LAMBDA FUNCTION TESTS

Purpose:
Manual test events used to validate Lambda automation behavior before and after changes.

### How to Use
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

### TEST 1 -- CRITICAL FINDING WITH PUBLIC IPV4 ADDRESSES

#### Expected Outcome
* Lambda executes
* Public IPs extracted from finding
* IP reputation data retrieved from AbuseIPDB
* SNS notification sent to configured SNS topic
* If valid finding identifiers supplied and 'WRITE_TO_SECURITYHUB=true', note written back to Security Hub finding
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name ip-enrichment \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
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
        "Title": "AWS Config should be enabled and use the service-linked role for resource recording",
        "AwsAccountId": "<YOUR-ACCOUNT-ID>",
        "Region": "us-east-1",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "<REAL-SECURITY-HUB-FINDING-ID>",
        "ProductArn": "<REAL-PRODUCT-ARN>",
        "Severity": { "Label": "CRITICAL" },
        "Workflow": { "Status": "NEW" },
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
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"statusCode": 200, "body": "{\"message\": \"Processing complete\", \"resultCount\": 2}"}
```

##### Confirm Write to Security Hub Finding
Run the following from the CLI:
```bash
aws securityhub get-findings \
  --filters '{
    "Id": [
      {
        "Value": "<REAL-SECURITY-HUB-FINDING-ID>",
        "Comparison": "EQUALS"
      }
    ]
  }' \
  --query 'Findings[].Note'
```
If the "Note" JSON block is returned ("Text", "UpdatedBy", and "UpdatedAt" fields), the IP Enrichment Lambda successfully wrote to the Security Hub finding ✅
> NOTE: You can also confirm this via the AWS console by navigating to the Security Hub module, opening the referenced Security Hub finding, and checking the 'History' tab for 'Note Added'

Repeat this test for ALL other finding serverities, replacing "CRITICAL" in *"Severity": { "Label": "CRITICAL" }* with "HIGH", "MEDIUM", and "LOW"


### TEST 2 -- FINDING WITH PRIVATE/NON-PUBLIC IP ONLY

#### Expected Outcome
* Lambda executes
* No IP addresses are enriched
* No SNS message is sent
* No Security Hub writeback performed
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name ip-enrichment \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
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
        "Title": "AWS Config should be enabled and use the service-linked role for resource recording",
        "AwsAccountId": "<YOUR-ACCOUNT-ID>",
        "Region": "us-east-1",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "<REAL-SECURITY-HUB-FINDING-ID>",
        "ProductArn": "<REAL-PRODUCT-ARN>",
        "Severity": { "Label": "CRITICAL" },
        "Workflow": { "Status": "NEW" },
        "Network": {
          "SourceIpV4": "10.0.1.15"
        },
        "ProductFields": {
          "someField": "internal service connection from 172.16.5.10 observed"
        }
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"statusCode": 200, "body": "{\"message\": \"No IPs enriched\", \"resultCount\": 0}"}
```

##### Confirm Absense of Write to Security Hub Finding

Run the following from the CLI:
```bash
aws securityhub get-findings \
  --filters '{
    "Id": [
      {
        "Value": "<REAL-SECURITY-HUB-FINDING-ID>",
        "Comparison": "EQUALS"
      }
    ]
  }' \
  --query 'Findings[].Note'
```
Expected Outcome:
```json
[]
```
> NOTE: You can also confirm this via the AWS console by navigating to the Security Hub module, opening the referenced Security Hub finding, and checking the 'History' tab for 'Note Added'

### TEST 3 -- HIGH FINDING WITH NO IP DATA
#### Expected Outcome
* Lambda executes
* No IP addresses are enriched
* No SNS message is sent
* No Security Hub writeback performed
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name ip-enrichment \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
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
        "Title": "AWS Config should be enabled and use the service-linked role for resource recording",
        "AwsAccountId": "<YOUR-ACCOUNT-ID>",
        "Region": "us-east-1",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "<REAL-SECURITY-HUB-FINDING-ID>",
        "ProductArn": "<REAL-PRODUCT-ARN>",
        "Severity": { "Label": "HIGH" },
        "Workflow": { "Status": "NEW" },
        }
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"statusCode": 200, "body": "{\"message\": \"No IPs enriched\", \"resultCount\": 0}"}
```

##### Confirm Absense of Write to Security Hub Finding

Run the following from the CLI:
```bash
aws securityhub get-findings \
  --filters '{
    "Id": [
      {
        "Value": "<REAL-SECURITY-HUB-FINDING-ID>",
        "Comparison": "EQUALS"
      }
    ]
  }' \
  --query 'Findings[].Note'
```
Expected Outcome:
```json
[]
```
> NOTE: You can also confirm this via the AWS console by navigating to the Security Hub module, opening the referenced Security Hub finding, and checking the 'History' tab for 'Note Added'

### TEST 4 -- HIGH FINDING WITH INVALID SECURITY HUB IDENTIFIERS
#### Expected Outcome
* Lambda executes
* No IP addresses are enriched
* No SNS message is sent
* No Security Hub writeback performed
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name ip-enrichment \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
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
        "Title": "AWS Config should be enabled and use the service-linked role for resource recording",
        "AwsAccountId": "<YOUR-ACCOUNT-ID>",
        "Region": "us-east-1",
        "ProductName": "Security Hub",
        "Resources": [
          {
            "Id": "arn:aws:s3:::example-bucket",
            "Type": "AwsS3Bucket"
          }
        ],
        "Id": "arn:aws:securityhub:us-east-1:072288671186:security-control/Config.1/finding/86df343a-179d-4a02-9f65-dac5c417ab75",
        "ProductArn": "arn:aws:securityhub:us-east-1::product/aws/securityhub",
        "Severity": { "Label": "CRITICAL" },
        "Workflow": { "Status": "NEW" },
        "Network": {
          "SourceIpV4": "103.37.6.88"
        }
      }
    ]
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"statusCode": 200, "body": "{\"message\": \"No IPs enriched\", \"resultCount\": 0}"}
```

##### Confirm Absense of Write to Security Hub Finding

Run the following from the CLI:
```bash
aws securityhub get-findings \
  --filters '{
    "Id": [
      {
        "Value": "<REAL-SECURITY-HUB-FINDING-ID>",
        "Comparison": "EQUALS"
      }
    ]
  }' \
  --query 'Findings[].Note'
```
Expected Outcome:
```json
[]
```
> NOTE: You can also confirm this via the AWS console by navigating to the Security Hub module, opening the referenced Security Hub finding, and checking the 'History' tab for 'Note Added'

### TEST 5 -- EMPTY FINDINGS ARRAY

#### Expected Outcome
* Lambda executes
* Lambda returns a response indicating no findings were present
* No SNS message is sent
* No Security Hub writeback performed
* No errors in logs

#### Manual Event via AWS CLI:
Run the following from the CLI:
```bash
export AWS_PAGER="" # Prevents AWS CLI from launching 'less'
aws lambda invoke \
  --function-name ip-enrichment \
  --cli-binary-format raw-in-base64-out \
  --payload "$(cat <<EOF
{
  "version": "0",
  "id": "test-event-7",
  "detail-type": "Security Hub Findings - Imported",
  "source": "aws.securityhub",
  "account": "072288671186",
  "time": "2026-03-02T00:00:00Z",
  "region": "us-east-1",
  "detail": {
    "findings": []
  }
}
EOF
)" \
response.json && cat response.json && rm response.json
```
Expected output:
```json
{
    "StatusCode": 200,
    "ExecutedVersion": "$LATEST"
}
{"statusCode": 400, "body": "{\"message\": \"No findings in event\"}"}
```