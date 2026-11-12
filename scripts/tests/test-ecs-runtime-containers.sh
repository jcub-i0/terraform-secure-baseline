#!/usr/bin/env bash
set -euo pipefail

# Offline production-function regressions. Every AWS call is intercepted here.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../validation/lib/ecs-runtime/common.sh
source "$root/scripts/validation/lib/ecs-runtime/common.sh"
# shellcheck source=../validation/lib/ecs-runtime/services.sh
source "$root/scripts/validation/lib/ecs-runtime/services.sh"
# shellcheck source=../validation/lib/ecs-runtime/guardduty.sh
source "$root/scripts/validation/lib/ecs-runtime/guardduty.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "[FAIL] $*" >&2; exit 1; }
success() { :; }
info() { :; }
section() { :; }

AWS_ARGS=()
AWS_REGION=us-east-1
LOGS_CMK_ARN=logs-key
EFFECTIVE_CLOUDWATCH_RETENTION_DAYS=30
EXPECTED_CLUSTER_ARN=cluster-test
EXPECTED_GUARDDUTY_RUNTIME_ENABLED=true
ECS_SERVICES_JSON='{"api":{"arn":"service-test","name":"api-service"}}'
TASK_DEFINITION_ARNS_JSON='{"api":"task-definition-test"}'
declare -A SERVICE_CONTAINER_PORTS=()
ECR_REPOSITORIES_JSON='{"api":{"repository_url":"123456789012.dkr.ecr.us-east-1.amazonaws.com/api"},"scanner":{"repository_url":"123456789012.dkr.ecr.us-east-1.amazonaws.com/scanner"}}'

# Build a complete AWS-shaped fixture independently of the production normalizer.
jq -n '
  {logDriver:"awslogs",options:{"awslogs-group":"/ecs/api","awslogs-region":"us-east-1",
    "awslogs-stream-prefix":"ecs",mode:"non-blocking"}} as $logs
  | {command:["CMD","/bin/true"],interval:30,timeout:5,retries:3,startPeriod:0} as $health
  | {name:"api",image:("123456789012.dkr.ecr.us-east-1.amazonaws.com/api@sha256:" + ("a" * 64)),
      essential:true,portMappings:[{containerPort:8080,hostPort:8080,protocol:"tcp"}],
      environment:[],secrets:[],logConfiguration:$logs} as $primary
  | {taskDefinition:{taskDefinitionArn:"task-definition-test",status:"ACTIVE",
      requiresCompatibilities:["FARGATE"],networkMode:"awsvpc",
      runtimePlatform:{operatingSystemFamily:"LINUX",cpuArchitecture:"X86_64"},
      executionRoleArn:"execution-role",taskRoleArn:"task-role",cpu:"1024",memory:"2048",
      volumes:[],containerDefinitions:[$primary]}} as $single
  | $single
' > "$tmp/single.json"

jq '
  .taskDefinition as $task
  | $task.containerDefinitions[0] as $primary
  | .taskDefinition.volumes = [{name:"shared"},{name:"cache"}]
  | .taskDefinition.ephemeralStorage = {sizeInGiB:40}
  | .taskDefinition.containerDefinitions = [
      ($primary + {healthCheck:{command:["CMD","/bin/true"],interval:30,timeout:5,retries:3,startPeriod:0},
        startTimeout:90,stopTimeout:40,
        dependsOn:[{containerName:"scanner",condition:"HEALTHY"},{containerName:"init",condition:"SUCCESS"}],
        mountPoints:[{sourceVolume:"shared",containerPath:"/app/data",readOnly:false}]}),
      {name:"scanner",image:("123456789012.dkr.ecr.us-east-1.amazonaws.com/scanner@sha256:" + ("b" * 64)),
        essential:true,cpu:128,memory:256,memoryReservation:128,readonlyRootFilesystem:true,
        command:["--foreground","--scan"],entryPoint:["/bin/scanner"],startTimeout:30,stopTimeout:15,
        healthCheck:{command:["CMD-SHELL","exit 0"],interval:30,timeout:5,retries:3,startPeriod:0},
        dependsOn:[{containerName:"init",condition:"SUCCESS"}],
        mountPoints:[{sourceVolume:"shared",containerPath:"/data",readOnly:true},{sourceVolume:"cache",containerPath:"/cache",readOnly:false}],
        portMappings:[{containerPort:9000,hostPort:9000,protocol:"tcp"},{containerPort:9001,hostPort:9001,protocol:"udp"}],
        environment:[{name:"MODE",value:"synthetic\nλ<&\n"}],
        secrets:[{name:"TOKEN",valueFrom:"arn:aws:secretsmanager:us-east-1:123456789012:secret:scanner-AbCdEf:token::"}],
        logConfiguration:$primary.logConfiguration},
      {name:"init",image:$primary.image,essential:false,logConfiguration:$primary.logConfiguration,
        command:["/bin/true"],environment:[],secrets:[]}
    ]
