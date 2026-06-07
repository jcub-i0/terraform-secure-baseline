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
      ' >/dev/null
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

section "Validating expected IAM role"

# Core compute
EC2_ROLE="${NAME_PREFIX}-ec2_compute_role"

# Lambda automation
LAMBDA_ISOLATION_ROLE="${NAME_PREFIX}-lambda-ec2-isolation"
LAMBDA_ROLLBACK_ROLE="${NAME_PREFIX}-lambda-ec2-rollback"
LAMBDA_IP_ENRICHMENT_ROLE="${NAME_PREFIX}-lambda-ip-enrichment"

# Logging
CLOUDTRAIL_CW_ROLE="${NAME_PREFIX}-cloudtrail-cloudwatch-role"
VPC_FLOW_LOGS_ROLE="${NAME_PREFIX}-VpcFlowLogsRole"
CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE="${NAME_PREFIX}-CloudWatchLogsToFirehose"
FIREHOSE_FLOW_LOGS_ROLE="${NAME_PREFIX}-FirehoseFlowLogsRole"

# Security / operations
CONFIG_REMEDIATION_ROLE="${NAME_PREFIX}-ConfigRemediationRole"
BACKUP_ROLE="${NAME_PREFIX}-backup-role"
PATCH_MW_ROLE="${NAME_PREFIX}-patch-mw-role"
EVENTBRIDGE_SECOPS_ROLE="${NAME_PREFIX}-EventBridgePutEventsToSecopsBus"
BREAK_GLASS_ROLE="${NAME_PREFIX}-BreakGlass-Admin"

EXPECTED_ROLES=(
  "$EC2_ROLE"
  "$LAMBDA_ISOLATION_ROLE"
  "$LAMBDA_ROLLBACK_ROLE"
  "$LAMBDA_IP_ENRICHMENT_ROLE"
  "$CLOUDTRAIL_CW_ROLE"
  "$VPC_FLOW_LOGS_ROLE"
  "$CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE"
  "$FIREHOSE_FLOW_LOGS_ROLE"
  "$CONFIG_REMEDIATION_ROLE"
  "$BACKUP_ROLE"
  "$PATCH_MW_ROLE"
  "$EVENTBRIDGE_SECOPS_ROLE"
  "$BREAK_GLASS_ROLE"
)

for role_name in "${EXPECTED_ROLES[@]}"; do
  validate_role_exists "$role_name"
done

section "Validating service trust policies"

validate_service_trust "$EC2_ROLE" "ec2.amazonaws.com"

validate_service_trust "$LAMBDA_ISOLATION_ROLE" "lambda.amazonaws.com"
validate_service_trust "$LAMBDA_ROLLBACK_ROLE" "lambda.amazonaws.com"
validate_service_trust "$LAMBDA_IP_ENRICHMENT_ROLE" "lambda.amazonaws.com"

validate_service_trust "$CLOUDTRAIL_CW_ROLE" "cloudtrail.amazonaws.com"
validate_service_trust "$VPC_FLOW_LOGS_ROLE" "vpc-flow-logs.amazonaws.com"
validate_service_trust "$FIREHOSE_FLOW_LOGS_ROLE" "firehose.amazonaws.com"

# CloudWatch Logs service principals are often regional, i.e.
# logs.us-east-1.amazonaws.com. Validate the regional form first.
if trust_has_service_principal "$(get_role_json "$CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE")" "logs.${AWS_REGION}.amazonaws.com"; then
  success "Trust policy for ${CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE} includes service principal: logs.${AWS_REGION}.amazonaws.com"
elif trust_has_service_principal "$(get_role_json "$CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE")" "logs.amazonaws.com"; then
  success "Trust policy for ${CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE} includes service principal: logs.amazonaws.com"
else
  get_role_json "$CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE" | jq '.Role.AssumeRolePolicyDocument'
  fail "Trust policy for ${CLOUDWATCH_LOGS_TO_FIREHOSE_ROLE} does not include expected CloudWatch Logs service principal."
