#!/usr/bin/env bash

# validate-backup.sh
#
# Validates AWS Backup resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - effective_backup_enabled is respected
# - AWS caller identity is valid
# - Backup vault exists when backups are enabled
# - Backup vault encryption is configured
# - Backup plan exists when backups are enabled
# - Backup plan targets the expected vault
# - Backup selection exists when backups are enabled
# - Backup selection uses the expected tag-based selection model
# - Backup service role is configured on the selection
# - Recovery points and recent backup jobs are reported
#
# Usage:
#   ./scripts/validation/validate-backup.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-backup.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-backup.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-backup.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline Backup Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq found"

require_command git
success "git found"

section "Resolving repository paths and Terraform outputs"

REPO_ROOT="$(get_repo_root)"
ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$ENV_NAME")"

info "Repository root: $REPO_ROOT"
info "Environment: $ENV_NAME"
info "Environment dir: $ENV_DIR"
info "Name prefix: $NAME_PREFIX"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

EFFECTIVE_BACKUP_ENABLED="false"

if terraform_output_exists "$OUTPUTS_JSON" effective_backup_enabled; then
  EFFECTIVE_BACKUP_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_backup_enabled)"
  require_value_in_list "$EFFECTIVE_BACKUP_ENABLED" "true false" "effective_backup_enabled"
  success "effective_backup_enabled is valid: $EFFECTIVE_BACKUP_ENABLED"
else
  warn "Missing Terraform output: effective_backup_enabled. Treating backup validation as optional."
fi

EXPECTED_BACKUP_VAULT_NAME="${NAME_PREFIX}-backup-vault"
EXPECTED_BACKUP_PLAN_NAME="${NAME_PREFIX}-backup-plan"
EXPECTED_BACKUP_SELECTION_NAME="${NAME_PREFIX}-backup-selection"
EXPECTED_BACKUP_TAG_KEY="Backup"
EXPECTED_BACKUP_TAG_VALUE="true"

BACKUP_VAULT_NAME="$EXPECTED_BACKUP_VAULT_NAME"
BACKUP_PLAN_ID=""

if terraform_output_exists "$OUTPUTS_JSON" backup_vault_name; then
  BACKUP_VAULT_NAME="$(get_terraform_output_value "$OUTPUTS_JSON" backup_vault_name)"
  success "backup_vault_name output found: $BACKUP_VAULT_NAME"
else
  info "backup_vault_name output not found. Using expected name: $BACKUP_VAULT_NAME"
fi

if terraform_output_exists "$OUTPUTS_JSON" backup_plan_id; then
  BACKUP_PLAN_ID="$(get_terraform_output_value "$OUTPUTS_JSON" backup_plan_id)"
  success "backup_plan_id output found: $BACKUP_PLAN_ID"
else
  info "backup_plan_id output not found. Will resolve backup plan by name."
fi

section "Checking AWS caller identity"

ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

success "AWS credentials are valid"
info "AWS account ID: $ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

# -----------------------------------------------------------------------------
# Helper functions
# -----------------------------------------------------------------------------

backup_vault_exists() {
  local vault_name="$1"

  aws backup describe-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$vault_name" \
    --output json >/dev/null 2>&1
}

resolve_backup_plan_id_by_name() {
  local plan_name="$1"

  aws backup list-backup-plans \
    "${aws_args[@]}" \
    --output json |
    jq -r --arg plan_name "$plan_name" '
      [
        .BackupPlansList[]
        | select(.BackupPlanName == $plan_name)
        | .BackupPlanId
      ]
      | first // empty
    '
}

section "Handling backup-enabled state"

