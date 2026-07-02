#!/usr/bin/env bash

# validate-control-plane.sh
#
# Validates read-only control-plane foundations for tf-secure-baseline.
#
# Scope:
#   - Control-plane AWS caller identity
#   - bootstrap/control_plane/state backend resources
#   - bootstrap/control_plane/account GitHub OIDC roles
#   - bootstrap/control_plane/organizations OU structure
#   - bootstrap/control_plane/identity_center instance, groups, permission sets,
#     and optional account assignments
#
# Usage:
#   AWS_PROFILE=control-plane \
#   AWS_REGION=us-east-1 \
#   EXPECTED_ACCOUNT_ID=<control-plane-account-id> \
#   ./scripts/validation/validate-control-plane.sh
#
# Optional:
#   NAME_PREFIX=tf-secure-baseline-control-plane ./scripts/validation/validate-control-plane.sh
#   EXPECTED_GITHUB_REPOSITORY=owner/repo ./scripts/validation/validate-control-plane.sh
#   ACCOUNT_ID_DEV=<dev-account-id> ACCOUNT_ID_STAGING=<staging-account-id> ACCOUNT_ID_PROD=<prod-account-id> ./scripts/validation/validate-control-plane.sh
#
# Notes:
#   This script is intentionally read-only. It does not run GitHub workflows,
#   assume roles, modify Identity Center assignments, move accounts, or perform
#   destroy/cleanup operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CONTROL_PLANE_ENV_NAME="${CONTROL_PLANE_ENV_NAME:-control-plane}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${CONTROL_PLANE_ENV_NAME}}"

REQUIRE_CONTROL_PLANE_GITHUB_OIDC="${REQUIRE_CONTROL_PLANE_GITHUB_OIDC:-true}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"
CHECK_OPTIONAL_SECOPS_GROUPS="${CHECK_OPTIONAL_SECOPS_GROUPS:-false}"
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-false}"

export AWS_PAGER=""

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

