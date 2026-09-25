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
# - Backup vault identity, encryption, and force-destroy posture match Terraform
# - RDS live resilience configuration exactly matches Terraform
# - RDS deletion-time lifecycle intent is resource-backed by Terraform outputs
# - Workload EC2 and RDS Backup tags exactly match effective_backup_enabled
# - Backup plan and selection are absent when backups are disabled
# - Backup plan exists when backups are enabled
# - Backup plan schedule, retention, rule name, and target vault exactly match
#   Terraform's effective backup settings
# - Backup selection exists when backups are enabled
# - Backup selection uses the expected Backup=true tag-based selection model
# - Backup service role is configured on the selection
# - Recovery points and recent backup jobs are reported when backups are enabled
# - Restore Testing configuration exactly matches Terraform when enabled
# - Restore Testing targets the exact Terraform-managed RDS instance
# - RDS Restore Testing uses Terraform-owned private networking metadata
# - Latest Restore Testing execution, validation, and cleanup state are reported
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

for required_output in \
  effective_backup_enabled \
  rds_configuration \
  backup_vault_configuration \
  lifecycle_protection \
  restore_testing; do
  if ! terraform_output_exists "$OUTPUTS_JSON" "$required_output"; then
    fail "Missing required Terraform output: ${required_output}"
  fi
done

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

section "Resolving RDS and Backup vault Terraform contracts"

RDS_CONFIGURATION_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.rds_configuration.value'
)"

if ! echo "$RDS_CONFIGURATION_JSON" |
  jq -e '
    type == "object"
    and (.identifier | type == "string" and length > 0)
    and (.arn | type == "string" and length > 0)
    and ((.multi_az | type) == "boolean")
    and (.db_subnet_group_name | type == "string" and length > 0)
    and (
      (.vpc_security_group_ids | type) == "array"
      and (.vpc_security_group_ids | length) > 0
      and all(.vpc_security_group_ids[]; type == "string" and length > 0)
    )
    and ((.deletion_protection | type) == "boolean")
    and (
      (.backup_retention_period | type) == "number"
      and .backup_retention_period >= 0
      and (.backup_retention_period | floor) == .backup_retention_period
    )
    and ((.publicly_accessible | type) == "boolean")
    and ((.storage_encrypted | type) == "boolean")
    and ((.skip_final_snapshot | type) == "boolean")
    and ((.delete_automated_backups | type) == "boolean")
    and (
      if .skip_final_snapshot
      then .final_snapshot_identifier == null
      else (
        (.final_snapshot_identifier | type) == "string"
        and (.final_snapshot_identifier | length) > 0
      )
      end
    )
  ' >/dev/null; then
  echo "$RDS_CONFIGURATION_JSON" | jq .
  fail "rds_configuration does not contain a complete resource-backed RDS contract."
fi

BACKUP_VAULT_CONFIGURATION_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.backup_vault_configuration.value'
)"

if ! echo "$BACKUP_VAULT_CONFIGURATION_JSON" |
  jq -e '
    type == "object"
    and (.name | type == "string" and length > 0)
    and (.arn | type == "string" and length > 0)
    and (.kms_key_arn | type == "string" and length > 0)
    and ((.force_destroy | type) == "boolean")
  ' >/dev/null; then
  echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq .
  fail "backup_vault_configuration does not contain a complete resource-backed vault contract."
fi

LIFECYCLE_PROTECTION_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.lifecycle_protection.value'
)"

if ! echo "$LIFECYCLE_PROTECTION_JSON" |
  jq -e '
    type == "object"
    and ((.rds_deletion_protection | type) == "boolean")
    and ((.backup_vault_force_destroy | type) == "boolean")
  ' >/dev/null; then
  echo "$LIFECYCLE_PROTECTION_JSON" | jq .
  fail "lifecycle_protection lacks the RDS or Backup vault lifecycle fields required by validation."
fi

EXPECTED_RDS_IDENTIFIER="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.identifier')"
EXPECTED_RDS_ARN="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.arn')"
EXPECTED_RDS_MULTI_AZ="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.multi_az')"
EXPECTED_RDS_DB_SUBNET_GROUP_NAME="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.db_subnet_group_name')"
EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON="$(
  echo "$RDS_CONFIGURATION_JSON" |
    jq -c '.vpc_security_group_ids | sort | unique'
)"
EXPECTED_RDS_DELETION_PROTECTION="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.deletion_protection')"
EXPECTED_RDS_BACKUP_RETENTION_PERIOD="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.backup_retention_period')"
EXPECTED_RDS_PUBLICLY_ACCESSIBLE="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.publicly_accessible')"
EXPECTED_RDS_STORAGE_ENCRYPTED="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.storage_encrypted')"
EXPECTED_RDS_SKIP_FINAL_SNAPSHOT="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.skip_final_snapshot')"
EXPECTED_RDS_DELETE_AUTOMATED_BACKUPS="$(echo "$RDS_CONFIGURATION_JSON" | jq -r '.delete_automated_backups')"
EXPECTED_RDS_FINAL_SNAPSHOT_IDENTIFIER="$(
  echo "$RDS_CONFIGURATION_JSON" |
    jq -r '.final_snapshot_identifier // "<none>"'
)"

