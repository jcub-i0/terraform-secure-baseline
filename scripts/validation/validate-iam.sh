#!/usr/bin/env bash

# validate-iam.sh
#
# Validates IAM roles and trust policies for a deployed tf-secure-baseline
# environment.
#
# Checks:
# - Expected IAM roles exist
# - Service roles trust the expected AWS service principals
# - Break-glass role exists
# - Break-glass trust policy includes MFA protection when detectable
# - Optional GitHub OIDC roles are detected if present
# - Shared IAM policies from Terraform outputs exist if available
#
# Usage:
#   ./scripts/validation/validate-iam.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-iam.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-iam.sh dev