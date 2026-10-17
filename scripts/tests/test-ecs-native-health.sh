#!/usr/bin/env bash
set -euo pipefail

# Offline ECS-native health regression tests. All ECS calls are mocked.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../validation/lib/ecs-runtime/common.sh
source "$root/scripts/validation/lib/ecs-runtime/common.sh"
# shellcheck source=../validation/lib/ecs-runtime/health.sh
source "$root/scripts/validation/lib/ecs-runtime/health.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
poll_counter="$tmp/polls"

AWS_ARGS=()
EXPECTED_CLUSTER_ARN="cluster-test"
ECS_SERVICES_JSON='{"test":{"arn":"service-test","name":"test-service"}}'
TASK_DEFINITION_ARNS_JSON='{"test":"task-definition-test"}'
ECS_SERVICE_CONFIGURATION_JSON='{"test":{"health_check":{"command":["CMD","/bin/true"],"interval":30,"timeout":5,"retries":3,"start_period":0}}}'

fail() { echo "[FAIL] $*" >&2; exit 1; }
success() { :; }
info() { :; }
section() { :; }

aws() {
  if [[ "${MOCK_FORBID_AWS:-false}" == "true" ]]; then
    echo "AWS should not have been called" >&2
    return 99
  fi
  [[ "$1" == "ecs" ]] || { echo "Unexpected AWS service: $1" >&2; return 98; }

  case "$2" in
    describe-services)
      jq -nc \
        --arg arn "${MOCK_SERVICE_ARN:-service-test}" \
        --arg name "test-service" \
        --arg cluster "$EXPECTED_CLUSTER_ARN" \
        --argjson desired "${MOCK_DESIRED:-1}" \
        --argjson running "${MOCK_RUNNING:-${MOCK_DESIRED:-1}}" \
        --argjson pending "${MOCK_PENDING:-0}" '
          {failures:[], services:[{
            serviceArn:$arn, serviceName:$name, clusterArn:$cluster,
            status:"ACTIVE", desiredCount:$desired,
            runningCount:$running, pendingCount:$pending
          }]}
        '
      ;;
    list-tasks)
      if [[ "${MOCK_EMPTY_TASKS:-false}" == "true" ]]; then
        echo '{"taskArns":[]}'
      else
        echo '{"taskArns":["task-test"]}'
      fi
      ;;
    describe-tasks)
      local poll index status
      local -a statuses=()
      poll="$(cat "$poll_counter")"
      printf '%s\n' "$((poll + 1))" > "$poll_counter"
      IFS=',' read -r -a statuses <<< "${MOCK_HEALTH_STATES:-HEALTHY}"
      index="$poll"
      if ((index >= ${#statuses[@]})); then
        index=$((${#statuses[@]} - 1))
      fi
      status="${statuses[index]}"

      jq -nc \
        --arg health "$status" \
        --arg name "${MOCK_APP_NAME:-test}" \
        --arg task_status "${MOCK_TASK_STATUS:-RUNNING}" \
        --arg app_status "${MOCK_APP_STATUS:-RUNNING}" \
        --arg definition "${MOCK_TASK_DEFINITION:-task-definition-test}" \
        --arg group "${MOCK_TASK_GROUP:-service:test-service}" \
        --arg cluster "$EXPECTED_CLUSTER_ARN" \
        --argjson duplicate "${MOCK_DUPLICATE_APP:-false}" \
        --argjson omit_health "${MOCK_OMIT_HEALTH:-false}" '
          ({name:$name, lastStatus:$app_status, healthStatus:$health}
            | if $omit_health then del(.healthStatus) else . end
          ) as $app
          | {failures:[], tasks:[{
              taskArn:"task-test", clusterArn:$cluster,
              taskDefinitionArn:$definition, launchType:"FARGATE",
              lastStatus:$task_status, desiredStatus:"RUNNING", group:$group,
              containers: (if $duplicate then [$app, $app] else [$app] end)
            }]}
        '
      ;;
    *)
      echo "Unexpected ECS operation: $2" >&2
      return 97
      ;;
  esac
}

count=0
run_case() {
  printf '0\n' > "$poll_counter"
  ECS_NATIVE_HEALTH_MAX_ATTEMPTS=3
  ECS_NATIVE_HEALTH_POLL_INTERVAL_SECONDS=0
  ecs_runtime_validate_application_health
}
expect_pass() {
  local name="$1"
  if ! (run_case) >"$tmp/out" 2>&1; then
    echo "Unexpected failure: $name" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  count=$((count + 1))
}
expect_fail() {
  local name="$1"
  if (run_case) >"$tmp/out" 2>&1; then
    echo "Unexpected success: $name" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  count=$((count + 1))
}

expect_pass "Healthy application, GuardDuty not required"
MOCK_HEALTH_STATES="UNKNOWN,HEALTHY" expect_pass "Startup UNKNOWN becomes HEALTHY"
MOCK_HEALTH_STATES="UNKNOWN" expect_fail "Persistent UNKNOWN fails after bounded attempts"
MOCK_HEALTH_STATES="UNHEALTHY" expect_fail "Observed UNHEALTHY fails"
MOCK_OMIT_HEALTH=true expect_fail "Absent healthStatus cannot pass"
MOCK_EMPTY_TASKS=true expect_fail "No running tasks with positive desired capacity cannot pass"
MOCK_DESIRED=0 expect_pass "Zero desired capacity is skipped"
MOCK_TASK_DEFINITION="wrong-task-definition" expect_fail "Task definition drift fails"
MOCK_TASK_GROUP="service:wrong-service" expect_fail "Task group drift fails"
MOCK_SERVICE_ARN="wrong-service" expect_fail "Service identity drift fails"
MOCK_DUPLICATE_APP=true expect_fail "Duplicate application container fails"
MOCK_APP_NAME="wrong" expect_fail "Missing application container fails"
MOCK_TASK_STATUS="PENDING" expect_fail "Task never reaches RUNNING"
MOCK_APP_STATUS="STOPPED" expect_fail "Container never reaches RUNNING"
MOCK_RUNNING=0 expect_fail "Non-steady service count is bounded"
MOCK_HEALTH_STATES="INVALID" expect_fail "Unrecognized healthStatus cannot pass"

ECS_SERVICE_CONFIGURATION_JSON='{"test":{}}' MOCK_FORBID_AWS=true \
  expect_pass "Disabled native health performs no API calls"
ECS_SERVICES_JSON='{}' ECS_SERVICE_CONFIGURATION_JSON='{}' MOCK_FORBID_AWS=true \
  expect_pass "Empty ECS runtime performs no API calls"

echo "[PASS] $count offline ECS-native application health scenarios."
