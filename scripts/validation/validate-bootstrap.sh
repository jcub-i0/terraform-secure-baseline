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
#   STRICT_WORKLOAD_CMK_POLICY_CHECKS=false ./scripts/validation/validate-bootstrap.sh dev
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
#   - The backend files are the source of truth for state bucket location and
#     state locking behavior.
#   - Validation does not depend on local terraform.tfstate from
#     bootstrap/<env>/state, so the script can run from a fresh checkout.
#
#   Workload-created CMK policy validation:
#   - By default, stale/missing workload Lambda or Secrets Manager CMK policy
#     references fail validation.
#   - Set STRICT_WORKLOAD_CMK_POLICY_CHECKS=false to report stale/missing
#     workload CMK policy references as warnings instead of failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
require_env_name "$ENV_NAME"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"

REQUIRE_BOOTSTRAP_GITHUB_OIDC="${REQUIRE_BOOTSTRAP_GITHUB_OIDC:-true}"
REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE="${REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE:-true}"
STRICT_WORKLOAD_CMK_POLICY_CHECKS="${STRICT_WORKLOAD_CMK_POLICY_CHECKS:-true}"
REQUIRE_STATE_STACK_LOCAL="${REQUIRE_STATE_STACK_LOCAL:-true}"
STRICT_GITHUB_SUBJECT_CHECKS="${STRICT_GITHUB_SUBJECT_CHECKS:-true}"

EXPECTED_GITHUB_PLAN_SUBJECT="${EXPECTED_GITHUB_PLAN_SUBJECT:-}"
EXPECTED_GITHUB_APPLY_SUBJECT="${EXPECTED_GITHUB_APPLY_SUBJECT:-}"

# Workload-created CMK policy checks always run when workload outputs are readable.
# By default, stale/missing workload CMK policy references fail validation because
# they indicate the bootstrap account stack may not be reconciled with the current
# workload-created Lambda and Secrets Manager CMK ARNs.
# Set STRICT_WORKLOAD_CMK_POLICY_CHECKS=false to make those findings advisory.
case "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" in
  true|false)
    ;;
  *)
    fail "Invalid STRICT_WORKLOAD_CMK_POLICY_CHECKS: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}. Expected true or false."
    ;;
esac

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

get_backend_string_value() {
  local backend_file="$1"
  local attribute_name="$2"

  sed -nE "s/^[[:space:]]*${attribute_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" "$backend_file" |
    head -n 1
}

validate_backend_state_config() {
  local account_backend_file="$1"
  local env_backend_file="$2"

  section "Resolving state backend configuration from backend files"

  local account_backend_bucket
  local account_backend_region
  local account_backend_key
  local env_backend_bucket
  local env_backend_region
  local env_backend_key

  account_backend_bucket="$(get_backend_string_value "$account_backend_file" bucket)"
  account_backend_region="$(get_backend_string_value "$account_backend_file" region)"
  account_backend_key="$(get_backend_string_value "$account_backend_file" key)"

  env_backend_bucket="$(get_backend_string_value "$env_backend_file" bucket)"
  env_backend_region="$(get_backend_string_value "$env_backend_file" region)"
  env_backend_key="$(get_backend_string_value "$env_backend_file" key)"

  require_non_empty "$account_backend_bucket" "bootstrap/${ENV_NAME}/account backend bucket"
  require_non_empty "$account_backend_region" "bootstrap/${ENV_NAME}/account backend region"
  require_non_empty "$account_backend_key" "bootstrap/${ENV_NAME}/account backend key"

  require_non_empty "$env_backend_bucket" "environments/${ENV_NAME} backend bucket"
  require_non_empty "$env_backend_region" "environments/${ENV_NAME} backend region"
  require_non_empty "$env_backend_key" "environments/${ENV_NAME} backend key"

  if [[ "$account_backend_bucket" == "$env_backend_bucket" ]]; then
    success "Account and workload backends use the same state bucket: ${account_backend_bucket}"
  else
    fail "Account and workload backend bucket mismatch. Account: ${account_backend_bucket}; workload: ${env_backend_bucket}"
  fi

  if [[ "$account_backend_region" == "$env_backend_region" ]]; then
    success "Account and workload backends use the same state region: ${account_backend_region}"
  else
    fail "Account and workload backend region mismatch. Account: ${account_backend_region}; workload: ${env_backend_region}"
  fi

  if [[ "$account_backend_key" != "$env_backend_key" ]]; then
    success "Account and workload backends use distinct state keys"
  else
    fail "Account and workload backends use the same state key: ${account_backend_key}"
  fi

  if [[ "$account_backend_region" == "$AWS_REGION" ]]; then
    success "Backend region matches AWS_REGION: ${AWS_REGION}"
  else
    warn "Backend region (${account_backend_region}) differs from AWS_REGION (${AWS_REGION}). AWS API validation will still use AWS_REGION."
  fi

  TF_STATE_BUCKET_NAME="$account_backend_bucket"
  TF_STATE_BUCKET_ARN="arn:aws:s3:::${TF_STATE_BUCKET_NAME}"
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
}

check_s3_state_bucket() {
  local bucket_name="$1"

  section "Checking bootstrap state S3 bucket"

  aws s3api head-bucket \
    "${aws_args[@]}" \
    --bucket "$bucket_name" >/dev/null
  success "State bucket exists: ${bucket_name}"

  TF_STATE_BUCKET_ARN="arn:aws:s3:::${bucket_name}"
  success "Derived state bucket ARN from backend bucket: ${TF_STATE_BUCKET_ARN}"

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

  TF_STATE_BUCKET_CMK_ARN="$(
    aws kms describe-key \
      "${aws_args[@]}" \
      --key-id "$bucket_kms_key_id" \
      --query 'KeyMetadata.Arn' \
      --output text 2>/dev/null || true
  )"

  require_non_empty "$TF_STATE_BUCKET_CMK_ARN" "state bucket CMK ARN from bucket encryption configuration"
  success "Resolved state bucket encryption CMK from bucket configuration: ${TF_STATE_BUCKET_CMK_ARN}"
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
    success "State CMK ARN is valid"
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

