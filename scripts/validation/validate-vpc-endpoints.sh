#!/usr/bin/env bash

# validate-vpc-endpoints.sh
#
# Validates VPC Endpoint behavior for a deployed tf-secure-baseline environment.
#
# Checks:
# - VPC can be resolved
# - Endpoint private subnets exist
# - Endpoint private route tables exist and have no default route
# - Interface VPC Endpoints exist and are available
# - Interface VPC Endpoints are deployed into endpoint private subnets
# - S3 Gateway Endpoint exists
# - S3 Gateway Endpoint is associated with expected private route tables
#
# Usage:
#   ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-vpc-endpoints.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

# Space-separated list so callers can override this later if the module becomes configurable.
EXPECTED_INTERFACE_ENDPOINT_SERVICES="${EXPECTED_INTERFACE_ENDPOINT_SERVICES:-sts logs ssm ssmmessages secretsmanager kms config sns ec2 events securityhub lambda}"

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

section "tf-secure-baseline VPC Endpoints Validation"

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

info "Repository root:  $REPO_ROOT"
info "Environment:      $ENV_NAME"
info "Environment dir:  $ENV_DIR"
info "Name prefix:      $NAME_PREFIX"
info "AWS_PROFILE:      ${AWS_PROFILE:-<default>}"
info "AWS_REGION:       $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

if terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  require_value_in_list "$EFFECTIVE_EGRESS_MODE" "networking_firewall nat_only vpc_endpoints_only" "effective_egress_mode"
  success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"
else
  warn "Missing Terraform output: effective_egress_mode"
  EFFECTIVE_EGRESS_MODE="unknown"
fi

section "Resolving VPC"

# Prefer Terraform output if present. Fall back to AWS tag lookup.
if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  info "Resolved VPC ID from Terraform output: $VPC_ID"
else
  warn "Terraform output vpc_id not found. Falling back to AWS tag lookup."

  VPC_ID="$(
    aws ec2 describe-vpcs \
      "${aws_args[@]}" \
      --filters \
        "Name=tag:Name,Values=${NAME_PREFIX}-Main,${NAME_PREFIX}-VPC" \
        "Name=tag:Environment,Values=${ENV_NAME}" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"
fi

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  fail "Unable to resolve VPC ID. Expected VPC Name tag matching ${NAME_PREFIX}-Main or ${NAME_PREFIX}-VPC. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID