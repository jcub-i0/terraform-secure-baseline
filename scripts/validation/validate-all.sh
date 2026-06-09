#!/usr/bin/env bash

# validate-all.sh
#
# Runs the full tf-secure-baseline post-deployment validation suite for a single
# environment.
#
# Usage:
#   ./scripts/validation/validate-all.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-all.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-all.sh dev

set -euo pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

section "tf-secure-baseline Full Validation Suite"

info "Environment: $ENV_NAME"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: $AWS_REGION"
info "NAME_PREFIX: $NAME_PREFIX"

VALIDATION_SCRIPTS=(
  "validate-env.sh"
  "validate-networking.sh"
  "validate-vpc-endpoints.sh"
  "validate-logging.sh"
  "validate-security-services.sh"
  "validate-kms.sh"
  "validate-sns.sh"
  "validate-iam.sh"
)

PASSED_SCRIPTS=()
FAILED_SCRIPTS=()

for validation_script in "${VALIDATION_SCRIPTS[@]}"; do
  script_path="${SCRIPT_DIR}/${validation_script}"

  if [[ ! -x "$script_path" ]]; then
    warn "Validation script not found or not executable: $script_path"
    FAILED_SCRIPTS+=("$validation_script")
    continue
  fi

  section "Running ${validation_script}"

  if AWS_PROFILE="$AWS_PROFILE" AWS_REGION="$AWS_REGION" NAME_PREFIX="$NAME_PREFIX" EXPECTED_ACCOUNT_ID="$EXPECTED_ACCOUNT_ID" "$script_path" "$ENV_NAME"; then
    PASSED_SCRIPTS+=("$validation_script")
    success "${validation_script} completed successfully"
  else
    FAILED_SCRIPTS+=("$validation_script")
    warn "${validation_script} failed."
  fi
done

PASSED_COUNT="${#PASSED_SCRIPTS[@]}"
FAILED_COUNT="${#FAILED_SCRIPTS[@]}"
TOTAL_COUNT="${#VALIDATION_SCRIPTS[@]}"

section "Full Validation Summary"

cat <<SUMMARY
Environment:                ${ENV_NAME}
AWS profile:                ${AWS_PROFILE:-<default>}
AWS region:                 ${AWS_REGION}
Name prefix:                ${NAME_PREFIX}

Validation scripts passed:  ${PASSED_COUNT}/${TOTAL_COUNT}
Validation scripts failed:  ${FAILED_COUNT}/${TOTAL_COUNT}
SUMMARY

if [[ "${PASSED_COUNT}" -gt 0 ]]; then
  echo
  echo "Passed scripts:"
  for script_name in "${PASSED_SCRIPTS[@]}"; do
    echo "- ${script_name}"
  done
fi

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  echo
  echo "Failed scripts:"
  for script_name in "${FAILED_SCRIPTS[@]}"; do
    echo "- ${script_name}"
  done

  section "Validation Result"
  fail "Full validation suite completed with ${FAILED_COUNT} failed script(s)."
fi

section "Validation Result"

success "Full validation suite completed successfully for: ${ENV_NAME}"