' "$tmp/single.json" > "$tmp/multi.json"

# Expected metadata mirrors the additive Terraform output schema. Environment
# digests use a known literal, not the production hashing function under test.
environment_digest="$(printf 'synthetic\nλ<&\n' | sha256sum)"

for fixture in single multi; do
  jq --arg digest "${environment_digest%% *}" '
    .taskDefinition as $task | {api:{
      task_cpu:$task.cpu,task_memory:$task.memory,cpu_architecture:$task.runtimePlatform.cpuArchitecture,
      task_volumes:$task.volumes,ephemeral_storage_gib:$task.ephemeralStorage.sizeInGiB,
      health_check:($task.containerDefinitions[0].healthCheck | if . == null then null else
        {command,interval,timeout,retries,start_period:.startPeriod} end),
      containers:($task.containerDefinitions | map(. + {
        environment_hashes:[.environment[] | {name,value_sha256:$digest}]
      } | del(.environment)) | map({key:.name,value:.}) | from_entries)
    }}
  ' "$tmp/$fixture.json" > "$tmp/$fixture-expected.json"
done

aws() {
  printf '%s %s\n' "$1" "$2" >> "$tmp/aws-calls"
  case "$1 $2" in
    'ecs describe-task-definition') cat "$tmp/live.json" ;;
    'logs describe-log-groups') cat "$tmp/logs.json" ;;
    'ecs describe-services') echo '{"services":[{"runningCount":1}]}' ;;
    'ecs list-tasks') echo '{"taskArns":["task-test"]}' ;;
    'ecs describe-tasks') cat "$tmp/tasks.json" ;;
    *) echo "Unexpected mocked AWS call: $1 $2" >&2; return 99 ;;
  esac
}

passed=0
positive=0
negative=0

prepare() {
  cp "$tmp/${1:-multi}.json" "$tmp/live.json"
  ECS_SERVICE_CONFIGURATION_JSON="$(cat "$tmp/${1:-multi}-expected.json")"
  echo '{"logGroups":[{"logGroupName":"/ecs/api","arn":"log-arn:*","retentionInDays":30,"kmsKeyId":"logs-key"}]}' > "$tmp/logs.json"
  : > "$tmp/aws-calls"
}

run_validator() {
  validate_task_definition api task-definition-test execution-role task-role /ecs/api log-arn
  [[ "${SERVICE_CONTAINER_PORTS[api]}" == 8080 ]] || fail "Primary port not selected by name"
}

expect_pass() {
  local name="$1"
  shift
  if ! ("$@") > "$tmp/out" 2>&1; then
    echo "Unexpected failure: $name" >&2; cat "$tmp/out" >&2; exit 1
  fi
  passed=$((passed + 1)); positive=$((positive + 1))
}

expect_fail() {
  local name="$1" reason="$2"
  shift 2
  if ("$@") > "$tmp/out" 2>&1; then
    echo "Unexpected success: $name" >&2; exit 1
  fi
  # A jq syntax error, mock failure, or unrelated failure is not a passing test.
  if ! grep -F "[FAIL] $reason" "$tmp/out" >/dev/null; then
    echo "Wrong rejection reason: $name" >&2; cat "$tmp/out" >&2; exit 1
  fi
  passed=$((passed + 1)); negative=$((negative + 1))
}

mutate() {
  jq "$1" "$tmp/live.json" > "$tmp/mutated.json"
  mv "$tmp/mutated.json" "$tmp/live.json"
}

