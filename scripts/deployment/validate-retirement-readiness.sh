#!/usr/bin/env bash
set -euo pipefail

# validation-retirement-readiness.sh
#
# Read-only Stage-2 gate for retiring a tf-secure-baseline workload whose
# effective deployment profile is production.
#
# Run this only after the Stage-1 retirement Apply has converged and before
# generating the saved Terraform destroy plan.
#
# The script proves:
# - Terraform reports production_retirement_mode=true;
# - production force-delete/force-destroy behavior remains disabled;
# - RDS/ALB/Network Firewall native deletion protection is disabled live;
# - RDS final-snapshot and automated-backup retention behavior remains intact;
# - ECS services are fully quiesced;
# - ECS Application Auto Scaling cannot restore capacity;
# - Terraform-managed ECR repositories are empty; and
# - the Backup vault contains no recovery points or active backup jobs.
#
# This script performs no mutations.

export AWS_PAGER=""

# -----------------------------------------------------------------------------
# Output / validation helpers
# -----------------------------------------------------------------------------

info()    { printf '[INFO] %s\n' "$*"; }
success() { printf '[PASS] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*"; }

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
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

require_environment() {
  case "$1" in
    dev|staging|prod) ;;
    *) fail "Invalid environment: $1. Expected one of: dev, staging, prod." ;;
  esac
}

usage() {
  cat <<'USAGE'
Usage:
  validation-retirement-readiness.sh <dev|staging|prod> [options]

Or:
  validation-retirement-readiness.sh --environment <dev|staging|prod> [options]

Options:
  --environment <env>          Workload environment.
  --region <region>            AWS Region.
                               Default: $AWS_REGION, $AWS_DEFAULT_REGION,
                               or us-east-1.
  --profile <profile>          AWS CLI profile.
                               Default: $AWS_PROFILE.
  --expected-account-id <id>   Expected 12-digit AWS account ID.
                               Default: $EXPECTED_ACCOUNT_ID.
  -h, --help                   Show this help.

The script fails closed unless the selected workload is already in the
Terraform-managed production retirement posture.
USAGE
}

# -----------------------------------------------------------------------------
# Request
# -----------------------------------------------------------------------------

ENVIRONMENT=""
AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

