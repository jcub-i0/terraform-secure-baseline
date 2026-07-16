#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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

  if [[ "$key_state" != "Enabled" ]]; then
    fail "${description} is not enabled. Current state: ${key_state}"
  fi

  if [[ "$key_manager" != "CUSTOMER" ]]; then
    fail "${description} is not customer-managed. Key manager: ${key_manager}"
  fi

  success "${description} is a valid, enabled customer-managed KMS key"
}

TARGET="${1:-}"

if [[ -z "$TARGET" ]]; then
  usage
  exit 1
fi

case "$TARGET" in
  -h|--help)
    usage
    exit 0
    ;;
esac

require_env_name "$TARGET"
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

section "Workload account reconciliation: ${TARGET}"

section "Checking prerequisites and Terraform roots"

for command_name in terraform aws git sed mktemp rm; do
  require_command "$command_name"
done

REPO_ROOT="$(get_repo_root "$SCRIPT_DIR")" ||
  fail "Unable to resolve repository root"

ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$TARGET")"
ACCOUNT_DIR="$(get_bootstrap_account_dir "$REPO_ROOT" "$TARGET")"
VALIDATION_SCRIPT="${REPO_ROOT}/scripts/validation/validate-bootstrap.sh"

ENV_BACKEND="${ENV_DIR}/backend.tf"
ACCOUNT_BACKEND="${ACCOUNT_DIR}/backend.tf"

require_directory "$ENV_DIR"
success "Workload environment directory exists: ${ENV_DIR}"

require_directory "$ACCOUNT_DIR"
success "Bootstrap account directory exists: ${ACCOUNT_DIR}"

require_file "$ENV_BACKEND"
success "Workload backend file exists: ${ENV_BACKEND}"

require_file "$ACCOUNT_BACKEND"
success "Bootstrap account backend file exists: ${ACCOUNT_BACKEND}"

require_executable_file "$VALIDATION_SCRIPT"
success "Bootstrap validation script is available: ${VALIDATION_SCRIPT}"

ENV_BACKEND_REGION="$(get_backend_string_value "$ENV_BACKEND" region)"
ACCOUNT_BACKEND_REGION="$(get_backend_string_value "$ACCOUNT_BACKEND" region)"

require_non_empty "$ENV_BACKEND_REGION" "workload backend region"
require_non_empty "$ACCOUNT_BACKEND_REGION" "bootstrap account backend region"

if [[ "$ENV_BACKEND_REGION" != "$ACCOUNT_BACKEND_REGION" ]]; then
  fail "Backend region mismatch. Workload: ${ENV_BACKEND_REGION}; account: ${ACCOUNT_BACKEND_REGION}"
fi

success "Workload and account backends use the same region: ${ENV_BACKEND_REGION}"

AWS_REGION="${AWS_REGION:-$ENV_BACKEND_REGION}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"

if [[ "$AWS_REGION" != "$ENV_BACKEND_REGION" ]]; then
  fail "AWS_REGION (${AWS_REGION}) does not match backend region (${ENV_BACKEND_REGION})"
fi

AWS_ARGS=(--region "$AWS_REGION")

if [[ -n "$AWS_PROFILE" ]]; then
  AWS_ARGS+=(--profile "$AWS_PROFILE")
fi

EXECUTION_MODE="plan-only"
if [[ "$APPLY" == "true" ]]; then
  EXECUTION_MODE="apply"
fi

info "Repository root: ${REPO_ROOT}"
info "Target environment: ${TARGET}"
info "Workload stack: ${ENV_DIR}"
info "Bootstrap account stack: ${ACCOUNT_DIR}"
info "AWS region: ${AWS_REGION}"
info "AWS profile: ${AWS_PROFILE:-default credential chain}"
info "Execution mode: ${EXECUTION_MODE}"

section "Checking AWS caller identity"

ACTIVE_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

require_non_empty "$ACTIVE_ACCOUNT_ID" "AWS account ID"
require_non_empty "$CALLER_ARN" "AWS caller ARN"

success "AWS credentials are valid"
info "AWS account ID: ${ACTIVE_ACCOUNT_ID}"
info "AWS caller ARN: ${CALLER_ARN}"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$ACTIVE_ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
    fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACTIVE_ACCOUNT_ID}"
  fi

  success "AWS account matches EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID}"
else
  warn "EXPECTED_ACCOUNT_ID is not set. The active account will still be checked against both CMK ARNs."
fi

section "Initializing Terraform roots"

info "Initializing workload Terraform root"

if ! terraform -chdir="$ENV_DIR" init \
  -input=false \
  -no-color; then
  fail "Unable to initialize workload Terraform root: ${ENV_DIR}"
