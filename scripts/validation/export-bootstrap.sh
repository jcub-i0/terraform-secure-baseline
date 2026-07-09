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

VALIDATION_TIME="$(date +"%Y-%m-%dT%H:%M:%S%:z")"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"

REPO_ROOT="$(get_repo_root)"
OUTPUT_DIR="${REPO_ROOT}/validation-results/${ENV_NAME}/bootstrap/${TIMESTAMP}"
RELATIVE_OUTPUT_DIR="validation-results/${ENV_NAME}/bootstrap/${TIMESTAMP}"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

mkdir -p "$OUTPUT_DIR"

VALIDATION_SCRIPT="validate-bootstrap.sh"
VALIDATION_AREA="Workload Bootstrap"
VALIDATION_LAYER="workload_bootstrap"

RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$RESULTS_JSONL"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT=1

section "tf-secure-baseline Workload Bootstrap Validation Report Export"

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
info "Environment: ${ENV_NAME}"
info "Validation layer: ${VALIDATION_LAYER}"
info "Output dir: ${OUTPUT_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "Validation time: ${VALIDATION_TIME}"

if [[ "$NAME_PREFIX" != *"-${ENV_NAME}" ]]; then
  warn "NAME_PREFIX does not end with -${ENV_NAME}: ${NAME_PREFIX}"
  warn "This may be valid for custom/client deployments, but confirm it matches deployed resource names."
fi

section "Checking AWS caller identity"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

success "AWS credentials are valid"
info "AWS account ID: ${AWS_ACCOUNT_ID}"
info "AWS caller ARN: ${AWS_CALLER_ARN}"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$AWS_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: ${EXPECTED_ACCOUNT_ID}"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
fi

section "Running workload bootstrap validation"

SCRIPT_PATH="${SCRIPT_DIR}/${VALIDATION_SCRIPT}"
LOG_FILE="${OUTPUT_DIR}/${VALIDATION_SCRIPT%.sh}.log"
LOG_BASENAME="$(basename "$LOG_FILE")"
RESULT="FAIL"

info "Running ${VALIDATION_SCRIPT}"

if [[ ! -x "$SCRIPT_PATH" ]]; then
  warn "${VALIDATION_SCRIPT} is missing or not executable"

  {
    echo "[FAIL] Validation script is missing or not executable: ${SCRIPT_PATH}"
  } > "$LOG_FILE"

  FAILED_COUNT=$((FAILED_COUNT + 1))
  RESULT="FAIL"
elif "$SCRIPT_PATH" "$ENV_NAME" >"$LOG_FILE" 2>&1; then
  success "${VALIDATION_SCRIPT} passed"
  PASSED_COUNT=$((PASSED_COUNT + 1))
  RESULT="PATH"
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

section "Generating JSON summary"

jq -n \
  --arg project "tf-secure-baseline" \
  --arg report_type "validation_report" \
  --arg validation_layer "$VALIDATION_LAYER" \
  --arg validation_layer_display "Workload Bootstrap" \
  --arg environment "$ENV_NAME" \
  --arg aws_profile "$AWS_PROFILE" \
  --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" \
  --arg expected_account_id "$EXPECTED_ACCOUNT_ID" \
  --arg name_prefix "$NAME_PREFIX" \
  --arg validation_time "$VALIDATION_TIME" \
  --arg overall_result "$OVERALL_RESULT" \
  --argjson scripts_passed "$PASSED_COUNT" \
  --argjson scripts_failed "$FAILED_COUNT" \
  --argjson scripts_total "$TOTAL_COUNT" \
  --slurpfile results "$RESULTS_JSONL" \
  '{
    project: $project,
    report_type: $report_type,
    validation_layer: $validation_layer,
    validation_layer_display: $validation_layer_display,
    environment: $environment,
    aws_profile: $aws_profile,
    aws_region: $aws_region,
    aws_account_id: $aws_account_id,
    expected_account_id: $expected_account_id,
    name_prefix: $name_prefix,
    validation_time: $validation_time,
    overall_result: $overall_result,
    scripts_passed: $scripts_passed,
    scripts_failed: $scripts_failed,
    scripts_total: $scripts_total,
    results: $results,
    validation_scope: [
      "workload_bootstrap_directory_structure",
      "local_state_bootstrap_pattern",
      "remote_backend_files",
      "s3_native_lockfile_configuration",
      "state_bucket_security",
      "state_bucket_versioning",
      "state_bucket_public_access_block",
      "state_bucket_sse_kms_encryption",
      "state_cmk_status",
      "workload_github_oidc_provider",
      "workload_github_plan_role",
      "workload_github_apply_role",
      "github_repository_trust_conditions",
      "github_environment_subject_conditions",
      "github_state_bucket_access",
      "github_tflock_object_access",
      "github_state_cmk_access",
      "github_workload_cmk_access_when_required"
    ],
    manual_validation_remaining: [
      "workload_baseline_validation",
      "control_plane_validation",
      "github_actions_workflows",
      "identity_center_assignments",
      "live_ec2_isolation",
      "live_ec2_rollback",
      "live_ip_enrichment",
      "tamper_detection",
      "break_glass",
      "destroy_safety"
    ]
  }' > "$SUMMARY_JSON"

success "JSON summary written: ${SUMMARY_JSON}"