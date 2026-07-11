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

SCRIPT_PATH="${SCRIPT_DIR}/${VALIDATION_SCRIPT}"
LOG_FILE="${OUTPUT_DIR}/${VALIDATION_SCRIPT%.sh}.log"
LOG_BASENAME="$(basename "$LOG_FILE")"
RESULT="FAIL"

info "Running ${VALIDATION_SCRIPT}"

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

section "Generating JSON summary"

jq -n \
  --arg project "$CLOUD_NAME" \
  --arg report_type "validation_report" \
  --arg validation_layer "$VALIDATION_LAYER" \
  --arg validation_layer_display "Control Plane" \
  --arg control_plane_environment "$CONTROL_PLANE_ENV_NAME" \
  --arg aws_profile "$AWS_PROFILE" \
  --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" \
  --arg expected_account_id "$EXPECTED_ACCOUNT_ID" \
  --arg name_prefix "$NAME_PREFIX" \
  --arg validation_time "$VALIDATION_TIME" \
  --arg overall_result "$OVERALL_RESULT" \
  --arg expected_github_repository "$EXPECTED_GITHUB_REPOSITORY" \
  --arg require_control_plane_github_oidc "$REQUIRE_CONTROL_PLANE_GITHUB_OIDC" \
  --arg check_optional_secops_groups "$CHECK_OPTIONAL_SECOPS_GROUPS" \
  --arg strict_identity_center_assignments "$STRICT_IDENTITY_CENTER_ASSIGNMENTS" \
  --arg strict_account_ou_checks "$STRICT_ACCOUNT_OU_CHECKS" \
  --arg account_id_dev "$ACCOUNT_ID_DEV" \
  --arg account_id_staging "$ACCOUNT_ID_STAGING" \
  --arg account_id_prod "$ACCOUNT_ID_PROD" \
  --argjson scripts_passed "$PASSED_COUNT" \
  --argjson scripts_failed "$FAILED_COUNT" \
  --argjson scripts_total "$TOTAL_COUNT" \
  --slurpfile results "$RESULTS_JSONL" \
  '{
    project: $project,
    report_type: $report_type,
    validation_layer: $validation_layer,
    validation_layer_display: $validation_layer_display,
    control_plane_environment: $control_plane_environment,
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
    settings: {
      expected_github_repository: $expected_github_repository,
      require_control_plane_github_oidc: $require_control_plane_github_oidc,
      check_optional_secops_groups: $check_optional_secops_groups,
      strict_identity_center_assignments: $strict_identity_center_assignments,
      strict_account_ou_checks: $strict_account_ou_checks,
      account_id_dev: $account_id_dev,
      account_id_staging: $account_id_staging,
      account_id_prod: $account_id_prod
    },
    results: $results,
    validation_scope: [
      "control_plane_aws_identity",
      "control_plane_stack_directories",
      "control_plane_backend_locking",
      "control_plane_state_outputs",
      "control_plane_state_bucket_security",
      "control_plane_state_bucket_versioning",
      "control_plane_state_bucket_public_access_block",
      "control_plane_state_bucket_sse_kms_encryption",
      "control_plane_state_cmk_status",
      "control_plane_github_oidc_provider",
      "control_plane_github_plan_role",
      "control_plane_github_apply_role",
      "github_repository_trust_conditions",
      "aws_organizations_root",
      "aws_organizations_ou_structure",
      "optional_workload_account_ou_placement",
      "identity_center_instance",
      "identity_center_groups",
      "identity_center_permission_sets",
      "optional_identity_center_account_assignments"
    ],
    manual_validation_remaining: [
      "workload_bootstrap_validation",
      "workload_baseline_validation",
      "github_actions_workflows",
      "end_user_sso_login",
      "live_ec2_isolation",
      "live_ec2_rollback",
      "live_ip_enrichment",
      "tamper_detection",
      "break_glass",
      "destroy_safety"
    ]
  }' > "$SUMMARY_JSON"

success "JSON summary written: ${SUMMARY_JSON}"

section "Generating Markdown summary"