EXPECTED_BACKUP_VAULT_NAME="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.name')"
EXPECTED_BACKUP_VAULT_ARN="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.arn')"
EXPECTED_BACKUP_VAULT_KMS_KEY_ARN="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.kms_key_arn')"
EXPECTED_BACKUP_VAULT_FORCE_DESTROY="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.force_destroy')"

EXPECTED_LIFECYCLE_RDS_DELETION_PROTECTION="$(
  echo "$LIFECYCLE_PROTECTION_JSON" |
    jq -r '.rds_deletion_protection'
)"
EXPECTED_LIFECYCLE_BACKUP_VAULT_FORCE_DESTROY="$(
  echo "$LIFECYCLE_PROTECTION_JSON" |
    jq -r '.backup_vault_force_destroy'
)"

if [[ "$EXPECTED_RDS_DELETION_PROTECTION" != "$EXPECTED_LIFECYCLE_RDS_DELETION_PROTECTION" ]]; then
  jq -n \
    --arg rds_configuration "$EXPECTED_RDS_DELETION_PROTECTION" \
    --arg lifecycle_protection "$EXPECTED_LIFECYCLE_RDS_DELETION_PROTECTION" '
      {
        rds_configuration_deletion_protection: $rds_configuration,
        lifecycle_protection_rds_deletion_protection: $lifecycle_protection
      }
    '
  fail "RDS deletion protection disagrees between rds_configuration and lifecycle_protection."
fi

if [[ "$EXPECTED_BACKUP_VAULT_FORCE_DESTROY" != "$EXPECTED_LIFECYCLE_BACKUP_VAULT_FORCE_DESTROY" ]]; then
  jq -n \
    --arg backup_vault_configuration "$EXPECTED_BACKUP_VAULT_FORCE_DESTROY" \
    --arg lifecycle_protection "$EXPECTED_LIFECYCLE_BACKUP_VAULT_FORCE_DESTROY" '
      {
        backup_vault_configuration_force_destroy: $backup_vault_configuration,
        lifecycle_protection_backup_vault_force_destroy: $lifecycle_protection
      }
    '
  fail "Backup vault force_destroy disagrees between backup_vault_configuration and lifecycle_protection."
fi

success "RDS and Backup vault Terraform contracts are valid and lifecycle-consistent"
info "RDS identifier: ${EXPECTED_RDS_IDENTIFIER}"
info "RDS Multi-AZ: ${EXPECTED_RDS_MULTI_AZ}"
info "RDS deletion protection: ${EXPECTED_RDS_DELETION_PROTECTION}"
info "RDS skip final snapshot: ${EXPECTED_RDS_SKIP_FINAL_SNAPSHOT}"
info "RDS delete automated backups: ${EXPECTED_RDS_DELETE_AUTOMATED_BACKUPS}"
info "Backup vault force_destroy: ${EXPECTED_BACKUP_VAULT_FORCE_DESTROY}"

section "Resolving Restore Testing Terraform contract"

RESTORE_TESTING_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.restore_testing.value'
)"

if ! echo "$RESTORE_TESTING_JSON" |
  jq -e 'type == "object" and (.enabled | type == "boolean")' >/dev/null; then
  echo "$RESTORE_TESTING_JSON" | jq .
  fail "restore_testing must be an object with a boolean enabled field."
fi

RESTORE_TESTING_ENABLED="$(
  echo "$RESTORE_TESTING_JSON" |
    jq -r '.enabled'
)"

require_value_in_list \
  "$RESTORE_TESTING_ENABLED" \
  "true false" \
  "restore_testing.enabled"

# Summary defaults. Enabled deployments overwrite these with Terraform/live AWS
# values during Restore Testing validation.
RESTORE_TESTING_PLAN_NAME="<disabled>"
RESTORE_TESTING_PLAN_ARN="<none>"
RESTORE_TESTING_SCHEDULE="<disabled>"
RESTORE_TESTING_START_WINDOW_HOURS="<disabled>"
RESTORE_TESTING_SELECTION_WINDOW_DAYS="<disabled>"
RESTORE_TESTING_SELECTION_NAME="<disabled>"
RESTORE_TESTING_PROTECTED_RESOURCE_ARN="<none>"
RESTORE_TESTING_VALIDATION_WINDOW_HOURS="<disabled>"
RESTORE_TEST_JOB_COUNT=0
LATEST_RESTORE_TEST_JOB_ID="<none>"
LATEST_RESTORE_TEST_STATUS="<none>"
LATEST_RESTORE_TEST_RECOVERY_POINT_ARN="<none>"
LATEST_RESTORE_TEST_CREATED_RESOURCE_ARN="<none>"
LATEST_RESTORE_TEST_COMPLETION_TIME="<none>"
LATEST_RESTORE_TEST_VALIDATION_STATUS="<none>"
LATEST_RESTORE_TEST_DELETION_STATUS="<none>"

