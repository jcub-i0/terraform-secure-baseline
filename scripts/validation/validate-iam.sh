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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

# IAM is global, but keeping region in AWS CLI calls is harmless and helps
# profiles that rely on a configured region.
if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline IAM Validation"