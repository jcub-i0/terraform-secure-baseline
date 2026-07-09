#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/common.sh"

AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

CONTROL_PLANE_ENV_NAME="${CONTROL_PLANE_ENV_NAME:-control-plane}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${CONTROL_PLANE_ENV_NAME}}"

REQUIRE_CONTROL_PLANE_GITHUB_OIDC="${REQUIRE_CONTROL_PLANE_GITHUB_OIDC:-true}"
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:-}"
CHECK_OPTIONAL_SECOPS_GROUPS="${CHECK_OPTIONAL_SECOPS_GROUPS:-false}"
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-false}"

ACCOUNT_ID_DEV="${ACCOUNT_ID_DEV:-}"
ACCOUNT_ID_STAGING="${ACCOUNT_ID_STAGING:-}"
ACCOUNT_ID_PROD="${ACCOUNT_ID_PROD:-}"

VALIDATION_TIME="$(date +"%Y-%m-%dT%H:%M:%S%:z")"
TIMESTAMP="$(date +"%Y-%m-%dT%H%M%S")"

REPO_ROOT="$(get_repo_root)"
OUTPUT_DIR="${REPO_ROOT}/validation-results/control-plane/${TIMESTAMP}"
RELATIVE_OUTPUT_DIR="validation-results/control-plane/${TIMESTAMP}"
SUMMARY_JSON="${OUTPUT_DIR}/summary.json"
SUMMARY_MD="${OUTPUT_DIR}/summary.md"

mkdir -p "$OUTPUT_DIR"

VALIDATION_SCRIPT="validate-control-plane.sh"
VALIDATION_AREA="Control Plane"
VALIDATION_LAYER="control_plane"

RESULTS_JSONL="$(mktemp)"
trap 'rm -f "$RESULTS_JSONL"' EXIT

PASSED_COUNT=0
FAILED_COUNT=0
TOTAL_COUNT=1

section "${CLOUD_NAME} Control-Plane Validation Report Export"

section "Checking required local commands"

require_command "aws"
success "aws CLI found"

require_command "terraform"
success "terraform found"

require_command "jq"
success "jq found"

require_command "git"
success "git found"

section "Resolving repository paths and report settings"

info "Repository root: ${REPO_ROOT}"
info "Control-plane environment name: ${CONTROL_PLANE_ENV_NAME}"
info "Validation layer: ${VALIDATION_LAYER}"
info "Output dir: ${OUTPUT_DIR}"
info "Name prefix: ${NAME_PREFIX}"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"
info "EXPECTED_ACCOUNT_ID: ${EXPECTED_ACCOUNT_ID:-<not set>}"
info "EXPECTED_GITHUB_REPOSITORY: ${EXPECTED_GITHUB_REPOSITORY:-<not set>}"
info "REQUIRE_CONTROL_PLANE_GITHUB_OIDC: ${REQUIRE_CONTROL_PLANE_GITHUB_OIDC}"
info "CHECK_OPTIONAL_SECOPS_GROUPS: ${CHECK_OPTIONAL_SECOPS_GROUPS}"
info "STRICT_IDENTITY_CENTER_ASSIGNMENTS: ${STRICT_IDENTITY_CENTER_ASSIGNMENTS}"
info "STRICT_ACCOUNT_OU_CHECKS: ${STRICT_ACCOUNT_OU_CHECKS}"
info "ACCOUNT_ID_DEV: ${ACCOUNT_ID_DEV:-<not set>}"
info "ACCOUNT_ID_STAGING: ${ACCOUNT_ID_STAGING:-<not set>}"
info "ACCOUNT_ID_PROD: ${ACCOUNT_ID_PROD:-<not set>}"
info "Validation time: ${VALIDATION_TIME}"

if [[ "$NAME_PREFIX" != *"-${CONTROL_PLANE_ENV_NAME}" ]]; then
  warn "NAME_PREFIX does not end with -${CONTROL_PLANE_ENV_NAME}: ${NAME_PREFIX}"
  warn "This may be valid for custom/client deployments, but confirm it matches deployed resource names."
fi