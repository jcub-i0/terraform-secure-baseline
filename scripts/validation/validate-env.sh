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