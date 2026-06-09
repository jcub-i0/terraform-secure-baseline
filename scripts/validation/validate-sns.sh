#!/usr/bin/env bash

# validate-sns.sh
#
# Validates SNS topics and subscriptions for a deployed tf-secure-baseline
# workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - SNS topics matching the environment exist
# - SNS topics have subscriptions where expected
# - SNS subscriptions are confirmed where applicable
# - SNS topic KMS encryption is reported
#
# Usage:
#   ./scripts/validation/validate-sns.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-sns.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-sns.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-sns.sh dev