{
  echo "# ${CLOUD_NAME} Control-Plane Validation Report"
  echo
  echo "This report summarizes automated read-only control-plane validation results."
  echo
  echo "## Executive Summary"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Overall result | **${OVERALL_RESULT}** |"
  echo "| Validation layer | Control Plane |"
  echo "| Validation scripts passed | **${PASSED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Validation scripts failed | **${FAILED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Report Package Location | \`${RELATIVE_OUTPUT_DIR}/\` |"
  echo
  echo "## Control-Plane Environment"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Project | ${CLOUD_NAME} |"
  echo "| Control-plane Environment | ${CONTROL_PLANE_ENV_NAME} |"
  echo "| Validation Layer | Control Plane |"
  echo "| AWS Profile | ${AWS_PROFILE:-<default>} |"
  echo "| AWS Region | ${AWS_REGION} |"
  echo "| AWS Account ID | ${AWS_ACCOUNT_ID} |"
  echo "| Expected Account ID | ${EXPECTED_ACCOUNT_ID:-<not set>} |"
  echo "| Name Prefix | ${NAME_PREFIX} |"
  echo "| Validation Time | ${VALIDATION_TIME} |"
  echo "| Overall Result | ${OVERALL_RESULT} |"
  echo "| Scripts Passed | ${PASSED_COUNT}/${TOTAL_COUNT} |"
  echo "| Scripts Failed | ${FAILED_COUNT}/${TOTAL_COUNT} |"
  echo
  echo "## Validation Settings"
  echo
  echo "| Setting | Value |"
  echo "|---|---|"
  echo "| Expected GitHub Repository | ${EXPECTED_GITHUB_REPOSITORY:-<not set>} |"
  echo "| Require Control-Plane GitHub OIDC | ${REQUIRE_CONTROL_PLANE_GITHUB_OIDC} |"
  echo "| Check Optional SecOps Groups | ${CHECK_OPTIONAL_SECOPS_GROUPS} |"
  echo "| Strict Identity Center Assignments | ${STRICT_IDENTITY_CENTER_ASSIGNMENTS} |"
  echo "| Strict Account OU Checks | ${STRICT_ACCOUNT_OU_CHECKS} |"
  echo "| Dev Account ID | ${ACCOUNT_ID_DEV:-<not set>} |"
  echo "| Staging Account ID | ${ACCOUNT_ID_STAGING:-<not set>} |"
  echo "| Prod Account ID | ${ACCOUNT_ID_PROD:-<not set>} |"
  echo
  echo "## Validation Summary"
  echo
  echo "| Area | Script | Result | Log |"
  echo "|---|---|---|---|"

  jq -r '
    .results[]
    | "| \(.area) | `\(.script)` | \(.result) | `\(.log_file)` |"
  ' "$SUMMARY_JSON"

  echo
  echo "## Automated Validation Scope"
  echo
  echo "This control-plane validation report covers:"
  echo
  echo "- Control-plane AWS caller identity"
  echo "- Control-plane stack directory structure"
  echo "- Control-plane backend locking with \`use_lockfile = true\`"
  echo "- Control-plane state Terraform outputs"
  echo "- Control-plane state bucket existence and security configuration"
  echo "- State bucket versioning"
  echo "- State bucket public access block"
  echo "- State bucket SSE-KMS encryption"
  echo "- Customer-managed state CMK status"
  echo "- Control-plane GitHub OIDC provider"
  echo "- Control-plane GitHub Plan and Apply roles"
  echo "- Expected GitHub repository trust conditions when configured"
  echo "- AWS Organizations root and OU structure"
  echo "- Optional workload account OU placement checks"
  echo "- IAM Identity Center instance"
  echo "- Required SecOps Identity Center groups"
  echo "- Optional SecOps Identity Center groups when enabled"
  echo "- Identity Center permission sets"
  echo "- Optional Identity Center account assignment evidence"
  echo
  echo "## Manual Validation Remaining"
  echo
  echo "The automated control-plane validation export is intentionally read-only. The following checks remain outside this report:"
  echo
  echo "- Workload bootstrap validation"
  echo "- Workload baseline validation"
  echo "- GitHub Actions workflow execution validation"
  echo "- End-user SSO login validation"
  echo "- Live EC2 isolation test"
  echo "- Live EC2 rollback test"
  echo "- Live IP enrichment test"
  echo "- Tamper detection test"
  echo "- Break-glass role assumption test"
  echo "- Destroy safety review"
  echo
  echo "## Evidence Files"
  echo
  echo "This report directory contains the generated control-plane validation summary files and per-script log."
  echo
  echo "| File | Purpose |"
  echo "|---|---|"
  echo "| \`summary.md\` | Human-readable control-plane validation report |"
  echo "| \`summary.json\` | Machine-readable control-plane validation summary |"

  jq -r '
    .results[]
    | "| `\(.log_file)` | Log output for `\(.script)` |"
  ' "$SUMMARY_JSON"

  echo
  echo "## Limitations"
  echo
  echo "This report validates selected control-plane, backend locking, state backend, GitHub OIDC, AWS Organizations, and IAM Identity Center readiness controls."
  echo
  echo "The validation script is read-only and does not run GitHub workflows, assume roles, modify Identity Center assignments, move accounts, modify IAM policies, or perform destroy/cleanup operations."
  echo
  echo "This report does not replace a full SOC 2 or ISO 27001 audit, control owner review, policy review, evidence review, risk assessment, or ISMS."
} > "$SUMMARY_MD"

success "Markdown summary written: ${SUMMARY_MD}"

section "Control-Plane Validation Report Export Summary"

echo "Validation layer:           Control Plane"
echo "Control-plane env name:     ${CONTROL_PLANE_ENV_NAME}"
echo "AWS profile:                ${AWS_PROFILE:-<default>}"
echo "AWS region:                 ${AWS_REGION}"
echo "AWS account ID:             ${AWS_ACCOUNT_ID}"
echo "Name prefix:                ${NAME_PREFIX}"
echo
echo "Output directory:           ${OUTPUT_DIR}"
echo "Summary JSON:               ${SUMMARY_JSON}"
echo "Summary Markdown:           ${SUMMARY_MD}"
echo
echo "Validation scripts passed:  ${PASSED_COUNT}/${TOTAL_COUNT}"
echo "Validation scripts failed:  ${FAILED_COUNT}/${TOTAL_COUNT}"
echo "Overall result:             ${OVERALL_RESULT}"

section "Validation Result"

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  fail "Control-plane validation report export completed with failures"
fi

success "Control-plane validation report export completed successfully"