fi

success "Workload Terraform root initialized"

info "Initializing bootstrap account Terraform root"

if ! terraform -chdir="$ACCOUNT_DIR" init \
  -input=false \
  -no-color; then
  fail "Unable to initialize bootstrap account Terraform root: ${ACCOUNT_DIR}"
fi

success "Bootstrap account Terraform root initialized"

section "Resolving workload-created CMK outputs"

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

section "Validating workload-created CMKs"

validate_kms_arn "$LAMBDA_CMK_ARN" "Lambda CMK"
validate_kms_arn "$SECRETS_MANAGER_CMK_ARN" "Secrets Manager CMK"

TEMP_DIR="$(mktemp -d)"
PLAN_FILE="${TEMP_DIR}/${TARGET}-account-reconciliation.tfplan"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

section "Generating bootstrap account reconciliation plan"

TF_VAR_lambda_cmk_arn="$LAMBDA_CMK_ARN" \
TF_VAR_secrets_manager_cmk_arn="$SECRETS_MANAGER_CMK_ARN" \
terraform -chdir="$ACCOUNT_DIR" plan \
  -input=false \
  -no-color \
  -lock-timeout=5m \
  -out="$PLAN_FILE"

success "Terraform reconciliation plan generated"

cat <<PLAN_NOTICE

Terraform reconciliation plan:

  Target:               ${TARGET}
  AWS account:          ${ACTIVE_ACCOUNT_ID}
  AWS region:           ${AWS_REGION}
  Lambda CMK:           ${LAMBDA_CMK_ARN}
  Secrets Manager CMK:  ${SECRETS_MANAGER_CMK_ARN}

PLAN_NOTICE

terraform -chdir="$ACCOUNT_DIR" show \
  -no-color \
  "$PLAN_FILE"

if [[ "$APPLY" != "true" ]]; then
  section "Reconciliation summary"

  cat <<SUMMARY
Environment:                        ${TARGET}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
AWS account ID:                     ${ACTIVE_ACCOUNT_ID}
Execution mode:                     plan-only
Lambda CMK ARN:                     ${LAMBDA_CMK_ARN}
Secrets Manager CMK ARN:            ${SECRETS_MANAGER_CMK_ARN}
Plan applied:                       false
Post-apply validation performed:    false
SUMMARY

  cat <<NEXT_STEPS

Plan-only reconciliation completed successfully.

Review the plan above, then rerun with --apply:

  AWS_PROFILE=${AWS_PROFILE:-<profile>} \\
  EXPECTED_ACCOUNT_ID=${ACTIVE_ACCOUNT_ID} \\
  ./scripts/bootstrap/reconcile-workload-account.sh ${TARGET} --apply

NEXT_STEPS

  exit 0
fi

if [[ "$AUTO_APPROVE" != "true" ]]; then
  printf '\nType "apply" to apply this reconciliation plan: '
  read -r confirmation

  if [[ "$confirmation" != "apply" ]]; then
    fail "Reconciliation cancelled"
  fi
fi

section "Applying bootstrap account reconciliation plan"

terraform -chdir="$ACCOUNT_DIR" apply \
  -input=false \
  -no-color \
  "$PLAN_FILE"

success "Bootstrap account stack reconciliation applied"

VALIDATION_PERFORMED=true

if [[ "$SKIP_VALIDATION" == "true" ]]; then
  VALIDATION_PERFORMED=false
  warn "Post-apply bootstrap validation was skipped"
else
  section "Running strict workload bootstrap validation"

  AWS_PROFILE="$AWS_PROFILE" \
  AWS_REGION="$AWS_REGION" \
  EXPECTED_ACCOUNT_ID="$EXPECTED_ACCOUNT_ID" \
  EXPECTED_GITHUB_REPOSITORY="$EXPECTED_GITHUB_REPOSITORY" \
  REQUIRE_STATE_STACK_REMOTE=true \
  STRICT_WORKLOAD_CMK_POLICY_CHECKS=true \
  "$VALIDATION_SCRIPT" "$TARGET"

  success "Strict workload bootstrap validation passed"
fi

section "Reconciliation summary"

cat <<SUMMARY
Environment:                    ${TARGET}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACTIVE_ACCOUNT_ID}
Execution mode:                 apply
Lambda CMK ARN:                 ${LAMBDA_CMK_ARN}
Secrets Manager CMK ARN:        ${SECRETS_MANAGER_CMK_ARN}
Plan applied:                   true
Post-apply validation performed: ${VALIDATION_PERFORMED}
SUMMARY

section "Reconciliation result"

success "Workload account reconciliation completed: ${TARGET}"