if [[ "$EFFECTIVE_BACKUP_ENABLED" != "true" ]]; then
  warn "effective_backup_enabled=false. Backup resources are not required for this environment."

  if backup_vault_exists "$BACKUP_VAULT_NAME"; then
    warn "Backup vault exists even though effective_backup_enabled=false: $BACKUP_VAULT_NAME"
  else
    success "No required backup vault validation needed while backups are disabled"
  fi

  if [[ -z "$BACKUP_PLAN_ID" ]]; then
    BACKUP_PLAN_ID="$(resolve_backup_plan_id_by_name "$EXPECTED_BACKUP_PLAN_NAME")"
  fi

  if [[ -n "$BACKUP_PLAN_ID" ]]; then
    warn "Backup plan exists even though effective_backup_enabled=false: $BACKUP_PLAN_ID"
  else
    success "No required backup plan validation needed while backups are disabled"
  fi

  section "Backup Summary"

  cat <<SUMMARY
Environment:                ${ENV_NAME}
AWS profile:                ${AWS_PROFILE:-<default>}
AWS region:                 ${AWS_REGION}
AWS account ID:             ${ACCOUNT_ID}
Name prefix:                ${NAME_PREFIX}

effective_backup_enabled:   ${EFFECTIVE_BACKUP_ENABLED}
Backup validation mode:     optional/skipped
Expected backup vault name: ${EXPECTED_BACKUP_VAULT_NAME}
Expected backup plan name:  ${EXPECTED_BACKUP_PLAN_NAME}
SUMMARY

  section "Validation Result"

  success "Backup validation completed successfully for: ${ENV_NAME}"
  exit 0
fi

section "Validating backup vault"

if ! backup_vault_exists "$BACKUP_VAULT_NAME"; then
  fail "Required backup vault not found: ${BACKUP_VAULT_NAME}"
fi

success "Backup vault exists: $BACKUP_VAULT_NAME"

BACKUP_VAULT_JSON="$(
  aws backup describe-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)"

BACKUP_VAULT_ARN="$(echo "$BACKUP_VAULT_JSON" | jq -r '.BackupVaultArn // empty')"
BACKUP_VAULT_RECOVERY_POINT_COUNT="$(echo "$BACKUP_VAULT_JSON" | jq -r '.NumberOfRecoveryPoints // 0')"
BACKUP_VAULT_KMS_KEY_ARN="$(echo "$BACKUP_VAULT_JSON" | jq -r '.EncryptionKeyArn // empty')"

BACKUP_VAULT_KMS_KEY_ID="${BACKUP_VAULT_KMS_KEY_ARN##*/}"
[[ -z "$BACKUP_VAULT_KMS_KEY_ARN" ]] && BACKUP_VAULT_KMS_KEY_ID="<none>"

if [[ -n "$BACKUP_VAULT_ARN" ]]; then
  success "Backup vault ARN resolved: $BACKUP_VAULT_ARN"
else
  fail "Backup vault ARN could not be resolved"
fi

if [[ -n "$BACKUP_VAULT_KMS_KEY_ARN" ]]; then
  success "Backup vault encryption key configured: $BACKUP_VAULT_KMS_KEY_ARN"
else
  warn "Backup vault encryption key was not returned. Vault may be using default encryption behavior."
fi

info "Vault recovery points reported: $BACKUP_VAULT_RECOVERY_POINT_COUNT"

section "Validating backup plan"

if [[ -z "$BACKUP_PLAN_ID" ]]; then
  BACKUP_PLAN_ID="$(resolve_backup_plan_id_by_name "$EXPECTED_BACKUP_PLAN_NAME")"
fi

if [[ -z "$BACKUP_PLAN_ID" ]]; then
  fail "Required backup plan not found by name: ${EXPECTED_BACKUP_PLAN_NAME}"
fi

success "Backup plan exists: ${EXPECTED_BACKUP_PLAN_NAME} (${BACKUP_PLAN_ID})"

BACKUP_PLAN_JSON="$(
  aws backup get-backup-plan \
    "${aws_args[@]}" \
    --backup-plan-id "$BACKUP_PLAN_ID" \
    --output json
)"

BACKUP_PLAN_NAME="$(echo "$BACKUP_PLAN_JSON" | jq -r '.BackupPlan.BackupPlanName // empty')"
BACKUP_RULE_COUNT="$(echo "$BACKUP_PLAN_JSON" | jq '.BackupPlan.Rules | length')"

