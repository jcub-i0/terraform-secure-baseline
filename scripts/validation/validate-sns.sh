#!/usr/bin/env bash

# validate-sns.sh
#
# Validates SNS topics and subscriptions for a deployed tf-secure-baseline
# workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - SNS topics matching the environment exist
# - SNS topics have subscriptions where expected
# - SNS subscriptions are confirmed where applicable
# - SNS topic KMS encryption is reported
#
# Usage:
#   ./scripts/validation/validate-sns.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-sns.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-sns.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-sns.sh dev

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
  aws_args+=(--profile "$AWS_REGION")
fi

section "tf-secure-baseline SNS Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq cound"

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
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environmnet been applied?"
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

section "Listing SNS topics"

TOPICS_JSON="$(
  aws sns list-topics \
    "${aws_args[@]}" \
    --output json
)"

MATCHING_TOPICS_JSON="$(
  echo "$TOPICS_JSON" \
    jq --arg prefix "$NAME_PREFIX" '
      [
        .Topics[]
        | select(.TopicArn | contains($prefix))
      ]
    '
)"

MATCHING_TOPIC_COUNT="$(echo "$MATCHING_TOPICS_JSON" | jq 'length')"

if [[ "$MATCHING_TOPIC_COUNT" -gt 0 ]]; then
  success "Found SNS topics matching name prefix: $MATCHING_TOPIC_COUNT"
else
  fail "No SNS topics found containing name prefix: ${NAME_PREFIX}"
fi

info "Matching SNS topics:"
echo "$MATCHING_TOPICS_JSON" |
  jq -r '.[] | "- " + .TopicArn'