#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  reconcile-workload-account.sh <dev|staging|prod> [options]

Options:
  --apply               Apply the generated Terraform plan.
                        Without this option, the script is plan-only.
  --auto-approve        Skip the interactive confirmation before apply.
                        Requires --apply.
  --skip-validation     Skip strict bootstrap validation after apply.
  -h, --help            Show this help message.

Examples:
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev

  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  EXPECTED_GITHUB_REPOSITORY="<OWNER>/<REPOSITORY>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev --apply

  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev \
    --apply \
    --auto-approve
USAGE
}

info()      { printf '[INFO] %s\n' "$*"; }
success()   { printf '[PASS] %s\n' "$*"; }
warn()      { printf '[WARN] %s\n' "$*" >&2; }
fail()      { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Required command not found: $1"
}

get_backend_string_value() {
  local backend_file="$1"
  local attribute_name="$2"

  sed -nE \
    "s/^[[:space:]]*${attribute_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" \
    "$backend_file" |
    head -n 1
}

get_required_terraform_output() {
  local stack_dir="$1"
  local output_name="$2"
  local output_value

  output_value="$(
    terraform -chdir="$stack_dir" output -raw "$output_name" 2>/dev/null ||
      true
  )"

  if [[ -z "$output_value" ||
        "$output_value" == "null" ||
        "$output_value" == "None" ]]; then
    fail "Unable to read required Terraform output '${output_name}' from ${stack_dir}"
  fi

  printf '%s\n' "$output_value"
}

validate_kms_arn() {
  local kms_arn="$1"
  local description="$2"

  if [[ ! "$kms_arn" =~ ^arn:([^:]+):kms:([^:]+):([0-9]{12}):key/(.+)$ ]]; then
    fail "${description} is not a valid KMS key ARN: ${kms_arn}"
  fi

  local arn_region="${BASH_REMATCH[2]}"
  local arn_account_id="${BASH_REMATCH[3]}"

  if [[ "$arn_region" != "$AWS_REGION" ]]; then
    fail "${description} region mismatch. Expected ${AWS_REGION}, got ${arn_region}"
  fi

  if [[ "$arn_account_id" != "$ACTIVE_ACCOUNT_ID" ]]; then
    fail "${description} account mismatch. Expected ${ACTIVE_ACCOUNT_ID}, got ${arn_account_id}"
  fi

  local key_state
  local key_manager

  key_state="$(
    aws kms describe-key \
      "${AWS_ARGS[@]}" \
      --key-id "$kms_arn" \
      --query 'KeyMetadata.KeyState' \
      --output text
  )"

  key_manager="$(
    aws kms describe-key \
      "${AWS_ARGS[@]}" \
      --key-id "$kms_arn" \
      --query 'KeyMetadata.KeyManager' \
      --output text
  )"

  [[ "$key_state" == "Enabled" ]] ||
    fail "${description} is not enabled. Current state: ${key_state}"

  [[ "$key_manager" == "CUSTOMER" ]] ||
    fail "${description} is not customer-managed. Key manager: ${key_manager}"

  success "${description} is a valid, enabled customer-managed KMS key"
}

TARGET="${1:-}"

[[ -n "$TARGET" ]] || {
  usage
  exit 1
}

case "$TARGET" in
  dev|staging|prod)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    fail "Unsupported target: ${TARGET}"
    ;;
esac

shift

APPLY=false
AUTO_APPROVE=false
SKIP_VALIDATION=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      fail "Unknown option: $1"
      ;;
  esac

  shift
done

if [[ "$AUTO_APPROVE" == "true" && "$APPLY" != "true" ]]; then
  fail "--auto-approve requires --apply"
fi

for cmd in terraform aws git sed mktemp rm; do
  require_command "$cmd"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "Unable to resolve repository root"

ENV_DIR="${REPO_ROOT}/environments/${TARGET}"
ACCOUNT_DIR="${REPO_ROOT}/bootstrap/${TARGET}/account"
VALIDATION_SCRIPT="${REPO_ROOT}/scripts/validation/validate-bootstrap.sh"

ENV_BACKEND="${ENV_DIR}/backend.tf"
ACCOUNT_BACKEND="${ACCOUNT_DIR}/backend.tf"

[[ -d "$ENV_DIR" ]] ||
  fail "Workload environment directory not found: ${ENV_DIR}"

[[ -d "$ACCOUNT_DIR" ]] ||
  fail "Bootstrap account directory not found: ${ACCOUNT_DIR}"

