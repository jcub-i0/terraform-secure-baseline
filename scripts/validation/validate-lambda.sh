#!/usr/bin/env bash

# validate-lambda.sh
#
# Validates Lambda functions for a deployed tf-secure-baseline workload environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Expected Lambda functions exist
# - Functions are Active
# - Functions have expected execution roles
# - Functions have sane timeout and memory settings
# - Functions use KMS encryption where configured
# - Lambda resource policies are readable and summarized
#
# Usage:
#   ./scripts/validation/validate-lambda.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-lambda.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-lambda.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-lambda.sh dev

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

section "tf-secure-baseline Lambda Validation"

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

section "Listing Lambda functions"

FUNCTIONS_JSON="$(
  aws lambda list-functions \
    "${aws_args[@]}" \
    --output json
)"

MATCHING_FUNCTION_COUNT="$(
  echo "$FUNCTIONS_JSON" |
    jq --arg prefix "$NAME_PREFIX" '
      [
        .Functions[]
        | select(.FunctionName | contains($prefix))
      ]
    '
)"

MATCHING_FUNCTION_COUNT="$(echo "$MATCHING_FUNCTION_COUNT" | jq 'length')"

if [[ "$MATCHING_FUNCTION_COUNT" -gt 0 ]]; then
  success "Found Lambda functions matching name prefix: ${MATCHING_FUNCTION_COUNT}"
else
  fail "No Lambda functions found containing name prefix: ${NAME_PREFIX}"
fi

info "Matching Lambda functions:"
echo "$MATCHING_FUNCTIONS_JSON" |
  jq -r '.[] | "- " + .FunctionName'

# -----------------------------------------------------------------------------
# Lambda helper functions
# -----------------------------------------------------------------------------

