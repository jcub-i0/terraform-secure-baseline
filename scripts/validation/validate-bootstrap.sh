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