if [[ "$BACKUP_PLAN_NAME" == "$EXPECTED_BACKUP_PLAN_NAME" ]]; then
  success "Backup plan name matches expected name: $BACKUP_PLAN_NAME"
else
  warn "Backup plan name does not match expected name. Expected=${EXPECTED_BACKUP_PLAN_NAME}, Actual=${BACKUP_PLAN_NAME}"
fi

if [[ "$BACKUP_RULE_COUNT" -gt 0 ]]; then
  success "Backup plan has rule(s): $BACKUP_RULE_COUNT"
else
  fail "Backup plan has no rules"
fi

RULES_TARGETING_EXPECTED_VAULT="$(
  echo "$BACKUP_PLAN_JSON" |
    jq --arg vault_name "$BACKUP_VAULT_NAME" '
      [
        .BackupPlan.Rules[]
        | select(.TargetBackupVaultName == $vault_name)
      ]
      | length
    '
)"

if [[ "$RULES_TARGETING_EXPECTED_VAULT" -gt 0 ]]; then
  success "Backup plan has rule(s) targeting expected vault: $BACKUP_VAULT_NAME"
else
  echo "$BACKUP_PLAN_JSON" | jq '.BackupPlan.Rules'
  fail "Backup plan does not have a rule targeting expected vault: $BACKUP_VAULT_NAME"
fi

BACKUP_RULE_SUMMARY_ROWS=()

while IFS= read -r rule; do
  [[ -z "$rule" ]] && continue

  rule_name="$(echo "$rule" | jq -r '.RuleName // "unknown"')"
  target_vault="$(echo "$rule" | jq -r '.TargetBackupVaultName // "unknown"')"
  schedule="$(echo "$rule" | jq -r '.ScheduleExpression // "unknown"')"
  delete_after="$(echo "$rule" | jq -r '.Lifecycle.DeleteAfterDays // "none"')"

  if [[ "$schedule" != "unknown" && "$schedule" != "null" ]]; then
    success "Backup rule has schedule: ${rule_name} -> ${schedule}"
  else
    fail "Backup rule is missing schedule expression: ${rule_name}"
  fi

  if [[ "$delete_after" != "none" && "$delete_after" != "null" ]]; then
    success "Backup rule has retention policy: ${rule_name} delete_after=${delete_after} days"
  else
    warn "Backup rule does not have DeleteAfterDays configured: ${rule_name}"
  fi

  BACKUP_RULE_SUMMARY_ROWS+=("${rule_name}|${target_vault}|${schedule}|${delete_after}")
done < <(echo "$BACKUP_PLAN_JSON" | jq -c '.BackupPlan.Rules[]')

section "Validating backup selection"

SELECTIONS_JSON="$(
  aws backup list-backup-selections \
    "${aws_args[@]}" \
    --backup-plan-id "$BACKUP_PLAN_ID" \
    --output json
)"

BACKUP_SELECTION_COUNT="$(echo "$SELECTIONS_JSON" | jq '.BackupSelectionsList | length')"

if [[ "$BACKUP_SELECTION_COUNT" -gt 0 ]]; then
  success "Backup plan has selection(s): $BACKUP_SELECTION_COUNT"
else
  fail "Backup plan has no backup selections"
fi

EXPECTED_SELECTION_ID="$(
  echo "$SELECTIONS_JSON" |
    jq -r --arg selection_name "$EXPECTED_BACKUP_SELECTION_NAME" '
      [
        .BackupSelectionsList[]
        | select(.SelectionName == $selection_name)
        | .SelectionId
      ]
      | first // empty
    '
)"

if [[ -z "$EXPECTED_SELECTION_ID" ]]; then
  echo "$SELECTIONS_JSON" | jq '.BackupSelectionsList'
  fail "Expected backup selection not found: ${EXPECTED_BACKUP_SELECTION_NAME}"
fi

