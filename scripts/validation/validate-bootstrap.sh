#!/usr/bin/env bash
#
# Validate workload bootstrap resources for tf-secure-baseline.
#
# Usage:
#   AWS_PROFILE=dev \
#   AWS_REGION=us-east-1 \
#   EXPECTED_ACCOUNT_ID=<dev-account-id> \
#   EXPECTED_GITHUB_REPOSITORY=<owner>/<repo> \
#   ./scripts/validation/validate-bootstrap.sh dev
#
# Optional:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-bootstrap.sh dev
#   REQUIRE_BOOTSTRAP_GITHUB_OIDC=false ./scripts/validation/validate-bootstrap.sh dev
#   STRICT_GITHUB_SUBJECT_CHECKS=false ./scripts/validation/validate-bootstrap.sh dev
#   REQUIRE_WORKLOAD_CMK_PERMS=false ./scripts/validation/validate-bootstrap.sh dev
#   REQUIRE_STATE_STACK_LOCAL=false ./scripts/validation/validate-bootstrap.sh dev
#
# Notes:
#   This script is intentionally read-only. It does not initialize Terraform
#   backends, migrate state, run GitHub workflows, assume roles, modify IAM
#   policies, or perform destroy/cleanup operations.
#
#   Expected architecture:
#   - bootstrap/<env>/state uses local Terraform state and creates the S3 state
#     bucket and state CMK.
#   - bootstrap/<env>/account uses an S3 backend with use_lockfile = true.
#   - environments/<env> uses an S3 backend with use_lockfile = true.
#   - The backend files are the source of truth for state locking behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
require_env_name "$ENV_NAME"

AWS_PROFILE="${AWS_PROFILE:-$ENV_NAME}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"

REQUIRE_BOOTSTRAP_GITHUB_OIDC="${REQUIRE_BOOTSTRAP_GITHUB_OIDC:-true}"
REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE="${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE:-true}"
REQUIRE_WORKLOAD_CMK_PERMS="${REQUIRE_WORKLOAD_CMK_PERMS:-true}"
REQUIRE_STATE_STACK_LOCAL="${REQUIRE_STATE_STACK_LOCAL:-true}"
STRICT_GITHUB_SUBJECT_CHECKS="${STRICT_GITHUB_SUBJECT_CHECKS:-true}"
STRICT_STATE_BUCKET_KMS_MATCH="${STRICT_STATE_BUCKET_KMS_MATCH:-false}"

EXPECTED_GITHUB_PLAN_SUBJECT="${EXPECTED_GITHUB_PLAN_SUBJECT:-}"
EXPECTED_GITHUB_APPLY_SUBJECT="${EXPECTED_GITHUB_APPLY_SUBJECT:-}"

export AWS_PAGER=""

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

# -----------------------------------------------------------------------------
# Local helpers
# -----------------------------------------------------------------------------

get_bootstrap_dir() {
  local repo_root="$1"
  local env_name="$2"

  echo "${repo_root}/bootstrap/${env_name}"
}

get_environment_dir() {
  local repo_root="$1"
  local env_name="$2"

  echo "${repo_root}/environments/${env_name}"
}

terraform_output_json_required() {
  local stack_dir="$1"
  local stack_name="$2"

  local outputs_json
  if ! outputs_json="$(terraform_output_json "$stack_dir")"; then
    fail "Unable to read Terraform outputs for ${stack_name}: ${stack_dir}"
  fi

  if [[ -z "$outputs_json" ]]; then
    fail "No Terraform output JSON returned for ${stack_name}: ${stack_dir}"
  fi

  echo "$outputs_json"
}

terraform_output_json_optional() {
  local stack_dir="$1"

  terraform_output_json "$stack_dir" 2>/dev/null || true
}

require_terraform_output() {
  local outputs_json="$1"
  local output_name="$2"
  local stack_name="$3"

  if terraform_output_exists "$outputs_json" "$output_name"; then
    success "${stack_name} Terraform output exists: ${output_name}"
  else
    fail "Missing required Terraform output in ${stack_name}: ${output_name}"
  fi
}

get_output_string() {
  local outputs_json="$1"
  local output_name="$2"

  echo "$outputs_json" | jq -r --arg name "$output_name" '.[$name].value // empty'
}

