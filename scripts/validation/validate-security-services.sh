#!/usr/bin/env bash

# validate-security-services.sh
#
# Validates security services for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform effective security-service outputs are readable
# - GuardDuty detector exists and is enabled
# - Security Hub is enabled
# - Inspector is validated when effective_inspector_enabled = true
# - AWS Config is validated when effective_enable_config = true
# - AWS Backup is validated when effective_backup_enabled = true
#
# Usage:
#   ./scripts/validation/validate-security-services.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-security-services.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-security-services.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

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

section "tf-secure-baseline Security Services Validation"

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

REQUIRED_OUTPUTS=(
  effective_enable_config
  effective_backup_enabled
  effective_inspector_enabled
)

for output_name in "${REQUIRED_OUTPUTS[@]}"; do
  if terraform_output_exists "$OUTPUTS_JSON" "$output_name"; then
    success "Required output exists: $output_name"
  else
    fail "Missing required Terraform output: $output_name"
  fi
done

EFFECTIVE_ENABLE_CONFIG="$(get_terraform_output_value "$OUTPUTS_JSON" effective_enable_config)"
EFFECTIVE_BACKUP_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_backup_enabled)"
EFFECTIVE_INSPECTOR_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_inspector_enabled)"

require_value_in_list "$EFFECTIVE_ENABLE_CONFIG" "true false" "effective_enable_config"
require_value_in_list "$EFFECTIVE_BACKUP_ENABLED" "true false" "effective_backup_enabled"
require_value_in_list "$EFFECTIVE_INSPECTOR_ENABLED" "true false" "effective_inspector_enabled"

success "effective_enable_config is valid: $EFFECTIVE_ENABLE_CONFIG"
success "effective_backup_enabled is valid: $EFFECTIVE_BACKUP_ENABLED"
success "effective_inspector_enabled is valid: $EFFECTIVE_INSPECTOR_ENABLED"

section "Checking AWS caller identity"

ACCOUNT_ID="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Account \
    --output text
)"

CALLER_ARN="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Arn \
    --output text
)"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

success "AWS credentials are valid"
info "AWS account ID: $ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

section "Checking GuardDuty"

GUARDDUTY_DETECTORS_JSON="$(
  aws guardduty list-detectors \
    "${aws_args[@]}" \
    --output json
)"

GUARDDUTY_DETECTOR_COUNT="$(
  echo "$GUARDDUTY_DETECTORS_JSON" |
    jq '.DetectorIds | length'
)"

if [[ "$GUARDDUTY_DETECTOR_COUNT" -gt 0 ]]; then
  success "GuardDuty detector exists"
else
  fail "No GuardDuty detector found in region ${AWS_REGION}."
fi

GUARDDUTY_DETECTOR_ID="$(
  echo "$GUARDDUTY_DETECTORS_JSON" |
    jq -r '.DetectorIds[0]'
)"

GUARDDUTY_DETECTOR_JSON="$(
  aws guardduty get-detector \
    "${aws_args[@]}" \
    --detector-id "$GUARDDUTY_DETECTOR_ID" \
    --output json
)"

GUARDDUTY_STATUS="$(
  echo "$GUARDDUTY_DETECTOR_JSON" |
    jq -r '.Status'
)"

if [[ "$GUARDDUTY_STATUS" == "ENABLED" ]]; then
  success "GuardDuty detector is enabled"
else
  echo "$GUARDDUTY_DETECTOR_JSON" | jq .
  fail  "GuardDuty detector is not enabled. Current status: ${GUARDDUTY_STATUS}"
fi

info "GuardDuty detector ID: $GUARDDUTY_DETECTOR_ID"

section "Checking Security Hub"

SECURITY_HUB_JSON=""
SECURITY_HUB_ENABLED="false"

if SECURITY_HUB_JSON="$(
  aws securityhub describe-hub \
    "${aws_args[@]}" \
    --output json 2>/dev/null
)"; then
  SECURITY_HUB_ENABLED="true"
  success "Security Hub is enabled"
else
  fail "Security Hub is not enabled or describe-hub failed in region ${AWS_REGION}."
fi

SECURITY_HUB_ARN="$(
  echo "$SECURITY_HUB_JSON" |
    jq -r '.HubArn // empty'
)"

SECURITY_HUB_SUBSCRIBED_AT="$(
  echo "$SECURITY_HUB_JSON" |
    jq -r '.SubscribedAt // empty'
)"

