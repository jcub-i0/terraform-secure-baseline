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
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline SNS Validation"

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
  echo "$TOPICS_JSON" |
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

# -----------------------------------------------------------------------------
# SNS helper functions
# -----------------------------------------------------------------------------
find_topic_by_keyword() {
  local keyword="$1"

  echo "$MATCHING_TOPICS_JSON" |
    jq -r --arg keyword "$keyword" '
      [
        .[]
        | select((.TopicArn | ascii_downcase) | contains($keyword))
        | .TopicArn
      ]
      | first // empty
    '
}

validate_topic() {
  local label="$1"
  local keyword="$2"
  local required="$3"

  local topic_arn
  local attrs_json
  local topic_name
  local kms_key_id
  local subscriptions_confirmed
  local subscriptions_pending
  local subscriptions_deleted
  local subscriptions_json
  local subscription_count
  local pending_count

  topic_arn="$(find_topic_by_keyword "$keyword")"

  if [[ -z "$topic_arn" ]]; then
    if [[ "$required" == "true" ]]; then
      fail "Required SNS topic not found for ${label}. Expected topic ARN containing prefix '${NAME_PREFIX}' and keyword '${keyword}'."
    else
      warn "Optional SNS topic not found for ${label}. Expected topic ARN containing prefix '${NAME_PREFIX}' and keyword '${keyword}'."
      return 0
    fi
  fi

  success "SNS topic exists for ${label}: ${topic_arn}"

  attrs_json="$(
    aws sns get-topic-attributes \
      "${aws_args[@]}" \
      --topic-arn "$topic_arn" \
      --output json
  )"

  topic_name="${topic_arn##*:}"
  kms_key_id="$(echo "$attrs_json" | jq -r '.Attributes.KmsMasterKeyId // empty')"
  subscriptions_confirmed="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsConfirmed // "0"')"
  subscriptions_pending="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsPending // "0"')"
  subscriptions_deleted="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsDeleted // "0"')"

  info "${label} topic name: ${topic_name:-<none>}"

  if [[ -n "$kms_key_id" ]]; then
    success "SNS topic for ${label} has KMS encryption configured: $kms_key_id"
  else
    warn "SNS topic for ${label} does not show KMS encryption in topic attributes."
  fi

  subscriptions_json="$(
    aws sns list-subscriptions-by-topic \
      "${aws_args[@]}" \
      --topic-arn "$topic_arn" \
      --output json
  )"

  subscription_count="$(echo "$subscriptions_json" | jq '.Subscriptions | length')"

  if [[ "$subscription_count" -gt 0 ]]; then
    success "SNS topic for ${label} has subscriptions: $subscription_count"
  else
    warn "SNS topic for ${label} has no subscriptions."
  fi

  pending_count="$(
    echo "$subscriptions_json" |
      jq '[.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation")] | length'
  )"

  if [[ "$pending_count" -eq 0 ]]; then
    success "SNS topic for ${label} has no pending subscription confirmations"
  else
    echo "$subscriptions_json" |
      jq '[.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation") | {
        Protocol,
        Endpoint,
        SubscriptionArn
      }]'
    warn "SNS topic for ${label} has pending subscription confirmations: $pending_count"
  fi

  VALIDATED_TOPIC_COUNT=$((VALIDATED_TOPIC_COUNT + 1))

  if [[ "$required" == "true" ]]; then
    REQUIRED_TOPIC_COUNT=$((REQUIRED_TOPIC_COUNT + 1))
  else
    OPTIONAL_TOPIC_COUNT=$((OPTIONAL_TOPIC_COUNT + 1))
  fi

  TOTAL_SUBSCRIPTION_COUNT=$((TOTAL_SUBSCRIPTION_COUNT + subscription_count))
  TOTAL_PENDING_SUBSCRIPTION_COUNT=$((TOTAL_PENDING_SUBSCRIPTION_COUNT + pending_count))

  topic_short="${topic_name#${NAME_PREFIX}-}"

  SNS_SUMMARY_ROWS+=("${label}|${topic_short}|${subscription_count}|${subscriptions_confirmed}|${subscriptions_pending}|$([[ -n "$kms_key_id" ]] && echo "SSE-KMS" || echo "none")")
}

section "Validating expected SNS topics"

VALIDATED_TOPIC_COUNT=0
REQUIRED_TOPIC_COUNT=0
OPTIONAL_TOPIC_COUNT=0
TOTAL_SUBSCRIPTION_COUNT=0
TOTAL_PENDING_SUBSCRIPTION_COUNT=0
SNS_SUMMARY_ROWS=()

