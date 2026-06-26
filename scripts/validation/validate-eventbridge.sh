#!/usr/bin/env bash

# validate-eventbridge.sh
#
# Validates EventBridge buses, rules, and targets for a deployed
# tf-secure-baseline workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Environment EventBridge rules exist
# - Environment EventBridge rules are enabled
# - Environment EventBridge rules have targets
# - SecOps event bus exists
# - SecOps event bus rules are enabled and have targets, when present
# - EventBridge Lambda targets have configured DLQs
# - EventBridge Lambda targets have expected retry policies
# - EventBridge Lambda targets point to expected workflow DLQs
#
# Usage:
#   ./scripts/validation/validate-eventbridge.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-eventbridge.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-eventbridge.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-eventbridge.sh dev

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

section "tf-secure-baseline EventBridge Validation"

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

info "Repository root: ${REPO_ROOT}"
info "Environment: ${ENV_NAME}"
info "Environment dir: ${ENV_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

section "Checking AWS caller identity"

ACCOUNT_ID="$(get_aws_account_id "${AWS_PROFILE:-}" "${AWS_REGION:-}")"
CALLER_ARN="$(get_aws_caller_arn "${AWS_PROFILE:-}" "${AWS_REGION:-}")"

if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

success "AWS credentials are valid"
info "AWS account id: $ACCOUNT_ID"
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

# -----------------------------------------------------------------------------
# EventBridge helper functions
# -----------------------------------------------------------------------------

list_matching_rules_for_bus() {
  local event_bus_name="$1"

  aws events list-rules \
    "${aws_args[@]}" \
    --event-bus-name "$event_bus_name" \
    --output json |
      jq --arg prefix "$NAME_PREFIX" '
        [
          .Rules[]?
          | select(.Name | contains($prefix))
        ]
      '
}

validate_rule_targets() {
  local event_bus_name="$1"
  local rule_name="$2"
  local label="$3"

  local targets_json
  local target_count
  local target_arns

  targets_json="$(
    aws events list-targets-by-rule \
      "${aws_args[@]}" \
      --event-bus-name "$event_bus_name" \
      --rule "$rule_name" \
      --output json
  )"

  target_count="$(echo "$targets_json" | jq '.Targets | length')"

  if [[ "$target_count" -gt 0 ]]; then
    success "EventBridge rule has targets: ${rule_name} (${target_count})"
  else
    fail "EventBridge rule has no targets: ${rule_name}"
  fi

  target_arns="$(
    echo "$targets_json" |
      jq -r '
        [
          .Targets[]
          | .Arn
        ]
        | join(",")
      '
  )"

  RULE_SUMMARY_ROWS+=("${label}|${event_bus_name}|${rule_name}|${target_count}|${target_arns}")
  TOTAL_TARGET_COUNT=$((TOTAL_TARGET_COUNT + target_count))
}

validate_rules_json() {
  local event_bus_name="$1"
  local label="$2"
  local rules_json="$3"
  local required="$4"

  local rule_count
  local disabled_count

  rule_count="$(echo "$rules_json" | jq 'length')"

  if [[ "$rule_count" -eq 0 ]]; then
    if [[ "$required" == "true" ]]; then
      fail "No environment EventBridge rules found on required bus: ${event_bus_name}"
    else
      warn "No environment EventBridge rules found on optional bus: ${event_bus_name}"
      return 0
    fi
  fi

  success "Found EventBridge rules on ${label}: ${rule_count}"

  disabled_count="$(
    echo "$rules_json" |
      jq '[.[] | select(.State != "ENABLED")] | length'
  )"

  if [[ "$disabled_count" -eq 0 ]]; then
    success "All EventBridge rules on ${label} are enabled"
  else
    echo "$rules_json" |
      jq -r '.[] | select(.State != "ENABLED") | "- " + .Name + " state=" + .State'
    fail "One or more EventBridge rules on ${label} are not enabled"
  fi

  while IFS= read -r rule_name; do
    [[ -z "$rule_name" ]] && continue
    validate_rule_targets "$event_bus_name" "$rule_name" "$label"
    VALIDATED_RULE_COUNT=$((VALIDATED_RULE_COUNT + 1))
  done < <(echo "$rules_json" | jq -r '.[].Name')    
}

find_secops_event_bus_name() {
  echo "$EVENT_BUSES_JSON" |
    jq -r --arg prefix "$NAME_PREFIX" '
      [
        .EventBuses[]
        | select(.Name | contains($prefix))
        | select((.Name | ascii_downcase) | contains("secops"))
        | .Name
      ]
      | first // empty
    '
}

