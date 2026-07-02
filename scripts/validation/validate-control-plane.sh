#!/usr/bin/env bash

# validate-control-plane.sh
#
# Validates read-only control-plane foundations for tf-secure-baseline.
#
# Scope:
#   - Control-plane AWS caller identity
#   - bootstrap/control_plane/state backend resources
#   - bootstrap/control_plane/account GitHub OIDC roles
#   - bootstrap/control_plane/organizations OU structure
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
#   NAME_PREFIX=tf-secure-baseline-control-plane ./scripts/validation/validate-control-plane.sh
#   EXPECTED_GITHUB_REPOSITORY=owner/repo ./scripts/validation/validate-control-plane.sh
#   ACCOUNT_ID_DEV=<dev-account-id> ACCOUNT_ID_STAGING=<staging-account-id> ACCOUNT_ID_PROD=<prod-account-id> ./scripts/validation/validate-control-plane.sh
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
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${CONTROL_PLANE_ENV_NAME}}"

REQUIRE_CONTROL_PLANE_GITHUB_OIDC="${REQUIRE_CONTROL_PLANE_GITHUB_OIDC:-true}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"
CHECK_OPTIONAL_SECOPS_GROUPS="${CHECK_OPTIONAL_SECOPS_GROUPS:-false}"
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-false}"

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

check_dynamodb_lock_table() {
  local table_name="$1"

  section "Checking Terraform state DynamoDB lock table"

  local table_json
  table_json="$(
    aws dynamodb describe-table \
      "${aws_args[@]}" \
      --table-name "$table_name" \
      --output json
  )"

  local table_status
  table_status="$(echo "$table_json" | jq -r '.Table.TableStatus')"

  if [[ "$table_status" == "ACTIVE" ]]; then
    success "State lock table is ACTIVE: ${table_name}"
  else
    echo "$table_json" | jq .
    fail "State lock table is not ACTIVE. Current status: ${table_status}"
  fi

  local key_count
  key_count="$(echo "$table_json" | jq '.Table.KeySchema | length')"

  if [[ "$key_count" -ge 1 ]]; then
    success "State lock table has key schema configured"
  else
    echo "$table_json" | jq .
    fail "State lock table key schema is missing"
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
        jq --arg repo "$EXPECTED_GITHUB_REPOSITORY" '[.. | strings | select(contains("repo:" + $repo + ":"))] | length'
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

check_organizations_ou_structure() {
  section "Checking AWS Organizations OU structure"

  local org_json
  org_json="$(
    aws organizations describe-organization \
      "${aws_args[@]}" \
      --output json
  )"

  local org_id
  org_id="$(echo "$org_json" | jq -r '.Organization.Id')"

  local feature_set
  feature_set="$(echo "$org_json" | jq -r '.Organization.FeatureSet')"

  require_non_empty "$org_id" "AWS Organizations organization ID"
  success "AWS Organizations is accessible: ${org_id}"
  info "AWS Organizations feature set: ${feature_set}"

  local root_id
  root_id="$(
    aws organizations list-roots \
      "${aws_args[@]}" \
      --query 'Roots[0].Id' \
      --output text
  )"

  require_non_empty "$root_id" "AWS Organizations root ID"
  success "Resolved AWS Organizations root ID: ${root_id}"

  local root_ous_json
  root_ous_json="$(
    aws organizations list-organizational-units-for-parent \
      "${aws_args[@]}" \
      --parent-id "$root_id" \
      --output json
  )"

  local workloads_ou_id
  workloads_ou_id="$(
    echo "$root_ous_json" |
      jq -r '.OrganizationalUnits[]? | select(.Name == "Workloads") | .Id' |
      head -n 1
  )"

  require_non_empty "$workloads_ou_id" "Workloads OU ID"
  success "Workloads OU exists: ${workloads_ou_id}"

  local workloads_child_ous_json
  workloads_child_ous_json="$(
    aws organizations list-organizational-units-for-parent \
      "${aws_args[@]}" \
      --parent-id "$workloads_ou_id" \
      --output json
  )"

  local nonprod_ou_id
  nonprod_ou_id="$(
    echo "$workloads_child_ous_json" |
      jq -r '.OrganizationalUnits[]? | select(.Name == "NonProd") | .Id' |
      head -n 1
  )"

  local prod_ou_id
  prod_ou_id="$(
    echo "$workloads_child_ous_json" |
      jq -r '.OrganizationalUnits[]? | select(.Name == "Prod") | .Id' |
      head -n 1
  )"

  require_non_empty "$nonprod_ou_id" "NonProd OU ID"
  success "NonProd OU exists under Workloads: ${nonprod_ou_id}"

  require_non_empty "$prod_ou_id" "Prod OU ID"
  success "Prod OU exists under Workloads: ${prod_ou_id}"

  check_account_parent_if_requested "dev" "$ACCOUNT_ID_DEV" "$nonprod_ou_id" "NonProd"
  check_account_parent_if_requested "staging" "$ACCOUNT_ID_STAGING" "$nonprod_ou_id" "NonProd"
  check_account_parent_if_requested "prod" "$ACCOUNT_ID_PROD" "$prod_ou_id" "Prod"
}

