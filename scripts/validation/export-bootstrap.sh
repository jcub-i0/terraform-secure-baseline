#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"

REQUIRE_BOOTSTRAP_GITHUB_OIDC="${REQUIRE_BOOTSTRAP_GITHUB_OIDC:-true}"
REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE="${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE:-true}"
STRICT_WORKLOAD_CMK_POLICY_CHECKS="${STRICT_WORKLOAD_CMK_POLICY_CHECKS:-true}"
REQUIRE_STATE_STACK_LOCAL="${REQUIRE_STATE_STACK_LOCAL:-true}"
STRICT_GITHUB_SUBJECT_CHECKS="${STRICT_GITHUB_SUBJECT_CHECKS:-true}"

EXPECTED_GITHUB_PLAN_SUBJECT="${EXPECTED_GITHUB_PLAN_SUBJECT:-}"
EXPECTED_GITHUB_APPLY_SUBJECT="${EXPECTED_GITHUB_APPLY_SUBJECT:-}"

case "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" in
  true|false)
    ;;
  *)
    fail "Invalid STRICT_WORKLOAD_CMK_POLICY_CHECKS: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}. Expected true or false."
    ;;
esac

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"

# Derive GitHub OIDC trust subjects when the repository is known.
if [[ -n "$EXPECTED_GITHUB_REPOSITORY" ]]; then
  EXPECTED_GITHUB_PLAN_SUBJECT="${EXPECTED_GITHUB_PLAN_SUBJECT:-repo:${EXPECTED_GITHUB_REPOSITORY}:environment:${ENV_NAME}-plan}"
  EXPECTED_GITHUB_APPLY_SUBJECT="${EXPECTED_GITHUB_APPLY_SUBJECT:-repo:${EXPECTED_GITHUB_REPOSITORY}:environment:${ENV_NAME}}"
fi

# Keep report metadata and the child validator aligned.
export AWS_REGION
export CLOUD_NAME
export NAME_PREFIX
export EXPECTED_ACCOUNT_ID
export EXPECTED_GITHUB_REPOSITORY
export REQUIRE_BOOTSTRAP_GITHUB_OIDC
export REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE
export STRICT_WORKLOAD_CMK_POLICY_CHECKS
export REQUIRE_STATE_STACK_LOCAL
export STRICT_GITHUB_SUBJECT_CHECKS
export EXPECTED_GITHUB_PLAN_SUBJECT
export EXPECTED_GITHUB_APPLY_SUBJECT

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

section "${CLOUD_NAME} Workload Bootstrap Validation Report Export"

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
info "Cloud name: ${CLOUD_NAME}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "EXPECTED_GITHUB_REPOSITORY: ${EXPECTED_GITHUB_REPOSITORY:-<not set>}"
info "REQUIRE_BOOTSTRAP_GITHUB_OIDC: ${REQUIRE_BOOTSTRAP_GITHUB_OIDC}"
info "REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE: ${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE}"
info "STRICT_WORKLOAD_CMK_POLICY_CHECKS: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}"
info "REQUIRE_STATE_STACK_LOCAL: ${REQUIRE_STATE_STACK_LOCAL}"
info "STRICT_GITHUB_SUBJECT_CHECKS: ${STRICT_GITHUB_SUBJECT_CHECKS}"
info "EXPECTED_GITHUB_PLAN_SUBJECT: ${EXPECTED_GITHUB_PLAN_SUBJECT:-<derived by validate-bootstrap.sh when repository is set>}"
info "EXPECTED_GITHUB_APPLY_SUBJECT: ${EXPECTED_GITHUB_APPLY_SUBJECT:-<derived by validate-bootstrap.sh when repository is set>}"
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
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
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
  --arg project "${CLOUD_NAME}" \
  --arg report_type "validation_report" \
  --arg validation_layer "$VALIDATION_LAYER" \
  --arg validation_layer_display "Workload Bootstrap" \
  --arg environment "$ENV_NAME" \
  --arg aws_profile "$AWS_PROFILE" \
  --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" \
  --arg expected_account_id "$EXPECTED_ACCOUNT_ID" \
  --arg expected_github_repository "$EXPECTED_GITHUB_REPOSITORY" \
  --arg expected_github_plan_subject "$EXPECTED_GITHUB_PLAN_SUBJECT" \
  --arg expected_github_apply_subject "$EXPECTED_GITHUB_APPLY_SUBJECT" \
  --arg require_bootstrap_github_oidc "$REQUIRE_BOOTSTRAP_GITHUB_OIDC" \
  --arg require_bootstrap_github_apply_role "$REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE" \
  --arg strict_workload_cmk_policy_checks "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" \
  --arg require_state_stack_local "$REQUIRE_STATE_STACK_LOCAL" \
  --arg strict_github_subject_checks "$STRICT_GITHUB_SUBJECT_CHECKS" \
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
    expected_github_repository: $expected_github_repository,
    expected_github_plan_subject: $expected_github_plan_subject,
    expected_github_apply_subject: $expected_github_apply_subject,
    require_bootstrap_github_oidc: $require_bootstrap_github_oidc,
    require_bootstrap_github_apply_role: $require_bootstrap_github_apply_role,
    strict_workload_cmk_policy_checks: $strict_workload_cmk_policy_checks,
    require_state_stack_local: $require_state_stack_local,
    strict_github_subject_checks: $strict_github_subject_checks,
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
      "github_workload_cmk_access_strict_by_default"
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