if [[ "$RESTORE_TESTING_ENABLED" == "true" ]]; then
  if [[ "$EFFECTIVE_BACKUP_ENABLED" != "true" ]]; then
    echo "$RESTORE_TESTING_JSON" | jq .
    fail "Restore Testing cannot be enabled when effective_backup_enabled=false."
  fi

  if ! echo "$RESTORE_TESTING_JSON" |
    jq -e '
      (.schedule | type == "string" and length > 0)
      and (.start_window_hours | type == "number" and . >= 1 and floor == .)
      and (.selection_window_days | type == "number" and . >= 1 and floor == .)
      and (.validation_window_hours | type == "number" and . >= 1 and floor == .)
      and (.plan | type == "object")
      and (.plan.name | type == "string" and length > 0)
      and (.plan.arn | type == "string" and length > 0)
      and (.plan.schedule_expression == .schedule)
      and (.plan.start_window_hours == .start_window_hours)
      and (
        .plan.recovery_point_selection as $selection
        | (
            ($selection | type == "array" and length == 1)
            or ($selection | type == "object")
          )
      )
      and (.selection | type == "object")
      and (.selection.name | type == "string" and length > 0)
      and (.selection.restore_testing_plan_name == .plan.name)
      and (.selection.protected_resource_type | type == "string" and length > 0)
      and (.selection.protected_resource_arns | type == "array" and length == 1)
      and (.selection.iam_role_arn | type == "string" and length > 0)
      and (.selection.restore_metadata_overrides | type == "object")
      and (.selection.validation_window_hours == .validation_window_hours)
    ' >/dev/null; then
    echo "$RESTORE_TESTING_JSON" | jq .
    fail "Enabled restore_testing output does not contain a complete resource-backed contract."
  fi

  RESTORE_TESTING_PLAN_NAME="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.plan.name'
  )"
  RESTORE_TESTING_PLAN_ARN="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.plan.arn'
  )"
  RESTORE_TESTING_SCHEDULE="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.schedule'
  )"
  RESTORE_TESTING_START_WINDOW_HOURS="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.start_window_hours'
  )"
  RESTORE_TESTING_SELECTION_WINDOW_DAYS="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.selection_window_days'
  )"
  RESTORE_TESTING_SELECTION_NAME="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.selection.name'
  )"
  RESTORE_TESTING_PROTECTED_RESOURCE_ARN="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.selection.protected_resource_arns[0]'
  )"
  RESTORE_TESTING_VALIDATION_WINDOW_HOURS="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -r '.validation_window_hours'
  )"

  success "Enabled Restore Testing Terraform contract is complete"
else
  if ! echo "$RESTORE_TESTING_JSON" |
    jq -e '
      .schedule == null
      and .start_window_hours == null
      and .selection_window_days == null
      and .validation_window_hours == null
      and .plan == null
      and .selection == null
    ' >/dev/null; then
    echo "$RESTORE_TESTING_JSON" | jq .
    fail "Disabled restore_testing contract must contain null policy/resource values."
  fi

  success "Restore Testing is disabled by the Terraform contract"
fi

info "restore_testing.enabled: ${RESTORE_TESTING_ENABLED}"
info "restore_testing.schedule: ${RESTORE_TESTING_SCHEDULE}"
info "restore_testing.plan: ${RESTORE_TESTING_PLAN_NAME}"
info "restore_testing.selection: ${RESTORE_TESTING_SELECTION_NAME}"

EXPECTED_BACKUP_PLAN_NAME="${NAME_PREFIX}-backup-plan"
EXPECTED_BACKUP_SELECTION_NAME="${NAME_PREFIX}-backup-selection"
EXPECTED_BACKUP_RULE_NAME="daily-backups"
EXPECTED_BACKUP_TAG_KEY="Backup"
EXPECTED_BACKUP_TAG_VALUE="true"

BACKUP_VAULT_NAME="$EXPECTED_BACKUP_VAULT_NAME"
BACKUP_PLAN_ID=""

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

