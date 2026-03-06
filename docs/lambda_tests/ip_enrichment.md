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

# TEST 1 -- HIGH FINDING WITH PUBLIC IPV4 ADDRESSES
