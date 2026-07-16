#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

usage() {
  cat <<'USAGE'
This script requires GitHub OIDC and the GitHub Apply role to be enabled.
It reconciles workload-created CMK permissions into the existing GitHub
Apply role.

Usage:
  reconcile-workload-account.sh <dev|staging|prod> [options]

Terraform input requirements:
  This script uses Terraform's normal input-loading behavior for
  bootstrap/<env>/account.

  Inputs may be supplied through:
    terraform.tfvars or terraform.tfvars.json
    *.auto.tfvars or *.auto.tfvars.json
    exported TF_VAR_* environment variables
    Terraform variable defaults
    --var or --var-file options accepted by this script

  Relative --var-file paths are resolved from bootstrap/<env>/account.

  The resolved account-stack configuration must include:
    cloud_name
    environment
    primary_region
    enable_github_oidc = true
    owner_github
    repo_github
    tf_state_bucket_arn
    tf_state_bucket_cmk_arn
    enable_apply_role_github = true
    environment_apply_github

  The resolved environment and environment_apply_github values must match
  the target passed to this script.

  See bootstrap/<env>/account/terraform.tfvars.example for the complete
  account-stack configuration.

  The script automatically resolves and overrides:
    lambda_cmk_arn
    secrets_manager_cmk_arn

Options:
  --apply               Apply the generated Terraform plan.
                        Without this option, the script is plan-only.
  --auto-approve        Skip the interactive confirmation before apply.
                        Requires --apply.
  --skip-validation     Skip strict bootstrap validation after apply.
  --var <name=value>    Pass an explicit Terraform variable.
                        May be specified more than once.
  --var-file <path>     Pass an additional Terraform variable file.
                        May be specified more than once.
  -h, --help            Show this help message.

Examples:
  # Use terraform.tfvars, *.auto.tfvars, TF_VAR_* values, and defaults.
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev

  # Use an explicit variable file and apply the saved plan.
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev \
    --var-file=terraform.tfvars \
    --apply

  # Pass an individual variable explicitly.
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev \
    --var='branches_apply_github=["main"]'
USAGE
}

get_plan_variable() {
  local plan_json="$1"
  local variable_name="$2"
  local variable_value

  if ! jq -e \
    --arg variable_name "$variable_name" \
    '((.variables | type) == "object") and (.variables | has($variable_name))' \
    "$plan_json" >/dev/null; then
    fail "Resolved Terraform plan does not contain variable '${variable_name}'"
  fi

  if jq -e \
    --arg variable_name "$variable_name" \
    '.variables[$variable_name].value == null' \
    "$plan_json" >/dev/null; then
    fail "Resolved Terraform variable '${variable_name}' is null"
  fi

  variable_value="$(
    jq -r \
      --arg variable_name "$variable_name" \
      '.variables[$variable_name].value |
        if type == "string" then . else tojson end' \
      "$plan_json"
  )"

  require_non_empty \
    "$variable_value" \
    "resolved Terraform variable '${variable_name}'"

  printf '%s\n' "$variable_value"
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
    fail \
      "${description} region mismatch. Expected ${AWS_REGION}, got ${arn_region}"
  fi

  if [[ "$arn_account_id" != "$ACTIVE_ACCOUNT_ID" ]]; then
    fail \
      "${description} account mismatch. Expected ${ACTIVE_ACCOUNT_ID}, got ${arn_account_id}"
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
    fail \
      "${description} is not customer-managed. Key manager: ${key_manager}"
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
TERRAFORM_INPUT_ARGS=()
VAR_FILE_PATHS=()

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --auto-approve)
      AUTO_APPROVE=true
      shift
      ;;
    --skip-validation)
      SKIP_VALIDATION=true
      shift
      ;;
    --var|-var)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
        fail "$1 requires a name=value argument"
      fi

      TERRAFORM_INPUT_ARGS+=("-var=$2")
      shift 2
      ;;
    --var=*|-var=*)
      variable_assignment="${1#*=}"

      if [[ -z "$variable_assignment" ]]; then
        fail "${1%%=*} requires a non-empty name=value argument"
      fi

      TERRAFORM_INPUT_ARGS+=("-var=${variable_assignment}")
      shift
      ;;
    --var-file|-var-file)
      if [[ "$#" -lt 2 || -z "${2:-}" ]]; then
        fail "$1 requires a path"
      fi

      VAR_FILE_PATHS+=("$2")
      TERRAFORM_INPUT_ARGS+=("-var-file=$2")
      shift 2
      ;;
    --var-file=*|-var-file=*)
      var_file_path="${1#*=}"

      if [[ -z "$var_file_path" ]]; then
        fail "${1%%=*} requires a non-empty path"
      fi

      VAR_FILE_PATHS+=("$var_file_path")
      TERRAFORM_INPUT_ARGS+=("-var-file=${var_file_path}")
      shift
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
done

if [[ "$AUTO_APPROVE" == "true" && "$APPLY" != "true" ]]; then
  fail "--auto-approve requires --apply"
fi

section "Workload account reconciliation: ${TARGET}"

