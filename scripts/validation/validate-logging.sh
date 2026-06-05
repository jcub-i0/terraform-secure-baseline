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

section "Resolving VPC"

if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  info "Resolved VPC ID from Terraform output: $VPC_ID"
else
  warn "Terraform output vpc_id not found. Failing back to AWS tag lookup."

  VPC_ID="$(
    aws ec2 describe-vpcs \
      "${aws_args[@]}" \
      --filters
        "Name=tag:Name,Values=${NAME_PREFIX}-Main,${NAME_PREFIX}-VPC" \
        "Name=tag:Environment,Values=${ENV_NAME}" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"
fi

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  fail "Unable to resolve VPC ID. Expected VPC Name tag matching ${NAME_PREFIX}-Main or ${NAME_PREFIX}-VPC. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID"

section "Checking centralized logs bucket"

CENTRALIZED_LOGS_BUCKET_NAME=""

if terraform_output_exists "$OUTPUTS_JSON" centralized_logs_bucket_name; then
  CENTRALIZED_LOGS_BUCKET_NAME="$(get_terraform_output_value "$OUTPUTS_JSON" centralized_logs_bucket_name)"
  info "Resolved centralized logs bucket from Terraform output: $CENTRALIZED_LOGS_BUCKET_NAME"
else
  warn "Terraform output centralized_logs_bucket_name not found. Falling back to S3 bucket name search."

  CENTRALIZED_LOGS_BUCKET_NAME="$(
    aws s3api list-buckets \
      "${aws_args[@]}" \
      --query "Buckets[?contains(Name, \'${NAME_PREFIX}\') && contains(Name, \'logs\')].Name | [0]" \
      --output text
  )"
fi

if [[ -z "$CENTRALIZED_LOGS_BUCKET_NAME" || "$CENTRALIZED_LOGS_BUCKET_NAME" == "None" ]]; then
  fail "Unable to resolve centralized logs bucket. Consider adding centralized_logs_bucket_name as a Terraform output."
fi

aws s3api head-bucket \
  "${aws_args[@]}" \
  --bucket "$CENTRALIZED_LOGS_BUCKET_NAME" >/dev/null

success "Centralized logs bucket exists: $CENTRALIZED_LOGS_BUCKET_NAME"

