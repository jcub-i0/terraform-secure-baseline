#!/usr/bin/env bash

# validate-vpc-endpoints.sh
#
# Validates VPC Endpoint behavior for a deployed tf-secure-baseline environment.
#
# Checks:
# - VPC can be resolved
# - Endpoint private subnets exist
# - Endpoint private route tables exist and have no default route
# - Interface VPC Endpoints exist and are available
# - Interface VPC Endpoints are deployed into endpoint private subnets
# - S3 Gateway Endpoint exists
# - S3 Gateway Endpoint is associated with expected private route tables
#
# Usage:
#   ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-vpc-endpoints.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

# Space-separated list so callers can override this later if the module becomes configurable.
EXPECTED_INTERFACE_ENDPOINT_SERVICES="${EXPECTED_INTERFACE_ENDPOINT_SERVICES:-sts logs ssm ssmmessages secretsmanager kms config sns ec2 events securityhub lambda}"

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