reject_mutation() {
  prepare
  mutate "$2"
  expect_fail "$1" "${3:-Container configuration does not match Terraform}" run_validator
}

prepare single
expect_pass 'Legacy single container' run_validator
prepare
expect_pass 'Full M1 multi-container task' run_validator
prepare
mutate '.taskDefinition.containerDefinitions |= reverse'
expect_pass 'Primary is last' run_validator
prepare
mutate '.taskDefinition.containerDefinitions |= map(.cpu = (.cpu // 0) | .mountPoints = (.mountPoints // []) | .portMappings = (.portMappings // []) | .volumesFrom = [] | .systemControls = [] | .logConfiguration.secretOptions = []) | .taskDefinition.volumes |= map(.host = {}) | del(.taskDefinition.containerDefinitions[0,1].healthCheck.startPeriod)'
expect_pass 'Documented AWS empty/default representations' run_validator
prepare
mutate '.taskDefinition.volumes |= map(.configuredAtLaunch = false)'
expect_pass 'Provider sends volumes not configured at launch' run_validator
prepare
mutate '.taskDefinition.volumes |= reverse | .taskDefinition.containerDefinitions[0].dependsOn |= reverse | .taskDefinition.containerDefinitions[1].mountPoints |= reverse | .taskDefinition.containerDefinitions[1].portMappings |= reverse'
expect_pass 'Unordered inventories may reorder' run_validator

for mutation in \
  'del(.taskDefinition.containerDefinitions[1])' \
  'del(.taskDefinition.containerDefinitions[0])' \
  '.taskDefinition.containerDefinitions += [.taskDefinition.containerDefinitions[1]]' \
  '.taskDefinition.containerDefinitions[1].name = "unexpected"' \
  '.taskDefinition.containerDefinitions += [{name:"aws-gd-agent"}]'; do
  reject_mutation 'Missing, unexpected, duplicate or canonical GuardDuty container' "$mutation" 'Task definition container inventory does not match Terraform'
done

for index in 0 1; do
  other_repository=scanner
  if [[ "$index" == 1 ]]; then other_repository=api; fi
  reject_mutation 'Mutable image tag' ".taskDefinition.containerDefinitions[$index].image = \"repo:latest\"" 'Task definition image is not digest pinned'
  reject_mutation 'Wrong digest' ".taskDefinition.containerDefinitions[$index].image |= sub(\"@sha256:.*\";\"@sha256:\" + (\"c\" * 64))"
  reject_mutation 'Unmanaged ECR' ".taskDefinition.containerDefinitions[$index].image |= sub(\"amazonaws.com/\";\"amazonaws.com/unmanaged-\")" 'Task image repository URL does not match exactly one'
  reject_mutation 'Wrong managed repository' ".taskDefinition.containerDefinitions[$index].image |= sub(\"amazonaws.com/[^@]+\";\"amazonaws.com/$other_repository\")"
  reject_mutation 'Essential drift' ".taskDefinition.containerDefinitions[$index].essential = false"
  reject_mutation 'Missing health check' "del(.taskDefinition.containerDefinitions[$index].healthCheck)"
  for field in interval timeout retries startPeriod; do
    reject_mutation "Health $field drift" ".taskDefinition.containerDefinitions[$index].healthCheck.$field = 99"
  done
  reject_mutation 'Health command drift' ".taskDefinition.containerDefinitions[$index].healthCheck.command = [\"CMD\",\"false\"]"
  reject_mutation 'Dependency condition drift' ".taskDefinition.containerDefinitions[$index].dependsOn[0].condition = \"START\""
  reject_mutation 'Dependency target drift' ".taskDefinition.containerDefinitions[$index].dependsOn[0].containerName = \"wrong\""
  reject_mutation 'Missing dependency' "del(.taskDefinition.containerDefinitions[$index].dependsOn)"
  for field in startTimeout stopTimeout; do
    reject_mutation "Timeout $field drift" ".taskDefinition.containerDefinitions[$index].$field = 120"
    reject_mutation "Missing $field" "del(.taskDefinition.containerDefinitions[$index].$field)"
  done
  reject_mutation 'Mount write permission drift' ".taskDefinition.containerDefinitions[$index].mountPoints[0].readOnly |= not"
  reject_mutation 'Port drift' ".taskDefinition.containerDefinitions[$index].portMappings[0].containerPort = 8081"
  reject_mutation 'Wrong log driver' ".taskDefinition.containerDefinitions[$index].logConfiguration.logDriver = \"json-file\""
  for field in awslogs-group awslogs-region awslogs-stream-prefix mode; do
    reject_mutation "Logging $field drift" ".taskDefinition.containerDefinitions[$index].logConfiguration.options[\"$field\"] = \"wrong\""
  done
  reject_mutation 'Forbidden log group creation' ".taskDefinition.containerDefinitions[$index].logConfiguration.options[\"awslogs-create-group\"] = \"true\""