# Keep these broad enough to match current topic names.
# These labels correspond to common baseline notification patterns:
# - security / SecOps alerts
# - compliance or general baseline notifications
# - automation workflow notifications
#
# If actual topic names are more specific, adjust the keywords after
# the first test run.

validate_topic "security notifications" "security-notifications" "true"
validate_topic "compliance notifications" "compliance-notifications" "true"

if [[ "$VALIDATED_TOPIC_COUNT" -eq 0 ]]; then
  warn "No expected SNS topic keywords matched. Falling back to validating all environment-matching topics."

  while IFS= read -r topic_arn; do
    [[ -z "$topic_arn" ]] && continue

    keyword="$(basename "$topic_arn")"

    # Direct fallback validation for any matching topic.
    attrs_json="$(
      aws sns get-topic-attributes \
        "${aws_args[@]}" \
        --topic-arn "$topic_arn" \
        --output json
    )"

    kms_key_id="$(echo "$attrs_json" | jq -r '.Attributes.KmsMasterKeyId // empty')"
    subscriptions_confirmed="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsConfirmed // "0"')"
    subscriptions_pending="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsPending // "0"')"
    subscriptions_deleted="$(echo "$attrs_json" | jq -r '.Attributes.SubscriptionsDeleted // "0"')"

    subscriptions_json="$(
      aws sns list-subscriptions-by-topic \
        "${aws_args[@]}" \
        --topic-arn "$topic_arn" \
        --output json
    )"

    subscription_count="$(echo "$subscriptions_json" | jq '.Subscriptions | length')"

    pending_count="$(
      echo "$subscriptions_json" |
        jq '[.Subscriptions[] | select(.SubscriptionArn == "PendingConfirmation")] | length'
    )"

    if [[ "$pending_count" -eq 0 ]]; then
      success "SNS topic has no pending subscription confirmations: $topic_arn"
    else
      warn "SNS topic has pending subscription confirmations: $topic_arn"
    fi

    if [[ -n "$kms_key_id" ]]; then
      success "SNS topic has KMS encryption configured: $topic_arn"
    else
      warn "SNS topic does not show KMS encryption in topic attributes: $topic_arn"
    fi

    VALIDATED_TOPIC_COUNT=$((VALIDATED_TOPIC_COUNT + 1))
    OPTIONAL_TOPIC_COUNT=$((OPTIONAL_TOPIC_COUNT + 1))
    TOTAL_SUBSCRIPTION_COUNT=$((TOTAL_SUBSCRIPTION_COUNT + subscription_count))
    TOTAL_PENDING_SUBSCRIPTION_COUNT=$((TOTAL_PENDING_SUBSCRIPTION_COUNT + pending_count))

    SNS_SUMMARY_ROWS+=("${keyword}|${topic_arn}|${subscription_count}|${subscriptions_confirmed}|${subscriptions_pending}|${subscriptions_deleted}|${kms_key_id:-<none>}")
  done < <(echo "$MATCHING_TOPICS_JSON" | jq -r '.[].TopicArn')
fi

if [[ "$VALIDATED_TOPIC_COUNT" -eq 0 ]]; then
  fail "SNS topics were found for the environment, but none could be validated."
fi

section "SNS Summary"

cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
AWS account ID:                     ${ACCOUNT_ID}
Name prefix:                        ${NAME_PREFIX}

Matching environment topics:        ${MATCHING_TOPIC_COUNT}
Required SNS topics validated:      ${REQUIRED_TOPIC_COUNT}
Optional SNS topics validated:      ${OPTIONAL_TOPIC_COUNT}
Total SNS topics validated:         ${VALIDATED_TOPIC_COUNT}
Total subscriptions discovered:     ${TOTAL_SUBSCRIPTION_COUNT}
Pending subscription confirmations: ${TOTAL_PENDING_SUBSCRIPTION_COUNT}
SUMMARY

if [[ "${#SNS_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Validated topics:"
  printf '%s\n' "${SNS_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-26s %-28s %-13s %-9s %-8s %-10s\n", "Label", "Topic", "Subs", "Confirmed", "Pending", "Encryption"
        printf "%-26s %-28s %-13s %-9s %-8s %-10s\n", "-----", "-----", "----", "---------", "-------", "----------"
      }
      {
        printf "%-26s %-28s %-13s %-9s %-8s %-10s\n", $1, $2, $3, $4, $5, $6
      }
    '
fi

section "Validation Result"

success "SNS validation completed successfully for: ${ENV_NAME}"