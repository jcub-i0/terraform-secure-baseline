#!/usr/bin/env bash

# validate-env.sh
#
# Validates that the selected tf-secure-baseline environment is usable before
# running deeper AWS service validation scripts.
#
# Usage:
#   ./scripts/validation/validate-env.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-env.sh dev

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

section "tf-secure-baseline Environment Validation"

require_env_name "$ENV_NAME"

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

section "Checking AWS caller identity"

info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$AWS_ACCOUNT_ID" || "$AWS_ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

if [[ -z "$AWS_CALLER_ARN" || "$AWS_CALLER_ARN" == "None" ]]; then
  fail "Unable to resolve AWS caller ARN"
fi

success "AWS credentials are valid"
info "AWS account ID: $AWS_ACCOUNT_ID"
info "AWS caller ARN: $AWS_CALLER_ARN"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

section "Checking Terraform environment outputs"

if [[ ! -d "${ENV_DIR}/.terraform" ]]; then
  warn "Terraform has not been initialized in ${ENV_DIR}"
  warn "Run: terraform -chdir=${ENV_DIR} init"
fi

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

REQUIRED_OUTPUTS=(
  deployment_profile
  egress_mode
  effective_egress_mode
  effective_cloudwatch_retention_days
  effective_enable_config
  effective_enable_rules
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

section "Checking effective baseline settings"

DEPLOYMENT_PROFILE="$(get_terraform_output_value "$OUTPUTS_JSON" deployment_profile)"
EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" egress_mode)"
EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
EFFECTIVE_ENABLE_CONFIG="$(get_terraform_output_value "$OUTPUTS_JSON" effective_enable_config)"
EFFECTIVE_BACKUP_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_backup_enabled)"
EFFECTIVE_INSPECTOR_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_inspector_enabled)"

require_value_in_list "$DEPLOYMENT_PROFILE" "production development minimal" "deployment_profile"
success "deployment_profile is valid: $DEPLOYMENT_PROFILE"

require_value_in_list "$EGRESS_MODE" "auto network_firewall nat_only vpc_endpoints_only" "egress_mode"
success "egress_mode is valid: $EGRESS_MODE"

require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"
success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"

section "Environment Summary"

cat <<SUMMARY
Environment:                            ${ENV_NAME}
AWS profile:                            ${AWS_PROFILE:-<default>}
AWS region:                             ${AWS_REGION}
AWS account ID:                         ${AWS_ACCOUNT_ID}
Expected AWS account ID:                ${EXPECTED_ACCOUNT_ID:-<not set>}
AWS caller ARN:                         ${AWS_CALLER_ARN}

Terraform environment directory:        ${ENV_DIR}

deployment_profile:                     ${DEPLOYMENT_PROFILE}
egress_mode:                            ${EGRESS_MODE}
effective_egress_mode:                  ${EFFECTIVE_EGRESS_MODE}
effective_cloudwatch_retention_days:    ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}
effective_enable_config:                ${EFFECTIVE_ENABLE_CONFIG}
effective_backup_enabled:               ${EFFECTIVE_BACKUP_ENABLED}
effective_inspector_enabled:            ${EFFECTIVE_INSPECTOR_ENABLED}
SUMMARY

section "Validation Result"

success "Environment validation completed successfully for: ${ENV_NAME}"