validate_rds_configuration_live() {
  local rds_instance_json="$1"
  local actual_rds_vpc_security_group_ids_json

  section "Validating exact RDS resilience configuration"

  actual_rds_vpc_security_group_ids_json="$(
    echo "$rds_instance_json" |
      jq -c '[.VpcSecurityGroups[]?.VpcSecurityGroupId] | sort | unique'
  )"

  if ! echo "$rds_instance_json" |
    jq -e \
      --arg identifier "$EXPECTED_RDS_IDENTIFIER" \
      --arg arn "$EXPECTED_RDS_ARN" \
      --arg subnet_group "$EXPECTED_RDS_DB_SUBNET_GROUP_NAME" \
      --argjson expected_vpc_security_group_ids "$EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON" \
      --argjson multi_az "$EXPECTED_RDS_MULTI_AZ" \
      --argjson deletion_protection "$EXPECTED_RDS_DELETION_PROTECTION" \
      --argjson backup_retention_period "$EXPECTED_RDS_BACKUP_RETENTION_PERIOD" \
      --argjson publicly_accessible "$EXPECTED_RDS_PUBLICLY_ACCESSIBLE" \
      --argjson storage_encrypted "$EXPECTED_RDS_STORAGE_ENCRYPTED" '
        .DBInstanceIdentifier == $identifier
        and .DBInstanceArn == $arn
        and .MultiAZ == $multi_az
        and .DBSubnetGroup.DBSubnetGroupName == $subnet_group
        and (
          ([.VpcSecurityGroups[]?.VpcSecurityGroupId] | sort | unique)
          == $expected_vpc_security_group_ids
        )
        and .DeletionProtection == $deletion_protection
        and .BackupRetentionPeriod == $backup_retention_period
        and .PubliclyAccessible == $publicly_accessible
        and .StorageEncrypted == $storage_encrypted
      ' >/dev/null; then
    jq -n \
      --argjson expected "$RDS_CONFIGURATION_JSON" \
      --argjson actual "$(
        echo "$rds_instance_json" |
          jq -c '{
            identifier: .DBInstanceIdentifier,
            arn: .DBInstanceArn,
            multi_az: .MultiAZ,
            db_subnet_group_name: .DBSubnetGroup.DBSubnetGroupName,
            vpc_security_group_ids: ([.VpcSecurityGroups[]?.VpcSecurityGroupId] | sort | unique),
            deletion_protection: .DeletionProtection,
            backup_retention_period: .BackupRetentionPeriod,
            publicly_accessible: .PubliclyAccessible,
            storage_encrypted: .StorageEncrypted
          }'
      )" '
        {
          expected_rds_configuration: $expected,
          live_rds_configuration: $actual
        }
      '
    fail "Live RDS resilience configuration does not exactly match Terraform."
  fi

  if [[ "$actual_rds_vpc_security_group_ids_json" != "$EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON" ]]; then
    fail "Live RDS VPC security-group set does not exactly match Terraform."
  fi

  success "Live RDS resilience configuration exactly matches Terraform"
  success "Terraform-owned RDS deletion-time lifecycle intent is resource-backed and internally consistent"
  info "RDS skip_final_snapshot: ${EXPECTED_RDS_SKIP_FINAL_SNAPSHOT}"
  info "RDS delete_automated_backups: ${EXPECTED_RDS_DELETE_AUTOMATED_BACKUPS}"
  info "RDS final_snapshot_identifier: ${EXPECTED_RDS_FINAL_SNAPSHOT_IDENTIFIER}"
}

validate_workload_backup_tags() {
  local expected_value="$1"
  local ec2_response_json
  local ec2_instances_json
  local invalid_ec2_json
  local rds_response_json
  local rds_instances_json
  local invalid_rds_json
  local rds_instance_json

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

  if ! rds_response_json="$(
    aws rds describe-db-instances \
      "${aws_args[@]}" \
      --db-instance-identifier "$EXPECTED_RDS_IDENTIFIER" \
      --output json 2>/dev/null
  )"; then
    fail "Terraform expects RDS instance ${EXPECTED_RDS_IDENTIFIER}, but it could not be described in live AWS."
  fi

  rds_instances_json="$(
    echo "$rds_response_json" |
      jq -c '.DBInstances // []'
  )"

  ENV_RDS_RESOURCE_COUNT="$(
    echo "$rds_instances_json" |
      jq 'length'
  )"

  if [[ "$ENV_RDS_RESOURCE_COUNT" -ne 1 ]]; then
    echo "$rds_instances_json" | jq .
    fail "Expected exactly one live RDS instance for Terraform identifier: ${EXPECTED_RDS_IDENTIFIER}"
  fi

  rds_instance_json="$(
    echo "$rds_instances_json" |
      jq -c '.[0]'
  )"

  ENV_RDS_ARN="$(
    echo "$rds_instance_json" |
      jq -r '.DBInstanceArn // empty'
  )"

  if [[ "$ENV_RDS_ARN" != "$EXPECTED_RDS_ARN" ]]; then
    jq -n \
      --arg expected "$EXPECTED_RDS_ARN" \
      --arg actual "$ENV_RDS_ARN" '
        {
          expected_rds_arn: $expected,
          live_rds_arn: $actual
        }
      '
    fail "Live RDS ARN does not match rds_configuration."
  fi

  validate_rds_configuration_live "$rds_instance_json"

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

  success "Environment RDS instance has Backup=${expected_value}: ${EXPECTED_RDS_IDENTIFIER}"
}

