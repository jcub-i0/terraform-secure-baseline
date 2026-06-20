#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"

if [[ -z "ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

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