if [[ $# -gt 0 && "${1:0:1}" != "-" ]]; then
  ENVIRONMENT="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      [[ $# -ge 2 ]] || fail "--environment requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || fail "--region requires a value"
      AWS_REGION="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      AWS_PROFILE="$2"
      shift 2
      ;;
    --expected-account-id)
      [[ $# -ge 2 ]] || fail "--expected-account-id requires a value"
      EXPECTED_ACCOUNT_ID="$2"
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

[[ -n "$ENVIRONMENT" ]] || {
  usage
  fail "Environment is required."
}

require_environment "$ENVIRONMENT"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]] &&
  [[ ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  fail "Expected AWS account ID must contain exactly 12 digits."
fi

aws_args=()
[[ -z "$AWS_PROFILE" ]] || aws_args+=(--profile "$AWS_PROFILE")
[[ -z "$AWS_REGION" ]] || aws_args+=(--region "$AWS_REGION")

STATE_JSON_FILE=""

cleanup() {
  [[ -z "$STATE_JSON_FILE" || ! -f "$STATE_JSON_FILE" ]] ||
    rm -f "$STATE_JSON_FILE"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# Local prerequisites / Terraform contract
# -----------------------------------------------------------------------------

section "Production Retirement Readiness"
section "Checking local prerequisites"

for command_name in aws terraform jq git mktemp; do
  require_command "$command_name"
  success "${command_name} found"
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  fail "Unable to resolve repository root."

ENV_DIR="${REPO_ROOT}/environments/${ENVIRONMENT}"
[[ -d "$ENV_DIR" ]] ||
  fail "Environment directory not found: ${ENV_DIR}"

info "Repository root: ${REPO_ROOT}"
info "Environment: ${ENVIRONMENT}"
info "Environment dir: ${ENV_DIR}"
info "AWS profile: ${AWS_PROFILE:-<default>}"
info "AWS region: ${AWS_REGION}"

OUTPUTS_JSON="$(terraform -chdir="$ENV_DIR" output -json)"

[[ -n "$OUTPUTS_JSON" && "$OUTPUTS_JSON" != "{}" ]] ||
  fail "No Terraform outputs found for ${ENV_DIR}. Has Stage 1 been applied?"

output_exists() {
  echo "$OUTPUTS_JSON" |
    jq -e --arg name "$1" 'has($name)' >/dev/null
}

output_json() {
  echo "$OUTPUTS_JSON" |
    jq -c --arg name "$1" '.[$name].value'
}

output_raw() {
  echo "$OUTPUTS_JSON" |
    jq -r --arg name "$1" '.[$name].value'
}

required_outputs=(
  deployment_profile
  name_prefix
  rds_address
  effective_egress_mode
  lifecycle_protection
  ecr_repositories
  ecs_cluster
  ecs_services
  ecs_autoscaling_targets
)

for output_name in "${required_outputs[@]}"; do
  output_exists "$output_name" ||
    fail "Missing required Terraform output: ${output_name}"
done

DEPLOYMENT_PROFILE="$(output_raw deployment_profile)"
NAME_PREFIX="$(output_raw name_prefix)"
RDS_ADDRESS="$(output_raw rds_address)"
EFFECTIVE_EGRESS_MODE="$(output_raw effective_egress_mode)"
LIFECYCLE_JSON="$(output_json lifecycle_protection)"

PRODUCTION_RETIREMENT_MODE="$(
  echo "$LIFECYCLE_JSON" |
    jq -r '.production_retirement_mode'
)"

ECR_REPOSITORIES_JSON="$(output_json ecr_repositories)"
ECS_CLUSTER_JSON="$(output_json ecs_cluster)"
ECS_SERVICES_JSON="$(output_json ecs_services)"
ECS_AUTOSCALING_TARGETS_JSON="$(output_json ecs_autoscaling_targets)"

if output_exists application_load_balancer; then
  APPLICATION_LOAD_BALANCER_JSON="$(output_json application_load_balancer)"
else
  APPLICATION_LOAD_BALANCER_JSON="null"
fi

[[ "$DEPLOYMENT_PROFILE" == "production" ]] ||
  fail "This gate requires deployment_profile=production; Terraform reports ${DEPLOYMENT_PROFILE}."

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
  fail "Terraform lifecycle_protection output is not in the required retirement posture."
fi

success "Terraform reports the required production retirement posture"

# -----------------------------------------------------------------------------
# Terraform state evidence for provider-only deletion behavior
# -----------------------------------------------------------------------------

section "Checking Terraform lifecycle state"

STATE_JSON_FILE="$(mktemp)"
chmod 600 "$STATE_JSON_FILE"

terraform -chdir="$ENV_DIR" show -json >"$STATE_JSON_FILE" ||
  fail "Unable to read Terraform state as JSON."

jq -e '.values.root_module | type == "object"' \
  "$STATE_JSON_FILE" >/dev/null ||
  fail "Terraform state JSON does not contain a readable root module."

state_resources() {
  jq -c \
    --arg type "$1" '
      [
        .values.root_module
        | recurse(.child_modules[]?)
        | .resources[]?
        | select(.mode == "managed" and .type == $type)
      ]
    ' "$STATE_JSON_FILE"
}

RDS_STATE_JSON="$(state_resources aws_db_instance)"
ECR_STATE_JSON="$(state_resources aws_ecr_repository)"
ECS_STATE_JSON="$(state_resources aws_ecs_service)"
BACKUP_VAULT_STATE_JSON="$(state_resources aws_backup_vault)"

[[ "$(echo "$RDS_STATE_JSON" | jq 'length')" -eq 1 ]] ||
  fail "Expected exactly one Terraform-managed RDS DB instance."

if ! echo "$RDS_STATE_JSON" |
  jq -e '
    .[0].values.skip_final_snapshot == false
    and .[0].values.delete_automated_backups == false
    and (
      .[0].values.final_snapshot_identifier
      | type == "string" and length > 0
    )
  ' >/dev/null; then
  echo "$RDS_STATE_JSON" |
    jq '.[0] | {
      address,
      skip_final_snapshot: .values.skip_final_snapshot,
      delete_automated_backups: .values.delete_automated_backups,
      final_snapshot_identifier: .values.final_snapshot_identifier
    }'
  fail "RDS final-snapshot/automated-backup retirement contract is invalid in Terraform state."
fi

EXPECTED_ECR_COUNT="$(echo "$ECR_REPOSITORIES_JSON" | jq 'length')"
EXPECTED_ECS_COUNT="$(echo "$ECS_SERVICES_JSON" | jq 'length')"

if [[ "$(echo "$ECR_STATE_JSON" | jq 'length')" -ne "$EXPECTED_ECR_COUNT" ]] ||
  ! echo "$ECR_STATE_JSON" |
    jq -e 'all(.[]; .values.force_delete == false)' >/dev/null; then
  echo "$ECR_STATE_JSON" |
    jq '[.[] | {address, name: .values.name, force_delete: .values.force_delete}]'
  fail "ECR Terraform state is not fail-closed for production retirement."
fi

if [[ "$(echo "$ECS_STATE_JSON" | jq 'length')" -ne "$EXPECTED_ECS_COUNT" ]] ||
  ! echo "$ECS_STATE_JSON" |
    jq -e 'all(.[]; .values.force_delete == false)' >/dev/null; then
  echo "$ECS_STATE_JSON" |
    jq '[.[] | {address, name: .values.name, force_delete: .values.force_delete}]'
  fail "ECS Terraform state is not fail-closed for production retirement."
fi

if [[ "$(echo "$BACKUP_VAULT_STATE_JSON" | jq 'length')" -ne 1 ]] ||
  ! echo "$BACKUP_VAULT_STATE_JSON" |
    jq -e '.[0].values.force_destroy == false' >/dev/null; then
  echo "$BACKUP_VAULT_STATE_JSON" |
    jq '[.[] | {address, name: .values.name, force_destroy: .values.force_destroy}]'
  fail "Backup vault Terraform state is not fail-closed for production retirement."
fi

RDS_IDENTIFIER="$(echo "$RDS_STATE_JSON" | jq -r '.[0].values.identifier // empty')"
FINAL_SNAPSHOT_IDENTIFIER="$(
  echo "$RDS_STATE_JSON" |
    jq -r '.[0].values.final_snapshot_identifier // empty'
)"
BACKUP_VAULT_NAME="$(
  echo "$BACKUP_VAULT_STATE_JSON" |
    jq -r '.[0].values.name // empty'
)"

