#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

SECURITY_OPERATIONS_ENV_NAME="${SECURITY_OPERATIONS_ENV_NAME:-security-operations}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${SECURITY_OPERATIONS_ENV_NAME}}"

WORKLOADS_OU_NAME="${WORKLOADS_OU_NAME:-Workloads}"
WORKLOAD_ACCOUNT_NAMES="${WORKLOAD_ACCOUNT_NAMES:-dev staging prod}"

if [[ -n "${AWS_PROFILE}" ]]; then
  AWS_CREDENTIAL_SOURCE="AWS CLI profile: ${AWS_PROFILE}"
elif [[ "${GITHUB_ACTIONS:-false}" == "true" ]]; then
  AWS_CREDENTIAL_SOURCE="GitHub OIDC environment credentials"
else
  AWS_CREDENTIAL_SOURCE="AWS default credential chain"
fi

# Keep report metadata and the child validator aligned.
export AWS_REGION
export CLOUD_NAME
export WORKLOADS_OU_NAME
export WORKLOAD_ACCOUNT_NAMES

VALIDATION_TIME="$(date +"%Y-%m-%dT%H:%M:%S%:z")"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"

REPO_ROOT="$(get_repo_root)"
OUTPUT_DIR="${REPO_ROOT}/validation-results/security-operations/security-services/${TIMESTAMP}"
RELATIVE_OUTPUT_DIR="validation-results/security-operations/security-services/${TIMESTAMP}"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

mkdir -p "$OUTPUT_DIR"

VALIDATION_SCRIPT="validate-security-operations.sh"
VALIDATION_AREA="Security Operations"
VALIDATION_LAYER="security_operations"

RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$RESULTS_JSONL"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT=1

section "${CLOUD_NAME} Security Operations Validation Report Export"

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
info "Security-operations environment name: ${SECURITY_OPERATIONS_ENV_NAME}"
info "Validation layer: ${VALIDATION_LAYER}"
info "Output dir: ${OUTPUT_DIR}"
info "Cloud name: ${CLOUD_NAME}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<not set>}"
info "AWS credential source: ${AWS_CREDENTIAL_SOURCE}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "WORKLOADS_OU_NAME: ${WORKLOADS_OU_NAME}"
info "WORKLOAD_ACCOUNT_NAMES: ${WORKLOAD_ACCOUNT_NAMES}"
info "Validation time: ${VALIDATION_TIME}"

if [[ "$NAME_PREFIX" != *"-${SECURITY_OPERATIONS_ENV_NAME}" ]]; then
  warn "NAME_PREFIX does not end with -${SECURITY_OPERATIONS_ENV_NAME}: ${NAME_PREFIX}"
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
    success "AWS account ID matches expected security-operations account: ${EXPECTED_ACCOUNT_ID}"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
fi

