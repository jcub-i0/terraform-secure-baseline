#!/usr/bin/env bash
set -euo pipefail

# cleanup-retirement-durable-data.sh
#
# Explicitly inventories or deletes durable data that production retirement
# intentionally refuses to force-delete:
# - images in Terraform-managed ECR repositories; and
# - recovery points in the Terraform-managed AWS Backup vault.
#
# This script is deliberately separate from production_retirement_mode and from
# validate-retirement-readiness.sh. Retirement mode relaxes only the native
# deletion protections required for deliberate teardown. This script performs
# the separately-approved durable-data mutation.
#
# Modes:
#   plan  - read-only inventory of the durable data that would be deleted.
#   apply - delete exactly the Terraform-managed ECR image digests and Backup
#           recovery points after an explicit confirmation token.
#
# Usage:
#   cleanup-retirement-durable-data.sh prod --mode plan \
#     --expected-account-id 123456789012
#
#   cleanup-retirement-durable-data.sh prod --mode apply \
#     --expected-account-id 123456789012 \
#     --confirm DELETE-DURABLE-DATA

export AWS_PAGER=""

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

usage() {
  cat <<'USAGE'
Usage:
  cleanup-retirement-durable-data.sh <prod> [options]

Or:
  cleanup-retirement-durable-data.sh --environment prod [options]

Options:
  --environment <env>          Workload environment. This script requires prod.
  --mode <plan|apply>          plan is read-only; apply performs deletion.
                               Default: plan.
  --confirm <token>            Required for --mode apply. Must be exactly:
                               DELETE-DURABLE-DATA
  --region <region>            AWS Region. Default: $AWS_REGION,
                               $AWS_DEFAULT_REGION, or us-east-1.
  --profile <profile>          AWS CLI profile. Default: $AWS_PROFILE.
  --expected-account-id <id>   Required 12-digit workload account ID.
                               Default: $EXPECTED_ACCOUNT_ID.
  -h, --help                   Show this help.

The script fails closed unless Terraform reports the complete production
retirement posture, including force_delete=false for ECR and
force_destroy=false for the Backup vault.
USAGE
}