require_non_empty() {
  local value="$1"
  local description="$2"

  if [[ -z "$value" || "$value" == "null" || "$value" == "None" ]]; then
    fail "Unable to resolve ${description}"
  fi
}

get_role_name_from_arn() {
  local role_arn="$1"
  echo "${role_arn##*/}"
}

bucket_name_from_arn() {
  local bucket_arn="$1"
  echo "${bucket_arn#arn:aws:s3:::}"
}

resolve_kms_key_id() {
  local key_ref="$1"

  aws kms describe-key \
    "${aws_args[@]}" \
    --key-id "$key_ref" \
    --query 'KeyMetadata.KeyId' \
    --output text 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# AWS / Terraform validation helpers
# -----------------------------------------------------------------------------

validate_aws_identity() {
  section "Checking AWS caller identity"

  local account_id
  local caller_arn

  account_id="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
  caller_arn="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

  require_non_empty "$account_id" "AWS account ID"
  require_non_empty "$caller_arn" "AWS caller ARN"

  success "AWS identity resolved"
  info "AWS profile: ${AWS_PROFILE:-<default>}"
  info "AWS region: ${AWS_REGION}"
  info "Caller ARN: ${caller_arn}"
  info "Account ID: ${account_id}"

  if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
    if [[ "$account_id" == "$EXPECTED_ACCOUNT_ID" ]]; then
      success "AWS account matches EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID}"
    else
      fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${account_id}"
    fi
  else
    warn "EXPECTED_ACCOUNT_ID not set. Skipping expected account check."
  fi
}

validate_directories() {
  local repo_root="$1"
  local bootstrap_dir="$2"
  local state_dir="$3"
  local account_dir="$4"
  local env_dir="$5"

  section "Checking bootstrap stack directories"

  require_directory "$bootstrap_dir"
  success "Bootstrap environment directory exists: ${bootstrap_dir}"

  require_directory "$state_dir"
  success "Bootstrap state stack directory exists: ${state_dir}"

  require_directory "$account_dir"
  success "Bootstrap account stack directory exists: ${account_dir}"

  require_directory "$env_dir"
  success "Workload environment directory exists: ${env_dir}"

  require_file "${state_dir}/main.tf"
  require_file "${state_dir}/outputs.tf"
  require_file "${state_dir}/variables.tf"
  success "State stack Terraform files exist"

  require_file "${account_dir}/main.tf"
  require_file "${account_dir}/outputs.tf"
  require_file "${account_dir}/variables.tf"
  require_file "${account_dir}/backend.tf"
  success "Account stack Terraform files exist"

  require_file "${env_dir}/backend.tf"
  success "Workload environment backend file exists"

  info "Repository root: ${repo_root}"
}

validate_backend_locking() {
  local backend_file="$1"
  local description="$2"

  section "Checking ${description} backend locking"

  require_file "$backend_file"

  if grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true' "$backend_file"; then
    success "${description} backend uses S3 native lockfile: use_lockfile = true"
  else
    fail "${description} backend does not set use_lockfile = true"
  fi
}

validate_state_stack_local_backend() {
  local state_dir="$1"

  section "Checking bootstrap state stack backend mode"

  if [[ -f "${state_dir}/backend.tf" ]]; then
    local message="bootstrap/${ENV_NAME}/state has backend.tf. Expected local state for the root bootstrap state stack."
    if [[ "$REQUIRE_STATE_STACK_LOCAL" == "true" ]]; then
      fail "$message"
    else
      warn "$message"
    fi
  else
    success "bootstrap/${ENV_NAME}/state does not define a remote backend; local state bootstrap pattern is preserved"
  fi

  if [[ -f "${state_dir}/terraform.tfstate" ]]; then
    success "Local Terraform state file is present for bootstrap/${ENV_NAME}/state"
  else
    warn "Local Terraform state file not found in bootstrap/${ENV_NAME}/state. This may be expected if validation is running from a fresh checkout."
  fi
}

validate_state_outputs() {
  local state_outputs_json="$1"
  local active_account_id="$2"

  section "Checking bootstrap state Terraform outputs"

  local required_outputs=(
    tf_state_bucket_arn
    tf_state_bucket_name
    tf_state_bucket_cmk_arn
  )

  for output_name in "${required_outputs[@]}"; do
    require_terraform_output "$state_outputs_json" "$output_name" "bootstrap/${ENV_NAME}/state"
  done

  if terraform_output_exists "$state_outputs_json" account_id; then
    local output_account_id
    output_account_id="$(get_output_string "$state_outputs_json" account_id)"

    if [[ "$output_account_id" == "$active_account_id" ]]; then
      success "State stack account_id output matches active AWS account"
    else
      fail "State stack account_id output mismatch. Output: ${output_account_id}; active AWS account: ${active_account_id}"
    fi
  else
    warn "State stack account_id output not found. STS caller identity is being used as the authoritative account check."
  fi
}
check_s3_state_bucket() {
  local bucket_name="$1"
  local expected_bucket_arn="$2"
  local expected_kms_key_arn="$3"

  section "Checking bootstrap state S3 bucket"

  aws s3api head-bucket \
    "${aws_args[@]}" \
    --bucket "$bucket_name" >/dev/null
  success "State bucket exists: ${bucket_name}"

  local resolved_bucket_name
  resolved_bucket_name="$(bucket_name_from_arn "$expected_bucket_arn")"

  if [[ "$resolved_bucket_name" == "$bucket_name" ]]; then
    success "State bucket name matches Terraform bucket ARN"
  else
    fail "State bucket name/ARN mismatch. Name output: ${bucket_name}; ARN output: ${expected_bucket_arn}"
  fi

  local versioning_status
  versioning_status="$(
    aws s3api get-bucket-versioning \
      "${aws_args[@]}" \
      --bucket "$bucket_name" \
      --query 'Status' \
      --output text
  )"

  if [[ "$versioning_status" == "Enabled" ]]; then
    success "State bucket versioning is enabled"
  else
    fail "State bucket versioning is not enabled. Current status: ${versioning_status}"
  fi

  local public_access_block_json
  public_access_block_json="$(
    aws s3api get-public-access-block \
      "${aws_args[@]}" \
      --bucket "$bucket_name" \
      --output json
  )"

  local public_access_block_failures
  public_access_block_failures="$(
    echo "$public_access_block_json" |
      jq '[
        .PublicAccessBlockConfiguration.BlockPublicAcls,
        .PublicAccessBlockConfiguration.IgnorePublicAcls,
        .PublicAccessBlockConfiguration.BlockPublicPolicy,
        .PublicAccessBlockConfiguration.RestrictPublicBuckets
      ] | map(select(. != true)) | length'
  )"

  if [[ "$public_access_block_failures" -eq 0 ]]; then
    success "State bucket public access block is fully enabled"
  else
    echo "$public_access_block_json" | jq .
    fail "State bucket public access block is not fully enabled"
  fi

  local encryption_json
  encryption_json="$(
    aws s3api get-bucket-encryption \
      "${aws_args[@]}" \
      --bucket "$bucket_name" \
      --output json
  )"

  local sse_algorithm
  sse_algorithm="$(
    echo "$encryption_json" |
      jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm // ""'
  )"

  local bucket_kms_key_id
  bucket_kms_key_id="$(
    echo "$encryption_json" |
      jq -r '.ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.KMSMasterKeyID // ""'
  )"

  if [[ "$sse_algorithm" == "aws:kms" ]]; then
    success "State bucket uses SSE-KMS encryption"
  else
    echo "$encryption_json" | jq .
    fail "Expected state bucket to use SSE-KMS encryption, got: ${sse_algorithm:-<empty>}"
  fi

  require_non_empty "$bucket_kms_key_id" "state bucket KMS key ID"

  local expected_key_id
  local actual_key_id
  expected_key_id="$(resolve_kms_key_id "$expected_kms_key_arn")"
  actual_key_id="$(resolve_kms_key_id "$bucket_kms_key_id")"

  if [[ -n "$expected_key_id" && -n "$actual_key_id" && "$expected_key_id" == "$actual_key_id" ]]; then
    success "State bucket encryption uses expected CMK"
  else
    local message="State bucket KMS key does not resolve to expected CMK. Bucket: ${bucket_kms_key_id}; Terraform output: ${expected_kms_key_arn}"
    if [[ "$STRICT_STATE_BUCKET_KMS_MATCH" == "true" ]]; then
      fail "$message"
    else
      warn "$message"
    fi
  fi
}

