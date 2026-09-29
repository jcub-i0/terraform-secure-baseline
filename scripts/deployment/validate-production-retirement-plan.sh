#!/usr/bin/env bash
set -euo pipefail

# validate-production-retirement-plan.sh
#
# Read-only Stage-1 guard for a saved production retirement Terraform plan.
#
# The script proves that the exact saved plan:
# - targets deployment_profile=production;
# - resolves production_retirement_mode=true;
# - disables only the native deletion protections required for retirement;
# - preserves fail-closed ECR/ECS/Backup destructive behavior;
# - derives zero-capacity ECS retirement configuration; and
# - contains no create, delete, replacement, or otherwise unsupported resource
#   actions.
#
# Allowed resource actions are read, no-op, and update only.
# This script performs no mutations and never applies Terraform.

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

success() {
  printf '[PASS] %s\n' "$*"
}

info() {
  printf '[INFO] %s\n' "$*"
}

section() {
  printf '\n%s\n%s\n%s\n' \
    '================================================================================' \
    "$*" \
    '================================================================================'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 ||
    fail "Required command not found: $1"
}

usage() {
  cat <<'USAGE'
Usage:
  validate-production-retirement-plan.sh \
    --working-directory <path> \
    --plan-file <path>

Options:
  --working-directory <path>  Terraform workload root used to read the plan.
  --plan-file <path>          Exact saved Terraform plan file to validate.
  -h, --help                  Show this help.

The plan must represent production retirement Stage 1. It may contain only
read, no-op, and in-place update actions. Any create, delete, replacement, or
unknown action fails closed.
USAGE
}

WORKING_DIRECTORY=""
PLAN_FILE=""
PLAN_JSON_FILE=""

cleanup() {
  [[ -z "$PLAN_JSON_FILE" || ! -f "$PLAN_JSON_FILE" ]] ||
    rm -f "$PLAN_JSON_FILE"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --working-directory)
      [[ $# -ge 2 ]] || fail "--working-directory requires a value"
      WORKING_DIRECTORY="$2"
      shift 2
      ;;
    --plan-file)
      [[ $# -ge 2 ]] || fail "--plan-file requires a value"
      PLAN_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unsupported argument: $1"
      ;;
  esac
done

[[ -n "$WORKING_DIRECTORY" ]] || {
  usage
  fail "--working-directory is required."
}

[[ -n "$PLAN_FILE" ]] || {
  usage
  fail "--plan-file is required."
}

for command_name in terraform jq mktemp; do
  require_command "$command_name"
done

[[ -d "$WORKING_DIRECTORY" ]] ||
  fail "Working directory not found: ${WORKING_DIRECTORY}"

[[ -f "$PLAN_FILE" && ! -L "$PLAN_FILE" ]] ||
  fail "Plan file is missing, is not a regular file, or is a symlink: ${PLAN_FILE}"

section "Production Retirement Stage-1 Plan Validation"
info "Working directory: ${WORKING_DIRECTORY}"
info "Plan file: ${PLAN_FILE}"

PLAN_JSON_FILE="$(mktemp)"
chmod 600 "$PLAN_JSON_FILE"

terraform -chdir="$WORKING_DIRECTORY" show -json "$PLAN_FILE" >"$PLAN_JSON_FILE" ||
  fail "Unable to decode saved Terraform plan as JSON."

if ! jq -e 'type == "object" and .errored != true' "$PLAN_JSON_FILE" >/dev/null; then
  fail "Terraform plan JSON is invalid or reports an errored plan."
fi

section "Checking Stage-1 resource actions"

INVALID_RESOURCE_CHANGES_JSON="$(
  jq -c '
    [
      .resource_changes[]?
      | select(
          any(.change.actions[]?;
            . != "read"
            and . != "no-op"
            and . != "update"
          )
        )
      | {
          address,
          mode,
          type,
          name,
          actions: .change.actions
        }
    ]
  ' "$PLAN_JSON_FILE"
)"

if [[ "$(echo "$INVALID_RESOURCE_CHANGES_JSON" | jq 'length')" -ne 0 ]]; then
  echo "$INVALID_RESOURCE_CHANGES_JSON" | jq .
  fail "Production retirement Stage 1 contains create, delete, replacement, or unsupported resource actions."
fi

RESOURCE_CHANGE_COUNT="$(
  jq '[.resource_changes[]?] | length' "$PLAN_JSON_FILE"
)"
UPDATE_CHANGE_COUNT="$(
  jq '[.resource_changes[]? | select(.change.actions == ["update"])] | length' \
    "$PLAN_JSON_FILE"
)"

success "Stage-1 plan contains only read, no-op, or in-place update actions"
info "Resource changes inspected: ${RESOURCE_CHANGE_COUNT}"
info "In-place updates: ${UPDATE_CHANGE_COUNT}"

