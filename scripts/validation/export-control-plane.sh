#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

CONTROL_PLANE_ENV_NAME="${CONTROL_PLANE_ENV_NAME:-control-plane}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${CONTROL_PLANE_ENV_NAME}}"

REQUIRE_CONTROL_PLANE_GITHUB_OIDC="${REQUIRE_CONTROL_PLANE_GITHUB_OIDC:-true}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"
CHECK_OPTIONAL_SECOPS_GROUPS="${CHECK_OPTIONAL_SECOPS_GROUPS:-false}"
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-false}"

ACCOUNT_ID_DEV="${ACCOUNT_ID_DEV:-}"
ACCOUNT_ID_STAGING="${ACCOUNT_ID_STAGING:-}"
ACCOUNT_ID_PROD="${ACCOUNT_ID_PROD:-}"

VALIDATION_TIME="$(date +"%Y-%m-%dT%H:%M:%S%:z")"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"

REPO_ROOT="$(get_repo_root)"
OUTPUT_DIR="${REPO_ROOT}/validation-results/control-plane/${TIMESTAMP}"
RELATIVE_OUTPUT_DIR="validation-results/control-plane/${TIMESTAMP}"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

mkdir -p "$OUTPUT_DIR"

VALIDATION_SCRIPT="validate-control-plane.sh"
VALIDATION_AREA="Control Plane"
VALIDATION_LAYER="control_plane"

RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$RESULTS_JSONL"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT=1

section "${CLOUD_NAME} Control-Plane Validation Report Export"

section "Checking required local commands"

require_command "aws"
success "aws CLI found"

require_command "terraform"
success "terraform found"

require_command "jq"
success "jq found"

require_command "git"
success "git found"

section "Resolving repository paths and report settings"

info "Repository root: ${REPO_ROOT}"
info "Control-plane environment name: ${CONTROL_PLANE_ENV_NAME}"
info "Validation layer: ${VALIDATION_LAYER}"
info "Output dir: ${OUTPUT_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "EXPECTED_GITHUB_REPOSITORY: ${EXPECTED_GITHUB_REPOSITORY:-<not set>}"
info "REQUIRE_CONTROL_PLANE_GITHUB_OIDC: ${REQUIRE_CONTROL_PLANE_GITHUB_OIDC}"
info "CHECK_OPTIONAL_SECOPS_GROUPS: ${CHECK_OPTIONAL_SECOPS_GROUPS}"
info "STRICT_IDENTITY_CENTER_ASSIGNMENTS: ${STRICT_IDENTITY_CENTER_ASSIGNMENTS}"
info "STRICT_ACCOUNT_OU_CHECKS: ${STRICT_ACCOUNT_OU_CHECKS}"
info "ACCOUNT_ID_DEV: ${ACCOUNT_ID_DEV:-<not set>}"
info "ACCOUNT_ID_STAGING: ${ACCOUNT_ID_STAGING:-<not set>}"
info "ACCOUNT_ID_PROD: ${ACCOUNT_ID_PROD:-<not set>}"
info "Validation time: ${VALIDATION_TIME}"

if [[ "$NAME_PREFIX" != *"-${CONTROL_PLANE_ENV_NAME}" ]]; then
  warn "NAME_PREFIX does not end with -${CONTROL_PLANE_ENV_NAME}: ${NAME_PREFIX}"
  warn "This may be valid for custom/client deployments, but confirm it matches deployed resource names."
fi

section "Checking AWS caller identity"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

success "AWS credentials are valid"
info "AWS account ID: ${AWS_ACCOUNT_ID}"
info "AWS caller ARN: ${AWS_CALLER_ARN}"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected control-plane account: ${EXPECTED_ACCOUNT_ID}"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
fi

section "Running control-plane validation"

SCRIPT_PATH="${SCRIPT_PATH}/${VALIDATION_SCRIPT}"
LOG_FILE="${OUTPUT_DIR}/${VALIDATION_SCRIPT%.sh}.log"
LOG_BASENAME="$(basename "$LOG_FILE")"
RESULT="FAIL"

info "Running ${VALIDATION_SCRIPT}"

export AWS_PROFILE
export AWS_REGION
export EXPECTED_ACCOUNT_ID
export CONTROL_PLANE_ENV_NAME
export CLOUD_NAME
export NAME_PREFIX
export REQUIRE_CONTROL_PLANE_GITHUB_OIDC
export EXPECTED_GITHUB_REPOSITORY
export CHECK_OPTIONAL_SECOPS_GROUPS
export STRICT_IDENTITY_CENTER_ASSIGNMENTS
export STRICT_ACCOUNT_OU_CHECKS
export ACCOUNT_ID_DEV
export ACCOUNT_ID_STAGING
export ACCOUNT_ID_PROD

if [[ ! -x "$SCRIPT_PATH" ]]; then
  warn "${VALIDATION_SCRIPT} is missing or not executable"

  {
    echo "[FAIL] Validation script is missing or not executable: ${SCRIPT_PATH}"
  } > "$LOG_FILE"

  FAILED_COUNT=$((FAILED_COUNT + 1))
  RESULT="FAIL"
elif "$SCRIPT_PATH" >"$LOG_FILE" 2>&1; then
  success "${VALIDATION_SCRIPT} passed"
  PASSED_COUNT=$((PASSED_COUNT + 1))
  RESULT="PASS"
else
  warn "${VALIDATION_SCRIPT} failed. See log: ${LOG_FILE}"
  FAILED_COUNT=$((FAILED_COUNT + 1))
  RESULT="FAIL"
fi

jq -n \
  --arg area "$VALIDATION_AREA" \
  --arg script "$VALIDATION_SCRIPT" \
  --arg result "$RESULT" \
  --arg log_file "$LOG_BASENAME" \
  '{
    area: $area,
    script: $script,
    result: $result,
    log_file: $log_file
  }' >> "$RESULTS_JSONL"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  OVERALL_RESULT="FAIL"
else
  OVERALL_RESULT="PASS"
fi

