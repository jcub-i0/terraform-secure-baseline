#!/usr/bin/env bash
set -euo pipefail

# Offline release-acceptance tests. No real Terraform or AWS calls.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$root/scripts/deployment/validate-ecs-release.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat > "$tmp/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -chdir=* && "$2" == output && "$3" == -json ]] || exit 98
cat "$MOCK_OUTPUTS"
MOCK
cat > "$tmp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_FORBID_AWS:-0}" != 1 ]] || { echo "Unexpected AWS call" >&2; exit 99; }
case "$1:$2" in
  sts:get-caller-identity) echo 123456789012 ;;
  ecs:describe-services) cat "$MOCK_SERVICE" ;;
  ecs:list-tasks)
    [[ "${MOCK_FORBID_TASKS:-0}" != 1 ]] || exit 99
    echo '{"taskArns":["task-test"]}' ;;
  ecs:describe-tasks)
    [[ "${MOCK_FORBID_TASKS:-0}" != 1 ]] || exit 99
    cat "$MOCK_TASKS" ;;
  elbv2:describe-target-health)
    [[ "${MOCK_FORBID_ALB:-0}" != 1 ]] || exit 99
    cat "$MOCK_TARGETS" ;;
  *) echo "Unexpected AWS operation: $1:$2" >&2; exit 97 ;;
esac
MOCK
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws"

cluster='arn:aws:ecs:us-east-1:123456789012:cluster/test-cluster'
service='arn:aws:ecs:us-east-1:123456789012:service/test-cluster/test-service'
definition='arn:aws:ecs:us-east-1:123456789012:task-definition/test:2'
target_group='arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/test/1234567890123456'

jq -n --arg c "$cluster" --arg s "$service" --arg d "$definition" --arg tg "$target_group" '{
  primary_region:{value:"us-east-1"},
  ecs_cluster:{value:{arn:$c}},
  ecs_services:{value:{test:{arn:$s,name:"test-service"}}},
  ecs_task_definition_arns:{value:{test:$d}},
  ecs_service_configuration:{value:{test:{ingress_enabled:true,health_check:{command:["CMD","true"]}}}},
  lifecycle_protection:{value:{production_retirement_mode:false}},
  application_load_balancer:{value:{target_groups:{test:{arn:$tg}}}}
}' > "$tmp/base-outputs.json"

jq -n --arg c "$cluster" --arg s "$service" --arg d "$definition" --arg tg "$target_group" '{
  failures:[],services:[{
    serviceArn:$s,serviceName:"test-service",clusterArn:$c,status:"ACTIVE",
    taskDefinition:$d,desiredCount:1,runningCount:1,pendingCount:0,
    deployments:[{status:"PRIMARY",rolloutState:"COMPLETED",taskDefinition:$d}],
    loadBalancers:[{targetGroupArn:$tg,containerName:"test",containerPort:8080}]
  }]
}' > "$tmp/base-service.json"

jq -n --arg c "$cluster" --arg d "$definition" '{
  failures:[],tasks:[{
    clusterArn:$c,taskDefinitionArn:$d,group:"service:test-service",
    launchType:"FARGATE",desiredStatus:"RUNNING",lastStatus:"RUNNING",
    containers:[{name:"test",lastStatus:"RUNNING",healthStatus:"HEALTHY"}],
    attachments:[{type:"ElasticNetworkInterface",details:[
      {name:"privateIPv4Address",value:"10.0.1.10"}]}]
  }]
}' > "$tmp/base-tasks.json"

jq -n '{TargetHealthDescriptions:[{Target:{Id:"10.0.1.10",Port:8080},TargetHealth:{State:"healthy"}}]}' \
  > "$tmp/base-targets.json"

export MOCK_OUTPUTS="$tmp/outputs.json"
export MOCK_SERVICE="$tmp/service.json"
export MOCK_TASKS="$tmp/tasks.json"
export MOCK_TARGETS="$tmp/targets.json"

reset() {
  cp "$tmp/base-outputs.json" "$MOCK_OUTPUTS"
  cp "$tmp/base-service.json" "$MOCK_SERVICE"
  cp "$tmp/base-tasks.json" "$MOCK_TASKS"
  cp "$tmp/base-targets.json" "$MOCK_TARGETS"
}

passed=0
check() {
  local label="$1" expected="$2" message="$3" rc=0
  PATH="$tmp/bin:$PATH" AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID=123456789012 \
    ECS_RELEASE_TIMEOUT_SECONDS=1 ECS_RELEASE_POLL_SECONDS=1 \
    bash "$validator" dev > "$tmp/out" 2>&1 || rc=$?

  if [[ "$expected" == pass && "$rc" != 0 ]] ||
     [[ "$expected" == fail && "$rc" == 0 ]] ||
     ! grep -Fq "$message" "$tmp/out"; then
    printf '[FAIL] %s (exit=%s)\n' "$label" "$rc" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  printf '[PASS] %s\n' "$label"
  passed=$((passed + 1))
}

reset
check 'Healthy intended revision with ALB' pass 'ECS release accepted: test'

reset
jq '.ecs_service_configuration.value.test.ingress_enabled=false |
    .application_load_balancer.value=null' "$MOCK_OUTPUTS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_OUTPUTS"
MOCK_FORBID_ALB=1 check 'Service without ingress skips ALB' pass 'ECS release accepted: test'

reset
jq '.services[0].desiredCount=0 | .services[0].runningCount=0' \
  "$MOCK_SERVICE" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_SERVICE"
MOCK_FORBID_TASKS=1 MOCK_FORBID_ALB=1 \
  check 'Zero-capacity revision verified without health checks' pass 'runtime health skipped at zero desired capacity'

reset
jq '.services[0].taskDefinition="arn:aws:ecs:us-east-1:123456789012:task-definition/test:1" |
    .services[0].deployments[0].taskDefinition="arn:aws:ecs:us-east-1:123456789012:task-definition/test:1"' \
  "$MOCK_SERVICE" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_SERVICE"
check 'Rollback to older completed revision' fail 'possible rollback'

reset
jq '.services[0].deployments[0].rolloutState="FAILED"' \
  "$MOCK_SERVICE" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_SERVICE"
check 'Intended deployment reports FAILED' fail 'Intended ECS deployment FAILED'

reset
jq '.tasks[0].taskDefinitionArn="arn:aws:ecs:us-east-1:123456789012:task-definition/test:1"' \
  "$MOCK_TASKS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_TASKS"
check 'Running task uses wrong revision' fail 'Timed out awaiting intended ECS revision'

reset
jq '.tasks[0].containers[0].healthStatus="UNHEALTHY"' \
  "$MOCK_TASKS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_TASKS"
check 'Unhealthy application task' fail 'Timed out awaiting intended ECS revision'

reset
jq '.TargetHealthDescriptions[0].TargetHealth.State="unhealthy"' \
  "$MOCK_TARGETS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_TARGETS"
check 'Unhealthy ALB target' fail 'Timed out awaiting intended ECS revision'

reset
jq '.ecs_services.value={} | .ecs_task_definition_arns.value={} |
    .ecs_service_configuration.value={}' "$MOCK_OUTPUTS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_OUTPUTS"
MOCK_FORBID_AWS=1 check 'Null-image or empty runtime' pass 'skipped'

reset
jq '.lifecycle_protection.value.production_retirement_mode=true' \
  "$MOCK_OUTPUTS" > "$tmp/modified.json"
mv "$tmp/modified.json" "$MOCK_OUTPUTS"
MOCK_FORBID_AWS=1 check 'Production retirement' pass 'skipped'

printf '[PASS] %s offline ECS release-acceptance scenarios\n' "$passed"
