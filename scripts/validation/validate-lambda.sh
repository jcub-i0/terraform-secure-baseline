#!/usr/bin/env bash

# validate-lambda.sh
#
# Validates Lambda functions for a deployed tf-secure-baseline workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Expected Lambda functions exist
# - Functions are Active
# - Functions have expected execution roles
# - Functions have sane timeout and memory settings
# - Functions use KMS encryption where configured
# - Lambda resource policies are readable and summarized
#
# Usage:
#   ./scripts/validation/validate-lambda.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-lambda.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-lambda.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-lambda.sh dev