validate_restore_testing_live() {
  section "Validating AWS Backup Restore Testing"

  if [[ "$RESTORE_TESTING_ENABLED" != "true" ]]; then
    success "Restore Testing is disabled by Terraform; no live Restore Testing configuration is required."
    return 0
  fi

  local expected_plan_recovery_selection_json
  local expected_selection_json
  local expected_metadata_json
  local restore_testing_plan_response_json
  local live_plan_json
  local restore_testing_selection_response_json
  local live_selection_json
  local restore_jobs_json
  local latest_restore_job_json

  expected_plan_recovery_selection_json="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -c '
        .plan.recovery_point_selection
        | if type == "array" then .[0] else . end
      '
  )"

  expected_selection_json="$(
    echo "$RESTORE_TESTING_JSON" |
      jq -c '.selection'
  )"

  expected_metadata_json="$(
    echo "$expected_selection_json" |
      jq -c '.restore_metadata_overrides'
  )"

  if ! echo "$expected_metadata_json" |
    jq -e \
      --arg subnet_group "$EXPECTED_RDS_DB_SUBNET_GROUP_NAME" \
      --argjson vpc_security_group_ids "$EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON" '
        .dbSubnetGroupName == $subnet_group
        and (
          (.vpcSecurityGroupIds | fromjson | sort | unique)
          == $vpc_security_group_ids
        )
        and (.publiclyAccessible | ascii_downcase) == "false"
        and (.multiAz | ascii_downcase) == "false"
      ' >/dev/null; then
    jq -n \
      --arg expected_subnet_group "$EXPECTED_RDS_DB_SUBNET_GROUP_NAME" \
      --argjson expected_vpc_security_group_ids "$EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON" \
      --argjson restore_metadata "$expected_metadata_json" '
        {
          expected_source_rds_subnet_group: $expected_subnet_group,
          expected_source_rds_vpc_security_group_ids: $expected_vpc_security_group_ids,
          restore_testing_metadata: $restore_metadata
        }
      '
    fail "Restore Testing private-network metadata does not align with rds_configuration."
  fi

  success "Restore Testing private-network metadata aligns with the Terraform-owned RDS configuration"

  # Cross-resource Terraform/live relationship: the Restore Testing contract
  # must target the exact RDS instance already resolved by this validator.
  if [[ "$RESTORE_TESTING_PROTECTED_RESOURCE_ARN" != "$ENV_RDS_ARN" ]]; then
    jq -n \
      --arg terraform_restore_target "$RESTORE_TESTING_PROTECTED_RESOURCE_ARN" \
      --arg live_environment_rds "$ENV_RDS_ARN" \
      '{
        terraform_restore_target: $terraform_restore_target,
        live_environment_rds: $live_environment_rds
      }'
    fail "Restore Testing does not target the exact live Terraform-managed RDS instance."
  fi

  restore_testing_plan_response_json="$(
    aws backup get-restore-testing-plan \
      "${aws_args[@]}" \
      --restore-testing-plan-name "$RESTORE_TESTING_PLAN_NAME" \
      --output json
  )"

  live_plan_json="$(
    echo "$restore_testing_plan_response_json" |
      jq -c '.RestoreTestingPlan'
  )"

  if ! echo "$live_plan_json" |
    jq -e \
      --arg expected_name "$RESTORE_TESTING_PLAN_NAME" \
      --arg expected_arn "$RESTORE_TESTING_PLAN_ARN" \
      --arg expected_schedule "$RESTORE_TESTING_SCHEDULE" \
      --argjson expected_start_window "$RESTORE_TESTING_START_WINDOW_HOURS" \
      --argjson expected_recovery_selection "$expected_plan_recovery_selection_json" \
      --arg backup_vault_arn "$BACKUP_VAULT_ARN" '
        def sorted_strings:
          if . == null then [] else sort end;

        .RestoreTestingPlanName == $expected_name
        and .RestoreTestingPlanArn == $expected_arn
        and .ScheduleExpression == $expected_schedule
        and .StartWindowHours == $expected_start_window
        and .RecoveryPointSelection.Algorithm
          == $expected_recovery_selection.algorithm
        and (
          (.RecoveryPointSelection.IncludeVaults | sorted_strings)
          == ($expected_recovery_selection.include_vaults | sorted_strings)
        )
        and (
          (.RecoveryPointSelection.IncludeVaults | sorted_strings)
          == ([$backup_vault_arn] | sorted_strings)
        )
        and (
          (.RecoveryPointSelection.RecoveryPointTypes | sorted_strings)
          == ($expected_recovery_selection.recovery_point_types | sorted_strings)
        )
        and .RecoveryPointSelection.SelectionWindowDays
          == $expected_recovery_selection.selection_window_days
      ' >/dev/null; then
    jq -n \
      --argjson expected "$RESTORE_TESTING_JSON" \
      --argjson actual "$live_plan_json" '
        {
          expected_restore_testing: $expected,
          actual_restore_testing_plan: $actual
        }
      '
    fail "Live Restore Testing plan does not exactly match Terraform."
  fi

  success "Live Restore Testing plan exactly matches Terraform"

  restore_testing_selection_response_json="$(
    aws backup get-restore-testing-selection \
      "${aws_args[@]}" \
      --restore-testing-plan-name "$RESTORE_TESTING_PLAN_NAME" \
      --restore-testing-selection-name "$RESTORE_TESTING_SELECTION_NAME" \
      --output json
  )"

  live_selection_json="$(
    echo "$restore_testing_selection_response_json" |
      jq -c '.RestoreTestingSelection'
  )"

  if ! echo "$live_selection_json" |
    jq -e \
      --argjson expected "$expected_selection_json" \
      --argjson expected_metadata "$expected_metadata_json" '
        def normalize_metadata:
          with_entries(.key |= ascii_downcase)
          | if has("vpcsecuritygroupids") then
              .vpcsecuritygroupids = (
                .vpcsecuritygroupids
                | fromjson
                | sort
                | tojson
              )
            else .
            end
          | if has("publiclyaccessible") then
              .publiclyaccessible |= ascii_downcase
            else .
            end
          | if has("multiaz") then
              .multiaz |= ascii_downcase
            else .
            end;

        .RestoreTestingSelectionName == $expected.name
        and .RestoreTestingPlanName == $expected.restore_testing_plan_name
        and .ProtectedResourceType == $expected.protected_resource_type
        and ((.ProtectedResourceArns // [] | sort)
          == ($expected.protected_resource_arns // [] | sort))
        and .IamRoleArn == $expected.iam_role_arn
        and .ValidationWindowHours == $expected.validation_window_hours
        and (
          (.RestoreMetadataOverrides // {} | normalize_metadata)
          == ($expected_metadata | normalize_metadata)
        )
      ' >/dev/null; then
    jq -n \
      --argjson expected "$expected_selection_json" \
      --argjson actual "$live_selection_json" '
        {
          expected_restore_testing_selection: $expected,
          actual_restore_testing_selection: $actual
        }
      '
    fail "Live Restore Testing selection does not exactly match Terraform."
  fi

  success "Live Restore Testing selection exactly matches Terraform"
  success "Restore Testing uses the exact RDS ARN, Backup role, and Terraform-owned private restore metadata"

  section "Reporting Restore Testing execution state"

  restore_jobs_json="$(
    aws backup list-restore-jobs \
      "${aws_args[@]}" \
      --by-restore-testing-plan-arn "$RESTORE_TESTING_PLAN_ARN" \
      --output json
  )"

  RESTORE_TEST_JOB_COUNT="$(
    echo "$restore_jobs_json" |
      jq '.RestoreJobs | length'
  )"

  latest_restore_job_json="$(
    echo "$restore_jobs_json" |
      jq -c '
        [.RestoreJobs[]?]
        | sort_by(.CreationDate // "")
        | last // null
      '
  )"

  if [[ "$latest_restore_job_json" == "null" ]]; then
    warn "No Restore Testing jobs exist yet. Configuration is valid, but live restore qualification has not occurred."
    return 0
  fi

  LATEST_RESTORE_TEST_JOB_ID="$(
    echo "$latest_restore_job_json" |
      jq -r '.RestoreJobId // "<none>"'
  )"
  LATEST_RESTORE_TEST_STATUS="$(
    echo "$latest_restore_job_json" |
      jq -r '.Status // "<none>"'
  )"
  LATEST_RESTORE_TEST_RECOVERY_POINT_ARN="$(
    echo "$latest_restore_job_json" |
      jq -r '.RecoveryPointArn // "<none>"'
  )"
  LATEST_RESTORE_TEST_CREATED_RESOURCE_ARN="$(
    echo "$latest_restore_job_json" |
      jq -r '.CreatedResourceArn // "<none>"'
  )"
  LATEST_RESTORE_TEST_COMPLETION_TIME="$(
    echo "$latest_restore_job_json" |
      jq -r '.CompletionDate // "<none>"'
  )"
  LATEST_RESTORE_TEST_VALIDATION_STATUS="$(
    echo "$latest_restore_job_json" |
      jq -r '.ValidationStatus // "<none>"'
  )"
  LATEST_RESTORE_TEST_DELETION_STATUS="$(
    echo "$latest_restore_job_json" |
      jq -r '.DeletionStatus // "<none>"'
  )"

  case "$LATEST_RESTORE_TEST_STATUS" in
    COMPLETED)
      success "Latest Restore Testing job completed successfully: ${LATEST_RESTORE_TEST_JOB_ID}"
      ;;
    PENDING|RUNNING)
      warn "Latest Restore Testing job is still ${LATEST_RESTORE_TEST_STATUS}: ${LATEST_RESTORE_TEST_JOB_ID}"
      ;;
    FAILED|ABORTED)
      echo "$latest_restore_job_json" | jq .
      fail "Latest Restore Testing job is ${LATEST_RESTORE_TEST_STATUS}: ${LATEST_RESTORE_TEST_JOB_ID}"
      ;;
    *)
      echo "$latest_restore_job_json" | jq .
      warn "Latest Restore Testing job has an unexpected status: ${LATEST_RESTORE_TEST_STATUS}"
      ;;
  esac

  case "$LATEST_RESTORE_TEST_VALIDATION_STATUS" in
    FAILED|TIMED_OUT)
      warn "Latest Restore Testing validation status is ${LATEST_RESTORE_TEST_VALIDATION_STATUS}; R6.4 reports this state but does not enforce application-level validation."
      ;;
    VALIDATING)
      warn "Latest Restore Testing validation is still in progress."
      ;;
    SUCCESSFUL)
      success "Latest Restore Testing validation status is SUCCESSFUL"
      ;;
    "<none>")
      info "Latest Restore Testing job has no validation result yet."
      ;;
    *)
      warn "Latest Restore Testing validation status is unexpected: ${LATEST_RESTORE_TEST_VALIDATION_STATUS}"
      ;;
  esac

  case "$LATEST_RESTORE_TEST_DELETION_STATUS" in
    FAILED)
      warn "Restore Testing cleanup reports FAILED. R6.5 live qualification must resolve and prove cleanup."
      ;;
    DELETING)
      warn "Restore Testing temporary resource cleanup is still in progress."
      ;;
    SUCCESSFUL)
      success "Restore Testing reports successful cleanup of the temporary restored resource"
      ;;
    "<none>")
      info "Latest Restore Testing job has no deletion status yet."
      ;;
    *)
      warn "Latest Restore Testing deletion status is unexpected: ${LATEST_RESTORE_TEST_DELETION_STATUS}"
      ;;
  esac

  info "Latest Restore Testing recovery point: ${LATEST_RESTORE_TEST_RECOVERY_POINT_ARN}"
  info "Latest Restore Testing created resource: ${LATEST_RESTORE_TEST_CREATED_RESOURCE_ARN}"
  info "Latest Restore Testing completion time: ${LATEST_RESTORE_TEST_COMPLETION_TIME}"
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

if ! echo "$BACKUP_VAULT_JSON" |
  jq -e \
    --arg name "$EXPECTED_BACKUP_VAULT_NAME" \
    --arg arn "$EXPECTED_BACKUP_VAULT_ARN" \
    --arg kms_key_arn "$EXPECTED_BACKUP_VAULT_KMS_KEY_ARN" '
      .BackupVaultName == $name
      and .BackupVaultArn == $arn
      and .EncryptionKeyArn == $kms_key_arn
    ' >/dev/null; then
  jq -n \
    --argjson expected "$BACKUP_VAULT_CONFIGURATION_JSON" \
    --argjson actual "$(
      echo "$BACKUP_VAULT_JSON" |
        jq -c '{
          name: .BackupVaultName,
          arn: .BackupVaultArn,
          kms_key_arn: .EncryptionKeyArn
        }'
    )" '
      {
        expected_backup_vault_configuration: $expected,
        live_backup_vault_configuration: $actual
      }
    '
  fail "Live Backup vault identity or KMS encryption does not exactly match Terraform."
fi

success "Live Backup vault identity and KMS encryption exactly match Terraform"
success "Backup vault force_destroy matches the Terraform lifecycle contract: ${EXPECTED_BACKUP_VAULT_FORCE_DESTROY}"
info "Backup vault ARN: ${BACKUP_VAULT_ARN}"
info "Backup vault KMS key: ${BACKUP_VAULT_KMS_KEY_ARN}"
info "Backup vault force_destroy: ${EXPECTED_BACKUP_VAULT_FORCE_DESTROY}"
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