section "Checking planned production retirement outputs"

if ! jq -e '
  .planned_values.outputs
  | type == "object"
  and has("deployment_profile")
  and has("lifecycle_protection")
  and has("ecs_service_configuration")
' "$PLAN_JSON_FILE" >/dev/null; then
  fail "Plan is missing one or more required retirement outputs: deployment_profile, lifecycle_protection, ecs_service_configuration."
fi

DEPLOYMENT_PROFILE="$(
  jq -er '.planned_values.outputs.deployment_profile.value' "$PLAN_JSON_FILE"
)" || fail "Unable to resolve planned deployment_profile output."

[[ "$DEPLOYMENT_PROFILE" == "production" ]] ||
  fail "Stage-1 retirement plan requires deployment_profile=production; planned value is ${DEPLOYMENT_PROFILE}."

LIFECYCLE_JSON="$(
  jq -cer '.planned_values.outputs.lifecycle_protection.value' "$PLAN_JSON_FILE"
)" || fail "Unable to resolve planned lifecycle_protection output."

if ! echo "$LIFECYCLE_JSON" |
  jq -e '
    type == "object"
    and .production_retirement_mode == true
    and .rds_deletion_protection == false
    and .alb_deletion_protection == false
    and .network_firewall_delete_protection == false
    and .ecr_force_delete == false
    and .ecs_service_force_delete == false
    and .backup_vault_force_destroy == false
  ' >/dev/null; then
  echo "$LIFECYCLE_JSON" | jq .
  fail "Planned lifecycle_protection output is not the required production retirement posture."
fi

success "Planned lifecycle protections match the production retirement contract"

ECS_SERVICE_CONFIGURATION_JSON="$(
  jq -cer '.planned_values.outputs.ecs_service_configuration.value' "$PLAN_JSON_FILE"
)" || fail "Unable to resolve planned ecs_service_configuration output."

if ! echo "$ECS_SERVICE_CONFIGURATION_JSON" |
  jq -e '
    type == "object"
    and all(.[];
      (.desired_count | type) == "number"
      and .desired_count == 0
      and (
        .scaling == null
        or (
          (.scaling | type) == "object"
          and (.scaling.min_capacity | type) == "number"
          and (.scaling.max_capacity | type) == "number"
          and .scaling.min_capacity == 0
          and .scaling.max_capacity == 0
        )
      )
    )
  ' >/dev/null; then
  echo "$ECS_SERVICE_CONFIGURATION_JSON" |
    jq '[
      to_entries[]
      | {
          service: .key,
          desired_count: .value.desired_count,
          scaling: (
            if .value.scaling == null
            then null
            else {
              min_capacity: .value.scaling.min_capacity,
              max_capacity: .value.scaling.max_capacity
            }
            end
          )
        }
    ]'
  fail "Planned ECS service configuration is not zero-capacity for every deployable service."
fi

ECS_SERVICE_COUNT="$(echo "$ECS_SERVICE_CONFIGURATION_JSON" | jq 'length')"
AUTOSCALED_SERVICE_COUNT="$(
  echo "$ECS_SERVICE_CONFIGURATION_JSON" |
    jq '[.[] | select(.scaling != null)] | length'
)"

success "Planned ECS retirement configuration is zero-capacity"

section "Stage-1 Plan Summary"
cat <<SUMMARY
Deployment profile:              ${DEPLOYMENT_PROFILE}
Resource changes inspected:      ${RESOURCE_CHANGE_COUNT}
In-place resource updates:       ${UPDATE_CHANGE_COUNT}
Deployable ECS services:         ${ECS_SERVICE_COUNT}
Autoscaled ECS services:         ${AUTOSCALED_SERVICE_COUNT}
production_retirement_mode:      $(echo "$LIFECYCLE_JSON" | jq -r '.production_retirement_mode')
RDS deletion protection:         $(echo "$LIFECYCLE_JSON" | jq -r '.rds_deletion_protection')
ALB deletion protection:         $(echo "$LIFECYCLE_JSON" | jq -r '.alb_deletion_protection')
Network Firewall protection:     $(echo "$LIFECYCLE_JSON" | jq -r '.network_firewall_delete_protection')
ECR force_delete:                $(echo "$LIFECYCLE_JSON" | jq -r '.ecr_force_delete')
ECS service force_delete:        $(echo "$LIFECYCLE_JSON" | jq -r '.ecs_service_force_delete')
Backup vault force_destroy:      $(echo "$LIFECYCLE_JSON" | jq -r '.backup_vault_force_destroy')
SUMMARY

section "Validation Result"
success "Production retirement Stage-1 plan is non-destructive and matches the Terraform-owned retirement contract"