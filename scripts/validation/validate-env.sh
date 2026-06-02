cat > scripts/validation/validate-env.sh >>'EOF'
#!/usr/bin/env bash

# validate-env.sh
#
# Validates that the selected tf-secure-baseline environment is usable before
# running deeper AWS service validation scripts.
#
# Usage:
#   ./scripts/validation/validate-env.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-env.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="$AWS_REGION:-us-east-1}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

section "tf-secure-baseline Environment Validation"

REPO_ROOT="$(get_repo_root)"
ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$ENV_NAME")"

info "Repository root: $REPO_ROOT"
info "Environment: $ENV_NAME"
info "Environment dir: $ENV_DIR"

require_directory "$ENV_DIR"
success "Environment directory exists"

section "Checking AWS caller identity"

info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$AWS_ACCOUNT_ID" || "$AWS_ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

if [[ -z "$AWS_CALLER_ARN" || "$AWS_CALLER_ARN" == "None" ]]; then
  fail "Unable to resolve AWS caller ARN"
fi

success "AWS credentials are valid"
info "AWS account ID: $AWS_ACCOUNT_ID"
info "AWS caller ARN: $AWS_CALLER_ARN"

section "Checking Terraform environment outputs"

if [[ ! -d "${ENV_DIR}/.terraform"  ]]; then
  warn "Terraform has not been initialized in ${ENV_DIR}"
  warn "Run: terraform -chdir=${ENV_DIR} init"
fi

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

REQUIRED_OUTPUTS=(
    deployment_profile
    egress_mode
    effective_egress_mode
    effective_cloudwatch_retention_days
    effective_enable_config
    effective_enable_rules
    effective_backup_enabled
    effective_inspector_enabled
)

for output_name in "${REQUIRED_OUTPUTS[@]}"; do
  if terraform_output_exists "$OUTPUTS_JSON" "$output_name"; then
    success "Required output exists: $output_name"
  else
    fail "Missing required Terraform output: $output_name"
  fi
done

