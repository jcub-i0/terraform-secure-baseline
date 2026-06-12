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

section "Resolving expected SQS resources"

resource_name() {
  local suffix="$1"
  echo "${NAME_PREFIX}-${suffix}"
}

# Format:
#   label|queue_suffix|required|producer_ref
#
# producer_ref formats:
#   sns:<topic_suffix>       Validate SNS topic -> SQS subscription and queue policy
#   none                     Validate queue only
#
# Potential examples:
#   "lambda dlq|ip-enrichment-dlq|optional|none"
#   "eventbridge dlq|eventbridge-dlq|optional|none"
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
    success "${queue_label} queue policy allows SNS topic to send messages"
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

validate_sqs_queue() {
  local queue_label="$1"
  local queue_suffix="$2"
  local requirement="$3"
  local producer_ref="$4"

  local queue_name
  local queue_url
  local queue_attributes_json
  local queue_arn
  local kms_key_id
  local sqs_managed_sse
  local policy_raw
  local policy_json
  local redrive_policy_raw
  local visibility_timeout
  local message_retention_period
  local approximate_number_of_messages
  local approximate_number_of_messages_not_visible
  local producer_type
  local producer_suffix
  local sns_topic_arn="<none>"
  local sns_subscription_count="0"
  local sns_pending_count="0"
  local redrive_policy_configured="false"

  queue_name="$(resource_name "$queue_suffix")"

  section "Validating ${queue_label} SQS queue"

  info "Expected SQS queue: ${queue_name}"
  info "Requirement:        ${requirement}"
  info "Producer reference: ${producer_ref}"

  if ! queue_url="$(
    aws sqs get-queue-url \
      "${aws_args[@]}" \
      --queue-name "$queue_name" \
      --query 'QueueUrl' \
      --output text 2>/dev/null
  )"; then
    if [[ "$requirement" == "required" ]]; then
      fail "Required SQS queue not found for ${queue_label}: ${queue_name}"
    else
      warn "Optional SQS queue not found for ${queue_label}: ${queue_name}"
      return 0
    fi
  fi

  success "SQS queue exists for ${queue_label}: ${queue_name}"
  info "${queue_label} queue URL: ${queue_url}"

  queue_attributes_json="$(
    aws sqs get-queue-attributes \
      "${aws_args[@]}" \
      --queue-url "$queue_url" \
      --attribute-names All \
      --output json
  )"

  queue_arn="$(echo "$queue_attributes_json" | jq -r '.Attributes.QueueArn // empty')"
  kms_key_id="$(echo "$queue_attributes_json" | jq -r '.Attributes.KmsMasterKeyId // empty')"
  sqs_managed_sse="$(echo "$queue_attributes_json" | jq -r '.Attributes.SqsManagedSseEnabled // "false"')"
  policy_raw="$(echo "$queue_attributes_json" | jq -r '.Attributes.Policy // empty')"
  redrive_policy_raw="$(echo "$queue_attributes_json" | jq -r '.Attributes.RedrivePolicy // empty')"
  visibility_timeout="$(echo "$queue_attributes_json" | jq -r '.Attributes.VisibilityTimeout // "unknown"')"
  message_retention_period="$(echo "$queue_attributes_json" | jq -r '.Attributes.MessageRetentionPeriod // "unknown"')"
  approximate_number_of_messages="$(echo "$queue_attributes_json" | jq -r '.Attributes.ApproximateNumberOfMessages // "0"')"
  approximate_number_of_messages_not_visible="$(echo "$queue_attributes_json" | jq -r '.Attributes.ApproximateNumberOfMessagesNotVisible // "0"')"

  if [[ -n "$queue_arn" ]]; then
    success "${queue_label} queue ARN resolved: ${queue_arn}"
  else
    fail "Unable to resolve queue ARN for ${queue_label}"
  fi

  if [[ -n "$kms_key_id" ]]; then
    success "${queue_label} queue uses SSE-KMS: ${kms_key_id}"
  elif [[ "$sqs_managed_sse" == "true" ]]; then
    success "${queue_label} queue uses SQS-managed server-side encryption"
  else
    fail "${queue_label} queue encryption is not configured"
  fi

  info "${queue_label} queue visibility timeout: ${visibility_timeout}s"
  info "${queue_label} queue message retention period: ${message_retention_period}s"

  if [[ -n "$redrive_policy_raw" ]]; then
    redrive_policy_configured="true"
    success "${queue_label} queue has a redrive policy configured"
    info "Redrive policy:"
    echo "$redrive_policy_raw" | jq .
  else
    info "${queue_label} queue does not have a redrive policy configured."
  fi

  producer_type="${producer_ref%%:*}"
  producer_suffix="${producer_ref#*:}"

  case "$producer_type" in
    sns)
      if [[ -z "$policy_raw" ]]; then
        fail "${queue_label} queue policy is missing. SNS-to-SQS delivery requires a queue policy allowing the SNS topic to send messages."
      fi

      success "${queue_label} queue policy exists"

      policy_json="$(echo "$policy_raw" | jq '.')"

      SNS_TOPIC_ARN_RESULT="<none>"
      SNS_SUBSCRIPTION_COUNT_RESULT="0"
      SNS_PENDING_COUNT_RESULT="0"

      validate_sns_producer_for_queue "$queue_label" "$queue_arn" "$producer_suffix" "$policy_json"

      sns_topic_arn="$SNS_TOPIC_ARN_RESULT"
      sns_subscription_count="$SNS_SUBSCRIPTION_COUNT_RESULT"
      sns_pending_count="$SNS_PENDING_COUNT_RESULT"
      ;;

    none)
      if [[ -n "$policy_raw" ]]; then
        success "${queue_label} queue policy exists"
      else
        info "${queue_label} queue policy not configured; no producer-specific policy check required."
      fi
      ;;

    *)
      fail "Unsupported SQS producer reference for ${queue_label}: ${producer_ref}"
      ;;
  esac

  TOTAL_VALIDATED_QUEUES=$((TOTAL_VALIDATED_QUEUES + 1))

  if [[ "$requirement" == "required" ]]; then
    TOTAL_REQUIRED_QUEUES=$((TOTAL_REQUIRED_QUEUES + 1))
  else
    TOTAL_OPTIONAL_QUEUES=$((TOTAL_OPTIONAL_QUEUES + 1))
  fi

  QUEUE_SUMMARY_ROWS+=("${queue_label}|${requirement}|${queue_name}|${queue_arn}|${producer_ref}|${sns_topic_arn}|${sns_subscription_count}|${sns_pending_count}|${kms_key_id:-<none>}|${sqs_managed_sse}|${redrive_policy_configured}|${approximate_number_of_messages}|${approximate_number_of_messages_not_visible}")
}