[[ -n "$RDS_IDENTIFIER" ]] ||
  fail "Unable to resolve RDS identifier from Terraform state."
[[ -n "$FINAL_SNAPSHOT_IDENTIFIER" ]] ||
  fail "Unable to resolve RDS final snapshot identifier from Terraform state."
[[ -n "$BACKUP_VAULT_NAME" ]] ||
  fail "Unable to resolve Backup vault name from Terraform state."

success "Provider-only lifecycle state remains fail-closed"

# -----------------------------------------------------------------------------
# AWS identity
# -----------------------------------------------------------------------------

section "Checking AWS caller identity"

CALLER_JSON="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --output json
)"

AWS_ACCOUNT_ID="$(echo "$CALLER_JSON" | jq -r '.Account // empty')"
AWS_CALLER_ARN="$(echo "$CALLER_JSON" | jq -r '.Arn // empty')"

[[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] ||
  fail "Unable to resolve a valid AWS account ID."

[[ -n "$AWS_CALLER_ARN" ]] ||
  fail "Unable to resolve AWS caller ARN."

if [[ -n "$EXPECTED_ACCOUNT_ID" &&
      "$AWS_ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}."
fi

success "AWS caller identity is valid for account ${AWS_ACCOUNT_ID}"
info "AWS caller ARN: ${AWS_CALLER_ARN}"

# -----------------------------------------------------------------------------
# Native AWS deletion protections
# -----------------------------------------------------------------------------

section "Checking RDS deletion readiness"

RDS_LIVE_JSON="$(
  aws rds describe-db-instances \
    "${aws_args[@]}" \
    --db-instance-identifier "$RDS_IDENTIFIER" \
    --output json
)" || fail "Unable to describe RDS instance: ${RDS_IDENTIFIER}"

RDS_DELETION_PROTECTION="$(
  echo "$RDS_LIVE_JSON" |
    jq -r '.DBInstances[0].DeletionProtection'
)"

if ! echo "$RDS_LIVE_JSON" |
  jq -e \
    --arg address "$RDS_ADDRESS" '
      (.DBInstances | length) == 1
      and .DBInstances[0].Endpoint.Address == $address
      and .DBInstances[0].DeletionProtection == false
    ' >/dev/null; then
  echo "$RDS_LIVE_JSON" |
    jq '.DBInstances[]? | {
      DBInstanceIdentifier,
      DBInstanceStatus,
      endpoint: .Endpoint.Address,
      DeletionProtection
    }'
  fail "Live RDS identity or deletion-protection state is not retirement-ready."