[[ -f "$ENV_BACKEND" ]] ||
  fail "Workload backend file not found: ${ENV_BACKEND}"

[[ -f "$ACCOUNT_BACKEND" ]] ||
  fail "Bootstrap account backend file not found: ${ACCOUNT_BACKEND}"

[[ -x "$VALIDATION_SCRIPT" ]] ||
  fail "Bootstrap validation script is missing or not executable: ${VALIDATION_SCRIPT}"

ENV_BACKEND_REGION="$(get_backend_string_value "$ENV_BACKEND" region)"
ACCOUNT_BACKEND_REGION="$(get_backend_string_value "$ACCOUNT_BACKEND" region)"

[[ -n "$ENV_BACKEND_REGION" ]] ||
  fail "Unable to resolve workload backend region"

[[ -n "$ACCOUNT_BACKEND_REGION" ]] ||
  fail "Unable to resolve bootstrap account backend region"

[[ "$ENV_BACKEND_REGION" == "$ACCOUNT_BACKEND_REGION" ]] ||
  fail "Backend region mismatch. Workload: ${ENV_BACKEND_REGION}; account: ${ACCOUNT_BACKEND_REGION}"

AWS_REGION="${AWS_REGION:-$ENV_BACKEND_REGION}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"

[[ "$AWS_REGION" == "$ENV_BACKEND_REGION" ]] ||
  fail "AWS_REGION (${AWS_REGION}) does not match backend region (${ENV_BACKEND_REGION})"

export AWS_PAGER=""

AWS_ARGS=(--region "$AWS_REGION")

if [[ -n "$AWS_PROFILE" ]]; then
  AWS_ARGS+=(--profile "$AWS_PROFILE")
fi

info "Target environment: ${TARGET}"
info "Workload stack: ${ENV_DIR}"
info "Bootstrap account stack: ${ACCOUNT_DIR}"
info "AWS region: ${AWS_REGION}"
info "AWS profile: ${AWS_PROFILE:-default credential chain}"
info "Mode: $([[ "$APPLY" == "true" ]] && printf 'apply' || printf 'plan-only')"

ACTIVE_ACCOUNT_ID="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query Account \
    --output text
)"

CALLER_ARN="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query Arn \
    --output text
)"

success "AWS credentials are valid"
info "AWS account ID: ${ACTIVE_ACCOUNT_ID}"
info "AWS caller ARN: ${CALLER_ARN}"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  [[ "$ACTIVE_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] ||
    fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACTIVE_ACCOUNT_ID}"

  success "AWS account matches EXPECTED_ACCOUNT_ID"
else
  warn "EXPECTED_ACCOUNT_ID is not set. The active account will still be checked against both CMK ARNs."
fi

info "Initializing workload Terraform root"
terraform -chdir="$ENV_DIR" init \
  -input=false \
  -no-color >/dev/null
success "Workload Terraform root initialized"

info "Initializing bootstrap account Terraform root"
terraform -chdir="$ACCOUNT_DIR" init \
  -input=false \
  -no-color >/dev/null
success "Bootstrap account Terraform root initialized"

LAMBDA_CMK_ARN="$(
  get_required_terraform_output \
    "$ENV_DIR" \
    "lambda_cmk_arn"
)"

SECRETS_MANAGER_CMK_ARN="$(
  get_required_terraform_output \
    "$ENV_DIR" \
    "secrets_manager_cmk_arn"
)"

success "Resolved workload-created CMK outputs"
info "Lambda CMK ARN: ${LAMBDA_CMK_ARN}"
info "Secrets Manager CMK ARN: ${SECRETS_MANAGER_CMK_ARN}"

validate_kms_arn "$LAMBDA_CMK_ARN" "Lambda CMK"
validate_kms_arn "$SECRETS_MANAGER_CMK_ARN" "Secrets Manager CMK"

TEMP_DIR="$(mktemp -d)"
PLAN_FILE="${TEMP_DIR}/${TARGET}-account-reconciliation.tfplan"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

info "Generating bootstrap account reconciliation plan"

TF_VAR_lambda_cmk_arn="$LAMBDA_CMK_ARN" \
TF_VAR_secrets_manager_cmk_arn="$SECRETS_MANAGER_CMK_ARN" \
terraform -chdir="$ACCOUNT_DIR" plan \
  -input=false \
  -no-color \
  -lock-timeout=5m \
  -out="$PLAN_FILE"

success "Terraform reconciliation plan generated"