ENVIRONMENT=""
MODE="plan"
CONFIRM=""
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
    --mode)
      [[ $# -ge 2 ]] || fail "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --confirm)
      [[ $# -ge 2 ]] || fail "--confirm requires a value"
      CONFIRM="$2"
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

[[ "$ENVIRONMENT" == "prod" ]] ||
  fail "Durable production-retirement cleanup may only run for environment=prod."

case "$MODE" in
  plan|apply) ;;
  *) fail "Invalid mode: ${MODE}. Expected plan or apply." ;;
esac

[[ "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] ||
  fail "Expected AWS account ID must contain exactly 12 digits."

if [[ "$MODE" == "apply" && "$CONFIRM" != "DELETE-DURABLE-DATA" ]]; then
  fail "--mode apply requires --confirm DELETE-DURABLE-DATA."
fi

aws_args=()
[[ -z "$AWS_PROFILE" ]] || aws_args+=(--profile "$AWS_PROFILE")
[[ -z "$AWS_REGION" ]] || aws_args+=(--region "$AWS_REGION")

section "Production Retirement Durable-Data ${MODE^}"
section "Checking local prerequisites"

for command_name in aws terraform jq git; do
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
info "Mode: ${MODE}"
info "AWS profile: ${AWS_PROFILE:-<default>}"
info "AWS region: ${AWS_REGION}"

section "Resolving Terraform retirement contract"

OUTPUTS_JSON="$(terraform -chdir="$ENV_DIR" output -json)"

[[ -n "$OUTPUTS_JSON" && "$OUTPUTS_JSON" != "{}" ]] ||
  fail "No Terraform outputs found for ${ENV_DIR}. Has retirement Stage 1 been applied?"

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
  lifecycle_protection
  ecr_repositories
  backup_vault_configuration
)

for output_name in "${required_outputs[@]}"; do
  output_exists "$output_name" ||
    fail "Missing required Terraform output: ${output_name}"
done

DEPLOYMENT_PROFILE="$(output_raw deployment_profile)"
NAME_PREFIX="$(output_raw name_prefix)"
LIFECYCLE_JSON="$(output_json lifecycle_protection)"
ECR_REPOSITORIES_JSON="$(output_json ecr_repositories)"
BACKUP_VAULT_CONFIGURATION_JSON="$(output_json backup_vault_configuration)"

[[ "$DEPLOYMENT_PROFILE" == "production" ]] ||
  fail "Durable retirement cleanup requires deployment_profile=production; Terraform reports ${DEPLOYMENT_PROFILE}."

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
  fail "Terraform lifecycle_protection is not in the complete production retirement posture."
fi

if ! echo "$ECR_REPOSITORIES_JSON" |
  jq -e '
    type == "object"
    and all(
      to_entries[];
      (.key | type) == "string"
      and (.value | type) == "object"
      and (.value.name | type) == "string"
      and (.value.arn | type) == "string"
      and (.value.registry_id | type) == "string"
      and .value.force_delete == false
    )
  ' >/dev/null; then
  echo "$ECR_REPOSITORIES_JSON" | jq .
  fail "Terraform-managed ECR repository metadata is incomplete or force_delete is not false."
fi

if ! echo "$BACKUP_VAULT_CONFIGURATION_JSON" |
  jq -e '
    type == "object"
    and (.name | type) == "string"
    and (.name | length) > 0
    and (.arn | type) == "string"
    and (.arn | length) > 0
    and (.kms_key_arn | type) == "string"
    and (.kms_key_arn | length) > 0
    and .force_destroy == false
  ' >/dev/null; then
  echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq .
  fail "backup_vault_configuration is incomplete or force_destroy is not false."
fi

BACKUP_VAULT_NAME="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.name')"
BACKUP_VAULT_ARN="$(echo "$BACKUP_VAULT_CONFIGURATION_JSON" | jq -r '.arn')"
EXPECTED_ECR_COUNT="$(echo "$ECR_REPOSITORIES_JSON" | jq 'length')"

success "Terraform reports the required fail-closed production retirement posture"

section "Checking AWS caller identity"

CALLER_JSON="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --output json
)"

AWS_ACCOUNT_ID="$(echo "$CALLER_JSON" | jq -r '.Account // empty')"
AWS_CALLER_ARN="$(echo "$CALLER_JSON" | jq -r '.Arn // empty')"

[[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]] ||
  fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID:-<missing>}."

[[ -n "$AWS_CALLER_ARN" ]] ||
  fail "Unable to resolve AWS caller ARN."

success "AWS caller identity matches expected workload account: ${AWS_ACCOUNT_ID}"
info "AWS caller ARN: ${AWS_CALLER_ARN}"

section "Inventorying Terraform-managed ECR images"

ECR_INVENTORY_JSON='[]'
TOTAL_ECR_IMAGE_DIGESTS=0

while IFS= read -r repository_key; do
  [[ -n "$repository_key" ]] || continue

  repository_json="$(
    echo "$ECR_REPOSITORIES_JSON" |
      jq -c --arg repository "$repository_key" '.[$repository]'
  )"

  repository_name="$(echo "$repository_json" | jq -r '.name')"
  repository_arn="$(echo "$repository_json" | jq -r '.arn')"
  registry_id="$(echo "$repository_json" | jq -r '.registry_id')"

  [[ "$registry_id" == "$AWS_ACCOUNT_ID" ]] ||
    fail "Terraform ECR repository ${repository_name} belongs to unexpected registry ${registry_id}."

  live_repository_json="$(
    aws ecr describe-repositories \
      "${aws_args[@]}" \
      --registry-id "$registry_id" \
      --repository-names "$repository_name" \
      --output json
  )" || fail "Unable to describe Terraform-managed ECR repository: ${repository_name}"

  if ! echo "$live_repository_json" |
    jq -e \
      --arg name "$repository_name" \
      --arg arn "$repository_arn" \
      --arg registry_id "$registry_id" '
        (.repositories | length) == 1
        and .repositories[0].repositoryName == $name
        and .repositories[0].repositoryArn == $arn
        and .repositories[0].registryId == $registry_id
      ' >/dev/null; then
    echo "$live_repository_json" | jq .
    fail "Live ECR repository identity does not exactly match Terraform: ${repository_key}"
  fi

  image_ids_json="$(
    aws ecr list-images \
      "${aws_args[@]}" \
      --registry-id "$registry_id" \
      --repository-name "$repository_name" \
      --filter tagStatus=ANY \
      --output json |
      jq -c '.imageIds // []'
  )"

  image_digests_json="$(
    echo "$image_ids_json" |
      jq -c '[.[].imageDigest? | select(type == "string" and length > 0)] | sort | unique'
  )"

  image_digest_count="$(echo "$image_digests_json" | jq 'length')"
  TOTAL_ECR_IMAGE_DIGESTS=$((TOTAL_ECR_IMAGE_DIGESTS + image_digest_count))

  repository_inventory="$(
    jq -cn \
      --arg key "$repository_key" \
      --arg name "$repository_name" \
      --arg arn "$repository_arn" \
      --arg registry_id "$registry_id" \
      --argjson image_digest_count "$image_digest_count" \
      --argjson image_digests "$image_digests_json" '
        {
          key: $key,
          name: $name,
          arn: $arn,
          registry_id: $registry_id,
          image_digest_count: $image_digest_count,
          image_digests: $image_digests
        }
      '
  )"

  ECR_INVENTORY_JSON="$(
    jq -cn \
      --argjson inventory "$ECR_INVENTORY_JSON" \
      --argjson repository "$repository_inventory" \
      '$inventory + [$repository]'
  )"
