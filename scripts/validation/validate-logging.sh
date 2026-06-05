#!/usr/bin/env bash

# validate-logging.sh
#
# Validates logging controls for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform outputs are readable
# - VPC can be resolved
# - Centralized logs bucket exists
# - CloudTrail exists
# - CloudTrail is multi-region
# - CloudTrail is actively logging
# - CloudTrail has S3 delivery configured
# - VPC Flow Logs exist for the VPC
# - VPC Flow Logs are active
# - CloudWatch log groups exist for the baseline
# - CloudWatch log group retention matches effective_cloudwatch_retention_days where applicable
#
# Usage:
#   ./scripts/validation/validate-logging.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-logging.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-logging.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="{$1:-}"
AWS_PROFILE="${AWS_REGION:-us-east-1}"
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

section "tf-secure-baseline Logging Validation"

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

if terraform_output_exists "$OUTPUTS_JSON" effective_cloudwatch_retention_days; then
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
  success "Resolved effective_cloudwatch_retention_days: $EFFECTIVE_CLOUDWATCH_RETENTION_DAYS"
else
  warn "Missing Terraform output: effective_cloudwatch_retention_days"
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS=""
fi