check_kms_key() {
  local kms_key_arn="$1"

  section "Checking bootstrap state KMS key"

  local key_json
  key_json="$(
    aws kms describe-key \
      "${aws_args[@]}" \
      --key-id "$kms_key_arn" \
      --output json
  )"

  local key_arn
  local key_state
  local key_manager

  key_arn="$(echo "$key_json" | jq -r '.KeyMetadata.Arn')"
  key_state="$(echo "$key_json" | jq -r '.KeyMetadata.KeyState')"
  key_manager="$(echo "$key_json" | jq -r '.KeyMetadata.KeyManager')"

  if [[ "$key_arn" == "$kms_key_arn" ]]; then
    success "State CMK ARN matches Terraform output"
  else
    fail "State CMK ARN mismatch. Expected ${kms_key_arn}, got ${key_arn}"
  fi

  if [[ "$key_state" == "Enabled" ]]; then
    success "State CMK is enabled"
  else
    echo "$key_json" | jq .
    fail "State CMK is not enabled. Current state: ${key_state}"
  fi

  if [[ "$key_manager" == "CUSTOMER" ]]; then
    success "State CMK is customer-managed"
  else
    echo "$key_json" | jq .
    fail "Expected state CMK to be customer-managed, got: ${key_manager}"
  fi
}

