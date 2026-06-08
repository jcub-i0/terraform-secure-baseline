#!/usr/bin/env bash

# validate-kms.sh
#
# Validates KMS keys and aliases for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform outputs are readable
# - KMS aliases matching the environment exist
# - Expected workload CMK aliases exist:
#   - logs
#   - lambda
#   - ebs
#   - secrets manager
# - Backup CMK alias is validated only when effective_backup_enabled=true
# - Matching KMS keys are enabled
# - Key rotation status is checked and reported
#
# Usage:
#   ./scripts/validation/validate-kms.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-kms.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-kms.sh dev