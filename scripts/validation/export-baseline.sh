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

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"

if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_CREDENTIAL_SOURCE="AWS CLI profile: ${AWS_PROFILE}"
elif [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  AWS_CREDENTIAL_SOURCE="GitHub OIDC environment credentials"
else
  AWS_CREDENTIAL_SOURCE="AWS default credential chain"
fi

VALIDATION_TIME="$(date +"%Y-%m-%dT%H:%M:%S%:z")"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"

REPO_ROOT="$(get_repo_root)"
OUTPUT_DIR="${REPO_ROOT}/validation-results/${ENV_NAME}/baseline/${TIMESTAMP}"
RELATIVE_OUTPUT_DIR="validation-results/${ENV_NAME}/baseline/${TIMESTAMP}"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

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

RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$RESULTS_JSONL"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT="${#VALIDATION_SCRIPTS[@]}"

section "${CLOUD_NAME} Validation Report Export"

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
info "Output dir: ${OUTPUT_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<not set>}"
info "AWS credential source: ${AWS_CREDENTIAL_SOURCE}"
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
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: ${EXPECTED_ACCOUNT_ID}"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
fi

section "Running validation scripts"

for SCRIPT_NAME in "${VALIDATION_SCRIPTS[@]}"; do
  AREA="${VALIDATION_AREAS[$SCRIPT_NAME]:-$SCRIPT_NAME}"
  SCRIPT_PATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
  LOG_FILE="${OUTPUT_DIR}/${SCRIPT_NAME%.sh}.log"
  LOG_BASENAME="$(basename "$LOG_FILE")"
  RESULT="FAIL"

  info "Running ${SCRIPT_NAME}"

  if [[ ! -x "$SCRIPT_PATH" ]]; then
    warn "${SCRIPT_NAME} is missing or not executable"

    {
      echo "[FAIL] Validation script is missing or not executable: ${SCRIPT_PATH}"
    } > "$LOG_FILE"

    FAILED_COUNT=$((FAILED_COUNT + 1))
    RESULT="FAIL"
  elif "$SCRIPT_PATH" "$ENV_NAME" >"$LOG_FILE" 2>&1; then
    success "${SCRIPT_NAME} passed"
    PASSED_COUNT=$((PASSED_COUNT + 1))
    RESULT="PASS"
  else
    warn "${SCRIPT_NAME} failed. See log: ${LOG_FILE}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    RESULT="FAIL"
  fi

  jq -n \
    --arg area "$AREA" \
    --arg script "$SCRIPT_NAME" \
    --arg result "$RESULT" \
    --arg log_file "$LOG_BASENAME" \
    '{
      area: $area,
      script: $script,
      result: $result,
      log_file: $log_file
    }' >> "$RESULTS_JSONL"
done

if [[ "$FAILED_COUNT" -gt 0 ]]; then
  OVERALL_RESULT="FAIL"
else
  OVERALL_RESULT="PASS"
fi

section "Generating JSON summary"

jq -n \
  --arg project "$CLOUD_NAME" \
  --arg environment "$ENV_NAME" \
  --arg aws_profile "$AWS_PROFILE" \
  --arg aws_credential_source "$AWS_CREDENTIAL_SOURCE" \
  --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" \
  --arg expected_account_id "$EXPECTED_ACCOUNT_ID" \
  --arg name_prefix "$NAME_PREFIX" \
  --arg validation_time "$VALIDATION_TIME" \
  --arg overall_result "$OVERALL_RESULT" \
  --argjson scripts_passed "$PASSED_COUNT" \
  --argjson scripts_failed "$FAILED_COUNT" \
  --slurpfile results "$RESULTS_JSONL" \
  '{
    project: $project,
    environment: $environment,
    aws_profile: $aws_profile,
    aws_credential_source: $aws_credential_source,
    aws_region: $aws_region,
    aws_account_id: $aws_account_id,
    expected_account_id: $expected_account_id,
    name_prefix: $name_prefix,
    validation_time: $validation_time,
    overall_result: $overall_result,
    scripts_passed: $scripts_passed,
    scripts_failed: $scripts_failed,
    results: $results,
    manual_validation_remaining: [
      "control_plane",
      "identity_center_assignments",
      "github_actions_workflows",
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
  echo "# ${CLOUD_NAME} Validation Report"
  echo
  echo "This report summarizes automated read-only validation results for the \`$ENV_NAME\` workload environment."
  echo
  echo "## Executive Summary"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Overall result | **${OVERALL_RESULT}** |"
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
  echo "| AWS Profile | \`${AWS_PROFILE:-not set}\` |"
  echo "| AWS Credential Source | \`${AWS_CREDENTIAL_SOURCE}\` |"
  echo "| AWS Region | ${AWS_REGION} |"
  echo "| AWS Account ID | ${AWS_ACCOUNT_ID} |"
  echo "| Expected Account ID | ${EXPECTED_ACCOUNT_ID:-<not set>} |"
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
  echo "## Manual Validation Remaining"
  echo
  echo "The automated validation suite is intentionally read-only. The following checks remain manual:"
  echo
  echo "- Control-plane resource validation"
  echo "- IAM Identity Center assignment validation"
  echo "- GitHub Actions workflow validation"
  echo "- Live EC2 isolation test"
  echo "- Live EC2 rollback test"
  echo "- Live IP enrichment test"
  echo "- Tamper detection test"
  echo "- Break-glass role assumption test"
  echo "- Destroy safety review"
  echo
  echo "## Evidence Files"
  echo
  echo "This report directory contains the generated validation summary files and per-script logs."
  echo
  echo "| File | Purpose |"
  echo "|---|---|"
  echo "| \`summary.md\` | Human-readable validation report |"
  echo "| \`summary.json\` | Machine-readable validation summary |"

  jq -r '
    .results[]
    | "| `\(.log_file)` | Log output for `\(.script)` |"
  ' "$SUMMARY_JSON"

  echo
  echo "## Limitations"
  echo
  echo "This report validates deployed AWS control presence and selected configuration settings for the target workload environment."
  echo
  echo "The validation suite confirms the presence and configuration of selected AWS security controls in the deployed environment."
  echo
  echo "This report does not replace a full SOC 2 or ISO 27001 audit, control owner review, policy review, evidence review, risk assessment, or ISMS."
} > "$SUMMARY_MD"

success "Markdown summary written: ${SUMMARY_MD}"

section "Validation Report Export Summary"

echo "Environment:                ${ENV_NAME}"
echo "AWS profile:                ${AWS_PROFILE:-not set}"
echo "AWS credential source:      ${AWS_CREDENTIAL_SOURCE}"
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
  fail "Validation report export completed with failures for: ${ENV_NAME}"
fi

success "Validation report export completed successfully for: ${ENV_NAME}"