fi

# Depending on implementation, Config remediation may be assumed by SSM Automation
# or by Config. Accept either to avoid false negatives.
CONFIG_REMEDIATION_ROLE_JSON="$(get_role_json "$CONFIG_REMEDIATION_ROLE")"
if trust_has_service_principal "$CONFIG_REMEDIATION_ROLE_JSON" "ssm.amazonaws.com"; then
  success "Trust policy for ${CONFIG_REMEDIATION_ROLE} includes service principal: ssm.amazonaws.com"
elif trust_has_service_principal "$CONFIG_REMEDIATION_ROLE_JSON" "config.amazonaws.com"; then
  success "Trust policy for ${CONFIG_REMEDIATION_ROLE} includes service principal: config.amazonaws.com"
else
  echo "$CONFIG_REMEDIATION_ROLE_JSON" | jq '.Role.AssumeRolePolicyDocument'
  fail "Trust policy for ${CONFIG_REMEDIATION_ROLE} does not include ssm.amazonaws.com or config.amazonaws.com."
fi

validate_service_trust "$BACKUP_ROLE" "backup.amazonaws.com"
validate_service_trust "$PATCH_MW_ROLE" "ssm.amazonaws.com"
validate_service_trust "$EVENTBRIDGE_SECOPS_ROLE" "events.amazonaws.com"

section "Validating break-glass role trust policy"

BREAK_GLASS_ROLE_JSON="$(get_role_json "$BREAK_GLASS_ROLE")"

if trust_has_aws_principal "$BREAK_GLASS_ROLE_JSON"; then
  success "Break-glass role trust policy includes an AWS principal"
else
  echo "$BREAK_GLASS_ROLE_JSON" | jq '.Role.AssumeRolePolicyDocument'
  fail "Break-glass role trust policy does not include an AWS principal."
fi

if trust_has_mfa_condition "$BREAK_GLASS_ROLE_JSON"; then
  success "Break-glass role trust policy includes MFA condition"
else
  echo "$BREAK_GLASS_ROLE_JSON" | jq '.Role.AssumeRolePolicyDocument'
  warn "Break-glass role trust policy does not appear to include aws:MultiFactorAuthPresent. Review manually if MFA is enforced elsewhere."
fi

section "Checking role policy attachments"

for role_name in "${EXPECTED_ROLES[@]}"; do
  validate_role_has_some_policy "$role_name"
done

section "Checking optional GitHub OIDC roles"

GITHUB_PLAN_ROLE="${NAME_PREFIX}-github-plan-role"
GITHUB_APPLY_ROLE="${NAME_PREFIX}-github-apply-role"

GITHUB_PLAN_PRESENT="false"
GITHUB_APPLY_PRESENT="false"

if validate_optional_role_exists "$GITHUB_PLAN_ROLE"; then
  GITHUB_PLAN_PRESENT="true"
fi

if validate_optional_role_exists "$GITHUB_APPLY_ROLE"; then
  GITHUB_APPLY_PRESENT="true"
fi

if [[ "$GITHUB_PLAN_PRESENT" == "true" ]]; then
  GITHUB_PLAN_ROLE_JSON="$(get_role_json "$GITHUB_PLAN_ROLE")"

  if echo "$GITHUB_PLAN_ROLE_JSON" | jq -e '.Role.AssumeRolePolicyDocument.Statement | tostring | contains("token.actions.githubusercontent.com")' >/dev/null; then
    success "GitHub plan role trust references GitHub OIDC provider"
  else
    echo "$GITHUB_PLAN_ROLE_JSON" | jq '.Role.AssumeRolePolicyDocument'
    warn "GitHub plan role exists but trust policy does not appear to reference token.actions.githubusercontent.com"
  fi
fi

