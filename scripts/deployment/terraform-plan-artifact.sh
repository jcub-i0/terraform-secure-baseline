#!/usr/bin/env bash
set -euo pipefail

# terraform-plan-artifact.sh
#
# Shared exact-plan artifact helper for tf-secure-baseline CI/CD.
#
# The workflow owns policy, AWS identity, approvals, and Terraform apply.
# This helper owns only the portable exact-plan artifact contract:
#
#   create -> saved plan + readable plan + metadata + checksum manifest
#   verify -> checksum + metadata + Terraform version + plan-mode validation
#
# It never applies Terraform.

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

success() {
  printf '[PASS] %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Required command not found: $1"
}

usage() {
  cat <<'USAGE'
Usage:
  terraform-plan-artifact.sh <create|verify> \
    --mode <apply|destroy> \
    --working-directory <path> \
    --artifact-directory <path> \
    --artifact-basename <name> \
    --context-json '<json-object>'

Derived files:
  <basename>.tfplan
  <basename>-plan.txt
  <basename>-plan-metadata.json
  <basename>-plan.sha256

The caller supplies a small, non-secret context object. The helper adds GitHub
run identity and Terraform CLI version automatically.
USAGE
}

OPERATION="${1:-}"

case "$OPERATION" in
  create|verify)
    shift
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  "")
    usage
    exit 1
    ;;
  *)
    fail "Unsupported operation: ${OPERATION}"
    ;;
esac

