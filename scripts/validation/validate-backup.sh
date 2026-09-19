#!/usr/bin/env bash

# validate-backup.sh
#
# Validates AWS Backup resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - effective_backup_enabled, effective_backup_schedule, and
#   effective_delete_backups_after_days match the resolved backup contract
# - AWS caller identity is valid
# - Backup vault exists and remains encrypted regardless of backup enablement
# - Workload EC2 and RDS Backup tags exactly match effective_backup_enabled
# - Backup plan and selection are absent when backups are disabled
# - Backup plan exists when backups are enabled
# - Backup plan schedule, retention, rule name, and target vault exactly match
#   Terraform's effective backup settings
# - Backup selection exists when backups are enabled
# - Backup selection uses the expected Backup=true tag-based selection model
# - Backup service role is configured on the selection
# - Recovery points and recent backup jobs are reported when backups are enabled
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
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME:-unknown}}"
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

section "${CLOUD_NAME} Backup Validation"

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

if ! terraform_output_exists "$OUTPUTS_JSON" effective_backup_enabled; then
  fail "Missing required Terraform output: effective_backup_enabled"
fi

EFFECTIVE_BACKUP_ENABLED="$(
  get_terraform_output_value "$OUTPUTS_JSON" effective_backup_enabled
)"
require_value_in_list \
  "$EFFECTIVE_BACKUP_ENABLED" \
  "true false" \
  "effective_backup_enabled"

# Terraform omits root outputs whose evaluated value is null from
# `terraform output -json`. Treat an absent effective schedule/retention output
# as null so the disabled-state contract can be validated correctly.
if terraform_output_exists "$OUTPUTS_JSON" effective_backup_schedule; then
  EFFECTIVE_BACKUP_SCHEDULE_JSON="$(
    echo "$OUTPUTS_JSON" |
      jq -c '.effective_backup_schedule.value'
  )"
else
  EFFECTIVE_BACKUP_SCHEDULE_JSON="null"
fi

if terraform_output_exists "$OUTPUTS_JSON" effective_delete_backups_after_days; then
  EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON="$(
    echo "$OUTPUTS_JSON" |
      jq -c '.effective_delete_backups_after_days.value'
  )"
else
  EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON="null"
fi

if [[ "$EFFECTIVE_BACKUP_ENABLED" == "true" ]]; then
  if ! echo "$EFFECTIVE_BACKUP_SCHEDULE_JSON" |
    jq -e 'type == "string" and length > 0' >/dev/null; then
    echo "$EFFECTIVE_BACKUP_SCHEDULE_JSON" | jq .
    fail "effective_backup_schedule must be a non-empty string when backups are enabled."
  fi

  if ! echo "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON" |
    jq -e 'type == "number" and . >= 1 and floor == .' >/dev/null; then
    echo "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON" | jq .
    fail "effective_delete_backups_after_days must be a positive integer when backups are enabled."
  fi

  EFFECTIVE_BACKUP_SCHEDULE="$(
    echo "$EFFECTIVE_BACKUP_SCHEDULE_JSON" |
      jq -r '.'
  )"

  EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS="$(
    echo "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON" |
      jq -r '.'
  )"
else
  if [[ "$EFFECTIVE_BACKUP_SCHEDULE_JSON" != "null" ]]; then
    echo "$EFFECTIVE_BACKUP_SCHEDULE_JSON" | jq .
    fail "effective_backup_schedule must be null when backups are disabled."
  fi

  if [[ "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON" != "null" ]]; then
    echo "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS_JSON" | jq .
    fail "effective_delete_backups_after_days must be null when backups are disabled."
  fi

  EFFECTIVE_BACKUP_SCHEDULE="<disabled>"
  EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS="<disabled>"
fi

success "Effective AWS Backup Terraform contract is valid"
info "effective_backup_enabled: ${EFFECTIVE_BACKUP_ENABLED}"
info "effective_backup_schedule: ${EFFECTIVE_BACKUP_SCHEDULE}"
info "effective_delete_backups_after_days: ${EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS}"

EXPECTED_BACKUP_VAULT_NAME="${NAME_PREFIX}-backup-vault"
EXPECTED_BACKUP_PLAN_NAME="${NAME_PREFIX}-backup-plan"
EXPECTED_BACKUP_SELECTION_NAME="${NAME_PREFIX}-backup-selection"
EXPECTED_BACKUP_RULE_NAME="daily-backups"
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