validate_account_outputs() {
  local account_outputs_json="$1"

  section "Checking bootstrap account Terraform outputs"

  if [[ "$REQUIRE_BOOTSTRAP_GITHUB_OIDC" == "true" ]]; then
    require_terraform_output "$account_outputs_json" plan_role_github_arn "bootstrap/${ENV_NAME}/account"

    if [[ "$REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE" == "true" ]]; then
      require_terraform_output "$account_outputs_json" apply_role_github_arn "bootstrap/${ENV_NAME}/account"
    else
      warn "REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE is false. Apply role output is not required."
    fi
  else
    warn "REQUIRE_BOOTSTRAP_GITHUB_OIDC is false. Account GitHub OIDC outputs are not required."
  fi
}

check_oidc_provider() {
  section "Checking GitHub OIDC provider"

  local providers_json
  providers_json="$(
    aws iam list-open-id-connect-providers \
      "${aws_args[@]}" \
      --output json
  )"

  local oidc_provider_count
  oidc_provider_count="$(
    echo "$providers_json" |
      jq '[.OpenIDConnectProviderList[]? | select(.Arn | contains("token.actions.githubusercontent.com"))] | length'
  )"

  if [[ "$oidc_provider_count" -gt 0 ]]; then
    success "GitHub OIDC provider exists"
  else
    fail "GitHub OIDC provider was not found"
  fi
}

check_trust_policy_subject() {
  local trust_json="$1"
  local role_description="$2"
  local expected_subject="$3"

  if [[ -z "$expected_subject" ]]; then
    return 0
  fi

  local subject_count
  subject_count="$(
    echo "$trust_json" |
      jq --arg subject "$expected_subject" '[.. | strings | select(. == $subject or contains($subject))] | length'
  )"

  if [[ "$subject_count" -gt 0 ]]; then
    success "${role_description} trust policy references expected GitHub subject: ${expected_subject}"
  else
    local message="${role_description} trust policy does not reference expected GitHub subject: ${expected_subject}"
    if [[ "$STRICT_GITHUB_SUBJECT_CHECKS" == "true" ]]; then
      echo "$trust_json" | jq .
      fail "$message"
    else
      warn "$message"
    fi
  fi
}

