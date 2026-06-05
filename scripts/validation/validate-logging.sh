#!/usr/bin/env bash

# validate-logging.sh
#
# Validates logging controls for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform outputs are readable
# - VPC can be resolved
# - Centralized logs bucket exists
# - CloudTrail exists
# - CloudTrail is multi-region
# - CloudTrail is actively logging
# - CloudTrail has S3 delivery configured
# - VPC Flow Logs exist for the VPC
# - VPC Flow Logs are active
# - CloudWatch log groups exist for the baseline
# - CloudWatch log group retention matches effective_cloudwatch_retention_days where applicable
#
# Usage:
#   ./scripts/validation/validate-logging.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-logging.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-logging.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="{$1:-}"
AWS_PROFILE="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline Logging Validation"