resolve_backup_plan_ids_by_name() {
  local plan_name="$1"

  aws backup list-backup-plans \
    "${aws_args[@]}" \
    --output json |
    jq -c --arg plan_name "$plan_name" '
      [
        .BackupPlansList[]?
        | select(.BackupPlanName == $plan_name)
        | .BackupPlanId
      ]
      | sort
      | unique
    '
}

validate_workload_backup_tags() {
  local expected_value="$1"
  local ec2_response_json
  local ec2_instances_json
  local invalid_ec2_json
  local rds_response_json
  local rds_instances_json
  local invalid_rds_json
  local expected_rds_identifier

  section "Validating workload Backup tags"

  ec2_response_json="$(
    aws ec2 describe-instances \
      "${aws_args[@]}" \
      --filters \
        "Name=tag:Name,Values=${NAME_PREFIX}-EC2-*" \
        "Name=tag:Environment,Values=${ENV_NAME}" \
        "Name=tag:Terraform,Values=true" \
        "Name=instance-state-name,Values=pending,running,stopping,stopped" \
      --output json
  )"

  ec2_instances_json="$(
    echo "$ec2_response_json" |
      jq -c '[.Reservations[].Instances[]?]'
  )"

  ENV_EC2_RESOURCE_COUNT="$(
    echo "$ec2_instances_json" |
      jq 'length'
  )"

  if [[ "$ENV_EC2_RESOURCE_COUNT" -eq 0 ]]; then
    fail "No environment EC2 compute instances were found for Backup tag validation."
  fi

  invalid_ec2_json="$(
    echo "$ec2_instances_json" |
      jq -c \
        --arg expected "$expected_value" '
          [
            .[]
            | {
                instance_id: .InstanceId,
                name: (
                  [
                    .Tags[]?
                    | select(.Key == "Name")
                    | .Value
                  ][0] // "<missing>"
                ),
                backup_tag_values: [
                  .Tags[]?
                  | select(.Key == "Backup")
                  | .Value
                ]
              }
            | select(.backup_tag_values != [$expected])
          ]
        '
  )"

  if [[ "$(echo "$invalid_ec2_json" | jq 'length')" -ne 0 ]]; then
    echo "$invalid_ec2_json" | jq .
    fail "One or more environment EC2 instances do not have Backup=${expected_value}."
  fi

  success "All environment EC2 compute instances have Backup=${expected_value}: ${ENV_EC2_RESOURCE_COUNT}"

  expected_rds_identifier="${NAME_PREFIX}-saas-db"

  rds_response_json="$(
    aws rds describe-db-instances \
      "${aws_args[@]}" \
      --output json
  )"

  rds_instances_json="$(
    echo "$rds_response_json" |
      jq -c \
        --arg identifier "$expected_rds_identifier" '
          [
            .DBInstances[]?
            | select(.DBInstanceIdentifier == $identifier)
          ]
        '
  )"

  ENV_RDS_RESOURCE_COUNT="$(
    echo "$rds_instances_json" |
      jq 'length'
  )"

  if [[ "$ENV_RDS_RESOURCE_COUNT" -ne 1 ]]; then
    echo "$rds_instances_json" | jq .
    fail "Expected exactly one environment RDS instance for Backup tag validation: ${expected_rds_identifier}"
  fi

  invalid_rds_json="$(
    echo "$rds_instances_json" |
      jq -c \
        --arg expected "$expected_value" '
          [
            .[]
            | {
                db_instance_identifier: .DBInstanceIdentifier,
                backup_tag_values: [
                  (.TagList // [])[]?
                  | select(.Key == "Backup")
                  | .Value
                ]
              }
            | select(.backup_tag_values != [$expected])
          ]
        '
  )"

  if [[ "$(echo "$invalid_rds_json" | jq 'length')" -ne 0 ]]; then
    echo "$invalid_rds_json" | jq .
    fail "The environment RDS instance does not have Backup=${expected_value}."
  fi

  success "Environment RDS instance has Backup=${expected_value}: ${expected_rds_identifier}"
}

section "Validating backup vault"

if ! backup_vault_exists "$BACKUP_VAULT_NAME"; then
  fail "Required retained backup vault not found: ${BACKUP_VAULT_NAME}"
fi

success "Backup vault exists as required: $BACKUP_VAULT_NAME"

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