for queue_spec in "${EXPECTED_SQS_QUEUES[@]}"; do
  IFS='|' read -r queue_label queue_suffix requirement producer_ref <<< "$queue_spec"
  validate_sqs_queue "$queue_label" "$queue_suffix" "$requirement" "$producer_ref"
done

section "Listing environment SQS queues"

QUEUES_JSON="$(
  aws sqs list-queues \
    "${aws_args[@]}" \
    --queue-name-prefix "$NAME_PREFIX" \
    --output json
)"

MATCHING_QUEUE_COUNT="$(
  echo "$QUEUES_JSON" |
    jq '.QueueUrls // [] | length'
)"

if [[ "$MATCHING_QUEUE_COUNT" -gt 0 ]]; then
  success "Found SQS queues matching name prefix: $MATCHING_QUEUE_COUNT"
else
  fail "No SQS queues found matching name prefix: ${NAME_PREFIX}"
fi

info "Matching SQS queues:"
echo "$QUEUES_JSON" |
  jq -r '.QueueUrls // [] | .[] | "- " + .'

section "SQS Summary"

cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
AWS account ID:                     ${ACCOUNT_ID}
Name prefix:                        ${NAME_PREFIX}

Matching environment queues:        ${MATCHING_QUEUE_COUNT}
Required SQS queues validated:      ${TOTAL_REQUIRED_QUEUES}
Optional SQS queues validated:      ${TOTAL_OPTIONAL_QUEUES}
Total SQS queues validated:         ${TOTAL_VALIDATED_QUEUES}
Pending subscription confirmations: ${TOTAL_PENDING_SUBSCRIPTION_COUNT}
SUMMARY

if [[ "${#QUEUE_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Validated SQS queues:"
  printf '%s\n' "${QUEUE_SUMMARY_ROWS[@]}" |
    aws -F'|' '
      BEGIN {
        printf "%-14s %-10s %-45s %-95s %-32s %-95s %-14s %-10s %-40s %-10s %-8s %-10s %-10s\n", "Queue", "Required", "QueueName", "QueueArn", "Producer", "ProducerArn", "Subscriptions", "Pending", "KmsKeyId", "SQS-SSE", "DLQ", "Visible", "InFlight"
        printf "%-14s %-10s %-45s %-95s %-32s %-95s %-14s %-10s %-40s %-10s %-8s %-10s %-10s\n", "-----", "--------", "---------", "--------", "--------", "-----------", "-------------", "-------", "--------", "-------", "---", "-------", "--------"
      }
      {
        printf "%-14s %-10s %-45s %-95s %-32s %-95s %-14s %-10s %-40s %-10s %-8s %-10s %-10s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13
      }
    '
fi

section "Validation Result"

success "SQS validation comleted successfully for: ${ENV_NAME}"