if [[ "$GITHUB_APPLY_PRESENT" == "true" ]]; then
  GITHUB_APPLY_ROLE_JSON="$(get_role_json "$GITHUB_APPLY_ROLE")"

  if echo "$GITHUB_APPLY_ROLE_JSON" | jq -e '.Role.AssumeRolePolicyDocument.Statement | tostring | contains("token.actions.githubusercontent.com")' >/dev/null; then
    success "GitHub apply role trust references GitHub OIDC provider"
  else
    echo "$GITHUB_APPLY_ROLE_JSON" | jq '.Role.AssumeRolePolicyDocument'
    warn "GitHub apply role exists but trust policy does not appear to reference token.actions.githubusercontent.com"
  fi
fi

section "Checking shared IAM policies from Terraform outputs"

LOGS_S3_READONLY_POLICY_NAME=""
LOGS_CMK_DECRYPT_POLICY_NAME=""

if terraform_output_exists "$OUTPUTS_JSON" logs_s3_readonly_policy_name; then
  LOGS_S3_READONLY_POLICY_NAME="$(get_terraform_output_value "$OUTPUTS_JSON" logs_s3_readonly_policy_name)"
  info "Resolved logs_s3_readonly_policy_name: $LOGS_S3_READONLY_POLICY_NAME"

  LOGS_S3_POLICY_ARN="$(managed_policy_exists_by_name "$LOGS_S3_READONLY_POLICY_NAME")"

  if [[ -n "$LOGS_S3_POLICY_ARN" && "$LOGS_S3_POLICY_ARN" != "None" ]]; then
    success "Shared IAM policy exists: $LOGS_S3_READONLY_POLICY_NAME"
    info "Policy ARN: $LOGS_S3_POLICY_ARN"
  else
    fail "Terraform output logs_s3_readonly_policy_name exists, but IAM policy was not found: $LOGS_S3_READONLY_POLICY_NAME"
  fi
else
  warn "Terraform output logs_s3_readonly_policy_name not found. Skipping shared logs S3 policy check."
fi

if terraform_output_exists "$OUTPUTS_JSON" logs_cmk_decrypt_policy_name; then
  LOGS_CMK_DECRYPT_POLICY_NAME="$(get_terraform_output_value "$OUTPUTS_JSON" logs_cmk_decrypt_policy_name)"
  info "Resolved logs_cmk_decrypt_policy_name: $LOGS_CMK_DECRYPT_POLICY_NAME"

  LOGS_CMK_POLICY_ARN="$(managed_policy_exists_by_name "$LOGS_CMK_DECRYPT_POLICY_NAME")"

  if [[ -n "$LOGS_CMK_POLICY_ARN" && "$LOGS_CMK_POLICY_ARN" != "None" ]]; then
    success "Shared IAM policy exists: $LOGS_CMK_DECRYPT_POLICY_NAME"
    info "Policy ARN: $LOGS_CMK_POLICY_ARN"
  else
    fail "Terraform output logs_cmk_decrypt_policy_name exists, but IAM policy was not found: $LOGS_CMK_DECRYPT_POLICY_NAME"
  fi
else
  warn "Terraform output logs_cmk_decrypt_policy_name not found. Skipping shared logs CMK decrypt policy check."
fi

section "IAM Summary"

cat <<SUMMARY
Environment:                  ${ENV_NAME}
AWS profile:                  ${AWS_PROFILE:-<default>}
AWS region:                   ${AWS_REGION}
AWS account ID:               ${ACCOUNT_ID}
Name prefix:                  ${NAME_PREFIX}

Expected baseline roles:      ${#EXPECTED_ROLES[@]}
GitHub plan role present:     ${GITHUB_PLAN_PRESENT}
GitHub apply role present:    ${GITHUB_APPLY_PRESENT}

Logs S3 policy output:        ${LOGS_S3_READONLY_POLICY_NAME:-<missing>}
Logs CMK policy output:       ${LOGS_CMK_DECRYPT_POLICY_NAME:-<missing>}
SUMMARY