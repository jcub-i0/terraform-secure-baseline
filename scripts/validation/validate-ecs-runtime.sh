#!/usr/bin/env bash

# Validate ECS/Fargate runtime against the authoritative Terraform outputs.
# Internal modules share contract data and validated networking identities.
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/ecs-runtime/common.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/common.sh"
# shellcheck source=lib/ecs-runtime/contract.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/contract.sh"
# shellcheck source=lib/ecs-runtime/cluster.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/cluster.sh"
# shellcheck source=lib/ecs-runtime/services.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/services.sh"
# shellcheck source=lib/ecs-runtime/autoscaling.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/autoscaling.sh"
# shellcheck source=lib/ecs-runtime/ingress.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/ingress.sh"
# shellcheck source=lib/ecs-runtime/alarms.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/alarms.sh"
# shellcheck source=lib/ecs-runtime/summary.sh
source "${SCRIPT_DIR}/lib/ecs-runtime/summary.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

AWS_ARGS=()

if [[ -n "$AWS_PROFILE" ]]; then
  AWS_ARGS+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  AWS_ARGS+=(--region "$AWS_REGION")
fi

section "${CLOUD_NAME} ECS Runtime Validation"

section "Checking required local commands"

require_command aws
require_command terraform
require_command jq
require_command git

success "Required commands are available"

ecs_runtime_load_contract
ecs_runtime_validate_identity
ecs_runtime_validate_cluster
ecs_runtime_resolve_service_networking

# Validated task ports and attachments are consumed by ingress validation.
declare -A SERVICE_CONTAINER_PORTS=()
declare -A SERVICE_TARGET_GROUP_ARNS=()

ecs_runtime_validate_services
ecs_runtime_validate_autoscaling
ecs_runtime_validate_ingress
ecs_runtime_validate_alarms
ecs_runtime_print_summary

section "Validation Result"

success "ECS runtime validation completed successfully for: ${ENV_NAME}"
