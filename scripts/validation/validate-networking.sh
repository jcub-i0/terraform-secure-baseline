#!/usr/bin/env bash

# validate-networking.sh
#
# Validates core networking behavior for a deployed tf-secure-baseline
# environment based on the effective egress mode.
#
# Usage:
#   ./scripts/validation/validate-networking.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-networking.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-networking.sh dev

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

section "tf-secure-baseline Networking Validation"

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

info "Respository root: $REPO_ROOT"
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

if ! terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  fail "Missing required Terraform output: effective_egress_mode"
fi

EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"

success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"

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
        "Name=tag:Name,Values=${NAME_PREFIX}-VPC" \
        "Name=tag:Environment,Values=${ENV_NAME}" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"
fi

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  fail "Unable to resolve VPC ID. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID"

section "Checking NAT Gateways"

NAT_GATEWAYS_JSON="$(
  aws ec2 describe-nat-gateways \
    "${aws_args[@]}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --output json
)"

NAT_GATEWAY_COUNT="$(echo "$NAT_GATEWAYS_JSON" | jq '.NatGateways | length')"

info "NAT Gateway count: $NAT_GATEWAY_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall|nat_only)
    if [[ "$NAT_GATEWAY_COUNT" -gt 0 ]]; then
      success "NAT Gateway exists as expected for ${EFFECTIVE_EGRESS_MODE}"
    else
      fail "Expected NAT Gateway for ${EFFECTIVE_EGRESS_MODE}, but none were found."
    fi
    ;;
  vpc_endpoints_only)
    if [[ "$NAT_GATEWAY_COUNT" -eq 0 ]]; then
      success "No NAT Gateway found as expected for vpc_endpoints_only"
    else
      fail "Expected no NAT Gateway for vpc_endpoints_only, but found ${NAT_GATEWAY_COUNT}."
    fi
    ;;
esac