validate_restore_testing_live

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
Backup vault ARN:                         ${BACKUP_VAULT_ARN}
Backup vault KMS key ID:                  ${BACKUP_VAULT_KMS_KEY_ID}
Backup vault force_destroy:               ${EXPECTED_BACKUP_VAULT_FORCE_DESTROY}
Vault recovery points reported:           ${BACKUP_VAULT_RECOVERY_POINT_COUNT}
Backup plan count:                        ${LIVE_BACKUP_PLAN_COUNT}

RDS identifier:                           ${EXPECTED_RDS_IDENTIFIER}
RDS ARN:                                  ${EXPECTED_RDS_ARN}
RDS Multi-AZ:                             ${EXPECTED_RDS_MULTI_AZ}
RDS deletion protection:                  ${EXPECTED_RDS_DELETION_PROTECTION}
RDS DB subnet group:                      ${EXPECTED_RDS_DB_SUBNET_GROUP_NAME}
RDS VPC security groups:                  ${EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON}
RDS backup retention days:                ${EXPECTED_RDS_BACKUP_RETENTION_PERIOD}
RDS publicly accessible:                  ${EXPECTED_RDS_PUBLICLY_ACCESSIBLE}
RDS storage encrypted:                    ${EXPECTED_RDS_STORAGE_ENCRYPTED}
RDS skip final snapshot:                  ${EXPECTED_RDS_SKIP_FINAL_SNAPSHOT}
RDS delete automated backups:             ${EXPECTED_RDS_DELETE_AUTOMATED_BACKUPS}
RDS final snapshot identifier:            ${EXPECTED_RDS_FINAL_SNAPSHOT_IDENTIFIER}
Expected workload Backup tag value:       ${EXPECTED_RESOURCE_BACKUP_TAG_VALUE}
Environment EC2 resources checked:        ${ENV_EC2_RESOURCE_COUNT}
Environment RDS resources checked:        ${ENV_RDS_RESOURCE_COUNT}