validate_expected_target_dlq() {
  local label="$1"
  local event_bus_name="$2"
  local rule_suffix="$3"
  local target_id="$4"
  local lambda_suffix="$5"
  local dlq_suffix="$6"
  local expected_max_attempts="$7"
  local expected_max_event_age="$8"

  local rule_name
  local expected_lambda_arn
  local expected_dlq_arn
  local targets_json
  local target_json
  local target_count
  local actual_target_arn
  local actual_dlq_arn
  local actual_max_attempts
  local actual_max_event_age

  rule_name="${NAME_PREFIX}-${rule_suffix}"
  expected_lambda_arn="arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:${NAME_PREFIX}-${lambda_suffix}"
  expected_dlq_arn="arn:aws:sqs:${AWS_REGION}:${ACCOUNT_ID}:${NAME_PREFIX}-${dlq_suffix}"

  section "Validating EventBridge DLQ target for ${label}"

  info "Event bus:        ${event_bus_name}"
  info "Rule:             ${rule_name}"
  info "Target ID:        ${target_id}"
  info "Expected Lambda:  ${expected_lambda_arn}"
  info "Expected DLQ:     ${expected_dlq_arn}"

  targets_json="$(
    aws events list-targets-by-rule \
      "${aws_args[@]}" \
      --event-bus-name "$event_bus_name" \
      --rule "$rule_name" \
      --output json
  )"

  target_count="$(
    echo "$targets_json" |
      jq --arg target_id "$target_id" '
        [
          .Targets[]
          | select(.Id == $target_id)
        ]
        | length
      '
  )"

  if [[ "$target_count" -eq 1 ]]; then
    success "${label} EventBridge target exists: ${target_id}"
  else
    echo "$targets_json" | jq '.Targets'
    fail "${label} EventBridge target not found or not unique: ${target_id}"
  fi

  target_json="$(
    echo "$targets_json" |
      jq --arg target_id "$target_id" '
        .Targets[]
        | select(.Id == $target_id)
      '
  )"

  actual_target_arn="$(echo "$target_json" | jq -r '.Arn // empty')"
  actual_dlq_arn="$(echo "$target_json" | jq -r '.DeadLetterConfig.Arn // empty')"
  actual_max_attempts="$(echo "$target_json" | jq -r '.RetryPolicy.MaximumRetryAttempts // empty')"
  actual_max_event_age="$(echo "$target_json" | jq -r '.RetryPolicy.MaximumEventAgeInSeconds // empty')"

  if [[ "$actual_target_arn" == "$expected_lambda_arn" ]]; then
    success "${label} target points to expected Lambda"
  else
    fail "${label} target ARN mismatch. Expected ${expected_lambda_arn}, got ${actual_target_arn:-<none>}"
  fi

  if [[ "$actual_dlq_arn" == "$expected_dlq_arn" ]]; then
    success "${label} target has expected DLQ: ${actual_dlq_arn}"
  else
    fail "${label} target DLQ mismatch. Expected ${expected_dlq_arn}, got ${actual_dlq_arn:-<none>}"
  fi

  if [[ "$actual_max_attempts" == "$expected_max_attempts" ]]; then
    success "${label} target retry attempts match expected value: ${actual_max_attempts}"
  else
    fail "${label} target retry attempts mismatch. Expected ${expected_max_attempts}, got ${actual_max_attempts:-<none>}"
  fi

  if [[ "$actual_max_event_age" == "$expected_max_event_age" ]]; then
    success "${label} target max event age matches expected value: ${actual_max_event_age}s"
  else
    fail "${label} target max event age mismatch. Expected ${expected_max_event_age}, got ${actual_max_event_age:-<none>}"
  fi
}

section "Listing EventBridge event buses"

EVENT_BUSES_JSON="$(
  aws events list-event-buses \
    "${aws_args[@]}" \
    --output json
)"

SECOPS_EVENT_BUS_NAME="$(find_secops_event_bus_name)"

if [[ -n "$SECOPS_EVENT_BUS_NAME" ]]; then
  success "SecOps EventBridge bus exists: $SECOPS_EVENT_BUS_NAME"
else
  fail "SecOps EventBridge bus not found. Expected bus name containing prefix '${NAME_PREFIX}' and keyword 'secops'."
fi

section "Validating default event bus rules"