done

for mutation in \
  '.taskDefinition.containerDefinitions[2].essential = true' \
  '.taskDefinition.containerDefinitions[2].healthCheck = {command:["CMD","true"]}' \
  '.taskDefinition.containerDefinitions[1].cpu = 64' \
  '.taskDefinition.containerDefinitions[1].memory = 512' \
  '.taskDefinition.containerDefinitions[1].memoryReservation = 64' \
  'del(.taskDefinition.containerDefinitions[1].cpu)' \
  'del(.taskDefinition.containerDefinitions[1].memory)' \
  '.taskDefinition.containerDefinitions[1].readonlyRootFilesystem = false' \
  '.taskDefinition.containerDefinitions[1].command |= reverse' \
  '.taskDefinition.containerDefinitions[1].entryPoint = ["/bin/sh"]' \
  '.taskDefinition.containerDefinitions[1].secrets[0].valueFrom += "changed"' \
  '.taskDefinition.containerDefinitions[1].environment[0].value = "changed"' \
  '.taskDefinition.containerDefinitions[1].environment += [.taskDefinition.containerDefinitions[1].environment[0]]' \
  '.taskDefinition.containerDefinitions[1].environment[0].value = 7' \
  '.taskDefinition.containerDefinitions[1].mountPoints[0].sourceVolume = "cache"' \
  '.taskDefinition.containerDefinitions[1].mountPoints[0].containerPath = "/wrong"' \
  '.taskDefinition.containerDefinitions[1].portMappings[0].hostPort = 9999' \
  '.taskDefinition.containerDefinitions[1].portMappings[0].protocol = "udp"' \
  '.taskDefinition.containerDefinitions[1].dependsOn += [.taskDefinition.containerDefinitions[1].dependsOn[0]]' \
  '.taskDefinition.containerDefinitions[1].privileged = true' \
  '.taskDefinition.containerDefinitions[1].volumesFrom = [{sourceContainer:"api"}]' \
  '.taskDefinition.containerDefinitions[1].systemControls = [{namespace:"net.ipv4.ip_forward",value:"1"}]'; do

  if [[ "$mutation" == *'.value = 7' ]]; then
    reject_mutation 'Invalid environment representation' "$mutation" 'Invalid container environment representation'
  else
    reject_mutation 'Sidecar runtime attribute drift' "$mutation"
  fi
done

for mutation in \
  'del(.taskDefinition.volumes[0])' \
  '.taskDefinition.volumes += [{name:"extra"}]' \
  '.taskDefinition.volumes += [.taskDefinition.volumes[0]]' \
  '.taskDefinition.volumes[0].host = {sourcePath:"/host"}' \
  '.taskDefinition.volumes[0].configuredAtLaunch = true' \
  '.taskDefinition.volumes[0].efsVolumeConfiguration = {fileSystemId:"fs-test"}' \
  '.taskDefinition.ephemeralStorage.sizeInGiB = 50' \
  'del(.taskDefinition.ephemeralStorage)' \
  '.taskDefinition.cpu = "2048"' \
  '.taskDefinition.memory = "4096"' \
  '.taskDefinition.runtimePlatform.cpuArchitecture = "ARM64"'; do
  reject_mutation 'Task storage/resource drift' "$mutation" 'Task definition resources, architecture, volumes, or ephemeral storage do not match Terraform'
done

prepare single
mutate '.taskDefinition.ephemeralStorage = {sizeInGiB:40}'
expect_fail 'Unexpected expanded ephemeral storage' 'Task definition resources, architecture, volumes, or ephemeral storage do not match Terraform' run_validator