info "Security Hub ARN: ${SECURITY_HUB_ARN:-<unknown>}"
info "Security Hub subscribed at: ${SECURITY_HUB_SUBSCRIBED_AT:-<unknown>}"

section "Checking Inspector"

INSPECTOR_ACCOUNT_STATUS_JSON=""
INSPECTOR_ACCOUNT_STATUS="unknown"
INSPECTOR_EC2_STATUS="unknown"
INSPECTOR_LAMBDA_STATUS="unknown"
INSPECTOR_LAMBDA_CODE_STATUS="unknown"

if [[ "$EFFECTIVE_INSPECTOR_ENABLED" == "true" ]]; then
  INSPECTOR_ACCOUNT_STATUS_JSON="$(
    aws inspector2 batch-get-account-status \
      "${aws_args[@]}" \
      --account-ids "$ACCOUNT_ID" \
      --output json
  )"

  INSPECTOR_ACCOUNT_STATUS="$(
    echo "$INSPECTOR_ACCOUNT_STATUS_JSON" |
      jq -r '.accounts[0].state.status // "unknown"'
  )"

  INSPECTOR_EC2_STATUS="$(
    echo "$INSPECTOR_ACCOUNT_STATUS_JSON" |
      jq -r '.accounts[0].resourceState.ec2.status // "unknown"'
  )"

  INSPECTOR_LAMBDA_STATUS="$(
    echo "$INSPECTOR_ACCOUNT_STATUS_JSON" |
      jq -r '.accounts[0].resourceState.lambda.status // "unknown"'
  )"

  INSPECTOR_LAMBDA_CODE_STATUS="$(
    echo "$INSPECTOR_ACCOUNT_STATUS_JSON" |
      jq -r '.accounts[0].resourceState.lambdaCode.status // "unknown"'
  )"

  if [[ "$INSPECTOR_ACCOUNT_STATUS" == "ENABLED" ]]; then
    success "Inspector account status is ENABLED"
  else
    echo "$INSPECTOR_ACCOUNT_STATUS_JSON" | jq .
    fail "Inspector was expected to be enabled, but account status is: ${INSPECTOR_ACCOUNT_STATUS}"
  fi

  info "Inspector EC2 status: $INSPECTOR_EC2_STATUS"
  info "Inspector Lambda status: $INSPECTOR_LAMBDA_STATUS"
  info "Inspector Lambda code status: $INSPECTOR_LAMBDA_CODE_STATUS"
else
  warn "effective_inspector_enabled=false. Skipping Inspector validation."
fi

section "Checking AWS Config"

CONFIG_RECORDER_COUNT="0"
CONFIG_DELIVERY_CHANNEL_COUNT="0"
CONFIG_RULE_COUNT="0"

if [[ "$EFFECTIVE_ENABLE_CONFIG" == "true" ]]; then
  CONFIG_RECORDERS_JSON="$(
    aws configservice describe-configuration-recorders \
      "${aws_args[@]}" \
      --output json
  )"

  CONFIG_RECORDER_COUNT="$(
    echo "$CONFIG_RECORDERS_JSON" |
      jq '.ConfigurationRecorders | length'
  )"

  if [[ "$CONFIG_RECORDER_COUNT" -gt 0 ]]; then
    success "AWS Config configuration recorder exists"
  else
    fail "effective_enable_config=true, but no AWS Config configuration recorder was found."
  fi

  CONFIG_RECORDER_STATUS_JSON="$(
    aws configservice describe-configuration-recorder-status \
      "${aws_args[@]}" \
      --output json
  )"

  CONFIG_RECORDERS_NOT_RECORDING_COUNT="$(
    echo "$CONFIG_RECORDER_STATUS_JSON" |
      jq '[.ConfigurationRecordersStatus[]? | select(.recording != true)] | length'
  )"

  if [[ "$CONFIG_RECORDERS_NOT_RECORDING_COUNT" -eq 0 ]]; then
    success "AWS Config recorder is recording"
  else
    echo "$CONFIG_RECORDER_STATUS_JSON" | jq .
    fail "One or more AWS Config recorders are not recording."
  fi
  
  CONFIG_DELIVERY_CHANNELS_JSON="$(
    aws configservice describe-delivery-channels \
      "${aws_args[@]}" \
      --output json
  )"

  CONFIG_DELIVERY_CHANNEL_COUNT="$(
    echo "$CONFIG_DELIVERY_CHANNELS_JSON" |
      jq -r '.DeliveryChannels | length'
  )"

  if [[ "$CONFIG_DELIVERY_CHANNEL_COUNT" -gt 0 ]]; then
    success "AWS Config delivery channel exists"
  else
    fail  "effective_enable_config=true, but not AWS Config delivery channel was found."
  fi

  CONFIG_RULES_JSON="$(
    aws configservice describe-config-rules \
      "${aws_args[@]}" \
      --output json
  )"

  CONFIG_RULE_COUNT="$(
    echo "$CONFIG_RULES_JSON" |
      jq '.ConfigRules | length'
  )"

  if [[ "$CONFIG_RULE_COUNT" -gt 0 ]]; then
    success "AWS Config rules exist: $CONFIG_RULE_COUNT"
  else
    warn "AWS Config is enabled, but no Config rules were found."
  fi