section "Running security-operations validation"

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
  --arg validation_layer_display "Security Operations" \
  --arg security_operations_environment "$SECURITY_OPERATIONS_ENV_NAME" \
  --arg aws_profile "$AWS_PROFILE" \
  --arg aws_credential_source "$AWS_CREDENTIAL_SOURCE" \
  --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" \
  --arg expected_account_id "$EXPECTED_ACCOUNT_ID" \
  --arg name_prefix "$NAME_PREFIX" \
  --arg workloads_ou_name "$WORKLOADS_OU_NAME" \
  --arg workload_account_names "$WORKLOAD_ACCOUNT_NAMES" \
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
    security_operations_environment: $security_operations_environment,
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
    scripts_total: $scripts_total,
    settings: {
      workloads_ou_name: $workloads_ou_name,
      workload_account_names: $workload_account_names
    },
    results: $results,
    validation_scope: [
      "security_operations_aws_identity",
      "security_services_terraform_outputs",
      "security_services_applied_state",
      "securityhub_trusted_service_access",
      "guardduty_trusted_service_access",
      "guardduty_malware_protection_trusted_service_access",
      "securityhub_delegated_administrator",
      "guardduty_delegated_administrator",
      "securityhub_policy_type_enablement",
      "securityhub_cspm_administrator_state",
      "securityhub_finding_aggregation",
      "securityhub_central_organization_configuration",
      "securityhub_configuration_policies",
      "securityhub_configuration_policy_associations",
      "guardduty_administrator_detector",
      "guardduty_organization_member_enrollment",
      "guardduty_organization_features",
      "guardduty_runtime_monitoring_configuration",
      "securityhub_v2_administrator_state",
      "securityhub_v2_organization_policy",
      "securityhub_v2_workloads_policy_attachment",
      "securityhub_v2_effective_workload_policies"
    ],
    manual_validation_remaining: [
      "control_plane_validation",
      "workload_bootstrap_validation",
      "workload_baseline_validation",
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
  echo "# ${CLOUD_NAME} Security Operations Validation Report"
  echo
  echo "This report summarizes automated read-only validation of centralized security governance from the \`${SECURITY_OPERATIONS_ENV_NAME}\` account."
  echo
  echo "## Executive Summary"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Overall result | **${OVERALL_RESULT}** |"
  echo "| Validation layer | Security Operations |"
  echo "| Validation scripts passed | **${PASSED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Validation scripts failed | **${FAILED_COUNT}/${TOTAL_COUNT}** |"
  echo "| Report Package Location | \`${RELATIVE_OUTPUT_DIR}/\` |"
  echo
  echo "## Security-Operations Environment"
  echo
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Project | ${CLOUD_NAME} |"
  echo "| Security-Operations Environment | ${SECURITY_OPERATIONS_ENV_NAME} |"
  echo "| Validation Layer | Security Operations |"
  echo "| AWS Profile | \`${AWS_PROFILE:-not set}\` |"
  echo "| AWS Credential Source | \`${AWS_CREDENTIAL_SOURCE}\` |"
  echo "| AWS Region | ${AWS_REGION} |"
  echo "| AWS Account ID | ${AWS_ACCOUNT_ID} |"
  echo "| Expected Account ID | \`${EXPECTED_ACCOUNT_ID:-not configured}\` |"
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
  echo "| Workloads OU Name | \`${WORKLOADS_OU_NAME}\` |"
  echo "| Workload Account Names | \`${WORKLOAD_ACCOUNT_NAMES}\` |"
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
  echo "This security-operations validation report covers:"
  echo
  echo "- Security-operations AWS caller identity"
  echo "- Security-services Terraform outputs and applied state"
  echo "- Security Hub and GuardDuty trusted service access required by centralized security"
  echo "- GuardDuty malware-protection trusted service access when applicable"
  echo "- Security Hub and GuardDuty delegated-administrator registration"
  echo "- Security Hub V2 \`SECURITYHUB_POLICY\` enablement prerequisite"
  echo "- Security Hub CSPM administrator state and finding aggregation"
  echo "- Security Hub CSPM CENTRAL organization configuration"
  echo "- Security Hub CSPM configuration policies and workload associations"
  echo "- GuardDuty administrator detector"
  echo "- GuardDuty organization member enrollment"
  echo "- GuardDuty organization protection plans and Runtime Monitoring configuration"
  echo "- Security Hub V2 administrator state"
  echo "- Security Hub V2 organization policy and direct \`${WORKLOADS_OU_NAME}\` attachment"
  echo "- Effective Security Hub V2 policy for configured workload accounts"
  echo
  echo "## Manual Validation Remaining"
  echo
  echo "The automated security-operations validation export is intentionally read-only. The following checks remain outside this report:"
  echo
  echo "- Full control-plane and AWS Organizations topology validation"
  echo "- Workload bootstrap validation"
  echo "- Workload baseline validation"
  echo "- GitHub Actions workflow execution validation"
  echo "- Live EC2 isolation test"
  echo "- Live EC2 rollback test"
  echo "- Live IP enrichment test"
  echo "- Tamper detection test"
  echo "- Break-glass role assumption test"
  echo "- Destroy safety review"
  echo
  echo "## Evidence Files"
  echo
  echo "This report directory contains the generated security-operations validation summary files and per-script log."
  echo
  echo "| File | Purpose |"
  echo "|---|---|"
  echo "| \`summary.md\` | Human-readable security-operations validation report |"
  echo "| \`summary.json\` | Machine-readable security-operations validation summary |"

  jq -r '
    .results[]
    | "| `\(.log_file)` | Log output for `\(.script)` |"
  ' "$SUMMARY_JSON"

  echo
  echo "## Limitations"
  echo
  echo "This report validates selected centralized Security Hub CSPM, GuardDuty, Security Hub V2, and directly required AWS Organizations integration state."
  echo
  echo "It does not validate the complete AWS Organizations topology or account placement; those controls belong to control-plane validation."
  echo
  echo "It also does not validate workload-local realization of centrally governed services; those controls belong to workload validation."
  echo
  echo "The validation script is read-only and does not modify organization policies, delegated administrators, service configuration, workload accounts, or Terraform state."
  echo
  echo "This report does not replace a full SOC 2 or ISO 27001 audit, control owner review, policy review, evidence review, risk assessment, or ISMS."
} > "$SUMMARY_MD"

success "Markdown summary written: ${SUMMARY_MD}"

section "Security Operations Validation Report Export Summary"

echo "Validation layer:           Security Operations"
echo "Security-operations env:    ${SECURITY_OPERATIONS_ENV_NAME}"
echo "AWS profile:                ${AWS_PROFILE:-not set}"
echo "AWS credential source:      ${AWS_CREDENTIAL_SOURCE}"
echo "AWS region:                 ${AWS_REGION}"
echo "AWS account ID:             ${AWS_ACCOUNT_ID}"
echo "Cloud name:                 ${CLOUD_NAME}"
echo "Name prefix:                ${NAME_PREFIX}"
echo "Workloads OU name:          ${WORKLOADS_OU_NAME}"
echo "Workload account names:     ${WORKLOAD_ACCOUNT_NAMES}"
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
  fail "Security operations validation report export completed with failures"
fi

success "Security operations validation report export completed successfully"