fi

EXISTING_FINAL_SNAPSHOT_COUNT="$(
  aws rds describe-db-snapshots \
    "${aws_args[@]}" \
    --snapshot-type manual \
    --output json |
    jq \
      --arg snapshot_id "$FINAL_SNAPSHOT_IDENTIFIER" '
        [
          .DBSnapshots[]?
          | select(.DBSnapshotIdentifier == $snapshot_id)
        ]
        | length
      '
)"

[[ "$EXISTING_FINAL_SNAPSHOT_COUNT" -eq 0 ]] ||
  fail "Final snapshot identifier already exists and would block RDS deletion: ${FINAL_SNAPSHOT_IDENTIFIER}"

success "RDS deletion protection is disabled and final snapshot identifier is available"

section "Checking ALB deletion readiness"

if [[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]]; then
  success "No Terraform-managed Application Load Balancer is expected"
else
  ALB_ARN="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.arn // empty')"
  [[ -n "$ALB_ARN" ]] ||
    fail "application_load_balancer output does not contain an ARN."

  ALB_ATTRIBUTES_JSON="$(
    aws elbv2 describe-load-balancer-attributes \
      "${aws_args[@]}" \
      --load-balancer-arn "$ALB_ARN" \
      --output json
  )" || fail "Unable to describe Application Load Balancer: ${ALB_ARN}"

  if ! echo "$ALB_ATTRIBUTES_JSON" |
    jq -e '
      [
        .Attributes[]
        | select(.Key == "deletion_protection.enabled")
        | .Value
      ] == ["false"]
    ' >/dev/null; then
    echo "$ALB_ATTRIBUTES_JSON" |
      jq '[.Attributes[] | select(.Key == "deletion_protection.enabled")]'
    fail "Application Load Balancer deletion protection is still enabled."
  fi

  success "Application Load Balancer deletion protection is disabled"
fi

section "Checking Network Firewall deletion readiness"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    FIREWALL_NAME="${NAME_PREFIX}-egress-firewall"

    FIREWALL_JSON="$(
      aws network-firewall describe-firewall \
        "${aws_args[@]}" \
        --firewall-name "$FIREWALL_NAME" \
        --output json
    )" || fail "Unable to describe Network Firewall: ${FIREWALL_NAME}"

    if ! echo "$FIREWALL_JSON" |
      jq -e \
        --arg name "$FIREWALL_NAME" '
          .Firewall.FirewallName == $name
          and .Firewall.DeleteProtection == false
        ' >/dev/null; then
      echo "$FIREWALL_JSON" |
        jq '.Firewall | {
          FirewallName,
          FirewallArn,
          DeleteProtection
        }'
      fail "Network Firewall deletion protection is still enabled or its identity is unexpected."
    fi

    success "Network Firewall deletion protection is disabled"
    ;;
  nat_only|vpc_endpoints_only)
    MATCHING_FIREWALLS="$(
      aws network-firewall list-firewalls \
        "${aws_args[@]}" \
        --output json |
        jq \
          --arg name "${NAME_PREFIX}-egress-firewall" '
            [.Firewalls[]? | select(.FirewallName == $name)] | length
          '
    )"

    [[ "$MATCHING_FIREWALLS" -eq 0 ]] ||
      fail "Unexpected baseline Network Firewall exists while effective_egress_mode=${EFFECTIVE_EGRESS_MODE}."

    success "No Network Firewall is expected for effective_egress_mode=${EFFECTIVE_EGRESS_MODE}"
    ;;
  *)
    fail "Unsupported effective_egress_mode: ${EFFECTIVE_EGRESS_MODE}"
    ;;