else
  warn "effective_enable_config=false. Skipping AWS Config validation."
  warn "This is expected if Config was intentionally disabled."
fi

section "Checking AWS Backup"

BACKUP_VAULT_COUNT="0"
BACKUP_PLAN_COUNT="0"

if [[ "$EFFECTIVE_BACKUP_ENABLED" == "true" ]]; then
  BACKUP_VAULTS_JSON="$(
    aws backup list-backup-vaults \
      "${aws_args[@]}" \
      --output json
  )"

  BACKUP_VAULT_COUNT="$(
    echo "$BACKUP_VAULTS_JSON" |
      jq -r '.BackupVaultList | length'
  )"

  if [[ "$BACKUP_VAULT_COUNT" -gt 0 ]]; then
    success "AWS Backup vaults exist: $BACKUP_VAULT_COUNT"
  else
    fail "effective_backup_enabled=true, but no AWS Backup vaults were found."
  fi

  BACKUP_PLANS_JSON="$(
    aws backup list-backup-plans \
      "${aws_args[@]}" \
      --output json
  )"

  BACKUP_PLAN_COUNT="$(
    echo "$BACKUP_PLANS_JSON" |
      jq -r '.BackupPlansList | length'
  )"

  if [[ "$BACKUP_PLAN_COUNT" -gt 0 ]]; then
    success "AWS Backup plans exist: $BACKUP_PLAN_COUNT"
  else
    fail "effective_backup_enabled=true, but no AWS Backup plans were found."
  fi
else
  warn "effective_backup_enabled=false. Skipping AWS Backup validation."
  warn "This is expected for development/minimal profiles or explicit cost-control overrides."
fi

section "Security Services Summary"

cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
AWS account ID:                     ${ACCOUNT_ID}
Name prefix:                        ${NAME_PREFIX}

effective_enable_config:            ${EFFECTIVE_ENABLE_CONFIG}
effective_backup_enabled:           ${EFFECTIVE_BACKUP_ENABLED}
effective_inspector_enabled:        ${EFFECTIVE_INSPECTOR_ENABLED}

GuardDuty detector count:           ${GUARDDUTY_DETECTOR_COUNT}
GuardDuty detector ID:              ${GUARDDUTY_DETECTOR_ID}
GuardDuty status:                   ${GUARDDUTY_STATUS}

Security Hub enabled:               ${SECURITY_HUB_ENABLED}
Security Hub ARN:                   ${SECURITY_HUB_ARN:-<unknown>}

Inspector account status:           ${INSPECTOR_ACCOUNT_STATUS}
Inspector EC2 status:               ${INSPECTOR_EC2_STATUS}
Inspector Lambda status:            ${INSPECTOR_LAMBDA_STATUS}
Inspector Lambd code status:        ${INSPECTOR_LAMBDA_CODE_STATUS}

AWS Config recorder count:          ${CONFIG_RECORDER_COUNT}
AWS Config delivery channel count:  ${CONFIG_DELIVERY_CHANNEL_COUNT}
AWS Config rule count:              ${CONFIG_RULE_COUNT}

AWS Backup vault count:             ${BACKUP_VAULT_COUNT}
AWS Backup plan count:              ${BACKUP_PLAN_COUNT}
SUMMARY

section "Validation Result"

success "Security services validation completed successfully for: ${ENV_NAME}"