done < <(echo "$ECR_REPOSITORIES_JSON" | jq -r 'keys[]')

if [[ "$EXPECTED_ECR_COUNT" -eq 0 ]]; then
  success "No Terraform-managed ECR repositories are present"
elif [[ "$TOTAL_ECR_IMAGE_DIGESTS" -eq 0 ]]; then
  success "Terraform-managed ECR repositories contain no image digests"
else
  warn "Terraform-managed ECR repositories contain ${TOTAL_ECR_IMAGE_DIGESTS} image digest(s)"
  echo "$ECR_INVENTORY_JSON" |
    jq '[.[] | select(.image_digest_count > 0)]'
fi

section "Inventorying AWS Backup recovery points"

LIVE_BACKUP_VAULT_JSON="$(
  aws backup describe-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)" || fail "Unable to describe Terraform-managed Backup vault: ${BACKUP_VAULT_NAME}"

if ! echo "$LIVE_BACKUP_VAULT_JSON" |
  jq -e \
    --arg name "$BACKUP_VAULT_NAME" \
    --arg arn "$BACKUP_VAULT_ARN" '
      .BackupVaultName == $name
      and .BackupVaultArn == $arn
    ' >/dev/null; then
  echo "$LIVE_BACKUP_VAULT_JSON" | jq .
  fail "Live Backup vault identity does not exactly match Terraform."
fi

RECOVERY_POINTS_JSON="$(
  aws backup list-recovery-points-by-backup-vault \
    "${aws_args[@]}" \
    --backup-vault-name "$BACKUP_VAULT_NAME" \
    --output json
)"

RECOVERY_POINT_COUNT="$(echo "$RECOVERY_POINTS_JSON" | jq '.RecoveryPoints | length')"

RECOVERY_POINT_ARNS_JSON="$(
  echo "$RECOVERY_POINTS_JSON" |
    jq -c '[.RecoveryPoints[]?.RecoveryPointArn | select(type == "string" and length > 0)]'
)"

ACTIVE_BACKUP_JOBS_JSON="$(
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

ACTIVE_BACKUP_JOB_COUNT="$(echo "$ACTIVE_BACKUP_JOBS_JSON" | jq 'length')"

if [[ "$RECOVERY_POINT_COUNT" -eq 0 ]]; then
  success "Backup vault contains no recovery points"