esac

# -----------------------------------------------------------------------------
# ECS / Application Auto Scaling
# -----------------------------------------------------------------------------

section "Checking ECS service quiescence"

ECS_CLUSTER_ARN="$(echo "$ECS_CLUSTER_JSON" | jq -r '.arn // empty')"
ECS_CLUSTER_NAME="$(echo "$ECS_CLUSTER_JSON" | jq -r '.name // empty')"

[[ -n "$ECS_CLUSTER_ARN" && -n "$ECS_CLUSTER_NAME" ]] ||
  fail "ecs_cluster output is missing the cluster ARN or name."

if [[ "$EXPECTED_ECS_COUNT" -eq 0 ]]; then
  success "No deployable ECS services are present"
else
  while IFS= read -r service_key; do
    SERVICE_JSON="$(
      echo "$ECS_SERVICES_JSON" |
        jq -c --arg service "$service_key" '.[$service]'
    )"

    SERVICE_ARN="$(echo "$SERVICE_JSON" | jq -r '.arn // empty')"
    SERVICE_NAME="$(echo "$SERVICE_JSON" | jq -r '.name // empty')"

    [[ -n "$SERVICE_ARN" && -n "$SERVICE_NAME" ]] ||
      fail "Terraform ECS service metadata is incomplete: ${service_key}"

    LIVE_SERVICE_JSON="$(
      aws ecs describe-services \
        "${aws_args[@]}" \
        --cluster "$ECS_CLUSTER_ARN" \
        --services "$SERVICE_ARN" \
        --output json
    )" || fail "Unable to describe ECS service: ${service_key}"

    if ! echo "$LIVE_SERVICE_JSON" |
      jq -e \
        --arg arn "$SERVICE_ARN" \
        --arg name "$SERVICE_NAME" '
          (.failures | length) == 0
          and (.services | length) == 1
          and .services[0].serviceArn == $arn
          and .services[0].serviceName == $name
          and .services[0].status == "ACTIVE"
          and .services[0].desiredCount == 0
          and .services[0].runningCount == 0
          and .services[0].pendingCount == 0
        ' >/dev/null; then
      echo "$LIVE_SERVICE_JSON" |
        jq '{
          failures,
          services: [
            .services[]? |
            {
              serviceArn,
              serviceName,
              status,
              desiredCount,
              runningCount,
              pendingCount
            }
          ]
        }'
      fail "ECS service is not fully quiesced: ${service_key}"
    fi

    success "ECS service is quiesced: ${service_key}"
  done < <(echo "$ECS_SERVICES_JSON" | jq -r 'keys[]')
fi

section "Checking ECS Application Auto Scaling"

INVALID_TF_TARGETS="$(
  echo "$ECS_AUTOSCALING_TARGETS_JSON" |
    jq -c '
      [
        to_entries[]
        | select(
            .value.min_capacity != 0
            or .value.max_capacity != 0
          )
        | {
            service: .key,
            resource_id: .value.resource_id,
            min_capacity: .value.min_capacity,
            max_capacity: .value.max_capacity
          }
      ]
    '
)"

if [[ "$(echo "$INVALID_TF_TARGETS" | jq 'length')" -ne 0 ]]; then
  echo "$INVALID_TF_TARGETS" | jq .
  fail "Terraform autoscaling targets can restore ECS capacity; retirement requires min_capacity=0 and max_capacity=0."
fi

EXPECTED_TARGET_IDS="$(
  echo "$ECS_AUTOSCALING_TARGETS_JSON" |
    jq -c '[.[]?.resource_id] | sort | unique'
)"

LIVE_CLUSTER_TARGETS="$(
  aws application-autoscaling describe-scalable-targets \
    "${aws_args[@]}" \
    --service-namespace ecs \
    --output json |
    jq -c \
      --arg prefix "service/${ECS_CLUSTER_NAME}/" '
        [
          .ScalableTargets[]?
          | select(.ResourceId | startswith($prefix))
        ]
      '
)"

