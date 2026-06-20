#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"

if [[ -z "ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

REPO_ROOT="$(get_repo_root)"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"
OUTPUT_DIR="${REPO_ROOT}/validation-results/${ENV_NAME}/${TIMESTAMP}"

VALIDATION_SCRIPTS=(
  "validate-env.sh"
  "validate-networking.sh"
  "validate-vpc-endpoints.sh"
  "validate-logging.sh"
  "validate-security-services.sh"
  "validate-kms.sh"
  "validate-backup.sh"
  "validate-sns.sh"
  "validate-sqs.sh"
  "validate-eventbridge.sh"
  "validate-lambda.sh"
  "validate-ssm.sh"
  "validate-compute.sh"
  "validate-iam.sh"
)

FAILED_COUNT=0
PASSED_COUNT=0
TOTAL_COUNT="${#VALIDATION_SCRIPTS[@]}"