else
  warn "Backup vault contains ${RECOVERY_POINT_COUNT} recovery point(s)"
  echo "$RECOVERY_POINTS_JSON" |
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
fi

if [[ "$ACTIVE_BACKUP_JOB_COUNT" -eq 0 ]]; then
  success "Backup vault has no active backup jobs"
else
  warn "Backup vault has ${ACTIVE_BACKUP_JOB_COUNT} active backup job(s); apply mode will refuse to mutate durable data"
  echo "$ACTIVE_BACKUP_JOBS_JSON" | jq .
fi

append_github_summary() {
  [[ -n "${GITHUB_STEP_SUMMARY:-}" ]] || return 0

  {
    echo "# Production durable-data retirement"
    echo
    echo "- Environment: \`${ENVIRONMENT}\`"
    echo "- AWS account: \`${AWS_ACCOUNT_ID}\`"
    echo "- AWS region: \`${AWS_REGION}\`"
    echo "- Name prefix: \`${NAME_PREFIX}\`"
    echo "- Mode: \`${MODE}\`"
    echo "- Terraform-managed ECR repositories: \`${EXPECTED_ECR_COUNT}\`"
    echo "- ECR image digests: \`${TOTAL_ECR_IMAGE_DIGESTS}\`"
    echo "- Backup vault: \`${BACKUP_VAULT_NAME}\`"
    echo "- Backup recovery points: \`${RECOVERY_POINT_COUNT}\`"
    echo "- Active Backup jobs: \`${ACTIVE_BACKUP_JOB_COUNT}\`"
    echo

    if [[ "$MODE" == "plan" ]]; then
      echo "This job is read-only. A separately protected cleanup job must approve and perform permanent deletion."
    else
      echo "The explicitly approved durable-data cleanup was requested in this job."
    fi

    if [[ "$TOTAL_ECR_IMAGE_DIGESTS" -gt 0 ]]; then
      echo
      echo "## ECR image digests"
      echo
      echo '```json'
      echo "$ECR_INVENTORY_JSON" |
        jq '[.[] | select(.image_digest_count > 0)]'
      echo '```'
    fi

    if [[ "$RECOVERY_POINT_COUNT" -gt 0 ]]; then
      echo
      echo "## Backup recovery points"
      echo
      echo '```json'
      echo "$RECOVERY_POINTS_JSON" |
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
      echo '```'
    fi
  } >> "$GITHUB_STEP_SUMMARY"
}

append_github_summary

if [[ "$MODE" == "plan" ]]; then
  section "Durable-Data Cleanup Plan Result"
  success "Read-only durable-data inventory completed for: ${ENVIRONMENT}"
  exit 0
fi

section "Applying approved durable-data cleanup"

[[ "$ACTIVE_BACKUP_JOB_COUNT" -eq 0 ]] ||
  fail "Refusing durable-data cleanup while Backup jobs are active."

if [[ "$TOTAL_ECR_IMAGE_DIGESTS" -gt 0 ]]; then
  while IFS= read -r repository_entry; do
    repository_name="$(echo "$repository_entry" | jq -r '.name')"
    registry_id="$(echo "$repository_entry" | jq -r '.registry_id')"

    mapfile -t repository_digests < <(
      echo "$repository_entry" |
        jq -r '.image_digests[]'
    )

    [[ "${#repository_digests[@]}" -gt 0 ]] || continue

    info "Deleting ${#repository_digests[@]} image digest(s) from ${repository_name}"

    batch=()
    for digest in "${repository_digests[@]}"; do
      batch+=("imageDigest=${digest}")

      if [[ "${#batch[@]}" -eq 100 ]]; then
        delete_response="$(
          aws ecr batch-delete-image \
            "${aws_args[@]}" \
            --registry-id "$registry_id" \
            --repository-name "$repository_name" \
            --image-ids "${batch[@]}" \
            --output json
        )"

        if [[ "$(echo "$delete_response" | jq '.failures | length')" -ne 0 ]]; then
          echo "$delete_response" | jq .
          fail "ECR image deletion reported failures for repository: ${repository_name}"
        fi

        batch=()
      fi
    done

    if [[ "${#batch[@]}" -gt 0 ]]; then
      delete_response="$(
        aws ecr batch-delete-image \
          "${aws_args[@]}" \
          --registry-id "$registry_id" \
          --repository-name "$repository_name" \
          --image-ids "${batch[@]}" \
          --output json
      )"

      if [[ "$(echo "$delete_response" | jq '.failures | length')" -ne 0 ]]; then
        echo "$delete_response" | jq .
        fail "ECR image deletion reported failures for repository: ${repository_name}"
      fi
    fi

    success "Deleted approved ECR image digests from: ${repository_name}"
  done < <(echo "$ECR_INVENTORY_JSON" | jq -c '.[] | select(.image_digest_count > 0)')
