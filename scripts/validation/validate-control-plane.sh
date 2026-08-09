#!/usr/bin/env bash

# validate-control-plane.sh
#
# Validates read-only control-plane foundations for tf-secure-baseline.
#
# Scope:
#   - Control-plane AWS caller identity
#   - bootstrap/control_plane/state backend resources and optional remote-state proof
#   - bootstrap/control_plane/account GitHub OIDC roles
#   - bootstrap/control_plane/organizations Organization mode, OU structure,
#     account placement, and centralized-security prerequisites
#   - bootstrap/control_plane/identity_center instance, groups, permission sets,
#     and optional account assignments
#
# Usage:
#   AWS_PROFILE=control-plane \
#   AWS_REGION=us-east-1 \
#   EXPECTED_ACCOUNT_ID=<control-plane-account-id> \
#   ./scripts/validation/validate-control-plane.sh
#
# Optional:
#   REQUIRE_STATE_STACK_REMOTE=true
#   NAME_PREFIX=tf-secure-baseline-control-plane
#   EXPECTED_GITHUB_REPOSITORY=owner/repo
#   IDENTITY_CENTER_WORKLOADS='<JSON workload configuration map>'
#   IDENTITY_CENTER_SECOPS='<JSON security-operations configuration object>'
#
# The same values may be supplied through Terraform's standard environment
# variable names:
#   TF_VAR_identity_center_workloads
#   TF_VAR_identity_center_secops
#
# Notes:
#   This script is intentionally read-only. It does not run GitHub workflows,
#   assume roles, modify Identity Center assignments, move accounts, or perform
#   destroy/cleanup operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CONTROL_PLANE_ENV_NAME="${CONTROL_PLANE_ENV_NAME:-control-plane}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${CONTROL_PLANE_ENV_NAME}}"

REQUIRE_CONTROL_PLANE_GITHUB_OIDC="${REQUIRE_CONTROL_PLANE_GITHUB_OIDC:-true}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
CHECK_OPTIONAL_SECOPS_GROUPS="${CHECK_OPTIONAL_SECOPS_GROUPS:-false}"
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-true}"
REQUIRE_STATE_STACK_REMOTE="${REQUIRE_STATE_STACK_REMOTE:-false}"

WORKLOADS_OU_NAME="${WORKLOADS_OU_NAME:-Workloads}"
NONPROD_OU_NAME="${NONPROD_OU_NAME:-NonProd}"
PROD_OU_NAME="${PROD_OU_NAME:-Prod}"
SECURITY_OU_NAME="${SECURITY_OU_NAME:-Security}"
SECURITY_OPERATIONS_ACCOUNT_NAME="${SECURITY_OPERATIONS_ACCOUNT_NAME:-security-operations}"

for boolean_setting in   REQUIRE_CONTROL_PLANE_GITHUB_OIDC   CHECK_OPTIONAL_SECOPS_GROUPS   STRICT_IDENTITY_CENTER_ASSIGNMENTS   STRICT_ACCOUNT_OU_CHECKS   REQUIRE_STATE_STACK_REMOTE; do
  boolean_value="${!boolean_setting}"
  case "$boolean_value" in
    true|false)
      ;;
    *)
      fail "Invalid ${boolean_setting}: ${boolean_value}. Expected true or false."
      ;;
  esac
done

IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS:-${TF_VAR_identity_center_workloads:-}}"
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS:-${TF_VAR_identity_center_secops:-}}"

ACCOUNT_ID_DEV=""
ACCOUNT_ID_STAGING=""
ACCOUNT_ID_PROD=""
ACCOUNT_ID_SECOPS=""

ORGANIZATION_ID=""
ORGANIZATION_ROOT_ID=""
WORKLOADS_OU_ID=""
NONPROD_OU_ID=""
PROD_OU_ID=""
SECURITY_OU_ID=""

ENABLE_SECOPS_ANALYST_DEV="false"
ENABLE_SECOPS_ANALYST_STAGING="false"
ENABLE_SECOPS_ANALYST_PROD="false"
ENABLE_SECOPS_ANALYST_SECOPS="false"
ENABLE_SECOPS_ENGINEER_DEV="false"
ENABLE_SECOPS_ENGINEER_STAGING="false"
ENABLE_SECOPS_ENGINEER_PROD="false"
ENABLE_SECOPS_ENGINEER_SECOPS="false"

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