role_policy_contains_value() {
  local role_arn="$1"
  local expected_value="$2"

  if [[ -z "$expected_value" || "$expected_value" == "null" ]]; then
    return 1
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

  [[ "$match_count" -gt 0 ]]
}

check_role_policy_contains_workload_cmk() {
  local role_arn="$1"
  local role_description="$2"
  local expected_value="$3"
  local expected_description="$4"

  if [[ -z "$expected_value" || "$expected_value" == "null" ]]; then
    local message="${expected_description} not set. Unable to check policy reference for ${role_description}."

    if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
      fail "$message"
    fi

    warn "$message"
    return 0
  fi

  if role_policy_contains_value "$role_arn" "$expected_value"; then
    success "${role_description} attached/inline policy references ${expected_description}"
    return 0
  fi

  local message="${role_description} attached/inline policies do not reference current ${expected_description}: ${expected_value}"

  if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
    local role_name
    role_name="$(get_role_name_from_arn "$role_arn")"

    local policy_documents
    policy_documents="$(get_all_policy_documents_for_role "$role_name")"

    echo "$policy_documents" | jq -s .
    fail "$message"
  fi

  warn "$message"
  warn "Re-apply bootstrap/${ENV_NAME}/account with the latest workload CMK outputs if strict least-privilege evidence is required."
  return 0
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

  info "Strict workload CMK policy checks: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}"

  require_directory "$env_dir"

  local env_outputs_json
  env_outputs_json="$(terraform_output_json_optional "$env_dir")"

  if [[ -z "$env_outputs_json" ]]; then
    local message="Unable to read Terraform outputs for environments/${ENV_NAME}. Run workload apply before checking workload CMK permissions."

    if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
      fail "$message"
    fi

    warn "$message"
    return 0
  fi

  local missing_outputs=0

  if terraform_output_exists "$env_outputs_json" lambda_cmk_arn; then
    success "environments/${ENV_NAME} Terraform output exists: lambda_cmk_arn"
  else
    warn "Missing Terraform output in environments/${ENV_NAME}: lambda_cmk_arn"
    missing_outputs=1
  fi

  if terraform_output_exists "$env_outputs_json" secrets_manager_cmk_arn; then
    success "environments/${ENV_NAME} Terraform output exists: secrets_manager_cmk_arn"
  else
    warn "Missing Terraform output in environments/${ENV_NAME}: secrets_manager_cmk_arn"
    missing_outputs=1
  fi

  if [[ "$missing_outputs" -ne 0 ]]; then
    local message="One or more workload CMK outputs are missing from environments/${ENV_NAME}."

    if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
      fail "$message"
    fi

    warn "$message"
    return 0
  fi

  local lambda_cmk_arn
  local secrets_manager_cmk_arn

  lambda_cmk_arn="$(get_output_string "$env_outputs_json" lambda_cmk_arn)"
  secrets_manager_cmk_arn="$(get_output_string "$env_outputs_json" secrets_manager_cmk_arn)"

  if [[ -z "$lambda_cmk_arn" || "$lambda_cmk_arn" == "null" || "$lambda_cmk_arn" == "None" ]]; then
    local message="Unable to resolve workload Lambda CMK ARN"

    if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
      fail "$message"
    fi

    warn "$message"
  else
    check_role_policy_contains_workload_cmk "$apply_role_arn" "Bootstrap GitHub Apply" "$lambda_cmk_arn" "workload Lambda CMK ARN"
  fi

  if [[ -z "$secrets_manager_cmk_arn" || "$secrets_manager_cmk_arn" == "null" || "$secrets_manager_cmk_arn" == "None" ]]; then
    local message="Unable to resolve workload Secrets Manager CMK ARN"

    if [[ "$STRICT_WORKLOAD_CMK_POLICY_CHECKS" == "true" ]]; then
      fail "$message"
    fi

    warn "$message"
  else
    check_role_policy_contains_workload_cmk "$apply_role_arn" "Bootstrap GitHub Apply" "$secrets_manager_cmk_arn" "workload Secrets Manager CMK ARN"
  fi
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

validate_backend_state_config "${ACCOUNT_DIR}/backend.tf" "${ENV_DIR}/backend.tf"

require_non_empty "$TF_STATE_BUCKET_NAME" "Terraform state bucket name resolved from backend files"
require_non_empty "$TF_STATE_BUCKET_ARN" "Terraform state bucket ARN resolved from backend files"

check_s3_state_bucket "$TF_STATE_BUCKET_NAME"
require_non_empty "$TF_STATE_BUCKET_CMK_ARN" "Terraform state CMK ARN resolved from bucket encryption"
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
GitHub plan role ARN:              ${PLAN_ROLE_ARN:-<not validated>}
GitHub apply role ARN:             ${APPLY_ROLE_ARN:-<not validated>}
Expected GitHub repository:        ${EXPECTED_GITHUB_REPOSITORY:-<not checked>}
Expected GitHub plan subject:      ${EXPECTED_GITHUB_PLAN_SUBJECT:-<not checked>}
Expected GitHub apply subject:     ${EXPECTED_GITHUB_APPLY_SUBJECT:-<not checked>}
Strict workload CMK policy checks: ${STRICT_WORKLOAD_CMK_POLICY_CHECKS}
SUMMARY

section "Validation Result"

success "Bootstrap validation completed successfully for: ${ENV_NAME}"