Restore Testing enabled:                  ${RESTORE_TESTING_ENABLED}
Restore Testing plan:                     ${RESTORE_TESTING_PLAN_NAME}
Restore Testing plan ARN:                 ${RESTORE_TESTING_PLAN_ARN}
Restore Testing schedule:                 ${RESTORE_TESTING_SCHEDULE}
Restore Testing start window hours:       ${RESTORE_TESTING_START_WINDOW_HOURS}
Restore Testing selection:                ${RESTORE_TESTING_SELECTION_NAME}
Restore Testing protected resource:       ${RESTORE_TESTING_PROTECTED_RESOURCE_ARN}
Restore Testing validation window hours:  ${RESTORE_TESTING_VALIDATION_WINDOW_HOURS}
Latest Restore Testing job ID:             ${LATEST_RESTORE_TEST_JOB_ID}
Latest Restore Testing job status:         ${LATEST_RESTORE_TEST_STATUS}
Latest Restore Testing validation status:  ${LATEST_RESTORE_TEST_VALIDATION_STATUS}
Latest Restore Testing deletion status:    ${LATEST_RESTORE_TEST_DELETION_STATUS}
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
Backup vault ARN:                                   ${BACKUP_VAULT_ARN}
Backup vault KMS key ID:                            ${BACKUP_VAULT_KMS_KEY_ID}
Backup vault force_destroy:                         ${EXPECTED_BACKUP_VAULT_FORCE_DESTROY}
Vault recovery points reported:                     ${BACKUP_VAULT_RECOVERY_POINT_COUNT}

RDS identifier:                                     ${EXPECTED_RDS_IDENTIFIER}
RDS ARN:                                            ${EXPECTED_RDS_ARN}
RDS Multi-AZ:                                       ${EXPECTED_RDS_MULTI_AZ}
RDS deletion protection:                            ${EXPECTED_RDS_DELETION_PROTECTION}
RDS DB subnet group:                                ${EXPECTED_RDS_DB_SUBNET_GROUP_NAME}
RDS VPC security groups:                            ${EXPECTED_RDS_VPC_SECURITY_GROUP_IDS_JSON}
RDS backup retention days:                          ${EXPECTED_RDS_BACKUP_RETENTION_PERIOD}
RDS publicly accessible:                            ${EXPECTED_RDS_PUBLICLY_ACCESSIBLE}
RDS storage encrypted:                              ${EXPECTED_RDS_STORAGE_ENCRYPTED}
RDS skip final snapshot:                            ${EXPECTED_RDS_SKIP_FINAL_SNAPSHOT}
RDS delete automated backups:                       ${EXPECTED_RDS_DELETE_AUTOMATED_BACKUPS}
RDS final snapshot identifier:                      ${EXPECTED_RDS_FINAL_SNAPSHOT_IDENTIFIER}

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

Restore Testing enabled:                            ${RESTORE_TESTING_ENABLED}
Restore Testing plan:                               ${RESTORE_TESTING_PLAN_NAME}
Restore Testing plan ARN:                           ${RESTORE_TESTING_PLAN_ARN}
Restore Testing schedule:                           ${RESTORE_TESTING_SCHEDULE}
Restore Testing start window hours:                 ${RESTORE_TESTING_START_WINDOW_HOURS}
Restore Testing selection window days:              ${RESTORE_TESTING_SELECTION_WINDOW_DAYS}
Restore Testing selection:                          ${RESTORE_TESTING_SELECTION_NAME}
Restore Testing protected resource:                 ${RESTORE_TESTING_PROTECTED_RESOURCE_ARN}
Restore Testing validation window hours:            ${RESTORE_TESTING_VALIDATION_WINDOW_HOURS}
Restore Testing jobs listed:                        ${RESTORE_TEST_JOB_COUNT}
Latest Restore Testing job ID:                      ${LATEST_RESTORE_TEST_JOB_ID}
Latest Restore Testing job status:                  ${LATEST_RESTORE_TEST_STATUS}
Latest Restore Testing recovery point:              ${LATEST_RESTORE_TEST_RECOVERY_POINT_ARN}
Latest Restore Testing created resource:            ${LATEST_RESTORE_TEST_CREATED_RESOURCE_ARN}
Latest Restore Testing completion time:             ${LATEST_RESTORE_TEST_COMPLETION_TIME}
Latest Restore Testing validation status:           ${LATEST_RESTORE_TEST_VALIDATION_STATUS}
Latest Restore Testing deletion status:             ${LATEST_RESTORE_TEST_DELETION_STATUS}
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