get_control_plane_dir() {
  local repo_root="$1"
  echo "${repo_root}/bootstrap/control_plane"
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
  terraform_output_json "$stack_dir" 2>/dev/null || echo "{}"
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

get_output_string_values() {
  local outputs_json="$1"
  local output_name="$2"

  echo "$outputs_json" |
    jq -r --arg name "$output_name" '
      if has($name) then
        .[$name].value
        | ..
        | strings
        | select(length > 0)
      else
        empty
      end
    '
}

get_role_name_from_arn() {
  local role_arn="$1"
  echo "${role_arn##*/}"
}

require_non_empty() {
  local value="$1"
  local description="$2"

  if [[ -z "$value" || "$value" == "null" || "$value" == "None" ]]; then
    fail "Unable to resolve ${description}"
  fi
}

resolve_identity_center_configuration() {
  section "Checking Identity Center configuration inputs"

  if [[ -z "$IDENTITY_CENTER_WORKLOADS" ]]; then
    fail "IDENTITY_CENTER_WORKLOADS or TF_VAR_identity_center_workloads must be set"
  fi

  if [[ -z "$IDENTITY_CENTER_SECOPS" ]]; then
    fail "IDENTITY_CENTER_SECOPS or TF_VAR_identity_center_secops must be set"
  fi

  if ! jq -e '
    type == "object" and
    has("dev") and
    has("staging") and
    has("prod") and
    all(
      .dev,
      .staging,
      .prod;
      type == "object" and
      (.account_id | type == "string" and test("^[0-9]{12}$")) and
      (.primary_region | type == "string" and length > 0) and
      ((.enable_secops_analyst // false) | type == "boolean") and
      ((.enable_secops_engineer // false) | type == "boolean")
    )
  ' >/dev/null <<<"$IDENTITY_CENTER_WORKLOADS"; then
    fail "IDENTITY_CENTER_WORKLOADS does not match the expected workload configuration structure"
  fi

  if ! jq -e '
    type == "object" and
    (.account_id | type == "string" and test("^[0-9]{12}$")) and
    ((.enable_secops_analyst // false) | type == "boolean") and
    ((.enable_secops_engineer // false) | type == "boolean")
  ' >/dev/null <<<"$IDENTITY_CENTER_SECOPS"; then
    fail "IDENTITY_CENTER_SECOPS does not match the expected security-operations configuration structure"
  fi

  ACCOUNT_ID_DEV="$(jq -r '.dev.account_id' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ACCOUNT_ID_STAGING="$(jq -r '.staging.account_id' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ACCOUNT_ID_PROD="$(jq -r '.prod.account_id' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ACCOUNT_ID_SECOPS="$(jq -r '.account_id' <<<"$IDENTITY_CENTER_SECOPS")"

  ENABLE_SECOPS_ANALYST_DEV="$(jq -r '.dev.enable_secops_analyst // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ANALYST_STAGING="$(jq -r '.staging.enable_secops_analyst // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ANALYST_PROD="$(jq -r '.prod.enable_secops_analyst // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ANALYST_SECOPS="$(jq -r '.enable_secops_analyst // false' <<<"$IDENTITY_CENTER_SECOPS")"

  ENABLE_SECOPS_ENGINEER_DEV="$(jq -r '.dev.enable_secops_engineer // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ENGINEER_STAGING="$(jq -r '.staging.enable_secops_engineer // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ENGINEER_PROD="$(jq -r '.prod.enable_secops_engineer // false' <<<"$IDENTITY_CENTER_WORKLOADS")"
  ENABLE_SECOPS_ENGINEER_SECOPS="$(jq -r '.enable_secops_engineer // false' <<<"$IDENTITY_CENTER_SECOPS")"

  success "Identity Center workload and security-operations configuration inputs are valid"
  info "Dev account ID: ${ACCOUNT_ID_DEV}"
  info "Staging account ID: ${ACCOUNT_ID_STAGING}"
  info "Prod account ID: ${ACCOUNT_ID_PROD}"
  info "Security-operations account ID: ${ACCOUNT_ID_SECOPS}"
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

handle_state_stack_remote_issue() {
  local message="$1"

  if [[ "$REQUIRE_STATE_STACK_REMOTE" == "true" ]]; then
    fail "$message"
  else
    warn "${message} REQUIRE_STATE_STACK_REMOTE=false, so this finding is advisory."
  fi
}

validate_state_stack_remote_backend() {
  local state_dir="$1"
  local expected_bucket_name="$2"
  local backend_file="${state_dir}/backend.tf"

  section "Checking control-plane state stack remote backend"

  if [[ ! -f "$backend_file" ]]; then
    handle_state_stack_remote_issue \
      "Control-plane state backend file was not found: ${backend_file}"
    return 0
  fi

  if grep -Eq 'backend[[:space:]]+"s3"' "$backend_file"; then
    success "Control-plane state stack declares an S3 backend"
  else
    handle_state_stack_remote_issue \
      "Control-plane state stack does not declare an S3 backend: ${backend_file}"
    return 0
  fi

  if grep -Eq '^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*true' "$backend_file"; then
    success "Control-plane state stack uses S3 native locking: use_lockfile = true"
  else
    handle_state_stack_remote_issue \
      "Control-plane state stack does not set use_lockfile = true"
  fi

  local backend_bucket
  local backend_key
  local backend_region

  backend_bucket="$(get_backend_string_value "$backend_file" bucket)"
  backend_key="$(get_backend_string_value "$backend_file" key)"
  backend_region="$(get_backend_string_value "$backend_file" region)"

  if [[ -z "$backend_bucket" ]]; then
    handle_state_stack_remote_issue \
      "Unable to resolve the control-plane state backend bucket from ${backend_file}"
    return 0
  fi

  if [[ -z "$backend_key" ]]; then
    handle_state_stack_remote_issue \
      "Unable to resolve the control-plane state backend key from ${backend_file}"
    return 0
  fi

  if [[ -z "$backend_region" ]]; then
    handle_state_stack_remote_issue \
      "Unable to resolve the control-plane state backend region from ${backend_file}"
    return 0
  fi

  info "Control-plane state backend bucket: ${backend_bucket}"
  info "Control-plane state backend key: ${backend_key}"
  info "Control-plane state backend region: ${backend_region}"

  if [[ "$backend_bucket" == "$expected_bucket_name" ]]; then
    success "Control-plane state backend bucket matches the state stack output"
  else
    handle_state_stack_remote_issue \
      "Control-plane state backend bucket mismatch. Backend: ${backend_bucket}; state output: ${expected_bucket_name}"
  fi

  if [[ "$backend_region" == "$AWS_REGION" ]]; then
    success "Control-plane state backend region matches AWS_REGION: ${AWS_REGION}"
  else
    handle_state_stack_remote_issue \
      "Control-plane state backend region mismatch. Backend: ${backend_region}; AWS_REGION: ${AWS_REGION}"
  fi

  if aws s3api head-object \
    "${aws_args[@]}" \
    --bucket "$backend_bucket" \
    --key "$backend_key" >/dev/null 2>&1; then
    success "Control-plane state object exists and is readable: s3://${backend_bucket}/${backend_key}"
  else
    handle_state_stack_remote_issue \
      "Control-plane state object was not found or is not readable: s3://${backend_bucket}/${backend_key}"
    return 0
  fi

  if terraform -chdir="$state_dir" state pull >/dev/null 2>&1; then
    success "Control-plane state is readable through the configured remote backend"
  else
    handle_state_stack_remote_issue \
      "Unable to read control-plane state through the configured backend"
  fi
}

check_s3_state_bucket() {
  local bucket_name="$1"
  local expected_kms_key_arn="$2"

  section "Checking Terraform state S3 bucket"

  aws s3api head-bucket \
    "${aws_args[@]}" \
    --bucket "$bucket_name" >/dev/null
  success "State bucket exists: ${bucket_name}"

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

  if [[ -n "$expected_kms_key_arn" && "$expected_kms_key_arn" != "null" ]]; then
    if [[ "$bucket_kms_key_id" == "$expected_kms_key_arn" ]]; then
      success "State bucket encryption uses expected CMK ARN"
    else
      warn "State bucket KMS key does not exactly match Terraform output. Bucket: ${bucket_kms_key_id}; Terraform output: ${expected_kms_key_arn}"
    fi
  fi
}

check_kms_key() {
  local kms_key_arn="$1"

  section "Checking Terraform state KMS key"

  local key_json
  key_json="$(
    aws kms describe-key \
      "${aws_args[@]}" \
      --key-id "$kms_key_arn" \
      --output json
  )"

  local key_state
  key_state="$(echo "$key_json" | jq -r '.KeyMetadata.KeyState')"

  local key_manager
  key_manager="$(echo "$key_json" | jq -r '.KeyMetadata.KeyManager')"

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

check_oidc_provider() {
  section "Checking GitHub OIDC provider"

  local oidc_provider_count
  oidc_provider_count="$(
    aws iam list-open-id-connect-providers \
      "${aws_args[@]}" \
      --output json |
      jq '[.OpenIDConnectProviderList[]? | select(.Arn | contains("token.actions.githubusercontent.com"))] | length'
  )"

  if [[ "$oidc_provider_count" -gt 0 ]]; then
    success "GitHub OIDC provider exists"
  else
    fail "GitHub OIDC provider was not found"
  fi
}

check_github_role() {
  local role_arn="$1"
  local role_description="$2"

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
        jq --arg repo "$EXPECTED_GITHUB_REPOSITORY" \
          '[.. | strings | select(contains("repo:" + $repo + ":"))] | length'
    )"

    if [[ "$repo_condition_count" -gt 0 ]]; then
      success "${role_description} trust policy references expected GitHub repository: ${EXPECTED_GITHUB_REPOSITORY}"
    else
      echo "$trust_json" | jq .
      fail "${role_description} trust policy does not reference expected GitHub repository: ${EXPECTED_GITHUB_REPOSITORY}"
    fi
  else
    warn "EXPECTED_GITHUB_REPOSITORY not set. Skipping GitHub repository condition check for ${role_description}."
  fi
}

check_account_parent_if_requested() {
  local env_name="$1"
  local account_id="$2"
  local expected_parent_id="$3"
  local expected_parent_name="$4"

  if [[ -z "$account_id" ]]; then
    warn "No account ID resolved for ${env_name}. Skipping account OU placement check."
    return 0
  fi

  local parent_id
  parent_id="$(
    aws organizations list-parents \
      "${aws_args[@]}" \
      --child-id "$account_id" \
      --query 'Parents[0].Id' \
      --output text
  )"

  if [[ "$parent_id" == "$expected_parent_id" ]]; then
    success "${env_name} account is attached to expected ${expected_parent_name} OU"
  else
    local message="${env_name} account parent mismatch. Expected ${expected_parent_name} (${expected_parent_id}), got ${parent_id}"
    if [[ "$STRICT_ACCOUNT_OU_CHECKS" == "true" ]]; then
      fail "$message"
    else
      warn "$message"
    fi
  fi
}

resolve_unique_ou_id() {
  local parent_id="$1"
  local ou_name="$2"
  local description="$3"

  local ous_json
  ous_json="$(
    aws organizations list-organizational-units-for-parent \
      "${aws_args[@]}" \
      --parent-id "$parent_id" \
      --output json
  )"

  local match_count
  match_count="$(
    echo "$ous_json" |
      jq --arg name "$ou_name" '[.OrganizationalUnits[]? | select(.Name == $name)] | length'
  )"

  if [[ "$match_count" -ne 1 ]]; then
    echo "$ous_json" | jq .
    fail "Expected exactly one ${description} OU named '${ou_name}' under parent ${parent_id}; found ${match_count}"
  fi

  echo "$ous_json" |
    jq -r --arg name "$ou_name" '.OrganizationalUnits[] | select(.Name == $name) | .Id'
}

check_organization_account_identity() {
  local expected_name="$1"
  local expected_id="$2"
  local accounts_json="$3"

  local account_json
  account_json="$(
    echo "$accounts_json" |
      jq -c --arg account_id "$expected_id" '
        [
          .Accounts[]?
          | select(.Id == $account_id)
        ][0] // {}
      '
  )"

  if [[ "$account_json" == "{}" ]]; then
    fail "AWS Organizations account ID ${expected_id} (${expected_name}) was not found."
  fi

  local actual_name
  actual_name="$(echo "$account_json" | jq -r '.Name // empty')"

  local actual_state
  actual_state="$(echo "$account_json" | jq -r '.State // .Status // empty')"

  if [[ "$actual_name" != "$expected_name" ]]; then
    fail "AWS Organizations account ${expected_id} is named '${actual_name}', expected '${expected_name}'."
  fi

  if [[ "$actual_state" != "ACTIVE" ]]; then
    fail "AWS Organizations account '${expected_name}' (${expected_id}) is not ACTIVE. Current state: ${actual_state:-<unknown>}"
  fi

  success "AWS Organizations account identity is correct: ${expected_name} (${expected_id})"
}

compare_organizations_output_if_present() {
  local output_name="$1"
  local actual_value="$2"
  local description="$3"

  if ! terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" "$output_name"; then
    return 0
  fi

  local expected_value
  expected_value="$(get_terraform_output_value "$ORGANIZATIONS_OUTPUTS_JSON" "$output_name")"

  if [[ "$expected_value" == "$actual_value" ]]; then
    success "${description} matches organizations Terraform output"
  else
    fail "${description} mismatch. Terraform: ${expected_value}; AWS: ${actual_value}"
  fi
}

check_required_trusted_service_access() {
  local service_access_json="$1"
  local service_principal="$2"
  local description="$3"

  if echo "$service_access_json" |
    jq -e --arg principal "$service_principal" '
      any(.EnabledServicePrincipals[]?; .ServicePrincipal == $principal)
    ' >/dev/null; then
    success "${description} trusted service access is enabled"
  else
    fail "${description} trusted service access is not enabled (${service_principal})."
  fi
}

check_expected_delegated_administrator() {
  local service_principal="$1"
  local expected_account_id="$2"
  local description="$3"

  local delegated_json
  delegated_json="$(
    aws organizations list-delegated-administrators \
      "${aws_args[@]}" \
      --service-principal "$service_principal" \
      --output json
  )"

  local matching_count
  matching_count="$(
    echo "$delegated_json" |
      jq --arg account_id "$expected_account_id" '
        [
          .DelegatedAdministrators[]?
          | select(
              .Id == $account_id
              and (.State // .Status) == "ACTIVE"
            )
        ]
        | length
      '
  )"

  if [[ "$matching_count" -ne 1 ]]; then
    echo "$delegated_json" | jq .
    fail "${description} delegated administrator is not the expected security-operations account (${expected_account_id})."
  fi

  success "${description} delegated administrator is the security-operations account"
}

check_organizations_security_prerequisites() {
  local roots_json="$1"

  section "Checking AWS Organizations centralized-security prerequisites"

  if ! terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" central_security_features_enabled; then
    warn "organizations output central_security_features_enabled is not present. Skipping rollout-aware prerequisite checks."
    return 0
  fi

  local features_json
  features_json="$(
    echo "$ORGANIZATIONS_OUTPUTS_JSON" |
      jq -c '.central_security_features_enabled.value // {}'
  )"

  local securityhub_da_enabled
  securityhub_da_enabled="$(
    echo "$features_json" |
      jq -r '
        .securityhub_delegated_administrator
        // .securityhub
        // .securityhub_cspm
        // false
      '
  )"

  local guardduty_da_enabled
  guardduty_da_enabled="$(
    echo "$features_json" |
      jq -r '
        .guardduty_delegated_administrator
        // .guardduty
        // false
      '
  )"

  local securityhub_v2_org_enabled
  securityhub_v2_org_enabled="$(
    echo "$features_json" |
      jq -r '
        .securityhub_v2_organization_management
        // .securityhub_v2
        // false
      '
  )"

  local service_access_json
  service_access_json="$(
    aws organizations list-aws-service-access-for-organization \
      "${aws_args[@]}" \
      --output json
  )"

  if [[ "$securityhub_da_enabled" == "true" ]]; then
    check_required_trusted_service_access \
      "$service_access_json" \
      "securityhub.amazonaws.com" \
      "Security Hub"

    check_expected_delegated_administrator \
      "securityhub.amazonaws.com" \
      "$ACCOUNT_ID_SECOPS" \
      "Security Hub"
  else
    warn "Security Hub delegated-administrator rollout is disabled in organizations Terraform output."
  fi

  if [[ "$guardduty_da_enabled" == "true" ]]; then
    check_required_trusted_service_access \
      "$service_access_json" \
      "guardduty.amazonaws.com" \
      "GuardDuty"

    check_required_trusted_service_access \
      "$service_access_json" \
      "malware-protection.guardduty.amazonaws.com" \
      "GuardDuty malware protection"

    check_expected_delegated_administrator \
      "guardduty.amazonaws.com" \
      "$ACCOUNT_ID_SECOPS" \
      "GuardDuty"
  else
    warn "GuardDuty delegated-administrator rollout is disabled in organizations Terraform output."
  fi

  if [[ "$securityhub_v2_org_enabled" == "true" ]]; then
    local securityhub_policy_status
    securityhub_policy_status="$(
      echo "$roots_json" |
        jq -r '
          [
            .Roots[0].PolicyTypes[]?
            | select(.Type == "SECURITYHUB_POLICY")
            | .Status
          ][0] // "NOT_ENABLED"
        '
    )"

    if [[ "$securityhub_policy_status" != "ENABLED" ]]; then
      fail "SECURITYHUB_POLICY must be enabled on the organization root. Current status: ${securityhub_policy_status}"
    fi

    success "SECURITYHUB_POLICY is enabled on the organization root"
  else
    warn "Security Hub V2 organization-management rollout is disabled in organizations Terraform output."
  fi

  if terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" delegated_administrator_account_ids; then
    local delegated_output_json
    delegated_output_json="$(
      echo "$ORGANIZATIONS_OUTPUTS_JSON" |
        jq -c '.delegated_administrator_account_ids.value // {}'
    )"

    local output_securityhub_account_id
    output_securityhub_account_id="$(
      echo "$delegated_output_json" |
        jq -r '.securityhub // .securityhub_cspm // empty'
    )"

    local output_guardduty_account_id
    output_guardduty_account_id="$(
      echo "$delegated_output_json" |
        jq -r '.guardduty // empty'
    )"

    if [[ -n "$output_securityhub_account_id" && "$output_securityhub_account_id" != "$ACCOUNT_ID_SECOPS" ]]; then
      fail "organizations delegated-administrator output for Security Hub (${output_securityhub_account_id}) does not match security-operations account ${ACCOUNT_ID_SECOPS}."
    fi

    if [[ -n "$output_guardduty_account_id" && "$output_guardduty_account_id" != "$ACCOUNT_ID_SECOPS" ]]; then
      fail "organizations delegated-administrator output for GuardDuty (${output_guardduty_account_id}) does not match security-operations account ${ACCOUNT_ID_SECOPS}."
    fi

    success "Organizations delegated-administrator outputs are consistent with the security-operations account"
  fi
}

