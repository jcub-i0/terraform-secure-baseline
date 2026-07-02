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