success "Expected backup selection exists: ${EXPECTED_BACKUP_SELECTION_NAME} (${EXPECTED_SELECTION_ID})"

BACKUP_SELECTION_JSON="$(
  aws backup get-backup-selection \
    "${aws_args[@]}" \
    --backup-plan-id "$BACKUP_PLAN_ID" \
    --selection-id "$EXPECTED_SELECTION_ID" \
    --output json
)"

SELECTION_ROLE_ARN="$(echo "$BACKUP_SELECTION_JSON" | jq -r '.BackupSelection.IamRoleArn // empty')"

if [[ -n "$SELECTION_ROLE_ARN" ]]; then
  success "Backup selection has IAM role configured: $SELECTION_ROLE_ARN"
else
  fail "Backup selection IAM role is missing"
fi

if [[ "$SELECTION_ROLE_ARN" == *"backup"* || "$SELECTION_ROLE_ARN" == *"Backup"* ]]; then
  success "Backup selection IAM role appears backup-related"
else
  warn "Backup selection IAM role does not contain 'backup' keyword: $SELECTION_ROLE_ARN"
fi

SELECTION_ROLE_NAME="${SELECTION_ROLE_ARN##*/}"
[[ -z "$SELECTION_ROLE_ARN" ]] && SELECTION_ROLE_NAME="<none>"

SELECTION_TAG_MATCH_COUNT="$(
  echo "$BACKUP_SELECTION_JSON" |
    jq --arg key "$EXPECTED_BACKUP_TAG_KEY" --arg value "$EXPECTED_BACKUP_TAG_VALUE" '
      [
        .BackupSelection.Conditions.StringEquals[]?
        | select(.ConditionKey == $key)
        | select(.ConditionValue == $value)
      ]
      +
      [
        .BackupSelection.ListOfTags[]?
        | select(.ConditionKey == $key)
        | select(.ConditionValue == $value)
      ]
      | length
    '
)"

if [[ "$SELECTION_TAG_MATCH_COUNT" -gt 0 ]]; then
  success "Backup selection uses expected tag filter: ${EXPECTED_BACKUP_TAG_KEY}=${EXPECTED_BACKUP_TAG_VALUE}"
else
  echo "$BACKUP_SELECTION_JSON" | jq '.BackupSelection'
  fail "Backup selection does not clearly use expected tag filter: ${EXPECTED_BACKUP_TAG_KEY}=${EXPECTED_BACKUP_TAG_VALUE}"
fi

section "Reporting tagged backup resources"

TAGGED_EC2_COUNT="$(
  aws ec2 describe-instances \
    "${aws_args[@]}" \
    --filters \
      "Name=tag:${EXPECTED_BACKUP_TAG_KEY},Values=${EXPECTED_BACKUP_TAG_VALUE}" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'length(Reservations[].Instances[])' \
    --output text 2>/dev/null || echo "0"
)"

TAGGED_RDS_COUNT="$(
  aws rds describe-db-instances \
    "${aws_args[@]}" \
    --output json 2>/dev/null |
    jq --arg key "$EXPECTED_BACKUP_TAG_KEY" --arg value "$EXPECTED_BACKUP_TAG_VALUE" '
      [
        .DBInstances[]
        | select(
            (.TagList // [])
            | any(.Key == $key and .Value == $value)
          )
      ]
      | length
    ' 2>/dev/null || echo "0"
)"

info "EC2 instances tagged for backup: ${TAGGED_EC2_COUNT}"
info "RDS instances tagged for backup: ${TAGGED_RDS_COUNT}"

section "Reporting recovery points"

RECOVERY_POINTS_JSON="$(
  aws backup list-recovery-points-by-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)"

RECOVERY_POINT_COUNT="$(echo "$RECOVERY_POINTS_JSON" | jq '.RecoveryPoints | length')"

if [[ "$RECOVERY_POINT_COUNT" -gt 0 ]]; then
  success "Recovery points found in backup vault: $RECOVERY_POINT_COUNT"
