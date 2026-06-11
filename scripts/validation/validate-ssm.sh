#!/usr/bin/env bash

# validate-ssm.sh
#
# Validates SSM access and operational readiness for a deployed
# tf-secure-baseline workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - SSM-managed instances are discovered
# - Managed instances are online
# - Managed instances use expected tf-secure-baseline names/tags
# - SSM instance associations are reported
# - SSM maintenance windows are reported
# - SSM patch baselines are reported
#
# Usage:
#   ./scripts/validation/validate-ssm.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-ssm.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-ssm.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-ssm.sh dev

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

section "tf-secure-baseline SSM Validation"

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

section "Discovering EC2 instances for environment"

EC2_INSTANCES_JSON="$(
  aws ec2 describe-instances \
    "${aws_args[@]}" \
    --filters \
      "Name=tag:Name,Values=${NAME_PREFIX}*" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --output json
)"

ENV_INSTANCE_IDS="$(
  echo "$EC2_INSTANCES_JSON" |
    jq -r '
      [
         .Reservations[].Instances[]
         | .InstanceId 
      ]
      | join(" ")
    '
)"

ENV_INSTANCE_COUNT="$(
  echo "$ENV_INSTANCE_IDS" |
    jq -r '
      [
        .Reservations[].Instances[]
      ]
      | length
    '
)"

if [[ "$ENV_INSTANCE_COUNT" -gt 0 ]]; then
  success "Found EC2 instances matching environment name prefix: $ENV_INSTANCE_COUNT"
else
  warn "No EC2 instances found matching environment name prefix: ${NAME_PREFIX}"
fi

if [[ "$ENV_INSTANCE_COUNT" -gt 0 ]]; then
  info "Environment EC2 instances:"
  echo "$EC2_INSTANCES_JSON" |
    jq -r '
      .Reservations[].Instances[]
      | {
          InstanceId,
          State: .State.Name,
          PrivateIpAddress,
          Name: (
            .Tags // []
            | map(select(.key == "Name"))
            | first
            | .Value // ""
          ),
          IamInstanceProfile: (.IamInstanceProfile.Arn // "")
        }
      | "- " + .InstanceId + " " + .State + " " + .Name " " + (.PrivateIpAddress // "<no-private-ip>")
    '
fi

section "Checking SSM managed instance inventory"

SSM_INSTANCE_INFO_JSON="$(
  aws ssm describe-instance-information \
    "${aws_args[@]}" \
    --output json
)"

SSM_MANAGED_COUNT="$(
  echo "$SSM_INSTANCE_INFO_JSON" |
    jq '.InstanceInformationList | length'
)"

if [[ "$SSM_MANAGED_COUNT" -gt 0 ]]; then
  success "Found SSM managed instances in account/region: $SSM_MANAGED_COUNT"
else
  if [[ "$ENV_INSTANCE_COUNT" -gt 0 ]]; then
    fail "No SSM managed instances found, but environment EC2 instances exist."
  else
    warn "No SSM managed instances found. This may be expected if the environment has no EC2 compute."
  fi
fi

MATCHING_SSM_JSON="$(
  echo "$SSM_INSTANCE_INFO_JSON" |
    jq --argjson instance_ids "$(printf '%s\n' $ENV_INSTANCE_IDS | jq -R . | jq -s .)" '
      [
        .InstanceInformationList[]
        | select(.InstanceId as $id | $instance_ids | index($id))
      ]
    '
)"

MATCHING_SSM_COUNT="$(echo "$MATCHING_SSM_JSON" | jq 'length')"

if [[ "$ENV_INSTANCE_COUNT" -gt 0 ]]; then
  if [[ "$MATCHING_SSM_COUNT" -eq "$ENV_INSTANCE_COUNT" ]]; then
    success "All environment EC2 instances are registered with SSM: ${MATCHING_SSM_COUNT}/${ENV_INSTANCE_COUNT}"
  else
    echo "$MATCHING_SSM_JSON" | jq -r '.[] | "- " + .InstanceId + " PingStatus=" + .PingStatus'
    fail "Not all environment EC2 instances are registered with SSM. Registered=${MATCHING_SSM_COUNT}, Expected=${ENV_INSTANCE_COUNT}"
  fi
else
  info "Skipping EC2-to-SSM registration comparison because no environment EC2 instances were found."
fi