DEFAULT_RULES_JSON="$(list_matching_rules_for_bus "default")"

VALIDATED_RULE_COUNT=0
TOTAL_TARGET_COUNT=0
RULE_SUMMARY_ROWS=()

validate_rules_json "default" "default bus" "$DEFAULT_RULES_JSON" "true"

section "Validating SecOps event bus rules"

SECOPS_RULES_JSON="$(list_matching_rules_for_bus "$SECOPS_EVENT_BUS_NAME")"

validate_rules_json "$SECOPS_EVENT_BUS_NAME" "secops bus" "$SECOPS_RULES_JSON" "true"

section "Checking expected EventBridge rule patterns"

SECURITY_RULE_COUNT="$(
  echo "$DEFAULT_RULES_JSON" |
    jq '
      [
        .[]
        | select(.Name | ascii_downcase | contains("security"))
      ]
      | length
    '
)"

SECOPS_ROLLBACK_RULE_COUNT="$(
  echo "$SECOPS_RULES_JSON" |
    jq '
      [
        .[]
        | select(
          (.Name | ascii_downcase | contains("rollback"))
          or (.Name | ascii_downcase | contains("restore"))
        )
      ]
      | length
    '
)"

if [[ "$SECURITY_RULE_COUNT" -gt 0 ]]; then
  success "Found security-related EventBridge rule pattern(s): $SECURITY_RULE_COUNT"
else
  warn "No security-related EventBridge rule names found on default bus."
fi

if [[ "$SECOPS_ROLLBACK_RULE_COUNT" -gt 0 ]]; then
  success "Found rollback/restore-related EventBridge rule pattern(s) on SecOps bus: $SECOPS_ROLLBACK_RULE_COUNT"
else
  warn "No rollback/restore-related EventBridge rule names found on SecOps bus."
fi

section "Validating expected EventBridge target DLQs and retry policies"

validate_expected_target_dlq \
  "EC2 Isolation" \
  "default" \
  "securityhub-ec2-high-critical" \
  "Ec2IsolationLambda" \
  "ec2-isolation" \
  "ec2-isolation-dlq" \
  "3" \
  "3600"

validate_expected_target_dlq \
  "IP Enrichment" \
  "default" \
  "securityhub-high-critical" \
  "IpEnrichmentLambda" \
  "ip-enrichment" \
  "ip-enrichment-dlq" \
  "3" \
  "3600"

validate_expected_target_dlq \
  "EC2 Rollback" \
  "$SECOPS_EVENT_BUS_NAME" \
  "ec2-rollback" \
  "Ec2RollbackLambda" \
  "ec2-rollback" \
  "ec2-rollback-dlq" \
  "3" \
  "3600"

section "EventBridge Summary"

DEFAULT_RULE_COUNT="$(echo "$DEFAULT_RULES_JSON" | jq 'length')"
SECOPS_RULE_COUNT="$(echo "$SECOPS_RULES_JSON" | jq 'length')"

cat <<SUMMARY
Environment:                    ${ENV_NAME}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACCOUNT_ID}
Name prefix:                    ${NAME_PREFIX}

SecOps event bus:               ${SECOPS_EVENT_BUS_NAME}
Default bus rules validated:    ${DEFAULT_RULE_COUNT}
SecOps bus rules validated:     ${SECOPS_RULE_COUNT}
Total rules validated:          ${VALIDATED_RULE_COUNT}
Total targets discovered:       ${TOTAL_TARGET_COUNT}
Security rule patterns:         ${SECURITY_RULE_COUNT}
SecOps rollback rule patterns:  ${SECOPS_ROLLBACK_RULE_COUNT}
SUMMARY

if [[ "${#RULE_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Validated rules:"
  printf '%s\n' "${RULE_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-14s %-70s %-10s\n", "Bus", "RuleName", "Targets"
        printf "%-14s %-70s %-10s\n", "---", "--------", "-------"
      }
      {
        printf "%-14s %-70s %-10s\n", $1, $3, $4
      }
    '

  echo
  echo "Rule targets:"
  printf '%s\n' "${RULE_SUMMARY_ROWS[@]}" |
    while IFS='|' read -r label event_bus_name rule_name target_count target_arns; do
      echo "- ${rule_name}"
      echo "$target_arns" | tr ',' '\n' | sed 's/^/  - /'
    done
fi

section "Validation Result"

success "EventBridge validation completed successfully for: ${ENV_NAME}"