else
  warn "No recovery points were returned by list-recovery-points-by-backup-vault. This may be expected before recovery points are indexed, or if recent jobs have not produced visible recovery points yet."
fi

section "Reporting recent backup jobs"

BACKUP_JOBS_JSON="$(
  aws backup list-backup-jobs \
    "${aws_args[@]}" \
    --by-backup-vault-name "$BACKUP_VAULT_NAME" \
    --max-results 25 \
    --output json 2>/dev/null || echo '{"BackupJobs":[]}'
)"

BACKUP_JOB_COUNT="$(echo "$BACKUP_JOBS_JSON" | jq '.BackupJobs | length')"

if [[ "$BACKUP_JOB_COUNT" -gt 0 ]]; then
  success "Recent backup jobs found for vault: $BACKUP_JOB_COUNT"
else
  warn "No recent backup jobs found for vault. This may be expected before the first scheduled backup runs."
fi

FAILED_BACKUP_JOB_COUNT="$(
  echo "$BACKUP_JOBS_JSON" |
    jq '
      [
        .BackupJobs[]
        | select(.State == "FAILED" or .State == "ABORTED" or .State == "EXPIRED")
      ]
      | length
    '
)"

LATEST_BACKUP_JOBS_JSON="$(
  echo "$BACKUP_JOBS_JSON" |
    jq '
      [
        .BackupJobs[]
        | select(.ResourceArn != null and .ResourceArn != "")
      ]
      | group_by(.ResourceArn)
      | map(max_by(.CreationDate // ""))
    '
)"

LATEST_FAILED_BACKUP_JOB_COUNT="$(
  echo "$LATEST_BACKUP_JOBS_JSON" |
    jq '
      [
        .[]
        | select(.State == "FAILED" or .State == "ABORTED" or .State == "EXPIRED")
      ]
      | length
    '
)"

LATEST_IN_PROGRESS_BACKUP_JOB_COUNT="$(
  echo "$LATEST_BACKUP_JOBS_JSON" |
    jq '
      [
        .[]
        | select(.State == "CREATED" or .State == "PENDING" or .State == "RUNNING" or .State == "ABORTING")
      ]
      | length
    '
)"

LATEST_COMPLETED_BACKUP_JOB_COUNT="$(
  echo "$LATEST_BACKUP_JOBS_JSON" |
    jq '
      [
        .[]
        | select(.State == "COMPLETED")
      ]
      | length
    '
)"

OLDER_FAILED_BACKUP_JOB_COUNT="$(
  echo "$BACKUP_JOBS_JSON" |
    jq --argjson latest_jobs "$LATEST_BACKUP_JOBS_JSON" '
      [
        .BackupJobs[]
        | select(.State == "FAILED" or .State == "ABORTED" or .State == "EXPIRED")
        | . as $job
        | select(
            [
              $latest_jobs[]
              | select(
                  .BackupJobId == $job.BackupJobId
                )
            ]
            | length == 0
          )
      ]
      | length
    '
)"

if [[ "$LATEST_FAILED_BACKUP_JOB_COUNT" -eq 0 ]]; then
  success "No latest backup jobs are failed/aborted/expired"

  if [[ "$LATEST_IN_PROGRESS_BACKUP_JOB_COUNT" -gt 0 ]]; then
    warn "Latest backup job(s) still in progress or queued: ${LATEST_IN_PROGRESS_BACKUP_JOB_COUNT}"
    echo "$LATEST_BACKUP_JOBS_JSON" |
      jq '.[] | select(.State == "CREATED" or .State == "PENDING" or .State == "RUNNING" or .State == "ABORTING")'
  fi

  if [[ "$OLDER_FAILED_BACKUP_JOB_COUNT" -gt 0 ]]; then
    warn "Older failed/aborted/expired backup job(s) found, but they are not the latest job for their resource: ${OLDER_FAILED_BACKUP_JOB_COUNT}"
    echo "$BACKUP_JOBS_JSON" |
      jq --argjson latest_jobs "$LATEST_BACKUP_JOBS_JSON" '
        .BackupJobs[]
        | select(.State == "FAILED" or .State == "ABORTED" or .State == "EXPIRED")
        | . as $job
        | select(
            [
              $latest_jobs[]
              | select(.BackupJobId == $job.BackupJobId)
            ]
            | length == 0
          )
      '
  fi
