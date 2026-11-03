#!/usr/bin/env bash
set -euo pipefail

# Read-only post-Apply ECS release acceptance.
# Usage: validate-ecs-release.sh <dev|staging|prod>
# Uses deployed Terraform outputs as the intended task-definition contract.
# ECS_RELEASE_TIMEOUT_SECONDS (default 600) and ECS_RELEASE_POLL_SECONDS
# (default 10) bound rollout/health convergence.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../validation/lib/common.sh
source "$SCRIPT_DIR/../validation/lib/common.sh"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  echo "Usage: $0 <dev|staging|prod>"
  exit 0
fi
[[ $# -eq 1 ]] || fail "Usage: $0 <dev|staging|prod>"
ENV_NAME="$1"
require_env_name "$ENV_NAME"
require_command terraform
require_command aws
require_command jq

AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
timeout="${ECS_RELEASE_TIMEOUT_SECONDS:-600}"
poll="${ECS_RELEASE_POLL_SECONDS:-10}"
[[ "$timeout" =~ ^[1-9][0-9]*$ ]] && ((timeout <= 1800)) ||
  fail "ECS_RELEASE_TIMEOUT_SECONDS must be 1–1800"
[[ "$poll" =~ ^(0|[1-9][0-9]*)$ ]] && ((poll <= 60)) ||
  fail "ECS_RELEASE_POLL_SECONDS must be 0–60"

env_dir="$(get_environment_dir "$(get_repo_root)" "$ENV_NAME")"
require_directory "$env_dir"
if ! outputs="$(terraform_output_json "$env_dir")"; then
  fail "Cannot read Terraform outputs for $ENV_NAME"
fi
if ! jq -e '
  (.ecs_cluster.value.arn | type == "string")
  and (.ecs_services.value | type == "object")
  and (.ecs_task_definition_arns.value | type == "object")
  and (.ecs_service_configuration.value | type == "object")
  and (.lifecycle_protection.value.production_retirement_mode | type == "boolean")
  and ((.ecs_services.value | keys) == (.ecs_task_definition_arns.value | keys))
  and ((.ecs_services.value | keys) == (.ecs_service_configuration.value | keys))
  and all(.ecs_services.value[]; (.arn | type == "string") and (.name | type == "string"))
  and all(.ecs_task_definition_arns.value[]; type == "string" and startswith("arn:"))
  and all(.ecs_service_configuration.value[]; (.ingress_enabled | type) == "boolean")
' <<< "$outputs" >/dev/null; then
  fail "Missing or inconsistent ECS Terraform outputs for $ENV_NAME"
fi

if [[ "$(jq -r '.lifecycle_protection.value.production_retirement_mode' <<< "$outputs")" == "true" ]]; then
  info "Production retirement posture: ECS release acceptance skipped"
  exit 0
fi
if [[ "$(jq -r '.ecs_services.value | length' <<< "$outputs")" == "0" ]]; then
  info "No deployable ECS services (including null-image configurations): skipped"
  exit 0
fi

AWS_REGION="$(resolve_workload_region "$env_dir" "$outputs")"
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
AWS_ARGS=(--region "$AWS_REGION")
[[ -z "$AWS_PROFILE" ]] || AWS_ARGS+=(--profile "$AWS_PROFILE")

EXPECTED_CLUSTER_ARN="$(jq -r '.ecs_cluster.value.arn' <<< "$outputs")"
account="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
[[ "$account" =~ ^[0-9]{12}$ ]] || fail "Unable to identify AWS account"
[[ -z "$EXPECTED_ACCOUNT_ID" || "$account" == "$EXPECTED_ACCOUNT_ID" ]] ||
  fail "AWS account mismatch: expected $EXPECTED_ACCOUNT_ID, got $account"
[[ "$EXPECTED_CLUSTER_ARN" == arn:*:ecs:"$AWS_REGION":"$account":cluster/* ]] ||
  fail "ECS cluster ARN does not match the resolved AWS account and region"

# DescribeTasks accepts at most 100 task ARNs per request.
describe_tasks() {
  local -a arns=()
  local i response part all='[]'
  mapfile -t arns < <(jq -r '.[]' <<< "$1")
  for ((i = 0; i < ${#arns[@]}; i += 100)); do
    if ! response="$(aws ecs describe-tasks "${AWS_ARGS[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" --tasks "${arns[@]:i:100}" --output json)"; then
      fail "ECS describe-tasks failed"
    fi
    if ! jq -e '(.failures | type) == "array" and (.failures | length) == 0
      and (.tasks | type) == "array"' <<< "$response" >/dev/null; then
      fail "ECS describe-tasks returned failures or invalid data"
    fi
    part="$(jq -c '.tasks' <<< "$response")"
    all="$(jq -cn --argjson a "$all" --argjson b "$part" '$a + $b')"
  done
  printf '%s\n' "$all"
}

service_ready() {
  local key="$1" arn="$2" name="$3" definition="$4" ingress="$5" health_check="$6" target_group="$7"
  local response count listed task_arns tasks target_response ips port

  if ! response="$(aws ecs describe-services "${AWS_ARGS[@]}" \
    --cluster "$EXPECTED_CLUSTER_ARN" --services "$arn" --output json)"; then
    fail "ECS describe-services failed: $key"
  fi
  if ! jq -e --arg arn "$arn" --arg name "$name" --arg cluster "$EXPECTED_CLUSTER_ARN" '
    ((.failures // []) | length) == 0 and (.services | length) == 1
    and .services[0].serviceArn == $arn
    and .services[0].serviceName == $name
    and .services[0].clusterArn == $cluster
    and .services[0].status == "ACTIVE"
  ' <<< "$response" >/dev/null; then
    fail "ECS service missing, inactive, or unexpected: $key"
  fi
  if jq -e --arg def "$definition" '
    any(.services[0].deployments[]?; .taskDefinition == $def and .rolloutState == "FAILED")
  ' <<< "$response" >/dev/null; then
    fail "Intended ECS deployment FAILED: $key ($definition)"
  fi
  if jq -e --arg def "$definition" '
    any(.services[0].deployments[]?;
      .status == "PRIMARY" and .rolloutState == "COMPLETED" and .taskDefinition != $def)
  ' <<< "$response" >/dev/null; then
    fail "ECS service completed a different revision (possible rollback): $key"
  fi
  if ! jq -e --arg def "$definition" '
    .services[0] as $s
    | $s.taskDefinition == $def
      and ($s.deployments | length) == 1
      and $s.deployments[0].status == "PRIMARY"
      and $s.deployments[0].taskDefinition == $def
      and $s.deployments[0].rolloutState == "COMPLETED"
      and ($s.desiredCount | type) == "number"
      and $s.desiredCount > 0
      and $s.runningCount == $s.desiredCount
      and $s.pendingCount == 0
  ' <<< "$response" >/dev/null; then
    return 1
  fi

  count="$(jq -r '.services[0].desiredCount' <<< "$response")"
  if ! listed="$(aws ecs list-tasks "${AWS_ARGS[@]}" \
    --cluster "$EXPECTED_CLUSTER_ARN" --service-name "$name" \
    --desired-status RUNNING --output json)"; then
    fail "ECS list-tasks failed: $key"
  fi
  if ! jq -e '(.taskArns | type) == "array"' <<< "$listed" >/dev/null; then
    fail "Invalid ECS task listing: $key"
  fi
  task_arns="$(jq -c '.taskArns | unique' <<< "$listed")"
  [[ "$(jq 'length' <<< "$task_arns")" -eq "$count" ]] || return 1
  if ! tasks="$(describe_tasks "$task_arns")"; then
    fail "Unable to describe running ECS tasks: $key"
  fi
  if ! jq -e --arg def "$definition" --arg cluster "$EXPECTED_CLUSTER_ARN" \
    --arg group "service:$name" --arg service "$key" \
    --argjson count "$count" --argjson check "$health_check" '
    length == $count and all(.[];
      .clusterArn == $cluster and .taskDefinitionArn == $def
      and .group == $group and .launchType == "FARGATE"
      and .desiredStatus == "RUNNING" and .lastStatus == "RUNNING"
      and ([.containers[]? | select(
        .name == $service and .lastStatus == "RUNNING"
        and .healthStatus != "UNHEALTHY"
        and (if $check then .healthStatus == "HEALTHY" else true end)
      )] | length) == 1
    )
  ' <<< "$tasks" >/dev/null; then
    return 1
  fi

  if [[ "$ingress" == "true" ]]; then
    port="$(jq -r --arg group "$target_group" --arg service "$key" '
      [.services[0].loadBalancers[]? | select(
        .targetGroupArn == $group and .containerName == $service
      )] | if length == 1 then .[0].containerPort else empty end
    ' <<< "$response")"
    [[ "$port" =~ ^[0-9]+$ ]] || fail "Live ECS target group/port mismatch: $key"
    ips="$(jq -c '[.[] | (
      [.attachments[]? | select(.type == "ElasticNetworkInterface")
        | .details[]? | select(.name == "privateIPv4Address") | .value]
      | if length == 1 then .[0] else null end
    )]' <<< "$tasks")"
    if ! jq -e --argjson count "$count" '
      length == $count and all(.[]; type == "string" and length > 0)
    ' <<< "$ips" >/dev/null; then
      return 1
    fi
    if ! target_response="$(aws elbv2 describe-target-health "${AWS_ARGS[@]}" \
      --target-group-arn "$target_group" --output json)"; then
      fail "ALB target-health lookup failed: $key"
    fi
    if ! jq -e --argjson ips "$ips" --argjson port "$port" '
      (.TargetHealthDescriptions | type) == "array"
      and (.TargetHealthDescriptions as $targets |
        all($ips[]; . as $ip | any($targets[];
          .Target.Id == $ip and .Target.Port == $port
          and .TargetHealth.State == "healthy")))
    ' <<< "$target_response" >/dev/null; then
      return 1
    fi
  fi
  return 0
}

deadline=$((SECONDS + timeout))
mapfile -t service_keys < <(jq -r '.ecs_services.value | keys[]' <<< "$outputs")
for key in "${service_keys[@]}"; do
  arn="$(jq -r --arg k "$key" '.ecs_services.value[$k].arn' <<< "$outputs")"
  name="$(jq -r --arg k "$key" '.ecs_services.value[$k].name' <<< "$outputs")"
  definition="$(jq -r --arg k "$key" '.ecs_task_definition_arns.value[$k]' <<< "$outputs")"
  ingress="$(jq -r --arg k "$key" '.ecs_service_configuration.value[$k].ingress_enabled' <<< "$outputs")"
  health_check="$(jq -r --arg k "$key" '
    .ecs_service_configuration.value[$k].health_check != null
  ' <<< "$outputs")"
  target_group=""
  if [[ "$ingress" == "true" ]]; then
    target_group="$(jq -r --arg k "$key" '
      .application_load_balancer.value.target_groups[$k].arn // empty
    ' <<< "$outputs")"
    [[ "$target_group" == arn:*:elasticloadbalancing:* ]] ||
      fail "Missing Terraform ALB target group for $key"
  fi

  info "Awaiting intended ECS revision: $key ($definition)"
  while true; do
    if service_ready "$key" "$arn" "$name" "$definition" "$ingress" "$health_check" "$target_group"; then
      success "ECS release accepted: $key ($definition)"
      break
    fi
    ((SECONDS < deadline)) || fail "Timed out awaiting intended ECS revision: $key"
    sleep "$poll"
  done
done

success "ECS release acceptance completed: $ENV_NAME"