check_github_role() {
  local role_arn="$1"
  local role_description="$2"
  local expected_subject="$3"

  local role_name
  role_name="$(get_role_name_from_arn "$role_arn")"

  require_non_empty "$role_name" "${role_description} role name"

  local role_json
  role_json="$(
    aws iam get-role \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --output json
  )"

  local resolved_arn
  resolved_arn="$(echo "$role_json" | jq -r '.Role.Arn')"

  if [[ "$resolved_arn" == "$role_arn" ]]; then
    success "${role_description} role exists: ${role_name}"
  else
    echo "$role_json" | jq .
    fail "${role_description} role ARN mismatch. Expected ${role_arn}, got ${resolved_arn}"
  fi

  local trust_json
  trust_json="$(echo "$role_json" | jq '.Role.AssumeRolePolicyDocument')"

  local has_github_federated_principal
  has_github_federated_principal="$(
    echo "$trust_json" |
      jq '[.. | strings | select(contains("token.actions.githubusercontent.com"))] | length'
  )"

  local has_web_identity_action
  has_web_identity_action="$(
    echo "$trust_json" |
      jq '[.. | strings | select(. == "sts:AssumeRoleWithWebIdentity")] | length'
  )"

  if [[ "$has_github_federated_principal" -gt 0 && "$has_web_identity_action" -gt 0 ]]; then
    success "${role_description} trust policy allows GitHub OIDC web identity"
  else
    echo "$trust_json" | jq .
    fail "${role_description} trust policy does not appear to allow GitHub OIDC web identity"
  fi

  if [[ -n "$EXPECTED_GITHUB_REPOSITORY" ]]; then
    local repo_condition_count
    repo_condition_count="$(
      echo "$trust_json" |
        jq --arg repo "$EXPECTED_GITHUB_REPOSITORY" '[.. | strings | select(contains("repo:" + $repo + ":"))] | length'
    )"

    if [[ "$repo_condition_count" -gt 0 ]]; then
      success "${role_description} trust policy references expected GitHub repository: ${EXPECTED_GITHUB_REPOSITORY}"
    else
      echo "$trust_json" | jq .
      fail "${role_description} trust policy does not reference expected GitHub repository: ${EXPECTED_GITHUB_REPOSITORY}"
    fi

    check_trust_policy_subject "$trust_json" "$role_description" "$expected_subject"
  else
    warn "EXPECTED_GITHUB_REPOSITORY not set. Skipping GitHub repository and subject checks for ${role_description}."
  fi
}

get_attached_policy_documents_for_role() {
  local role_name="$1"

  local attached_policies_json
  attached_policies_json="$(
    aws iam list-attached-role-policies \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --output json
  )"

  local policy_arns
  policy_arns="$(echo "$attached_policies_json" | jq -r '.AttachedPolicies[]?.PolicyArn')"

  if [[ -z "$policy_arns" ]]; then
    fail "No managed policies attached to role: ${role_name}"
  fi

  local policy_arn
  while IFS= read -r policy_arn; do
    [[ -z "$policy_arn" ]] && continue

    local default_version_id
    default_version_id="$(
      aws iam get-policy \
        "${aws_args[@]}" \
        --policy-arn "$policy_arn" \
        --query 'Policy.DefaultVersionId' \
        --output text
    )"

    aws iam get-policy-version \
      "${aws_args[@]}" \
      --policy-arn "$policy_arn" \
      --version-id "$default_version_id" \
      --query 'PolicyVersion.Document' \
      --output json
  done <<< "$policy_arns"
}

get_inline_policy_documents_for_role() {
  local role_name="$1"

  local inline_policy_names
  inline_policy_names="$(
    aws iam list-role-policies \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --query 'PolicyNames[]' \
      --output text
  )"

  if [[ -z "$inline_policy_names" || "$inline_policy_names" == "None" ]]; then
    return 0
  fi

  local policy_name
  for policy_name in $inline_policy_names; do
    aws iam get-role-policy \
      "${aws_args[@]}" \
      --role-name "$role_name" \
      --policy-name "$policy_name" \
      --query 'PolicyDocument' \
      --output json
  done
}

get_all_policy_documents_for_role() {
  local role_name="$1"

  get_attached_policy_documents_for_role "$role_name"
  get_inline_policy_documents_for_role "$role_name"
}

check_role_policy_contains() {
  local role_arn="$1"
  local role_description="$2"
  local expected_value="$3"
  local expected_description="$4"

  if [[ -z "$expected_value" || "$expected_value" == "null" ]]; then
    warn "${expected_description} not set. Skipping policy reference check for ${role_description}."
    return 0
  fi

  local role_name
  role_name="$(get_role_name_from_arn "$role_arn")"

  local policy_documents
  policy_documents="$(get_all_policy_documents_for_role "$role_name")"

  local match_count
  match_count="$(
    echo "$policy_documents" |
      jq -s --arg value "$expected_value" '[.. | strings | select(. == $value or contains($value))] | length'
  )"

  if [[ "$match_count" -gt 0 ]]; then
    success "${role_description} attached/inline policy references ${expected_description}"
  else
    echo "$policy_documents" | jq -s .
    fail "${role_description} attached/inline policies do not reference ${expected_description}: ${expected_value}"
  fi
}

