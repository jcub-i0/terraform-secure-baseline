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

aws_args()
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

section "Resolving respository paths and Terraform outputs"

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
  effective_enableconfig
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
    "${aws_args[@]}"
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
  fail "Security Hub is not enabled or describe-hub failed in region ${AWS_REIGON}."
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
info "Security Hub subscribed at: ${SECURITY_HUB_SUSCRIBED_AT:-<unknown>}"


