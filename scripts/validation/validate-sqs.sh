#!/usr/bin/env bash

# validate-sqs.sh
#
# Validates SQS queues for a deployed tf-secure-baseline workload environment.
#
# Current expected SQS design:
# - Compliance SNS topic publishes to compliance SQS queue.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Compliance SQS queue exists
# - Queue encryption is configured
# - Queue policy exists
# - Queue policy allows the compliance SNS topic to publish
# - Compliance SNS topic has a subscription targeting the compliance queue
# - Queue DLQ/redrive config is reported
#
# Usage:
#   ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-sqs.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-sqs.sh dev