check_github_role_policies() {
  local role_arn="$1"
  local role_description="$2"
  local tf_state_bucket_arn="$3"
  local tf_state_bucket_cmk_arn="$4"

  check_role_policy_contains "$role_arn" "$role_description" "$tf_state_bucket_arn" "Terraform state bucket ARN"
  check_role_policy_contains "$role_arn" "$role_description" "${tf_state_bucket_arn}/*" "Terraform state bucket object ARN including .tflock objects"
  check_role_policy_contains "$role_arn" "$role_description" "$tf_state_bucket_cmk_arn" "Terraform state CMK ARN"
}

check_workload_cmk_permissions() {
  local env_dir="$1"
  local apply_role_arn="$2"

  section "Checking workload-created CMK permissions on GitHub Apply role"

  if [[ "$REQUIRE_WORKLOAD_CMK_PERMS" != "true" ]]; then
    warn "REQUIRE_WORKLOAD_CMK_PERMS is false. Skipping workload Lambda/Secrets Manager CMK policy checks."
    return 0
  fi

  require_directory "$env_dir"

  local env_outputs_json
  env_outputs_json="$(terraform_output_json_optional "$env_dir")"

  if [[ -z "$env_outputs_json" ]]; then
    fail "Unable to read Terraform outputs for environments/${ENV_NAME}. Run workload apply before requiring workload CMK permission checks."
  fi

  require_terraform_output "$env_outputs_json" lambda_cmk_arn "environments/${ENV_NAME}"
  require_terraform_output "$env_outputs_json" secrets_manager_cmk_arn "environments/${ENV_NAME}"

  local lambda_cmk_arn
  local secrets_manager_cmk_arn

  lambda_cmk_arn="$(get_output_string "$env_outputs_json" lambda_cmk_arn)"
  secrets_manager_cmk_arn="$(get_output_string "$env_outputs_json" secrets_manager_cmk_arn)"

  require_non_empty "$lambda_cmk_arn" "workload Lambda CMK ARN"
  require_non_empty "$secrets_manager_cmk_arn" "workload Secrets Manager CMK ARN"

  check_role_policy_contains "$apply_role_arn" "Bootstrap GitHub Apply" "$lambda_cmk_arn" "workload Lambda CMK ARN"
  check_role_policy_contains "$apply_role_arn" "Bootstrap GitHub Apply" "$secrets_manager_cmk_arn" "workload Secrets Manager CMK ARN"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

section "tf-secure-baseline bootstrap validation: ${ENV_NAME}"

require_command aws
require_command terraform
require_command jq
require_command git

REPO_ROOT="$(get_repo_root)"
BOOTSTRAP_DIR="$(get_bootstrap_dir "$REPO_ROOT" "$ENV_NAME")"
STATE_DIR="${BOOTSTRAP_DIR}/state"
ACCOUNT_DIR="${BOOTSTRAP_DIR}/account"
ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$ENV_NAME")"

validate_aws_identity
ACTIVE_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"

validate_directories "$REPO_ROOT" "$BOOTSTRAP_DIR" "$STATE_DIR" "$ACCOUNT_DIR" "$ENV_DIR"
validate_state_stack_local_backend "$STATE_DIR"
validate_backend_locking "${ACCOUNT_DIR}/backend.tf" "bootstrap/${ENV_NAME}/account"
validate_backend_locking "${ENV_DIR}/backend.tf" "environments/${ENV_NAME}"

STATE_OUTPUTS_JSON="$(terraform_output_json_required "$STATE_DIR" "bootstrap/${ENV_NAME}/state")"
validate_state_outputs "$STATE_OUTPUTS_JSON" "$ACTIVE_ACCOUNT_ID"

TF_STATE_BUCKET_ARN="$(get_output_string "$STATE_OUTPUTS_JSON" tf_state_bucket_arn)"
TF_STATE_BUCKET_NAME="$(get_output_string "$STATE_OUTPUTS_JSON" tf_state_bucket_name)"
TF_STATE_BUCKET_CMK_ARN="$(get_output_string "$STATE_OUTPUTS_JSON" tf_state_bucket_cmk_arn)"

require_non_empty "$TF_STATE_BUCKET_ARN" "Terraform state bucket ARN"
require_non_empty "$TF_STATE_BUCKET_NAME" "Terraform state bucket name"
require_non_empty "$TF_STATE_BUCKET_CMK_ARN" "Terraform state CMK ARN"

check_s3_state_bucket "$TF_STATE_BUCKET_NAME" "$TF_STATE_BUCKET_ARN" "$TF_STATE_BUCKET_CMK_ARN"
check_kms_key "$TF_STATE_BUCKET_CMK_ARN"

ACCOUNT_OUTPUTS_JSON="$(terraform_output_json_required "$ACCOUNT_DIR" "bootstrap/${ENV_NAME}/account")"
validate_account_outputs "$ACCOUNT_OUTPUTS_JSON"

PLAN_ROLE_ARN="$(get_output_string "$ACCOUNT_OUTPUTS_JSON" plan_role_github_arn)"
APPLY_ROLE_ARN="$(get_output_string "$ACCOUNT_OUTPUTS_JSON" apply_role_github_arn)"

if [[ "$REQUIRE_BOOTSTRAP_GITHUB_OIDC" == "true" ]]; then
  require_non_empty "$PLAN_ROLE_ARN" "bootstrap GitHub plan role ARN"
  check_oidc_provider

  if [[ -n "$EXPECTED_GITHUB_REPOSITORY" && -z "$EXPECTED_GITHUB_PLAN_SUBJECT" ]]; then
    EXPECTED_GITHUB_PLAN_SUBJECT="repo:${EXPECTED_GITHUB_REPOSITORY}:environment:${ENV_NAME}-plan"
  fi

  section "Checking bootstrap GitHub Plan role"
  check_github_role "$PLAN_ROLE_ARN" "Bootstrap GitHub Plan" "$EXPECTED_GITHUB_PLAN_SUBJECT"
  check_github_role_policies "$PLAN_ROLE_ARN" "Bootstrap GitHub Plan" "$TF_STATE_BUCKET_ARN" "$TF_STATE_BUCKET_CMK_ARN"

  if [[ "$REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE" == "true" ]]; then
    require_non_empty "$APPLY_ROLE_ARN" "bootstrap GitHub apply role ARN"

    if [[ -n "$EXPECTED_GITHUB_REPOSITORY" && -z "$EXPECTED_GITHUB_APPLY_SUBJECT" ]]; then
      EXPECTED_GITHUB_APPLY_SUBJECT="repo:${EXPECTED_GITHUB_REPOSITORY}:environment:${ENV_NAME}"
    fi

    section "Checking bootstrap GitHub Apply role"
    check_github_role "$APPLY_ROLE_ARN" "Bootstrap GitHub Apply" "$EXPECTED_GITHUB_APPLY_SUBJECT"
    check_github_role_policies "$APPLY_ROLE_ARN" "Bootstrap GitHub Apply" "$TF_STATE_BUCKET_ARN" "$TF_STATE_BUCKET_CMK_ARN"
    check_workload_cmk_permissions "$ENV_DIR" "$APPLY_ROLE_ARN"
  else
    warn "REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE is false. Skipping apply role validation."
  fi
else
  warn "REQUIRE_BOOTSTRAP_GITHUB_OIDC is false. Skipping GitHub OIDC role validation."
fi

section "Bootstrap validation summary"
cat <<SUMMARY
Environment:                       ${ENV_NAME}
AWS profile:                       ${AWS_PROFILE:-<default>}
AWS region:                        ${AWS_REGION}
AWS account ID:                    ${ACTIVE_ACCOUNT_ID}
Name prefix:                       ${NAME_PREFIX}
State bucket:                      ${TF_STATE_BUCKET_NAME}
State bucket ARN:                  ${TF_STATE_BUCKET_ARN}
State CMK ARN:                     ${TF_STATE_BUCKET_CMK_ARN}
State locking mode:                S3 native lockfile (use_lockfile = true)
GitHub plan role ARN:              ${PLAN_ROLE_ARN:-<not validated>}
GitHub apply role ARN:             ${APPLY_ROLE_ARN:-<not validated>}
Expected GitHub repository:        ${EXPECTED_GITHUB_REPOSITORY:-<not checked>}
Expected GitHub plan subject:      ${EXPECTED_GITHUB_PLAN_SUBJECT:-<not checked>}
Expected GitHub apply subject:     ${EXPECTED_GITHUB_APPLY_SUBJECT:-<not checked>}
Workload CMK permission checks:    ${REQUIRE_WORKLOAD_CMK_PERMS}
SUMMARY

section "Validation Result"

success "Bootstrap validation completed successfully for: ${ENV_NAME}"