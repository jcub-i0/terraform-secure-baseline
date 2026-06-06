#!/usr/bin/env bash

# validate-iam.sh
#
# Validates IAM roles and trust policies for a deployed tf-secure-baseline
# environment.
#
# Checks:
# - Expected IAM roles exist
# - Service roles trust the expected AWS service principals
# - Break-glass role exists
# - Break-glass trust policy includes MFA protection when detectable
# - Optional GitHub OIDC roles are detected if present
# - Shared IAM policies from Terraform outputs exist if available
#
# Usage:
#   ./scripts/validation/validate-iam.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-iam.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-iam.sh dev

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

# IAM is global, but keeping region in AWS CLI calls is harmless and helps
# profiles that rely on a configured region.
if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline IAM Validation"

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
  fail "Unable to resolve AWS account ID."
fi

success "AWS credentials are valid"
info "AWS account ID: $ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

# -----------------------------------------------------------------------------
# IAM helper functions
# -----------------------------------------------------------------------------

get_role_json() {
    local role_name="$1"

    aws iam get-role \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --output json
}

role_exists() {
    local role_name="$1"

    aws iam get-role \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --query 'Role.RoleName' \
      --output text >/dev/null 2>&1
}

validate_role_exists() {
    local role_name="$1"

    if role_exists "$role_name"; then
      success "IAM role exists: $role_name"
    else
      fail "Expected IAM role not found: $role_name"
    fi
}

validate_optional_role_exists() {
    local role_name="$1"

    if role_exists "$role_name"; then
      success "Optional IAM role exists: $role_name"
      return 0
    else
      warn "Optional IAM role not found: $role_name"
      return 1
    fi
}

trust_has_service_principal() {
    local role_json="$1"
    local expected_service="$2"

    echo "$role_json" |
      jq -e --arg expected "$expected_service" '
        .Role.AssumeRolePolicyDocument.Statement
        | if type == "array" then . else [.] end
        | any(
          .Principal.Service? as $svc
          | (
              ($svc == $expected)
              or
              (($svc | type) == "array" and ($svc | index($expected)))
            )
        )
    ' >/dev/null
}

validate_service_trust() {
    local role_name="$1"
    local expected_service="$2"

    local role_json
    role_json="$(get_role_json "$role_name")"

    if trust_has_service_principal "$role_json" "$expected_service"; then
      success "Trust policy for ${role_name} includes service principal: ${expected_service}"
    else
      echo "$role_json" | jq '.Role.AssumeRolePolicyDocument'
      fail "Trust policy for ${role_name} does not include expected service principal: ${expected_service}."
    fi
}

trust_has_aws_principal() {
    local role_json="$1"

    echo "$role_json" |
      jq -e '
        .Role.AssumeRolePolicyDocument.Statement
        | if type == "array" then . else [.] end
        | any(.Principal.AWS? != null)
      ' >/dev/null
}

trust_has_mfa_condition() {
    local role_json="$1"

    echo "$role_json" |
      jq -e '
        .Role.AssumeRolePolicyDocument.Statement
        | if type == "array" then . else [.] end
        | any(
          .Condition? != null
          and (
            tostring
            | contains("aws:MultiFactorAuthPresent")
          )
        )
      '>/dev/null
}

managed_policy_exists_by_name() {
    local policy_name="$1"

    aws iam list-policies \
      "${aws_args[@]}" \
      --scope Local \
      --query "Policies[?PolicyName=='${policy_name}'].Arn | [0]" \
      --output text
}

validate_role_has_some_policy() {
    local role_name="$1"

    local attached_count
    local inline_count

    attached_count="$(
      aws iam list-attached-role-policies \
        "${aws_args[@]}" \
        --role-name "$role_name" \
        --query 'AttachedPolicies | length(@)' \
        --output text
    )"

    inline_count="$(
      aws iam list-role-policies \
        "${aws_args[@]}" \
        --role-name "$role_name" \
        --query 'PolicyNames | length(@)' \
        --output text
    )"

    if [[ "$attached_count" -gt 0 || "$inline_count" -gt 0 ]]; then
      success "IAM role has attached or inline policies: ${role_name} attached=${attached_count} inline=${inline_count}"
    else
      warn "IAM role has no attached or inline policies: ${role_name}"
    fi
}

