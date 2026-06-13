#!/usr/bin/env bash

# validate-compute.sh
#
# Validates EC2 compute resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - VPC is resolved
# - Compute and quarantine security groups exist
# - EC2 instances exist and are private
# - EC2 instances are in compute private subnets
# - EC2 instances have no public IPs
# - EC2 instances enforce IMDSv2
# - EC2 instances have detailed monitoring enabled
# - EC2 instances have IAM instance profiles
# - Required automation/operations tags exist
# - Root EBS volumes are encrypted, gp3, 20 GiB
# - Root EBS volumes use a KMS key
#
# Usage:
#   ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-compute.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-compute.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SOURCE_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "${ENV_NAME}" ]]; then
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

