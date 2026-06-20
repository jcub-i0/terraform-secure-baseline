#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME}}"

if [[ "$NAME_PREFIX" != *"-${ENV_NAME}" ]]; then
  warn "NAME_PREFIX does not end with -${ENV_NAME}: ${NAME_PREFIX}"
  warn "This may be valid for custom/client deployments, but confirm it matches deployed resource names."
fi

info "Environment: ${ENV_NAME}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "NAME_PREFIX: ${NAME_PREFIX}"

REPO_ROOT="$(get_repo_root)"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"
OUTPUT_DIR="${REPO_ROOT}/validation-results/${ENV_NAME}/${TIMESTAMP}"

mkdir -p "$OUTPUT_DIR"

VALIDATION_SCRIPTS=(
  "validate-env.sh"
  "validate-networking.sh"
  "validate-vpc-endpoints.sh"
  "validate-logging.sh"
  "validate-security-services.sh"
  "validate-kms.sh"
  "validate-backup.sh"
  "validate-sns.sh"
  "validate-sqs.sh"
  "validate-eventbridge.sh"
  "validate-lambda.sh"
  "validate-ssm.sh"
  "validate-compute.sh"
  "validate-iam.sh"
)

declare -A VALIDATION_AREAS=(
  ["validate-env.sh"]="Environment"
  ["validate-networking.sh"]="Networking"
  ["validate-vpc-endpoints.sh"]="VPC Endpoints"
  ["validate-logging.sh"]="Logging"
  ["validate-security-services.sh"]="Security Services"
  ["validate-kms.sh"]="KMS"
  ["validate-backup.sh"]="Backup"
  ["validate-sns.sh"]="SNS"
  ["validate-sqs.sh"]="SQS"
  ["validate-eventbridge.sh"]="EventBridge"
  ["validate-lambda.sh"]="Lambda"
  ["validate-ssm.sh"]="SSM"
  ["validate-compute.sh"]="Compute"
  ["validate-iam.sh"]="IAM"
)

FAILED_COUNT=0
PASSED_COUNT=0
TOTAL_COUNT="${#VALIDATION_SCRIPTS[@]}"

section "Exporting validation report"
info "Environment: ${ENV_NAME}"
info "Output directory: ${OUTPUT_DIR}"

for script_name in "${VALIDATION_SCRIPTS[@]}"; do
  script_path="${SCRIPT_DIR}/${script_name}"
  log_file="${OUTPUT_DIR}/${script_name%.sh}.log"

  section "Running ${script_name}"

  if [[ ! -x "$script_path" ]]; then
    warn "${script_name} is missing or not executable"
    {
      echo "[FAIL] Validation script is missing or not executable: ${script_path}"
    } > "$log_file"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    continue
  fi

  if "$script_path" "$ENV_NAME" >"$log_file" 2>&1; then
    success "${script_name} passed"
    PASSED_COUNT=$((PASSED_COUNT + 1))
  else
    warn "${script_name} failed. See log: ${log_file}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

section "Validation report export summary"
info "Output directory: ${OUTPUT_DIR}"
info "Validation scripts passed: ${PASSED_COUNT}/${TOTAL_COUNT}"
info "Validation scripts failed: ${FAILED_COUNT}/${TOTAL_COUNT}"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  fail "One or more validation scripts failed. Review logs in ${OUTPUT_DIR}"
fi

success "Validation report logs exported successfully"