else
  success "No ECR image digests require deletion"
fi

if [[ "$RECOVERY_POINT_COUNT" -gt 0 ]]; then
  while IFS= read -r recovery_point_arn; do
    [[ -n "$recovery_point_arn" ]] || continue

    info "Deleting Backup recovery point: ${recovery_point_arn}"

    aws backup delete-recovery-point \
      "${aws_args[@]}" \
      --backup-vault-name "$BACKUP_VAULT_NAME" \
      --recovery-point-arn "$recovery_point_arn"
  done < <(echo "$RECOVERY_POINT_ARNS_JSON" | jq -r '.[]')
else
  success "No Backup recovery points require deletion"
fi

section "Verifying durable-data cleanup"

while IFS= read -r repository_entry; do
  repository_name="$(echo "$repository_entry" | jq -r '.name')"
  registry_id="$(echo "$repository_entry" | jq -r '.registry_id')"

  remaining_image_count="$(
    aws ecr list-images \
      "${aws_args[@]}" \
      --registry-id "$registry_id" \
      --repository-name "$repository_name" \
      --filter tagStatus=ANY \
      --output json |
      jq '[.imageIds[]?.imageDigest] | unique | length'
  )"

  [[ "$remaining_image_count" -eq 0 ]] ||
    fail "ECR repository still contains ${remaining_image_count} image digest(s): ${repository_name}"
done < <(echo "$ECR_INVENTORY_JSON" | jq -c '.[]')

remaining_recovery_points_json='{"RecoveryPoints":[]}'
remaining_recovery_point_count=0

for attempt in {1..30}; do
  remaining_recovery_points_json="$(
    aws backup list-recovery-points-by-backup-vault \
      "${aws_args[@]}" \
      --backup-vault-name "$BACKUP_VAULT_NAME" \
      --output json
  )"

  remaining_recovery_point_count="$(
    echo "$remaining_recovery_points_json" |
      jq '.RecoveryPoints | length'
  )"

  [[ "$remaining_recovery_point_count" -eq 0 ]] && break

  if [[ "$attempt" -eq 30 ]]; then
    break
  fi

  info "Waiting for Backup recovery-point deletion to converge (${remaining_recovery_point_count} remaining)."
  sleep 5
done

if [[ "$remaining_recovery_point_count" -ne 0 ]]; then
  echo "$remaining_recovery_points_json" |
    jq '[.RecoveryPoints[] | {RecoveryPointArn, ResourceArn, ResourceType, Status, CreationDate}]'
  fail "Backup vault still contains ${remaining_recovery_point_count} recovery point(s) after cleanup."
fi

post_cleanup_active_jobs_json="$(
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
      ]
    '
)"

[[ "$(echo "$post_cleanup_active_jobs_json" | jq 'length')" -eq 0 ]] || {
  echo "$post_cleanup_active_jobs_json" | jq .
  fail "A Backup job became active during cleanup; retirement readiness must fail closed."
}

section "Durable-Data Cleanup Result"
success "Terraform-managed ECR images and Backup recovery points are empty for: ${ENVIRONMENT}"
warn "Run validate-retirement-readiness.sh immediately before generating/applying the production destroy plan."