LIVE_TARGET_IDS="$(
  echo "$LIVE_CLUSTER_TARGETS" |
    jq -c '[.[].ResourceId] | sort | unique'
)"

if [[ "$EXPECTED_TARGET_IDS" != "$LIVE_TARGET_IDS" ]]; then
  jq -n \
    --argjson expected "$EXPECTED_TARGET_IDS" \
    --argjson live "$LIVE_TARGET_IDS" \
    '{
      expected: $expected,
      live: $live,
      missing: ($expected - $live),
      unexpected: ($live - $expected)
    }'
  fail "Live ECS scalable-target membership does not exactly match Terraform."
fi

INVALID_LIVE_TARGETS="$(
  echo "$LIVE_CLUSTER_TARGETS" |
    jq -c '
      [
        .[]
        | select(.MinCapacity != 0 or .MaxCapacity != 0)
        | {
            ResourceId,
            MinCapacity,
            MaxCapacity,
            SuspendedState
          }
      ]
    '
)"

if [[ "$(echo "$INVALID_LIVE_TARGETS" | jq 'length')" -ne 0 ]]; then
  echo "$INVALID_LIVE_TARGETS" | jq .
  fail "One or more live ECS scalable targets can still restore capacity."
fi

while IFS= read -r resource_id; do
  [[ -n "$resource_id" ]] || continue

  SCHEDULED_ACTIONS="$(
    aws application-autoscaling describe-scheduled-actions \
      "${aws_args[@]}" \
      --service-namespace ecs \
      --resource-id "$resource_id" \
      --scalable-dimension ecs:service:DesiredCount \
      --output json
  )"

  if [[ "$(echo "$SCHEDULED_ACTIONS" | jq '.ScheduledActions | length')" -ne 0 ]]; then
    echo "$SCHEDULED_ACTIONS" |
      jq '.ScheduledActions | map({
        ScheduledActionName,
        ResourceId,
        Schedule,
        ScalableTargetAction
      })'
    fail "Scheduled scaling action could restore ECS capacity: ${resource_id}"
  fi
done < <(echo "$EXPECTED_TARGET_IDS" | jq -r '.[]')

success "Application Auto Scaling cannot restore ECS capacity"

# -----------------------------------------------------------------------------
# Durable-resource blockers
# -----------------------------------------------------------------------------

section "Checking ECR repository emptiness"

if [[ "$EXPECTED_ECR_COUNT" -eq 0 ]]; then
  success "No Terraform-managed ECR repositories are present"
else
  while IFS= read -r repository_key; do
    REPOSITORY_JSON="$(
      echo "$ECR_REPOSITORIES_JSON" |
        jq -c --arg repository "$repository_key" '.[$repository]'
    )"

    REPOSITORY_NAME="$(echo "$REPOSITORY_JSON" | jq -r '.name // empty')"
    REGISTRY_ID="$(echo "$REPOSITORY_JSON" | jq -r '.registry_id // empty')"

    [[ -n "$REPOSITORY_NAME" && -n "$REGISTRY_ID" ]] ||
      fail "Terraform ECR repository metadata is incomplete: ${repository_key}"

    LIVE_REPOSITORY_JSON="$(
      aws ecr describe-repositories \
        "${aws_args[@]}" \
        --repository-names "$REPOSITORY_NAME" \
        --output json
    )" || fail "Unable to describe ECR repository: ${REPOSITORY_NAME}"

    echo "$LIVE_REPOSITORY_JSON" |
      jq -e \
        --arg name "$REPOSITORY_NAME" \
        --arg registry_id "$REGISTRY_ID" '
          (.repositories | length) == 1
          and .repositories[0].repositoryName == $name
          and .repositories[0].registryId == $registry_id
        ' >/dev/null ||
      fail "Live ECR repository identity does not match Terraform: ${repository_key}"

    IMAGE_COUNT="$(
      aws ecr list-images \
        "${aws_args[@]}" \
        --repository-name "$REPOSITORY_NAME" \
        --filter tagStatus=ANY \
        --output json |
        jq '[.imageIds[]?.imageDigest] | unique | length'
    )"

    [[ "$IMAGE_COUNT" -eq 0 ]] ||
      fail "ECR repository still contains ${IMAGE_COUNT} image digest(s): ${REPOSITORY_NAME}"

    success "ECR repository is empty: ${REPOSITORY_NAME}"
  done < <(echo "$ECR_REPOSITORIES_JSON" | jq -r 'keys[]')
