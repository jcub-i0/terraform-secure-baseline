#!/usr/bin/env bash

# validate-sqs.sh
#
# Validates SQS queues for a deployed tf-secure-baseline workload environment.
#
# Current expected SQS design:
# - Compliance SNS topic publishes to compliance SQS queue.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Compliance SQS queue exists
# - Queue encryption is configured
# - Queue policy exists
# - Queue policy allows the compliance SNS topic to publish
# - Compliance SNS topic has a subscription targeting the compliance queue
# - Queue DLQ/redrive config is reported
#
# Usage:
#   ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-sqs.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-sqs.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"
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

section "tf-secure-baseline SQS Validation"

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

if [[ -n "$ACCOUNT_ID" ]]; then
  if [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

section "Resolving expected SQS and SNS resources"

resource_name() {
  local suffix="$1"
  echo "{NAME_PREFIX}-${suffix}"
}

# Format:
#   label|queue_suffix|required|producer_ref
#
# producer_ref formats:
#   sns:<topic_suffix>       Validate SNS topic -> SQS subscription and queue policy
#   none                     Validate queue only
EXPECTED_SQS_QUEUES=(
  "compliance|compliance-queue|required|sns:compliance-notifications"
)

QUEUE_SUMMARY_ROWS=()
TOTAL_VALIDATED_QUEUES=0
TOTAL_REQUIRED_QUEUES=0
TOTAL_OPTIONAL_QUEUES=0
TOTAL_PENDING_SUBSCRIPTION_COUNT=0

validate_sns_producer_for_queue() {
  local queue_label="$1"
  local queue_arn="$2"
  local topic_suffix="$3"
  local policy_json="$4"

  local topic_name
  local topic_arn
  local subscriptions_json
  local queue_subscription_count
  local pending_subscription_count
  local sns_sendmessage_statement_count

  topic_name="$(resource_name "$topic_suffix")"
  topic_arn="arn:aws:sns:${AWS_REGION}:${ACCOUNT_ID}:${topic_name}"

  section "Validating SNS producer for ${queue_label}"

  info "Expected SNS topic: ${topic_name}"

  if aws sns get-topic-attributes \
    "${aws_args[@]}" \
    --topic-arn "$topic_arn" \
    --output json >/dev/null 2>&1; then
    success "SNS topic exists for ${queue_label}: ${topic_arn}"
  else
    fail "Required SNS topic not found for ${queue_label}: ${topic_arn}"
  fi

  sns_sendmessage_statement_count="$(
    echo "$policy_json" |
      jq --arg topic_arn "$topic_arn" '
        [
          .Statement[]
          | select(
              (
                (.Action == "sqs:SendMessage")
                or
                ((.Action | type) == "array" and (.Action | index("sqs:SendMessage")))
                or
                (.Action == "SQS:SendMessage")
                or
                ((.Action | type) == "array" and (.Action | index("SQS:SendMessage")))
              )
            )
          | select(
              (
                .Condition.ArnEquals."aws:SourceArn"? == $topic_arn
              )
              or
              (
                .Condition.ArnLike."aws:SourceArn"? == $topic_arn
              )
            )
        ]
        | length
      '
  )"

  if [[ "$sns_sendmessage_statement_count" -gt 0 ]]; then
    success "${queue_label} queue policy allows SNS topics to send messages"
  else
    echo "$policy_json" | jq .
    fail "${queue_label} queue policy does not clearly allow ${topic_arn} to send sqs:SendMessage"
  fi

  subscriptions_json="$(
    aws sns list-subscriptions-by-topic \
      "${aws_args[@]}" \
      --topic-arn "$topic_arn" \
      --output json
  )"

  queue_subscription_count="$(
    echo "$subscriptions_json" |
      jq --arg queue_arn "$queue_arn" '
        [
          .Subscriptions[]
          | select(.Protocol == "sqs")
          | select(.Endpoint == $queue_arn)
        ]
        | length
      '
  )"

  pending_subscription_count="$(
    echo "$subscriptions_json" |
      jq '
        [
          .Subscriptions[]
          | select(.SubscriptionArn == "PendingConfirmation")
        ]
        | length
      '
  )"

  if [[ "$queue_subscription_count" -gt 0 ]]; then
    success "${queue_label} SNS topic is subscribed to expected SQS queue"
  else
    echo "$subscriptions_json" | jq '.Subscriptions'
    fail "${queue_label} SNS topic is not subscribed to expected SQS queue: ${queue_arn}"
  fi

  if [[ "$pending_subscription_count" -eq 0 ]]; then
    success "${queue_label} SNS topic has no pending subscription confirmations"
  else
    echo "$subscriptions_json" |
      jq '[.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation")]'
    fail "${queue_label} SNS topic has pending subscription confirmations"
  fi

  TOTAL_PENDING_SUBSCRIPTION_COUNT=$((TOTAL_PENDING_SUBSCRIPTION_COUNT + pending_subscription_count))

  SNS_TOPIC_ARN_RESULT="$topic_arn"
  SNS_SUBSCRIPTION_COUNT_RESULT="$queue_subscription_count"
  SNS_PENDING_COUNT_RESULT="$pending_subscription_count"
}