check_organizations_ou_structure() {
  section "Checking AWS Organizations structure"

  local org_json
  org_json="$(
    aws organizations describe-organization \
      "${aws_args[@]}" \
      --output json
  )"

  ORGANIZATION_ID="$(echo "$org_json" | jq -r '.Organization.Id // empty')"

  local feature_set
  feature_set="$(echo "$org_json" | jq -r '.Organization.FeatureSet // empty')"

  require_non_empty "$ORGANIZATION_ID" "AWS Organizations organization ID"
  success "AWS Organizations is accessible: ${ORGANIZATION_ID}"

  if [[ "$feature_set" == "ALL" ]]; then
    success "AWS Organizations all-features mode is enabled"
  else
    fail "AWS Organizations FeatureSet must be ALL. Current value: ${feature_set:-<empty>}"
  fi

  local roots_json
  roots_json="$(
    aws organizations list-roots \
      "${aws_args[@]}" \
      --output json
  )"

  local root_count
  root_count="$(echo "$roots_json" | jq '.Roots | length')"

  if [[ "$root_count" -ne 1 ]]; then
    echo "$roots_json" | jq .
    fail "Expected exactly one AWS Organizations root; found ${root_count}."
  fi

  ORGANIZATION_ROOT_ID="$(echo "$roots_json" | jq -r '.Roots[0].Id // empty')"
  require_non_empty "$ORGANIZATION_ROOT_ID" "AWS Organizations root ID"
  success "Resolved AWS Organizations root ID: ${ORGANIZATION_ROOT_ID}"

  WORKLOADS_OU_ID="$(
    resolve_unique_ou_id \
      "$ORGANIZATION_ROOT_ID" \
      "$WORKLOADS_OU_NAME" \
      "workloads"
  )"

  SECURITY_OU_ID="$(
    resolve_unique_ou_id \
      "$ORGANIZATION_ROOT_ID" \
      "$SECURITY_OU_NAME" \
      "security"
  )"

  NONPROD_OU_ID="$(
    resolve_unique_ou_id \
      "$WORKLOADS_OU_ID" \
      "$NONPROD_OU_NAME" \
      "non-production workloads"
  )"

  PROD_OU_ID="$(
    resolve_unique_ou_id \
      "$WORKLOADS_OU_ID" \
      "$PROD_OU_NAME" \
      "production workloads"
  )"

  success "${WORKLOADS_OU_NAME} OU exists: ${WORKLOADS_OU_ID}"
  success "${NONPROD_OU_NAME} OU exists under ${WORKLOADS_OU_NAME}: ${NONPROD_OU_ID}"
  success "${PROD_OU_NAME} OU exists under ${WORKLOADS_OU_NAME}: ${PROD_OU_ID}"
  success "${SECURITY_OU_NAME} OU exists: ${SECURITY_OU_ID}"

  if terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" organization_id; then
    compare_organizations_output_if_present \
      organization_id \
      "$ORGANIZATION_ID" \
      "Organization ID"
  fi

  if terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" organization_root_id; then
    compare_organizations_output_if_present \
      organization_root_id \
      "$ORGANIZATION_ROOT_ID" \
      "Organization root ID"
  fi

  if terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" organizational_unit_ids; then
    local expected_ou_ids_json
    expected_ou_ids_json="$(
      echo "$ORGANIZATIONS_OUTPUTS_JSON" |
        jq -c '.organizational_unit_ids.value // {}'
    )"

    local expected_workloads_ou_id
    local expected_nonprod_ou_id
    local expected_prod_ou_id
    local expected_security_ou_id

    expected_workloads_ou_id="$(echo "$expected_ou_ids_json" | jq -r '.workloads // empty')"
    expected_nonprod_ou_id="$(echo "$expected_ou_ids_json" | jq -r '.nonprod // empty')"
    expected_prod_ou_id="$(echo "$expected_ou_ids_json" | jq -r '.prod // empty')"
    expected_security_ou_id="$(echo "$expected_ou_ids_json" | jq -r '.security // empty')"

    [[ -z "$expected_workloads_ou_id" || "$expected_workloads_ou_id" == "$WORKLOADS_OU_ID" ]] ||
      fail "Workloads OU ID mismatch. Terraform: ${expected_workloads_ou_id}; AWS: ${WORKLOADS_OU_ID}"

    [[ -z "$expected_nonprod_ou_id" || "$expected_nonprod_ou_id" == "$NONPROD_OU_ID" ]] ||
      fail "NonProd OU ID mismatch. Terraform: ${expected_nonprod_ou_id}; AWS: ${NONPROD_OU_ID}"

    [[ -z "$expected_prod_ou_id" || "$expected_prod_ou_id" == "$PROD_OU_ID" ]] ||
      fail "Prod OU ID mismatch. Terraform: ${expected_prod_ou_id}; AWS: ${PROD_OU_ID}"

    [[ -z "$expected_security_ou_id" || "$expected_security_ou_id" == "$SECURITY_OU_ID" ]] ||
      fail "Security OU ID mismatch. Terraform: ${expected_security_ou_id}; AWS: ${SECURITY_OU_ID}"

    success "Live OU IDs match organizations Terraform output"
  fi

  if terraform_output_exists "$ORGANIZATIONS_OUTPUTS_JSON" security_operations_account_id; then
    local output_secops_account_id
    output_secops_account_id="$(
      get_terraform_output_value \
        "$ORGANIZATIONS_OUTPUTS_JSON" \
        security_operations_account_id
    )"

    if [[ "$output_secops_account_id" != "$ACCOUNT_ID_SECOPS" ]]; then
      fail "organizations security_operations_account_id output (${output_secops_account_id}) does not match Identity Center configuration (${ACCOUNT_ID_SECOPS})."
    fi

    success "Security-operations account ID matches organizations Terraform output"
  fi

  local accounts_json
  accounts_json="$(
    aws organizations list-accounts \
      "${aws_args[@]}" \
      --output json
  )"

  check_organization_account_identity "dev" "$ACCOUNT_ID_DEV" "$accounts_json"
  check_organization_account_identity "staging" "$ACCOUNT_ID_STAGING" "$accounts_json"
  check_organization_account_identity "prod" "$ACCOUNT_ID_PROD" "$accounts_json"
  check_organization_account_identity \
    "$SECURITY_OPERATIONS_ACCOUNT_NAME" \
    "$ACCOUNT_ID_SECOPS" \
    "$accounts_json"

  check_account_parent_if_requested \
    "dev" \
    "$ACCOUNT_ID_DEV" \
    "$NONPROD_OU_ID" \
    "$NONPROD_OU_NAME"

  check_account_parent_if_requested \
    "staging" \
    "$ACCOUNT_ID_STAGING" \
    "$NONPROD_OU_ID" \
    "$NONPROD_OU_NAME"

  check_account_parent_if_requested \
    "prod" \
    "$ACCOUNT_ID_PROD" \
    "$PROD_OU_ID" \
    "$PROD_OU_NAME"

  check_account_parent_if_requested \
    "$SECURITY_OPERATIONS_ACCOUNT_NAME" \
    "$ACCOUNT_ID_SECOPS" \
    "$SECURITY_OU_ID" \
    "$SECURITY_OU_NAME"

  check_organizations_security_prerequisites "$roots_json"
}