section "Generating Markdown summary"

{
  echo "# ${CLOUD_NAME} Workload Bootstrap Validation Report"
  echo
  echo "This report summarizes automated read-only workload bootstrap validation results for the \`$ENV_NAME\` environment."
  echo
  echo "## Executive Summary"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Overall result | **${OVERALL_RESULT}** |"
  echo "| Validation layer | Workload Bootstrap |"
  echo "| Validation scripts passed | **${PASSED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Validation scripts failed | **${FAILED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Report Package Location | \`${RELATIVE_OUTPUT_DIR}/\` |"
  echo
  echo "## Environment"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Project | ${CLOUD_NAME} |"
  echo "| Environment | ${ENV_NAME} |"
  echo "| Validation Layer | Workload Bootstrap |"
  echo "| AWS Profile | ${AWS_PROFILE:-<default>} |"
  echo "| AWS Region | ${AWS_REGION} |"
  echo "| AWS Account ID | ${AWS_ACCOUNT_ID} |"
  echo "| Expected Account ID | ${EXPECTED_ACCOUNT_ID:-<not set>} |"
  echo "| Expected GitHub Repository | ${EXPECTED_GITHUB_REPOSITORY:-<not set>} |"
  echo "| Expected GitHub Plan Subject | ${EXPECTED_GITHUB_PLAN_SUBJECT:-<derived by validate-bootstrap.sh when repository is set>} |"
  echo "| Expected GitHub Apply Subject | ${EXPECTED_GITHUB_APPLY_SUBJECT:-<derived by validate-bootstrap.sh when repository is set>} |"
  echo "| Require Bootstrap GitHub OIDC | ${REQUIRE_BOOTSTRAP_GITHUB_OIDC} |"
  echo "| Require Bootstrap GitHub Apply Role | ${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE} |"
  echo "| Strict Workload CMK Policy Checks | ${STRICT_WORKLOAD_CMK_POLICY_CHECKS} |"
  echo "| Require State Stack Local | ${REQUIRE_STATE_STACK_LOCAL} |"
  echo "| Strict GitHub Subject Checks | ${STRICT_GITHUB_SUBJECT_CHECKS} |"
  echo "| Name Prefix | ${NAME_PREFIX} |"
  echo "| Validation Time | ${VALIDATION_TIME} |"
  echo "| Overall Result | ${OVERALL_RESULT} |"
  echo "| Scripts Passed | ${PASSED_COUNT}/${TOTAL_COUNT} |"
  echo "| Scripts Failed | ${FAILED_COUNT}/${TOTAL_COUNT} |"
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
  echo "This workload bootstrap validation report covers:"
  echo
  echo "- Workload bootstrap directory structure"
  echo "- Local-state bootstrap pattern for the state bootstrap stack"
  echo "- Remote backend file presence and parsing"
  echo "- Terraform S3 native locking configuration with \`use_lockfile = true\`"
  echo "- Distinct account and workload state object keys"
  echo "- State bucket existence and security configuration"
  echo "- State bucket versioning"
  echo "- State bucket public access block"
  echo "- State bucket SSE-KMS encryption"
  echo "- Customer-managed state CMK status"
  echo "- GitHub OIDC provider presence"
  echo "- Workload GitHub Plan and Apply roles"
  echo "- GitHub repository trust conditions"
  echo "- GitHub environment subject conditions"
  echo "- GitHub role access to state bucket resources"
  echo "- GitHub role access to \`.tflock\` objects"
  echo "- GitHub role access to the state CMK"
  echo "- GitHub Apply role access to current workload-created Lambda and Secrets Manager CMKs, with stale references treated as advisory unless strict checks are enabled"
  echo
  echo "## Manual Validation Remaining"
  echo
  echo "The automated workload bootstrap validation export is intentionally read-only. The following checks remain outside this report:"
  echo
  echo "- Workload baseline validation"
  echo "- Control-plane validation"
  echo "- GitHub Actions workflow execution validation"
  echo "- IAM Identity Center assignment validation"
  echo "- Live EC2 isolation test"
  echo "- Live EC2 rollback test"
  echo "- Live IP enrichment test"
  echo "- Tamper detection test"
  echo "- Break-glass role assumption test"
  echo "- Destroy safety review"
  echo
  echo "## Evidence Files"
  echo
  echo "This report directory contains the generated workload bootstrap validation summary files and per-script log."
  echo
  echo "| File | Purpose |"
  echo "|---|---|"
  echo "| \`summary.md\` | Human-readable workload bootstrap validation report |"
  echo "| \`summary.json\` | Machine-readable workload bootstrap validation summary |"

  jq -r '
    .results[]
    | "| `\(.log_file)` | Log output for `\(.script)` |"
  ' "$SUMMARY_JSON"

  echo
  echo "## Limitations"
  echo
  echo "This report validates selected workload bootstrap, backend locking, state backend, and GitHub OIDC readiness controls for the target environment."
  echo
  echo "The validation script is read-only and does not run \`terraform init\`, \`terraform apply\`, \`terraform destroy\`, backend migration, role assumption, or live GitHub workflow execution."
  echo
  echo "For fresh checkouts or manual GitHub workflow runs, initialize the remote-backed account and workload stacks before running bootstrap validation:"
  echo
  echo "\`\`\`bash"
  echo "terraform -chdir=bootstrap/${ENV_NAME}/account init -input=false"
  echo "terraform -chdir=environments/${ENV_NAME} init -input=false"
  echo "\`\`\`"
  echo
  echo "This report does not replace a full SOC 2 or ISO 27001 audit, control owner review, policy review, evidence review, risk assessment, or ISMS."
} > "$SUMMARY_MD"

success "Markdown summary written: ${SUMMARY_MD}"

section "Workload Bootstrap Validation Report Export Summary"

echo "Environment:                ${ENV_NAME}"
echo "Validation layer:           Workload Bootstrap"
echo "AWS profile:                ${AWS_PROFILE:-<default>}"
echo "AWS region:                 ${AWS_REGION}"
echo "AWS account ID:             ${AWS_ACCOUNT_ID}"
echo "Cloud name:                 ${CLOUD_NAME}"
echo "Name prefix:                ${NAME_PREFIX}"
echo "Expected GitHub repository: ${EXPECTED_GITHUB_REPOSITORY:-<not set>}"
echo "Require GitHub OIDC:        ${REQUIRE_BOOTSTRAP_GITHUB_OIDC}"
echo "Require GitHub apply role:  ${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE}"
echo "Strict workload CMK checks: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}"
echo "Require local state stack:  ${REQUIRE_STATE_STACK_LOCAL}"
echo "Strict subject checks:      ${STRICT_GITHUB_SUBJECT_CHECKS}"
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
  fail "Workload bootstrap validation report export completed with failures for: ${ENV_NAME}"
fi

success "Workload bootstrap validation report export completed successfully for: ${ENV_NAME}"