check_account_parent_if_requested() {
  local env_name="$1"
  local account_id="$2"
  local expected_parent_id="$3"
  local expected_parent_name="$4"

  if [[ -z "$account_id" ]]; then
    warn "ACCOUNT_ID_${env_name^^} not set. Skipping optional ${env_name} account OU placement check."
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
  else
    if [[ "$required" == "true" ]]; then
      echo "$groups_json" | jq .
      fail "Required Identity Center group not found: ${group_name}"
    else
      warn "Optional Identity Center group not found or not enabled: ${group_name}"
    fi
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
    warn "ACCOUNT_ID_${env_name^^} not set. Skipping Identity Center account assignment checks for ${env_name}."
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

  if [[ "$CHECK_OPTIONAL_SECOPS_GROUPS" == "true" ]]; then
    check_identity_center_group "SecOps-Analyst-Dev" "false"
    check_identity_center_group "SecOps-Analyst-Staging" "false"
    check_identity_center_group "SecOps-Analyst-Prod" "false"
    check_identity_center_group "SecOps-Engineer-Dev" "false"
    check_identity_center_group "SecOps-Engineer-Staging" "false"
    check_identity_center_group "SecOps-Engineer-Prod" "false"
  else
    warn "CHECK_OPTIONAL_SECOPS_GROUPS is false. Skipping optional SecOps-Analyst and SecOps-Engineer group checks."
  fi

  section "Checking IAM Identity Center Terraform outputs and permission sets"

  require_terraform_output "$identity_center_outputs_json" dev_permission_set_arns "identity_center"
  require_terraform_output "$identity_center_outputs_json" staging_permission_set_arns "identity_center"
  require_terraform_output "$identity_center_outputs_json" prod_permission_set_arns "identity_center"

  mapfile -t DEV_PERMISSION_SET_ARNS < <(get_output_string_values "$identity_center_outputs_json" dev_permission_set_arns)
  mapfile -t STAGING_PERMISSION_SET_ARNS < <(get_output_string_values "$identity_center_outputs_json" staging_permission_set_arns)
  mapfile -t PROD_PERMISSION_SET_ARNS < <(get_output_string_values "$identity_center_outputs_json" prod_permission_set_arns)

  if [[ "${#DEV_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No dev permission set ARNs found in identity_center output"
  fi
  if [[ "${#STAGING_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No staging permission set ARNs found in identity_center output"
  fi
  if [[ "${#PROD_PERMISSION_SET_ARNS[@]}" -eq 0 ]]; then
    fail "No prod permission set ARNs found in identity_center output"
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

  section "Checking IAM Identity Center account assignments"

  check_identity_center_assignments_for_env "dev" "$ACCOUNT_ID_DEV" "${DEV_PERMISSION_SET_ARNS[@]}"
  check_identity_center_assignments_for_env "staging" "$ACCOUNT_ID_STAGING" "${STAGING_PERMISSION_SET_ARNS[@]}"
  check_identity_center_assignments_for_env "prod" "$ACCOUNT_ID_PROD" "${PROD_PERMISSION_SET_ARNS[@]}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

section "tf-secure-baseline Control Plane Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq found"

require_command git
success "git found"

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

require_directory "$CONTROL_PLANE_DIR"
require_directory "$STATE_DIR"
require_directory "$ACCOUNT_DIR"
require_directory "$ORGANIZATIONS_DIR"
require_directory "$IDENTITY_CENTER_DIR"
success "Control-plane stack directories exist"

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

require_terraform_output "$STATE_OUTPUTS_JSON" control_plane_account_id "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_name "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_arn "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_bucket_cmk_arn "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_lock_table_name "state"
require_terraform_output "$STATE_OUTPUTS_JSON" tf_state_lock_table_arn "state"

STATE_ACCOUNT_ID="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" control_plane_account_id)"
STATE_BUCKET_NAME="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_name)"
STATE_BUCKET_ARN="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_arn)"
STATE_CMK_ARN="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_bucket_cmk_arn)"
STATE_LOCK_TABLE_NAME="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_lock_table_name)"
STATE_LOCK_TABLE_ARN="$(get_terraform_output_value "$STATE_OUTPUTS_JSON" tf_state_lock_table_arn)"

if [[ "$STATE_ACCOUNT_ID" == "$AWS_ACCOUNT_ID" ]]; then
  success "State stack account output matches current AWS account"
else
  fail "State stack account output mismatch. Terraform output: ${STATE_ACCOUNT_ID}; AWS caller account: ${AWS_ACCOUNT_ID}"
fi

info "State bucket name: ${STATE_BUCKET_NAME}"
info "State bucket ARN: ${STATE_BUCKET_ARN}"
info "State CMK ARN: ${STATE_CMK_ARN}"
info "State lock table name: ${STATE_LOCK_TABLE_NAME}"
info "State lock table ARN: ${STATE_LOCK_TABLE_ARN}"

check_s3_state_bucket "$STATE_BUCKET_NAME" "$STATE_CMK_ARN"
check_kms_key "$STATE_CMK_ARN"
check_dynamodb_lock_table "$STATE_LOCK_TABLE_NAME"

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
State lock table:                  ${STATE_LOCK_TABLE_NAME}
State CMK:                         ${STATE_CMK_ARN}

GitHub OIDC required:              ${REQUIRE_CONTROL_PLANE_GITHUB_OIDC}
GitHub plan role ARN:              ${PLAN_ROLE_ARN}
GitHub apply role ARN:             ${APPLY_ROLE_ARN}
Expected GitHub repository:        ${EXPECTED_GITHUB_REPOSITORY:-<not checked>}

Identity Center instance ARN:      ${IDENTITY_CENTER_INSTANCE_ARN}
Identity Store ID:                 ${IDENTITY_STORE_ID}
Dev permission sets:               ${#DEV_PERMISSION_SET_ARNS[@]}
Staging permission sets:           ${#STAGING_PERMISSION_SET_ARNS[@]}
Prod permission sets:              ${#PROD_PERMISSION_SET_ARNS[@]}

Account assignment checks:
  dev account ID:                  ${ACCOUNT_ID_DEV:-<not checked>}
  staging account ID:              ${ACCOUNT_ID_STAGING:-<not checked>}
  prod account ID:                 ${ACCOUNT_ID_PROD:-<not checked>}
SUMMARY

section "Validation Result"

success "Control-plane validation completed successfully"