MODE=""
WORKING_DIRECTORY=""
ARTIFACT_DIRECTORY=""
ARTIFACT_BASENAME=""
CONTEXT_JSON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      [[ $# -ge 2 ]] || fail "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --working-directory)
      [[ $# -ge 2 ]] || fail "--working-directory requires a value"
      WORKING_DIRECTORY="$2"
      shift 2
      ;;
    --artifact-directory)
      [[ $# -ge 2 ]] || fail "--artifact-directory requires a value"
      ARTIFACT_DIRECTORY="$2"
      shift 2
      ;;
    --artifact-basename)
      [[ $# -ge 2 ]] || fail "--artifact-basename requires a value"
      ARTIFACT_BASENAME="$2"
      shift 2
      ;;
    --context-json)
      [[ $# -ge 2 ]] || fail "--context-json requires a value"
      CONTEXT_JSON="$2"
      shift 2
      ;;
    *)
      fail "Unsupported argument: $1"
      ;;
  esac
done

for command_name in terraform jq sha256sum mktemp; do
  require_command "$command_name"
done

case "$MODE" in
  apply|destroy) ;;
  *) fail "--mode must be apply or destroy" ;;
esac

[[ -d "$WORKING_DIRECTORY" ]] ||
  fail "Working directory not found: ${WORKING_DIRECTORY}"

[[ -n "$ARTIFACT_DIRECTORY" ]] ||
  fail "--artifact-directory must not be empty"

[[ "$ARTIFACT_BASENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
  fail "--artifact-basename contains unsupported characters"

if ! jq -e 'type == "object"' <<<"$CONTEXT_JSON" >/dev/null; then
  fail "--context-json must be a valid JSON object"
fi

required_github_env=(
  GITHUB_SHA
  GITHUB_REPOSITORY
  GITHUB_RUN_ID
  GITHUB_RUN_ATTEMPT
  GITHUB_REF
  GITHUB_ACTOR
  GITHUB_WORKFLOW_REF
)

for variable_name in "${required_github_env[@]}"; do
  [[ -n "${!variable_name:-}" ]] ||
    fail "Required GitHub Actions variable is missing: ${variable_name}"
done

TRIGGERING_ACTOR="${GITHUB_TRIGGERING_ACTOR:-$GITHUB_ACTOR}"

PLAN_FILE_NAME="${ARTIFACT_BASENAME}.tfplan"
PLAN_TEXT_FILE_NAME="${ARTIFACT_BASENAME}-plan.txt"
METADATA_FILE_NAME="${ARTIFACT_BASENAME}-plan-metadata.json"
CHECKSUM_FILE_NAME="${ARTIFACT_BASENAME}-plan.sha256"

PLAN_FILE="${ARTIFACT_DIRECTORY}/${PLAN_FILE_NAME}"
PLAN_TEXT_FILE="${ARTIFACT_DIRECTORY}/${PLAN_TEXT_FILE_NAME}"
METADATA_FILE="${ARTIFACT_DIRECTORY}/${METADATA_FILE_NAME}"
CHECKSUM_FILE="${ARTIFACT_DIRECTORY}/${CHECKSUM_FILE_NAME}"

terraform_version() {
  terraform version -json |
    jq -er '.terraform_version | select(type == "string" and length > 0)'
}

validate_destroy_plan() {
  local plan_json_file="$1"

  [[ "$MODE" == "destroy" ]] || return 0

  local invalid_action_count
  local delete_change_count

  invalid_action_count="$(
    jq '
      [
        .resource_changes[]?
        | .change.actions[]?
        | select(
            . != "delete"
            and . != "no-op"
            and . != "read"
          )
      ]
      | length
    ' "$plan_json_file"
  )"

  [[ "$invalid_action_count" -eq 0 ]] ||
    fail "Destroy plan contains an action other than delete, no-op, or read"

  delete_change_count="$(
    jq '
      [
        .resource_changes[]?
        | select(.change.actions | index("delete"))
      ]
      | length
    ' "$plan_json_file"
  )"

  [[ "$delete_change_count" -gt 0 ]] ||
    fail "Destroy plan contains no resource deletions"
}

write_metadata() {
  local cli_version="$1"

  jq -n \
    --argjson context "$CONTEXT_JSON" \
    --arg mode "$MODE" \
    --arg commit_sha "$GITHUB_SHA" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg workflow_run_id "$GITHUB_RUN_ID" \
    --arg workflow_run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg git_ref "$GITHUB_REF" \
    --arg actor "$GITHUB_ACTOR" \
    --arg triggering_actor "$TRIGGERING_ACTOR" \
    --arg workflow_ref "$GITHUB_WORKFLOW_REF" \
    --arg terraform_version "$cli_version" '
      {
        schema_version: 1,
        plan_mode: $mode,
        github: {
          commit_sha: $commit_sha,
          repository: $repository,
          workflow_run_id: $workflow_run_id,
          workflow_run_attempt: $workflow_run_attempt,
          ref: $git_ref,
          actor: $actor,
          triggering_actor: $triggering_actor,
          workflow_ref: $workflow_ref
        },
        terraform_version: $terraform_version,
        context: $context
      }
    ' >"$METADATA_FILE"
}

verify_metadata() {
  local cli_version="$1"

  jq -e \
    --argjson expected_context "$CONTEXT_JSON" \
    --arg mode "$MODE" \
    --arg commit_sha "$GITHUB_SHA" \
    --arg repository "$GITHUB_REPOSITORY" \
    --arg workflow_run_id "$GITHUB_RUN_ID" \
    --arg workflow_run_attempt "$GITHUB_RUN_ATTEMPT" \
    --arg git_ref "$GITHUB_REF" \
    --arg actor "$GITHUB_ACTOR" \
    --arg triggering_actor "$TRIGGERING_ACTOR" \
    --arg workflow_ref "$GITHUB_WORKFLOW_REF" \
    --arg terraform_version "$cli_version" '
      .schema_version == 1
      and .plan_mode == $mode
      and .github.commit_sha == $commit_sha
      and .github.repository == $repository
      and .github.workflow_run_id == $workflow_run_id
      and .github.workflow_run_attempt == $workflow_run_attempt
      and .github.ref == $git_ref
      and .github.actor == $actor
      and .github.triggering_actor == $triggering_actor
      and .github.workflow_ref == $workflow_ref
      and .terraform_version == $terraform_version
      and .context == $expected_context
    ' "$METADATA_FILE" >/dev/null
}

create_artifact() {
  mkdir -p "$ARTIFACT_DIRECTORY"
  chmod 700 "$ARTIFACT_DIRECTORY"

  for artifact_path in \
    "$PLAN_FILE" \
    "$PLAN_TEXT_FILE" \
    "$METADATA_FILE" \
    "$CHECKSUM_FILE"; do
    [[ ! -e "$artifact_path" ]] ||
      fail "Refusing to overwrite existing artifact: ${artifact_path}"
  done

  local plan_args=(
    -input=false
    -no-color
    -lock-timeout=5m
    "-out=${PLAN_FILE}"
  )

  if [[ "$MODE" == "destroy" ]]; then
    plan_args=(-destroy "${plan_args[@]}")
  fi

  terraform -chdir="$WORKING_DIRECTORY" plan "${plan_args[@]}"

  terraform -chdir="$WORKING_DIRECTORY" show \
    -no-color \
    "$PLAN_FILE" |
    tee "$PLAN_TEXT_FILE"

  local plan_json_file
  plan_json_file="$(mktemp)"

  terraform -chdir="$WORKING_DIRECTORY" show \
    -json \
    "$PLAN_FILE" >"$plan_json_file"

  validate_destroy_plan "$plan_json_file"
  rm -f "$plan_json_file"

  write_metadata "$(terraform_version)"

  chmod 600 \
    "$PLAN_FILE" \
    "$PLAN_TEXT_FILE" \
    "$METADATA_FILE"

  (
    cd "$ARTIFACT_DIRECTORY"
    sha256sum \
      "$PLAN_FILE_NAME" \
      "$PLAN_TEXT_FILE_NAME" \
      "$METADATA_FILE_NAME" >"$CHECKSUM_FILE_NAME"
  )

  chmod 600 "$CHECKSUM_FILE"

  success "Created exact Terraform ${MODE} plan artifact"
}

verify_artifact() {
  for artifact_path in \
    "$PLAN_FILE" \
    "$PLAN_TEXT_FILE" \
    "$METADATA_FILE" \
    "$CHECKSUM_FILE"; do
    [[ -f "$artifact_path" && ! -L "$artifact_path" ]] ||
      fail "Artifact is missing, not a regular file, or is a symlink: ${artifact_path}"
  done

  (
    cd "$ARTIFACT_DIRECTORY"
    sha256sum --check "$CHECKSUM_FILE_NAME"
  )

  if ! verify_metadata "$(terraform_version)"; then
    jq . "$METADATA_FILE"
    fail "Saved plan metadata does not match the current workflow context"
  fi

  local plan_json_file
  plan_json_file="$(mktemp)"

  terraform -chdir="$WORKING_DIRECTORY" show \
    -json \
    "$PLAN_FILE" >"$plan_json_file"

  validate_destroy_plan "$plan_json_file"
  rm -f "$plan_json_file"

  success "Verified exact Terraform ${MODE} plan artifact"
}

case "$OPERATION" in
  create) create_artifact ;;
  verify) verify_artifact ;;
esac