if [[ "$(echo "$BACKUP_VAULT_JSON" | jq -r '.BackupVaultName // empty')" != "$BACKUP_VAULT_NAME" ]]; then
  echo "$BACKUP_VAULT_JSON" | jq '{BackupVaultName, BackupVaultArn, EncryptionKeyArn}'
  fail "Backup vault identity does not match the expected Terraform naming contract."
fi

if [[ -z "$BACKUP_VAULT_ARN" ]]; then
  fail "Backup vault ARN could not be resolved."
fi

if [[ -z "$BACKUP_VAULT_KMS_KEY_ARN" ]]; then
  fail "Backup vault does not report a KMS encryption key."
fi

success "Backup vault ARN and KMS encryption are configured"
info "Backup vault ARN: ${BACKUP_VAULT_ARN}"
info "Backup vault KMS key: ${BACKUP_VAULT_KMS_KEY_ARN}"
info "Vault recovery points reported: ${BACKUP_VAULT_RECOVERY_POINT_COUNT}"

EXPECTED_RESOURCE_BACKUP_TAG_VALUE="$EFFECTIVE_BACKUP_ENABLED"
validate_workload_backup_tags "$EXPECTED_RESOURCE_BACKUP_TAG_VALUE"

LIVE_BACKUP_PLAN_IDS_JSON="$(
  resolve_backup_plan_ids_by_name "$EXPECTED_BACKUP_PLAN_NAME"
)"

LIVE_BACKUP_PLAN_COUNT="$(
  echo "$LIVE_BACKUP_PLAN_IDS_JSON" |
    jq 'length'
)"

section "Validating backup enablement contract"

if [[ "$EFFECTIVE_BACKUP_ENABLED" != "true" ]]; then
  if [[ "$LIVE_BACKUP_PLAN_COUNT" -ne 0 ]]; then
    echo "$LIVE_BACKUP_PLAN_IDS_JSON" | jq .
    fail "Backup plan exists even though effective_backup_enabled=false."
  fi

  success "Backup plan is absent as required while backups are disabled"
  success "Backup selection is absent by construction because no backup plan exists"

  section "Backup Summary"

  cat <<SUMMARY
Environment:                              ${ENV_NAME}
AWS profile:                              ${AWS_PROFILE:-<default>}
AWS region:                               ${AWS_REGION}
AWS account ID:                           ${ACCOUNT_ID}
Name prefix:                              ${NAME_PREFIX}

effective_backup_enabled:                 ${EFFECTIVE_BACKUP_ENABLED}
effective_backup_schedule:                ${EFFECTIVE_BACKUP_SCHEDULE}
effective_delete_backups_after_days:      ${EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS}

Backup validation mode:                   disabled
Retained backup vault:                    ${BACKUP_VAULT_NAME}
Backup vault KMS key ID:                  ${BACKUP_VAULT_KMS_KEY_ID}
Vault recovery points reported:           ${BACKUP_VAULT_RECOVERY_POINT_COUNT}
Backup plan count:                        ${LIVE_BACKUP_PLAN_COUNT}
Expected workload Backup tag value:       ${EXPECTED_RESOURCE_BACKUP_TAG_VALUE}
Environment EC2 resources checked:        ${ENV_EC2_RESOURCE_COUNT}
Environment RDS resources checked:        ${ENV_RDS_RESOURCE_COUNT}
SUMMARY

  section "Validation Result"

  success "Backup disabled-state validation completed successfully for: ${ENV_NAME}"
  exit 0
fi

if [[ "$LIVE_BACKUP_PLAN_COUNT" -ne 1 ]]; then
  echo "$LIVE_BACKUP_PLAN_IDS_JSON" | jq .
  fail "Expected exactly one backup plan when backups are enabled; found ${LIVE_BACKUP_PLAN_COUNT}."
fi

BACKUP_PLAN_ID="$(
  echo "$LIVE_BACKUP_PLAN_IDS_JSON" |
    jq -r '.[0]'
)"

success "Exactly one backup plan exists as required when backups are enabled: ${BACKUP_PLAN_ID}"

section "Validating backup plan"

BACKUP_PLAN_JSON="$(
  aws backup get-backup-plan \
    "${aws_args[@]}" \
    --backup-plan-id "$BACKUP_PLAN_ID" \
    --output json
)"

BACKUP_PLAN_NAME="$(echo "$BACKUP_PLAN_JSON" | jq -r '.BackupPlan.BackupPlanName // empty')"
BACKUP_RULE_COUNT="$(echo "$BACKUP_PLAN_JSON" | jq '.BackupPlan.Rules | length')"