fi

section "Checking AWS Backup vault readiness"

aws backup describe-backup-vault \
  "${aws_args[@]}" \
  --backup-vault-name "$BACKUP_VAULT_NAME" \
  --output json >/dev/null ||
  fail "Unable to describe Backup vault: ${BACKUP_VAULT_NAME}"

RECOVERY_POINTS="$(
  aws backup list-recovery-points-by-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)"

RECOVERY_POINT_COUNT="$(echo "$RECOVERY_POINTS" | jq '.RecoveryPoints | length')"

if [[ "$RECOVERY_POINT_COUNT" -ne 0 ]]; then
  echo "$RECOVERY_POINTS" |
    jq '[
      .RecoveryPoints[] |
      {
        RecoveryPointArn,
        ResourceArn,
        ResourceType,
        Status,
        CreationDate
      }
    ]'
  fail "Backup vault still contains ${RECOVERY_POINT_COUNT} recovery point(s): ${BACKUP_VAULT_NAME}"
fi

ACTIVE_BACKUP_JOBS="$(
  aws backup list-backup-jobs \
    "${aws_args[@]}" \
    --by-backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json |
    jq -c '
      [
        .BackupJobs[]?
        | select(
            .State == "CREATED"
            or .State == "PENDING"
            or .State == "RUNNING"
            or .State == "ABORTING"
          )
        | {
            BackupJobId,
            ResourceArn,
            ResourceType,
            State,
            CreationDate
          }
      ]
    '
)"

if [[ "$(echo "$ACTIVE_BACKUP_JOBS" | jq 'length')" -ne 0 ]]; then
  echo "$ACTIVE_BACKUP_JOBS" | jq .
  fail "Backup vault has active backup jobs: ${BACKUP_VAULT_NAME}"
fi

ACTIVE_BACKUP_JOB_COUNT="$(
  echo "$ACTIVE_BACKUP_JOBS" |
    jq 'length'
)"

if [[ "$ACTIVE_BACKUP_JOB_COUNT" -ne 0 ]]; then
  echo "$ACTIVE_BACKUP_JOBS" | jq .
  fail "Backup vault has active backup jobs: ${BACKUP_VAULT_NAME}"
fi

success "Backup vault has no recovery points or active backup jobs"

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

section "Retirement Readiness Summary"

cat <<SUMMARY
Environment:                   ${ENVIRONMENT}
Deployment profile:            ${DEPLOYMENT_PROFILE}
AWS account ID:                ${AWS_ACCOUNT_ID}
AWS region:                    ${AWS_REGION}
Name prefix:                   ${NAME_PREFIX}
effective_egress_mode:         ${EFFECTIVE_EGRESS_MODE}
production_retirement_mode:    ${PRODUCTION_RETIREMENT_MODE}

RDS identifier:                ${RDS_IDENTIFIER}
RDS deletion protection:       ${RDS_DELETION_PROTECTION}
Final snapshot identifier:     ${FINAL_SNAPSHOT_IDENTIFIER}

ALB expected:                  $(if [[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]]; then echo "no"; else echo "yes"; fi)
Network Firewall expected:     $(if [[ "$EFFECTIVE_EGRESS_MODE" == "network_firewall" ]]; then echo "yes"; else echo "no"; fi)

ECS services:                  ${EXPECTED_ECS_COUNT}
ECS autoscaling targets:       $(echo "$ECS_AUTOSCALING_TARGETS_JSON" | jq 'length')
ECR repositories:              ${EXPECTED_ECR_COUNT}

Backup vault:                  ${BACKUP_VAULT_NAME}
Backup recovery points:        ${RECOVERY_POINT_COUNT}
Active backup jobs:            ${ACTIVE_BACKUP_JOB_COUNT}
SUMMARY

section "Validation Result"
success "Production retirement readiness validation passed for: ${ENVIRONMENT}"