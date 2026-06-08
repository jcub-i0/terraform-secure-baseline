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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "${ENV_NAME}"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi