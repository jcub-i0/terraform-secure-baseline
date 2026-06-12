#!/usr/bin/env bash

# validate-sqs.sh
#
# Validates SQS queues for a deployed tf-secure-baseline workload environment.
#
# Current expected SQS design:
# - Compliance SNS topic publishes to compliance SQS queue.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - Compliance SQS queue exists
# - Queue encryption is configured
# - Queue policy exists
# - Queue policy allows the compliance SNS topic to publish
# - Compliance SNS topic has a subscription targeting the compliance queue
# - Queue DLQ/redrive config is reported
#
# Usage:
#   ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-sqs.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-sqs.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-sqs.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

