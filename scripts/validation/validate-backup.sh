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
info "Environment:     $ENV_NAME"
info "Environment dir: $ENV_DIR"
info "Name prefix:     $NAME_PREFIX"
info "AWS_PROFILE:     ${AWS_PROFILE:-<default>}"
info "AWS_REGION:      $AWS_REGION"

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
EXPECTED_BACKUP_TAG_KEY="${Backup}"
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

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