resolve_identity_center_instance() {
  local instances_json
  instances_json="$(
    aws sso-admin list-instances \
      "${aws_args[@]}" \
      --output json
  )"

  local instance_count
  instance_count="$(echo "$instances_json" | jq '.Instances | length')"

  if [[ "$instance_count" -eq 0 ]]; then
    fail "No IAM Identity Center instances found"
  fi

  if [[ "$instance_count" -gt 1 ]]; then
    warn "Multiple IAM Identity Center instances found. Using the first instance returned by AWS CLI."
  fi

  IDENTITY_CENTER_INSTANCE_ARN="$(echo "$instances_json" | jq -r '.Instances[0].InstanceArn')"
  IDENTITY_STORE_ID="$(echo "$instances_json" | jq -r '.Instances[0].IdentityStoreId')"

  require_non_empty "$IDENTITY_CENTER_INSTANCE_ARN" "Identity Center instance ARN"
  require_non_empty "$IDENTITY_STORE_ID" "Identity Store ID"

  success "IAM Identity Center instance exists"
  info "Identity Center instance ARN: ${IDENTITY_CENTER_INSTANCE_ARN}"
  info "Identity Store ID: ${IDENTITY_STORE_ID}"
}

check_identity_center_group() {
  local group_name="$1"
  local required="$2"

  local groups_json
  groups_json="$(
    aws identitystore list-groups \
      "${aws_args[@]}" \
      --identity-store-id "$IDENTITY_STORE_ID" \
      --filters "AttributePath=DisplayName,AttributeValue=${group_name}" \
      --output json
  )"

  local group_count
  group_count="$(
    echo "$groups_json" |
      jq --arg name "$group_name" '[.Groups[]? | select(.DisplayName == $name)] | length'
  )"

  if [[ "$group_count" -gt 0 ]]; then
    success "Identity Center group exists: ${group_name}"
  elif [[ "$required" == "true" ]]; then
    echo "$groups_json" | jq .
    fail "Required Identity Center group not found: ${group_name}"
  else
    warn "Optional Identity Center group not found or not enabled: ${group_name}"
  fi
}