section "Checking prerequisites and Terraform roots"

for command_name in terraform aws git sed jq mktemp rm; do
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

for var_file_path in "${VAR_FILE_PATHS[@]}"; do
  resolved_var_file_path="$var_file_path"

  if [[ "$resolved_var_file_path" != /* ]]; then
    resolved_var_file_path="${ACCOUNT_DIR}/${resolved_var_file_path}"
  fi

  require_file "$resolved_var_file_path"
  success "Terraform variable file exists: ${resolved_var_file_path}"
done

ENV_BACKEND_REGION="$(
  get_backend_string_value \
    "$ENV_BACKEND" \
    region
)"

ACCOUNT_BACKEND_REGION="$(
  get_backend_string_value \
    "$ACCOUNT_BACKEND" \
    region
)"

require_non_empty \
  "$ENV_BACKEND_REGION" \
  "workload backend region"

require_non_empty \
  "$ACCOUNT_BACKEND_REGION" \
  "bootstrap account backend region"

if [[ "$ENV_BACKEND_REGION" != "$ACCOUNT_BACKEND_REGION" ]]; then
  fail \
    "Backend region mismatch. Workload: ${ENV_BACKEND_REGION}; account: ${ACCOUNT_BACKEND_REGION}"
fi

success \
  "Workload and account backends use the same region: ${ENV_BACKEND_REGION}"

AWS_REGION="${AWS_REGION:-$ENV_BACKEND_REGION}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
EXPECTED_GITHUB_REPOSITORY_INPUT="$(
  printf '%s' \
    "${EXPECTED_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
)"

if [[ "$AWS_REGION" != "$ENV_BACKEND_REGION" ]]; then
  fail \
    "AWS_REGION (${AWS_REGION}) does not match backend region (${ENV_BACKEND_REGION})"
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
    fail \
      "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACTIVE_ACCOUNT_ID}"
  fi

  success "AWS account matches EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID}"
else
  warn \
    "EXPECTED_ACCOUNT_ID is not set. The active account will still be checked against both CMK ARNs."
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
PLAN_JSON="${TEMP_DIR}/${TARGET}-account-reconciliation.json"

cleanup() {
  rm -rf "$TEMP_DIR"
}

trap cleanup EXIT

section "Generating bootstrap account reconciliation plan"

terraform -chdir="$ACCOUNT_DIR" plan \
  -input=false \
  -no-color \
  -lock-timeout=5m \
  "${TERRAFORM_INPUT_ARGS[@]}" \
  -var="lambda_cmk_arn=${LAMBDA_CMK_ARN}" \
  -var="secrets_manager_cmk_arn=${SECRETS_MANAGER_CMK_ARN}" \
  -out="$PLAN_FILE"

success "Terraform reconciliation plan generated"

terraform -chdir="$ACCOUNT_DIR" show \
  -json \
  "$PLAN_FILE" > "$PLAN_JSON"

if [[ ! -s "$PLAN_JSON" ]]; then
  fail "Unable to render the saved Terraform plan as JSON"
fi

section "Validating resolved account-stack Terraform inputs"

RESOLVED_CLOUD_NAME="$(
  get_plan_variable \
    "$PLAN_JSON" \
    cloud_name
)"

RESOLVED_ENVIRONMENT="$(
  get_plan_variable \
    "$PLAN_JSON" \
    environment
)"

RESOLVED_PRIMARY_REGION="$(
  get_plan_variable \
    "$PLAN_JSON" \
    primary_region
)"

RESOLVED_ENABLE_GITHUB_OIDC="$(
  get_plan_variable \
    "$PLAN_JSON" \
    enable_github_oidc
)"

RESOLVED_OWNER_GITHUB="$(
  get_plan_variable \
    "$PLAN_JSON" \
    owner_github
)"

RESOLVED_REPO_GITHUB="$(
  get_plan_variable \
    "$PLAN_JSON" \
    repo_github
)"

RESOLVED_TF_STATE_BUCKET_ARN="$(
  get_plan_variable \
    "$PLAN_JSON" \
    tf_state_bucket_arn
)"

RESOLVED_TF_STATE_BUCKET_CMK_ARN="$(
  get_plan_variable \
    "$PLAN_JSON" \
    tf_state_bucket_cmk_arn
)"

RESOLVED_ENABLE_APPLY_ROLE_GITHUB="$(
  get_plan_variable \
    "$PLAN_JSON" \
    enable_apply_role_github
)"

RESOLVED_ENVIRONMENT_APPLY_GITHUB="$(
  get_plan_variable \
    "$PLAN_JSON" \
    environment_apply_github
)"

RESOLVED_LAMBDA_CMK_ARN="$(
  get_plan_variable \
    "$PLAN_JSON" \
    lambda_cmk_arn
)"

RESOLVED_SECRETS_MANAGER_CMK_ARN="$(
  get_plan_variable \
    "$PLAN_JSON" \
    secrets_manager_cmk_arn
)"

if [[ "$RESOLVED_ENVIRONMENT" != "$TARGET" ]]; then
  fail \
    "Resolved environment (${RESOLVED_ENVIRONMENT}) must match target (${TARGET})"
fi

if [[ "$RESOLVED_PRIMARY_REGION" != "$ENV_BACKEND_REGION" ]]; then
  fail \
    "Resolved primary_region (${RESOLVED_PRIMARY_REGION}) does not match workload backend region (${ENV_BACKEND_REGION})"
fi

if [[ "$RESOLVED_PRIMARY_REGION" != "$ACCOUNT_BACKEND_REGION" ]]; then
  fail \
    "Resolved primary_region (${RESOLVED_PRIMARY_REGION}) does not match account backend region (${ACCOUNT_BACKEND_REGION})"
fi

if [[ "$RESOLVED_ENABLE_GITHUB_OIDC" != "true" ]]; then
  fail "Resolved enable_github_oidc must be true for account reconciliation"
fi

if [[ "$RESOLVED_ENABLE_APPLY_ROLE_GITHUB" != "true" ]]; then
  fail \
    "Resolved enable_apply_role_github must be true for account reconciliation"
fi

if [[ "$RESOLVED_ENVIRONMENT_APPLY_GITHUB" != "$TARGET" ]]; then
  fail \
    "Resolved environment_apply_github (${RESOLVED_ENVIRONMENT_APPLY_GITHUB}) must match target (${TARGET})"
fi

if [[ "$RESOLVED_LAMBDA_CMK_ARN" != "$LAMBDA_CMK_ARN" ]]; then
  fail \
    "Resolved lambda_cmk_arn does not match the workload Terraform output"
fi

if [[ "$RESOLVED_SECRETS_MANAGER_CMK_ARN" != "$SECRETS_MANAGER_CMK_ARN" ]]; then
  fail \
    "Resolved secrets_manager_cmk_arn does not match the workload Terraform output"
fi

RESOLVED_GITHUB_REPOSITORY="${RESOLVED_OWNER_GITHUB}/${RESOLVED_REPO_GITHUB}"

if [[ -n "$EXPECTED_GITHUB_REPOSITORY_INPUT" &&
      "$EXPECTED_GITHUB_REPOSITORY_INPUT" != "$RESOLVED_GITHUB_REPOSITORY" ]]; then
  fail \
    "Expected GitHub repository (${EXPECTED_GITHUB_REPOSITORY_INPUT}) does not match resolved Terraform repository (${RESOLVED_GITHUB_REPOSITORY})"
fi

EXPECTED_GITHUB_REPOSITORY="$RESOLVED_GITHUB_REPOSITORY"

success "Resolved account-stack Terraform inputs passed reconciliation checks"
info "Cloud name: ${RESOLVED_CLOUD_NAME}"
info "Environment: ${RESOLVED_ENVIRONMENT}"
info "Primary region: ${RESOLVED_PRIMARY_REGION}"
info "GitHub repository: ${RESOLVED_GITHUB_REPOSITORY}"
info "GitHub OIDC enabled: ${RESOLVED_ENABLE_GITHUB_OIDC}"
info "GitHub Apply role enabled: ${RESOLVED_ENABLE_APPLY_ROLE_GITHUB}"
info "GitHub Apply environment: ${RESOLVED_ENVIRONMENT_APPLY_GITHUB}"
info "Terraform state bucket ARN: ${RESOLVED_TF_STATE_BUCKET_ARN}"
info "Terraform state bucket CMK ARN: ${RESOLVED_TF_STATE_BUCKET_CMK_ARN}"

cat <<PLAN_NOTICE

Terraform reconciliation plan:

  Target:               ${TARGET}
  AWS account:          ${ACTIVE_ACCOUNT_ID}
  AWS region:           ${AWS_REGION}
  GitHub repository:    ${RESOLVED_GITHUB_REPOSITORY}
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
GitHub repository:                  ${RESOLVED_GITHUB_REPOSITORY}
Execution mode:                     plan-only
Lambda CMK ARN:                     ${LAMBDA_CMK_ARN}
Secrets Manager CMK ARN:            ${SECRETS_MANAGER_CMK_ARN}
Plan applied:                       false
Post-apply validation performed:    false
SUMMARY

  cat <<NEXT_STEPS

Plan-only reconciliation completed successfully.

Review the plan above, then rerun with --apply. Reuse the same --var and
--var-file options, if any:

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
Environment:                         ${TARGET}
AWS profile:                         ${AWS_PROFILE:-<default>}
AWS region:                          ${AWS_REGION}
AWS account ID:                      ${ACTIVE_ACCOUNT_ID}
GitHub repository:                   ${RESOLVED_GITHUB_REPOSITORY}
Execution mode:                      apply
Lambda CMK ARN:                      ${LAMBDA_CMK_ARN}
Secrets Manager CMK ARN:             ${SECRETS_MANAGER_CMK_ARN}
Plan applied:                        true
Post-apply validation performed:     ${VALIDATION_PERFORMED}
SUMMARY

section "Reconciliation result"

success "Workload account reconciliation completed: ${TARGET}"