for field in executionRoleArn taskRoleArn networkMode status; do
  reject_mutation "Task identity $field drift" ".taskDefinition.$field = \"wrong\"" 'Task definition platform or IAM role contract is invalid'
done

prepare
ECS_SERVICE_CONFIGURATION_JSON='{"api":{}}'
expect_fail 'Old outputs fail closed' 'Missing or invalid Terraform container inventory' run_validator
prepare
ECR_REPOSITORIES_JSON="$(jq '.duplicate = .scanner' <<< "$ECR_REPOSITORIES_JSON")"
expect_fail 'Duplicate managed repository URL' 'Task image repository URL does not match exactly one' run_validator
ECR_REPOSITORIES_JSON="$(jq 'del(.duplicate)' <<< "$ECR_REPOSITORIES_JSON")"

for field in kmsKeyId retentionInDays arn; do
  prepare
  jq --arg field "$field" '.logGroups[0][$field] = (if $field == "retentionInDays" then 1 else "wrong" end)' "$tmp/logs.json" > "$tmp/modified.json"
  mv "$tmp/modified.json" "$tmp/logs.json"
  expect_fail "CloudWatch $field drift" 'CloudWatch log-group' run_validator
done

# Exercise the protected running-task distinction through its production entry.
prepare_guardduty() {
  prepare "${1:-multi}"
  jq '{failures:[],tasks:[{taskArn:"task-test",clusterArn:"cluster-test",taskDefinitionArn:"task-definition-test",
    launchType:"FARGATE",lastStatus:"RUNNING",desiredStatus:"RUNNING",group:"service:api-service",
    containers:([.taskDefinition.containerDefinitions[] | {name,lastStatus:(if .name == "init" then "STOPPED" else "RUNNING" end),healthStatus:"HEALTHY"}] + [{name:"aws-gd-agent",lastStatus:"RUNNING"}])}]}' "$tmp/live.json" > "$tmp/tasks.json"
  GUARDDUTY_RUNNING_TASKS_CHECKED=0
  GUARDDUTY_AGENT_CONTAINERS_RUNNING=0
  GUARDDUTY_APPLICATION_CONTAINERS_VALID=0
}

prepare_guardduty single
expect_pass 'Single primary plus injected agent' validate_guardduty_service_tasks api
prepare_guardduty
expect_pass 'M1 sidecars plus injected agent, including completed init' validate_guardduty_service_tasks api
prepare_guardduty

jq '.tasks[0].containers[-1].name = "aws-guardduty-agent-generated"' "$tmp/tasks.json" > "$tmp/modified.json"
mv "$tmp/modified.json" "$tmp/tasks.json"

expect_pass 'Generated GuardDuty agent name' validate_guardduty_service_tasks api

for mutation in \
  'del(.tasks[0].containers[1])' \
  '.tasks[0].containers += [.tasks[0].containers[1]]' \
  '.tasks[0].containers += [{name:"unexpected",lastStatus:"RUNNING"}]'; do
  prepare_guardduty
  jq "$mutation" "$tmp/tasks.json" > "$tmp/modified.json"
  mv "$tmp/modified.json" "$tmp/tasks.json"
  expect_fail 'Protected runtime inventory drift' 'Protected Fargate task container inventory differs' validate_guardduty_service_tasks api
done

for mutation in \
  'del(.tasks[0].containers[-1])' \
  '.tasks[0].containers += [.tasks[0].containers[-1]]'; do
  prepare_guardduty
  jq "$mutation" "$tmp/tasks.json" > "$tmp/modified.json"
  mv "$tmp/modified.json" "$tmp/tasks.json"
  expect_fail 'Missing or duplicate GuardDuty agent' 'Protected Fargate task does not contain exactly one GuardDuty' validate_guardduty_service_tasks api
done

prepare_guardduty
jq '.tasks[0].containers[-1].lastStatus = "STOPPED"' "$tmp/tasks.json" > "$tmp/modified.json"
mv "$tmp/modified.json" "$tmp/tasks.json"

expect_fail 'Stopped GuardDuty agent' 'GuardDuty guardduty agent sidecar is not RUNNING' validate_guardduty_service_tasks api

echo "[PASS] $passed offline ECS runtime container scenarios ($positive positive, $negative rejection cases; 0 failed)."