check_permission_set_arn() {
  local permission_set_arn="$1"
  local description="$2"

  local permission_set_json
  permission_set_json="$(
    aws sso-admin describe-permission-set \
      "${aws_args[@]}" \
      --instance-arn "$IDENTITY_CENTER_INSTANCE_ARN" \
      --permission-set-arn "$permission_set_arn" \
      --output json
  )"

  local permission_set_name
  permission_set_name="$(echo "$permission_set_json" | jq -r '.PermissionSet.Name')"

  require_non_empty "$permission_set_name" "${description} permission set name"
  success "Permission set exists for ${description}: ${permission_set_name}"
}

check_identity_center_assignments_for_env() {
  local env_name="$1"
  local account_id="$2"
  shift 2

  local permission_set_arns=("$@")

  if [[ -z "$account_id" ]]; then
    warn "No account ID resolved for ${env_name}. Skipping Identity Center account assignment checks."
    return 0
  fi

  local permission_set_arn
  for permission_set_arn in "${permission_set_arns[@]}"; do
    local assignment_count
    assignment_count="$(
      aws sso-admin list-account-assignments \
        "${aws_args[@]}" \
        --instance-arn "$IDENTITY_CENTER_INSTANCE_ARN" \
        --account-id "$account_id" \
        --permission-set-arn "$permission_set_arn" \
        --output json |
        jq '.AccountAssignments | length'
    )"

    if [[ "$assignment_count" -gt 0 ]]; then
      success "Identity Center account assignment exists for ${env_name}: ${permission_set_arn}"
    else
      local message="No Identity Center account assignments found for ${env_name}: ${permission_set_arn}"
      if [[ "$STRICT_IDENTITY_CENTER_ASSIGNMENTS" == "true" ]]; then
        fail "$message"
      else
        warn "$message"
      fi
    fi
  done
}

check_identity_center() {
  local identity_center_outputs_json="$1"

  section "Checking IAM Identity Center instance"
  resolve_identity_center_instance

  section "Checking IAM Identity Center groups"

  check_identity_center_group "SecOps-Operator-Dev" "true"
  check_identity_center_group "SecOps-Operator-Staging" "true"
  check_identity_center_group "SecOps-Operator-Prod" "true"
  check_identity_center_group "SecOps-Administrator" "true"

  if [[ "$CHECK_OPTIONAL_SECOPS_GROUPS" == "true" ]]; then
    check_identity_center_group "SecOps-Analyst-Dev" "$ENABLE_SECOPS_ANALYST_DEV"
    check_identity_center_group "SecOps-Analyst-Staging" "$ENABLE_SECOPS_ANALYST_STAGING"
    check_identity_center_group "SecOps-Analyst-Prod" "$ENABLE_SECOPS_ANALYST_PROD"
    check_identity_center_group "SecOps-Engineer-Dev" "$ENABLE_SECOPS_ENGINEER_DEV"
    check_identity_center_group "SecOps-Engineer-Staging" "$ENABLE_SECOPS_ENGINEER_STAGING"
    check_identity_center_group "SecOps-Engineer-Prod" "$ENABLE_SECOPS_ENGINEER_PROD"
    check_identity_center_group "SecOps-Analyst-SecOps" "$ENABLE_SECOPS_ANALYST_SECOPS"
    check_identity_center_group "SecOps-Engineer-SecOps" "$ENABLE_SECOPS_ENGINEER_SECOPS"
  else
    warn "CHECK_OPTIONAL_SECOPS_GROUPS is false. Skipping optional SecOps-Analyst and SecOps-Engineer group checks."
  fi

  section "Checking IAM Identity Center Terraform outputs and permission sets"

  require_terraform_output "$identity_center_outputs_json" workload_permission_set_arns "identity_center"
  require_terraform_output "$identity_center_outputs_json" secops_permission_set_arns "identity_center"

  mapfile -t DEV_PERMISSION_SET_ARNS < <(
    echo "$identity_center_outputs_json" |
      jq -r '.workload_permission_set_arns.value.dev | .. | strings | select(length > 0)'
  )
  mapfile -t STAGING_PERMISSION_SET_ARNS < <(
    echo "$identity_center_outputs_json" |
      jq -r '.workload_permission_set_arns.value.staging | .. | strings | select(length > 0)'
  )
  mapfile -t PROD_PERMISSION_SET_ARNS < <(
    echo "$identity_center_outputs_json" |
      jq -r '.workload_permission_set_arns.value.prod | .. | strings | select(length > 0)'
  )
  mapfile -t SECOPS_PERMISSION_SET_ARNS < <(
    get_output_string_values "$identity_center_outputs_json" secops_permission_set_arns
  )

  if [[ "${#DEV_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No dev permission set ARNs found in identity_center workload output"
  fi

  if [[ "${#STAGING_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No staging permission set ARNs found in identity_center workload output"
  fi

  if [[ "${#PROD_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No prod permission set ARNs found in identity_center workload output"
  fi

  if [[ "${#SECOPS_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No security-operations permission set ARNs found in identity_center secops output"
  fi

  local arn
  for arn in "${DEV_PERMISSION_SET_ARNS[@]}"; do
    check_permission_set_arn "$arn" "dev"
  done

  for arn in "${STAGING_PERMISSION_SET_ARNS[@]}"; do
    check_permission_set_arn "$arn" "staging"
  done

  for arn in "${PROD_PERMISSION_SET_ARNS[@]}"; do
    check_permission_set_arn "$arn" "prod"
  done

  for arn in "${SECOPS_PERMISSION_SET_ARNS[@]}"; do
    check_permission_set_arn "$arn" "security-operations"
  done

  section "Checking IAM Identity Center account assignments"

  check_identity_center_assignments_for_env "dev" "$ACCOUNT_ID_DEV" "${DEV_PERMISSION_SET_ARNS[@]}"
  check_identity_center_assignments_for_env "staging" "$ACCOUNT_ID_STAGING" "${STAGING_PERMISSION_SET_ARNS[@]}"
  check_identity_center_assignments_for_env "prod" "$ACCOUNT_ID_PROD" "${PROD_PERMISSION_SET_ARNS[@]}"
  check_identity_center_assignments_for_env "security-operations" "$ACCOUNT_ID_SECOPS" "${SECOPS_PERMISSION_SET_ARNS[@]}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

section "${CLOUD_NAME} Control Plane Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq found"

require_command git
success "git found"

resolve_identity_center_configuration

section "Resolving repository paths"

REPO_ROOT="$(get_repo_root)"
CONTROL_PLANE_DIR="$(get_control_plane_dir "$REPO_ROOT")"
STATE_DIR="${CONTROL_PLANE_DIR}/state"
ACCOUNT_DIR="${CONTROL_PLANE_DIR}/account"
ORGANIZATIONS_DIR="${CONTROL_PLANE_DIR}/organizations"
IDENTITY_CENTER_DIR="${CONTROL_PLANE_DIR}/identity_center"

info "Repository root: ${REPO_ROOT}"
info "Control-plane dir: ${CONTROL_PLANE_DIR}"
info "State dir: ${STATE_DIR}"
info "Account dir: ${ACCOUNT_DIR}"
info "Organizations dir: ${ORGANIZATIONS_DIR}"
info "Identity Center dir: ${IDENTITY_CENTER_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "REQUIRE_STATE_STACK_REMOTE: ${REQUIRE_STATE_STACK_REMOTE}"
info "STRICT_ACCOUNT_OU_CHECKS: ${STRICT_ACCOUNT_OU_CHECKS}"
info "WORKLOADS_OU_NAME: ${WORKLOADS_OU_NAME}"
info "NONPROD_OU_NAME: ${NONPROD_OU_NAME}"
info "PROD_OU_NAME: ${PROD_OU_NAME}"
info "SECURITY_OU_NAME: ${SECURITY_OU_NAME}"
info "SECURITY_OPERATIONS_ACCOUNT_NAME: ${SECURITY_OPERATIONS_ACCOUNT_NAME}"

require_directory "$CONTROL_PLANE_DIR"
require_directory "$STATE_DIR"
require_directory "$ACCOUNT_DIR"
require_directory "$ORGANIZATIONS_DIR"
require_directory "$IDENTITY_CENTER_DIR"
success "Control-plane stack directories exist"

validate_backend_locking "${ACCOUNT_DIR}/backend.tf" "bootstrap/control_plane/account"
validate_backend_locking "${ORGANIZATIONS_DIR}/backend.tf" "bootstrap/control_plane/organizations"
validate_backend_locking "${IDENTITY_CENTER_DIR}/backend.tf" "bootstrap/control_plane/identity_center"

section "Checking AWS caller identity"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

require_non_empty "$AWS_ACCOUNT_ID" "AWS account ID"
require_non_empty "$AWS_CALLER_ARN" "AWS caller ARN"

success "AWS credentials are valid"
info "AWS account ID: ${AWS_ACCOUNT_ID}"
info "AWS caller ARN: ${AWS_CALLER_ARN}"

if [[ -n "${EXPECTED_ACCOUNT_ID:-}" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected control-plane account: ${EXPECTED_ACCOUNT_ID}"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit control-plane account ID match check."
fi

section "Reading Terraform outputs"

STATE_OUTPUTS_JSON="$(terraform_output_json_required "$STATE_DIR" "state")"
ACCOUNT_OUTPUTS_JSON="$(terraform_output_json_required "$ACCOUNT_DIR" "account")"
ORGANIZATIONS_OUTPUTS_JSON="$(terraform_output_json_optional "$ORGANIZATIONS_DIR")"
IDENTITY_CENTER_OUTPUTS_JSON="$(terraform_output_json_required "$IDENTITY_CENTER_DIR" "identity_center")"

info "Organizations outputs size: $(echo "$ORGANIZATIONS_OUTPUTS_JSON" | jq 'length')"

section "Checking state stack Terraform outputs"

require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_name "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_arn "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_cmk_arn "state"

STATE_BUCKET_NAME="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_name)"
STATE_BUCKET_ARN="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_arn)"
STATE_CMK_ARN="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_cmk_arn)"

require_non_empty "$STATE_BUCKET_NAME" "control-plane state bucket name"
require_non_empty "$STATE_BUCKET_ARN" "control-plane state bucket ARN"
require_non_empty "$STATE_CMK_ARN" "control-plane state CMK ARN"

info "State bucket name: ${STATE_BUCKET_NAME}"
info "State bucket ARN: ${STATE_BUCKET_ARN}"
info "State CMK ARN: ${STATE_CMK_ARN}"

validate_state_stack_remote_backend "$STATE_DIR" "$STATE_BUCKET_NAME"
check_s3_state_bucket "$STATE_BUCKET_NAME" "$STATE_CMK_ARN"
check_kms_key "$STATE_CMK_ARN"

section "Checking account stack GitHub OIDC outputs"

PLAN_ROLE_ARN="$(get_terraform_output_value "$ACCOUNT_OUTPUTS_JSON" plan_role_github_arn 2>/dev/null || echo "null")"
APPLY_ROLE_ARN="$(get_terraform_output_value "$ACCOUNT_OUTPUTS_JSON" apply_role_github_arn 2>/dev/null || echo "null")"

if [[ "$REQUIRE_CONTROL_PLANE_GITHUB_OIDC" == "true" ]]; then
  require_non_empty "$PLAN_ROLE_ARN" "control-plane GitHub plan role ARN"
  require_non_empty "$APPLY_ROLE_ARN" "control-plane GitHub apply role ARN"
  check_oidc_provider
  check_github_role "$PLAN_ROLE_ARN" "Control-plane GitHub Plan"
  check_github_role "$APPLY_ROLE_ARN" "Control-plane GitHub Apply"
else
  if [[ -z "$PLAN_ROLE_ARN" || "$PLAN_ROLE_ARN" == "null" || -z "$APPLY_ROLE_ARN" || "$APPLY_ROLE_ARN" == "null" ]]; then
    warn "Control-plane GitHub OIDC outputs are not fully populated, but REQUIRE_CONTROL_PLANE_GITHUB_OIDC=false."
  else
    check_oidc_provider
    check_github_role "$PLAN_ROLE_ARN" "Control-plane GitHub Plan"
    check_github_role "$APPLY_ROLE_ARN" "Control-plane GitHub Apply"
  fi
fi

check_organizations_ou_structure
check_identity_center "$IDENTITY_CENTER_OUTPUTS_JSON"

section "Control Plane Summary"

cat <<SUMMARY
AWS profile:                       ${AWS_PROFILE:-<default>}
AWS region:                        ${AWS_REGION}
Control-plane account ID:          ${AWS_ACCOUNT_ID}
Name prefix:                       ${NAME_PREFIX}

State bucket:                      ${STATE_BUCKET_NAME}
State CMK:                         ${STATE_CMK_ARN}
State stack remote required:       ${REQUIRE_STATE_STACK_REMOTE}

GitHub OIDC required:              ${REQUIRE_CONTROL_PLANE_GITHUB_OIDC}
GitHub plan role ARN:              ${PLAN_ROLE_ARN}
GitHub apply role ARN:             ${APPLY_ROLE_ARN}
Expected GitHub repository:        ${EXPECTED_GITHUB_REPOSITORY:-<not checked>}

AWS Organizations:
  organization ID:                 ${ORGANIZATION_ID}
  root ID:                         ${ORGANIZATION_ROOT_ID}
  Workloads OU:                    ${WORKLOADS_OU_ID}
  NonProd OU:                      ${NONPROD_OU_ID}
  Prod OU:                         ${PROD_OU_ID}
  Security OU:                     ${SECURITY_OU_ID}
  strict account OU checks:        ${STRICT_ACCOUNT_OU_CHECKS}

Identity Center instance ARN:      ${IDENTITY_CENTER_INSTANCE_ARN}
Identity Store ID:                 ${IDENTITY_STORE_ID}
Dev permission sets:               ${#DEV_PERMISSION_SET_ARNS[@]}
Staging permission sets:           ${#STAGING_PERMISSION_SET_ARNS[@]}
Prod permission sets:              ${#PROD_PERMISSION_SET_ARNS[@]}
Security-operations permission sets: ${#SECOPS_PERMISSION_SET_ARNS[@]}

Account assignment checks:
  dev account ID:                  ${ACCOUNT_ID_DEV}
  staging account ID:              ${ACCOUNT_ID_STAGING}
  prod account ID:                 ${ACCOUNT_ID_PROD}
  security-operations account ID:  ${ACCOUNT_ID_SECOPS}
SUMMARY

section "Validation Result"

success "Control-plane validation completed successfully"