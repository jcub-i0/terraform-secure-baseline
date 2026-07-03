#   AWS_REGION=us-east-1 \
#   EXPECTED_ACCOUNT_ID=<dev-account-id> \
#   EXPECTED_GITHUB_REPOSITORY=<owner>/<repo> \
#   ./scripts/validation/validate-bootstrap.sh dev
#
# Optional:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-bootstrap.sh dev
#   REQUIRE_BOOTSTRAP_GITHUB_OIDC=false ./scripts/validation/validate-bootstrap.sh dev
#   STRICT_GITHUB_SUBJECT_CHECKS=false ./scripts/validation/validate-bootstrap.sh dev
#
# Notes:
#   This script is intentionally read-only. It does not run GitHub workflows,
#   assume roles, modify IAM policies, initialize Terraform backends, or perform
#   destroy/cleanup operations.

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

terraform_output_json_required() {
  local stack_dir="$1"
  local stack_name="$2"

  local outputs_json
  if ! outputs_json="$(terraform_output_json "$stack_dir")"; then
    fail "Unable to read Terraform outputs for ${stack_name}: ${stack_dir}"
  fi

  if [[ -z "$outputs-json" ]]; then
    fail "No Terraform output JSON returned for ${stack_name}: ${stack_dir}"
  fi

  echo "$outputs_json"
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
    fail "Unable to resolve ${descriptions}"
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

json_contains_string() {
  local json="$1"
  local value="$2"

  echo "$json" | jq -e --arg value "$value" '[.. | strings | select(. == $value or contains($value))] | length > 0' >/dev/null
}