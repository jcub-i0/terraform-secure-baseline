#!/usr/bin/env bash

# validate-compute.sh
#
# Validates EC2 compute resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - VPC is resolved
# - Compute and quarantine security groups exist
# - EC2 instances exist and are private
# - EC2 instances are in compute private subnets
# - EC2 instances have no public IPs
# - EC2 instances enforce IMDSv2
# - EC2 instances have detailed monitoring enabled
# - EC2 instances have IAM instance profiles
# - Required automation/operations tags exist
# - Root EBS volumes are encrypted, gp3, 20 GiB
# - Root EBS volumes use a KMS key
#
# Usage:
#   ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-compute.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-compute.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SOURCE_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "${ENV_NAME}" ]]; then
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

section "tf-secure-baseline Compute Validation"

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

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

section "Resolving VPC and expected security groups"

VPC_ID=""

if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  success "vpc_id output found: $VPC_ID"
else
  VPC_ID="$(
    aws ec2 describe-vpcs \
      "${aws_args[@]}" \
      --filters "Name=tag:Name,Values=${NAME_PREFIX}-Main,${NAME_PREFIX}-VPC" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"

  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    fail "Unable to resolve VPC by Terraform output or expected Name tags"
  fi

  success "Resolved VPC by tag: $VPC_ID"
fi

COMPUTE_SG_ID=""
QUARANTINE_SG_ID=""

if terraform_output_exists "$OUTPUTS_JSON" compute_sg_id; then
  COMPUTE_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" compute_sg_id)"
  success "compute_sg_id output found: $COMPUTE_SG_ID"
else
  COMPUTE_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=${NAME_PREFIX}-Compute-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$COMPUTE_SG_ID" || "$COMPUTE_SG_ID" == "None" ]]; then
    fail "Unable to resolve compute security group"
  fi

  success "Resolved compute security group by name: $COMPUTE_SG_ID"
fi

if terraform_output_exists "$OUTPUTS_JSON" quarantine_sg_id; then
  QUARANTINE_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" quarantine_sg_id)"
  success "quarantine_sg_id output found: $QUARANTINE_SG_ID"
else
  QUARANTINE_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=${NAME_PREFIX}-Quarantine-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$QUARANTINE_SG_ID" || "$QUARANTINE_SG_ID" == "None" ]]; then
    fail "Unable to resolve quarantine security group"
  fi

  success "Resolved quarantine security group by name: $QUARANTINE_SG_ID"
fi