if [[ "$BACKUP_PLAN_NAME" != "$EXPECTED_BACKUP_PLAN_NAME" ]]; then
  echo "$BACKUP_PLAN_JSON" | jq '.BackupPlan | {BackupPlanName, Rules}'
  fail "Backup plan name does not match the expected Terraform naming contract."
fi

if [[ "$BACKUP_RULE_COUNT" -ne 1 ]]; then
  echo "$BACKUP_PLAN_JSON" | jq '.BackupPlan.Rules'
  fail "Expected exactly one backup rule; found ${BACKUP_RULE_COUNT}."
fi

if ! echo "$BACKUP_PLAN_JSON" |
  jq -e \
    --arg rule_name "$EXPECTED_BACKUP_RULE_NAME" \
    --arg vault_name "$BACKUP_VAULT_NAME" \
    --arg schedule "$EFFECTIVE_BACKUP_SCHEDULE" \
    --argjson retention_days "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS" '
      .BackupPlan.Rules[0].RuleName == $rule_name
      and .BackupPlan.Rules[0].TargetBackupVaultName == $vault_name
      and .BackupPlan.Rules[0].ScheduleExpression == $schedule
      and .BackupPlan.Rules[0].Lifecycle.DeleteAfterDays == $retention_days
    ' >/dev/null; then
  jq -n \
    --arg rule_name "$EXPECTED_BACKUP_RULE_NAME" \
    --arg vault_name "$BACKUP_VAULT_NAME" \
    --arg schedule "$EFFECTIVE_BACKUP_SCHEDULE" \
    --argjson retention_days "$EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS" \
    --argjson actual "$(echo "$BACKUP_PLAN_JSON" | jq -c '.BackupPlan.Rules[0]')" '
      {
        expected: {
          RuleName: $rule_name,
          TargetBackupVaultName: $vault_name,
          ScheduleExpression: $schedule,
          DeleteAfterDays: $retention_days
        },
        actual: $actual
      }
    '

  fail "Backup plan rule does not exactly match Terraform's effective backup schedule, retention, rule name, and target vault."
fi

success "Backup plan exactly matches Terraform's effective schedule, retention, rule name, and target vault"

BACKUP_RULE_SUMMARY_ROWS=()

rule_json="$(echo "$BACKUP_PLAN_JSON" | jq -c '.BackupPlan.Rules[0]')"
rule_name="$(echo "$rule_json" | jq -r '.RuleName')"
target_vault="$(echo "$rule_json" | jq -r '.TargetBackupVaultName')"
schedule="$(echo "$rule_json" | jq -r '.ScheduleExpression')"
delete_after="$(echo "$rule_json" | jq -r '.Lifecycle.DeleteAfterDays')"

BACKUP_RULE_SUMMARY_ROWS+=("${rule_name}|${target_vault}|${schedule}|${delete_after}")

section "Validating backup selection"

SELECTIONS_JSON="$(
  aws backup list-backup-selections \
    "${aws_args[@]}" \
    --backup-plan-id "$BACKUP_PLAN_ID" \
    --output json
)"

BACKUP_SELECTION_COUNT="$(echo "$SELECTIONS_JSON" | jq '.BackupSelectionsList | length')"

if [[ "$BACKUP_SELECTION_COUNT" -ne 1 ]]; then
  echo "$SELECTIONS_JSON" | jq '.BackupSelectionsList'
  fail "Expected exactly one backup selection; found ${BACKUP_SELECTION_COUNT}."
fi

success "Exactly one backup selection exists as expected"

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

if [[ "$SELECTION_TAG_MATCH_COUNT" -ne 1 ]]; then
  echo "$BACKUP_SELECTION_JSON" | jq '.BackupSelection'
  fail "Backup selection must contain exactly one ${EXPECTED_BACKUP_TAG_KEY}=${EXPECTED_BACKUP_TAG_VALUE} tag selector."
fi

if ! echo "$BACKUP_SELECTION_JSON" |
  jq -e '
    (.BackupSelection.Resources // []) as $resources
    | (
        ($resources | length) == 0
        or $resources == ["*"]
      )
      and ((.BackupSelection.NotResources // []) | length) == 0
  ' >/dev/null; then
  echo "$BACKUP_SELECTION_JSON" | jq '.BackupSelection'
  fail "Backup selection must use the tag-based selection model without explicit resource or exclusion ARNs."
fi

success "Backup selection uses the expected tag-only filter: ${EXPECTED_BACKUP_TAG_KEY}=${EXPECTED_BACKUP_TAG_VALUE}"

section "Reporting recovery points"

RECOVERY_POINTS_JSON="$(
  aws backup list-recovery-points-by-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)"

RECOVERY_POINT_COUNT="$(echo "$RECOVERY_POINTS_JSON" | jq '.RecoveryPoints | length')"

if [[ "$RECOVERY_POINT_COUNT" -gt 0 ]]; then
  success "Current restorable recovery point(s) found in backup vault: $RECOVERY_POINT_COUNT"
else
  warn "No current restorable recovery points found in backup vault. This is expected immediately after a fresh apply, before the first scheduled backup, or after a destroy/recreate cycle."
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

MISSING_COMPLETED_RECOVERY_POINT_COUNT=0

LATEST_COMPLETED_RECOVERY_POINT_ARNS="$(
  echo "$LATEST_BACKUP_JOBS_JSON" |
    jq -r '
      .[]
      | select(.State == "COMPLETED")
      | select(.RecoveryPointArn != null and .RecoveryPointArn != "")
      | .RecoveryPointArn
    '
)"

while IFS= read -r recovery_point_arn; do
  [[ -z "$recovery_point_arn" ]] && continue

  if aws backup describe-recovery-point \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --recovery-point-arn "$recovery_point_arn" \
    --output json >/dev/null 2>&1; then
    success "Latest completed backup job recovery point is currently restorable: $recovery_point_arn"
  else
    warn "Completed backup job references a recovery point that is not currently found in the vault, likely historical or deleted after destroy/recreate: $recovery_point_arn"
    MISSING_COMPLETED_RECOVERY_POINT_COUNT=$((MISSING_COMPLETED_RECOVERY_POINT_COUNT + 1))
  fi
done <<< "$LATEST_COMPLETED_RECOVERY_POINT_ARNS"

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
Environment:                                        ${ENV_NAME}
AWS profile:                                        ${AWS_PROFILE:-<default>}
AWS region:                                         ${AWS_REGION}
AWS account ID:                                     ${ACCOUNT_ID}
Name prefix:                                        ${NAME_PREFIX}

effective_backup_enabled:                           ${EFFECTIVE_BACKUP_ENABLED}
effective_backup_schedule:                          ${EFFECTIVE_BACKUP_SCHEDULE}
effective_delete_backups_after_days:                 ${EFFECTIVE_DELETE_BACKUPS_AFTER_DAYS}

Backup vault name:                                  ${BACKUP_VAULT_NAME}
Backup vault KMS key ID:                            ${BACKUP_VAULT_KMS_KEY_ID}
Vault recovery points reported:                     ${BACKUP_VAULT_RECOVERY_POINT_COUNT}
Backup plan name:                                   ${BACKUP_PLAN_NAME}
Backup plan ID:                                     ${BACKUP_PLAN_ID}
Backup plan rule count:                             ${BACKUP_RULE_COUNT}
Backup selections:                                  ${BACKUP_SELECTION_COUNT}
Expected selection ID:                              ${EXPECTED_SELECTION_ID}
Backup service role name:                           ${SELECTION_ROLE_NAME}
Expected workload Backup tag value:                 ${EXPECTED_RESOURCE_BACKUP_TAG_VALUE}
Environment EC2 resources checked:                  ${ENV_EC2_RESOURCE_COUNT}
Environment RDS resources checked:                  ${ENV_RDS_RESOURCE_COUNT}
Recovery points listed:                             ${RECOVERY_POINT_COUNT}
Recent backup jobs listed:                          ${BACKUP_JOB_COUNT}
Historical failed backup jobs:                      ${FAILED_BACKUP_JOB_COUNT}
Latest completed backup jobs:                       ${LATEST_COMPLETED_BACKUP_JOB_COUNT}
Historical completed jobs missing recovery points:  ${MISSING_COMPLETED_RECOVERY_POINT_COUNT}
Latest in-progress backup jobs:                     ${LATEST_IN_PROGRESS_BACKUP_JOB_COUNT}
Latest failed backup jobs:                          ${LATEST_FAILED_BACKUP_JOB_COUNT}
Older failed backup jobs:                           ${OLDER_FAILED_BACKUP_JOB_COUNT}
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