else
  echo "$LATEST_BACKUP_JOBS_JSON" |
    jq '.[] | select(.State == "FAILED" or .State == "ABORTED" or .State == "EXPIRED")'

  fail "Latest backup job failed/aborted/expired for one or more resources: ${LATEST_FAILED_BACKUP_JOB_COUNT}"
fi

section "Backup Summary"

cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
AWS account ID:                     ${ACCOUNT_ID}
Name prefix:                        ${NAME_PREFIX}

effective_backup_enabled:           ${EFFECTIVE_BACKUP_ENABLED}
Backup vault name:                  ${BACKUP_VAULT_NAME}
Backup vault ARN resolved:          true
Backup vault KMS key ID:            ${BACKUP_VAULT_KMS_KEY_ID}
Vault recovery points reported:     ${BACKUP_VAULT_RECOVERY_POINT_COUNT}
Backup plan name:                   ${BACKUP_PLAN_NAME}
Backup plan ID:                     ${BACKUP_PLAN_ID}
Backup plan rule count:             ${BACKUP_RULE_COUNT}
Backup selections:                  ${BACKUP_SELECTION_COUNT}
Expected selection ID:              ${EXPECTED_SELECTION_ID}
Backup service role name:           ${SELECTION_ROLE_NAME}
Tagged EC2 backup resources:        ${TAGGED_EC2_COUNT}
Tagged RDS backup resources:        ${TAGGED_RDS_COUNT}
Recovery points listed:             ${RECOVERY_POINT_COUNT}
Recent backup jobs listed:          ${BACKUP_JOB_COUNT}
Recent failed backup jobs:          ${FAILED_BACKUP_JOB_COUNT}
Latest completed backup jobs:       ${LATEST_COMPLETED_BACKUP_JOB_COUNT}
Latest in-progress backup jobs:     ${LATEST_IN_PROGRESS_BACKUP_JOB_COUNT}
Latest failed backup jobs:          ${LATEST_FAILED_BACKUP_JOB_COUNT}
Older failed backup jobs:           ${OLDER_FAILED_BACKUP_JOB_COUNT}
SUMMARY

if [[ "${#BACKUP_RULE_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Backup plan rules:"
  printf '%s\n' "${BACKUP_RULE_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-24s %-38s %-24s %-14s\n", "RuleName", "TargetVault", "Schedule", "DeleteAfterDays"
        printf "%-24s %-38s %-24s %-14s\n", "--------", "-----------", "--------", "---------------"
      }
      {
        printf "%-24s %-38s %-24s %-14s\n", $1, $2, $3, $4
      }
    '
fi

if [[ "$RECOVERY_POINT_COUNT" -gt 0 ]]; then
  echo
  echo "Recent recovery points:"
  echo "$RECOVERY_POINTS_JSON" |
    jq -r '
      .RecoveryPoints[0:10][]
      | "- " + (.ResourceType // "unknown")
        + " " + (.Status // "unknown")
        + " " + (.CreationDate // "unknown")
        + " " + (.RecoveryPointArn // "unknown")
    '
fi

if [[ "$BACKUP_JOB_COUNT" -gt 0 ]]; then
  echo
  echo "Recent backup jobs:"
  echo "$BACKUP_JOBS_JSON" |
    jq -r '
      .BackupJobs[]
      | "- " + (.ResourceType // "unknown")
        + " " + (.State // "unknown")
        + " created=" + (.CreationDate // "unknown")
        + " start_by=" + (.StartBy // "none")
        + " job=" + (.BackupJobId // "unknown")
    '
fi

section "Validation Result"

success "Backup validation completed successfully for: ${ENV_NAME}"