validate_lambda_function() {
  local label="$1"
  local function_name="$2"
  local expected_role_keyword="$3"
  local require_vpc="$4"

  local config_json
  local state
  local runtime
  local role_arn
  local timeout
  local memory_size
  local kms_key_arn
  local subnet_count
  local security_group_count
  local env_var_count
  local policy_json
  local statement_count
  local eventbridge_permission_count

  if ! config_json="$(
    aws lambda get-function-configuration \
      "${aws_args[@]}" \
      --function-name "$function_name" \
      --output json 2>/dev/null
  )"; then
    fail "Required Lambda function not found: ${function_name}"
  fi

  success "Lambda function exists for ${label}: ${function_name}"

  state="$(echo "$config_json" | jq -r '.State // "Unknown"')"
  runtime="$(echo "$config_json" | jq -r '.Runtime // "unknown"')"
  role_arn="$(echo "$config_json" | jq -r '.Role // empty')"
  timeout="$(echo "$config_json" | jq -r '.Timeout // 0')"
  memory_size="$(echo "$config_json" | jq -r '.MemorySize // 0')"
  kms_key_arn="$(echo "$config_json" | jq -r '.KMSKeyArn // empty')"
  subnet_count="$(echo "$config_json" | jq '.VpcConfig.SubnetIds // [] | length')"
  security_group_count="$(echo "$config_json" | jq '.VpcConfig.SecurityGroupIds // [] | length')"
  env_var_count="$(echo "$config_json" | jq '.Environment.Variables // {} | length')"

  if [[ "$state" == "Active" ]]; then
    success "Lambda function is Active: ${function_name}"
  else
    fail "Lambda function is not Active: ${function_name}. State=${state}"
  fi

  if [[ "$runtime" == "unknown" || "$runtime" == "null" ]]; then
    fail "Lambda function runtime is missing: ${function_name}"
  else
    success "Lambda runtime for ${label}: ${runtime}"
  fi

  if [[ -n "$role_arn" && "$role_arn" == *"$expected_role_keyword"* ]]; then
    success "Lambda execution role matches expected keyword '${expected_role_keyword}' for ${label}"
  elif [[ -n "$role_arn" ]]; then
    warn "Lambda execution role for ${label} does not contain expected keyword '${expected_role_keyword}': ${role_arn}"
  else
    fail "Lambda execution role is missing for ${label}"
  fi

  if [[ "$timeout" -gt 0 ]]; then
    success "Lambda timeout is configured for ${label}: ${timeout}s"
  else
    fail "Lambda timeout is invalid for ${label}: ${timeout}"
  fi

  if [[ "$memory_size" -ge 128 ]]; then
    success "Lambda memory size is valid for ${label}: ${memory_size} MB"
  else
    fail "Lambda memory size is invalid for ${label}: ${memory_size} MB"
  fi

  if [[ -n "$kms_key_arn" ]]; then
    success "Lambda KMS key configured for ${label}: ${kms_key_arn}"
  else
    warn "Lambda KMS key is not configured for ${label}"
  fi

  if [[ "$require_vpc" == "true" ]]; then
    if [[ "$subnet_count" -gt 0 && "$security_group_count" -gt 0 ]]; then
      success "Lambda VPC config exists for ${label}: ${subnet_count} subnet(s), ${security_group_count} security group(s)"
    else
      fail "Lambda VPC config missing for ${label}. Subnets=${subnet_count}, SecurityGroups=${security_group_count}"
    fi
  else
    if [[ "$subnet_count" -gt 0 || "$security_group_count" -gt 0 ]]; then
      success "Lambda VPC config exists for ${label}: ${subnet_count} subnet(s), ${security_group_count} security group(s)"
    else
      info "Lambda VPC config not present for ${label}; not required by this validation."
    fi
  fi

  if [[ "$env_var_count" -gt 0 ]]; then
    success "Lambda environment variables are configured for ${label}: ${env_var_count}"
  else
    warn "Lambda environment variables are not configured for ${label}"
  fi

  if policy_json="$(
    aws lambda get-policy \
      "${aws_args[@]}" \
      --function-name "$function_name" \
      --output json 2>/dev/null
  )"; then
    statement_count="$(
      echo "$policy_json" |
        jq -r '.Policy' |
        jq '.Statement | length'
    )"

    eventbridge_permission_count="$(
      echo "$policy_json" |
        jq -r '.Policy' |
        jq '
          [
            .Statement[]
            | select(.Principal.Service? == "events.amazonaws.com")
          ]
          | length
        '
    )"

    success "Lambda resource policy exists for ${label}: ${statement_count} statement(s)"

    if [[ "$eventbridge_permission_count" -gt 0 ]]; then
      success "Lambda resource policy allows EventBridge invocation for ${label}"
    else
      warn "Lambda resource policy does not show EventBridge invocation permission for ${label}"
    fi
  else
    warn "Lambda resource policy not found for ${label}. This is expected if the function is not directly invoked by EventBridge or another AWS service."
    statement_count=0
    eventbridge_permission_count=0
  fi

  VALIDATED_FUNCTION_COUNT=$((VALIDATED_FUNCTION_COUNT + 1))

  LAMBDA_SUMMARY_ROWS+=("${label}|${function_name}|${runtime}|${state}|${timeout}|${memory_size}|${subnet_count}|${security_group_count}|${env_var_count}|${statement_count}|${eventbridge_permission_count}")
}

section "Validating expected Lambda functions"

VALIDATED_FUNCTION_COUNT=0
LAMBDA_SUMMARY_ROWS=()

validate_lambda_function "IP enrichment" "${NAME_PREFIX}-ip-enrichment" "ip-enrichment" "true"
validate_lambda_function "EC2 rollback" "${NAME_PREFIX}-ec2-rollback" "ec2-rollback" "true"
validate_lambda_function "EC2 isolation" "${NAME_PREFIX}-ec2-isolation" "ec2-isolation" "true"

section "Lambda Summary"

cat <<SUMMARY
Environment:                    ${ENV_NAME}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACCOUNT_ID}
Name prefix:                    ${NAME_PREFIX}

Matching environment functions: ${MATCHING_FUNCTION_COUNT}
Expected functions validated:   ${VALIDATED_FUNCTION_COUNT}
SUMMARY

if [[ "${#LAMBDA_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Validated functions:"
  printf '%s\n' "${LAMBDA_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-18s %-55s %-16s %-10s %-8s %-8s %-8s %-8s %-8s %-10s %-10s\n", "Label", "FunctionName", "Runtime", "State", "Timeout", "Memory", "Subnets", "SGs", "EnvVars", "PolicyStmts", "EBPerms"
        printf "%-18s %-55s %-16s %-10s %-8s %-8s %-8s %-8s %-8s %-10s %-10s\n", "-----", "------------", "-------", "-----", "-------", "------", "-------", "---", "-------", "-----------", "-------"
      }
      {
        printf "%-18s %-55s %-16s %-10s %-8s %-8s %-8s %-8s %-8s %-10s %-10s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
      }
    '
fi
