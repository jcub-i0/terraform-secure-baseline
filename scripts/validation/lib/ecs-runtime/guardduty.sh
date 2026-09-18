#!/usr/bin/env bash

# Internal GuardDuty ECS/Fargate runtime helpers; sourced by validate-ecs-runtime.sh.
#
# Terraform owns the Runtime Monitoring policy, cluster enrollment intent, IAM,
# networking, and canonical application task definition. GuardDuty service-manages
# the injected aws-gd-agent sidecar and runtime coverage state.

readonly GUARDDUTY_FARGATE_AGENT_CONTAINER_NAME="aws-gd-agent"

ecs_runtime_describe_tasks_json() {
  local task_arns_json="$1"
  local all_tasks_json='[]'
  local response_json
  local response_tasks_json
  local response_failures_json
  local i
  local -a task_arns=()
  local -a task_batch=()

  mapfile -t task_arns < <(
    echo "$task_arns_json" |
      jq -r '.[]'
  )

  if [[ "${#task_arns[@]}" -eq 0 ]]; then
    echo "$all_tasks_json"
    return 0
  fi

  # ECS DescribeTasks accepts up to 100 task identifiers per request.
  for ((i = 0; i < ${#task_arns[@]}; i += 100)); do
    task_batch=("${task_arns[@]:i:100}")

    response_json="$(
      aws ecs describe-tasks \
        "${AWS_ARGS[@]}" \
        --cluster "$EXPECTED_CLUSTER_ARN" \
        --tasks "${task_batch[@]}" \
        --output json
    )"

    response_failures_json="$(
      echo "$response_json" |
        jq -c '.failures // []'
    )"

    if [[ "$(echo "$response_failures_json" | jq 'length')" -ne 0 ]]; then
      echo "$response_failures_json" | jq .
      fail "ECS describe-tasks returned one or more failures while validating GuardDuty runtime instrumentation."
    fi

    response_tasks_json="$(
      echo "$response_json" |
        jq -c '.tasks // []'
    )"

    all_tasks_json="$(
      jq -c -n \
        --argjson existing "$all_tasks_json" \
        --argjson batch "$response_tasks_json" \
        '$existing + $batch'
    )"
  done

  echo "$all_tasks_json"
}

validate_guardduty_service_tasks() {
  local service_name="$1"
  local expected_service_json
  local expected_service_arn
  local expected_service_name
  local expected_task_definition_arn
  local service_response_json
  local live_running_count
  local running_task_arns_json
  local running_task_count
  local tasks_json
  local task_json
  local task_arn
  local app_container_json
  local guardduty_container_json
  local app_health_status
  local unexpected_container_names_json

  expected_service_json="$(
    echo "$ECS_SERVICES_JSON" |
      jq -c --arg service "$service_name" '.[$service]'
  )"

  expected_service_arn="$(
    echo "$expected_service_json" |
      jq -r '.arn'
  )"

  expected_service_name="$(
    echo "$expected_service_json" |
      jq -r '.name'
  )"

  expected_task_definition_arn="$(
    echo "$TASK_DEFINITION_ARNS_JSON" |
      jq -r --arg service "$service_name" '.[$service]'
  )"

  service_response_json="$(
    aws ecs describe-services \
      "${AWS_ARGS[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" \
      --services "$expected_service_arn" \
      --output json
  )"

  if [[ "$(echo "$service_response_json" | jq '.services | length')" -ne 1 ]]; then
    echo "$service_response_json" | jq .
    fail "Expected ECS service was not returned while validating GuardDuty runtime tasks: ${service_name}"
  fi

  live_running_count="$(
    echo "$service_response_json" |
      jq -r '.services[0].runningCount'
  )"

  running_task_arns_json="$(
    aws ecs list-tasks \
      "${AWS_ARGS[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" \
      --service-name "$expected_service_name" \
      --desired-status RUNNING \
      --output json |
      jq -c '[.taskArns[]?] | sort | unique'
  )"

  running_task_count="$(
    echo "$running_task_arns_json" |
      jq 'length'
  )"

  if [[ "$running_task_count" -ne "$live_running_count" ]]; then
    jq -n \
      --arg service "$service_name" \
      --argjson expected "$live_running_count" \
      --argjson actual "$running_task_count" \
      --argjson task_arns "$running_task_arns_json" \
      '{
        service: $service,
        ecs_service_running_count: $expected,
        listed_running_task_count: $actual,
        running_task_arns: $task_arns
      }'
    fail "Running ECS task inventory does not match the service runningCount: ${service_name}"
  fi

  if [[ "$running_task_count" -eq 0 ]]; then
    info "No running tasks exist for service ${service_name}; GuardDuty sidecar validation is not applicable until the service runs a task."
    return 0
  fi

  tasks_json="$(ecs_runtime_describe_tasks_json "$running_task_arns_json")"

  if [[ "$(echo "$tasks_json" | jq 'length')" -ne "$running_task_count" ]]; then
    echo "$tasks_json" | jq .
    fail "ECS describe-tasks result count does not match the running task inventory: ${service_name}"
  fi

  while IFS= read -r task_json; do
    [[ -z "$task_json" ]] && continue

    task_arn="$(
      echo "$task_json" |
        jq -r '.taskArn // empty'
    )"

    if ! echo "$task_json" |
      jq -e \
        --arg cluster_arn "$EXPECTED_CLUSTER_ARN" \
        --arg task_definition_arn "$expected_task_definition_arn" \
        --arg service_name "$expected_service_name" '
          .clusterArn == $cluster_arn
          and .taskDefinitionArn == $task_definition_arn
          and .launchType == "FARGATE"
          and .lastStatus == "RUNNING"
          and .desiredStatus == "RUNNING"
          and .group == ("service:" + $service_name)
        ' >/dev/null; then
      echo "$task_json" |
        jq '{
          taskArn,
          clusterArn,
          taskDefinitionArn,
          launchType,
          lastStatus,
          desiredStatus,
          group
        }'
      fail "Running task does not match the expected ECS/Fargate service contract: ${service_name}"
    fi

    app_container_json="$(
      echo "$task_json" |
        jq -c \
          --arg service "$service_name" '
            [
              .containers[]?
              | select(.name == $service)
            ]
          '
    )"

    if [[ "$(echo "$app_container_json" | jq 'length')" -ne 1 ]]; then
      echo "$task_json" | jq '.containers'
      fail "Running task does not contain exactly one application container named ${service_name}: ${task_arn}"
    fi

    app_container_json="$(echo "$app_container_json" | jq -c '.[0]')"
    app_health_status="$(echo "$app_container_json" | jq -r '.healthStatus // "UNKNOWN"')"

    if [[ "$(echo "$app_container_json" | jq -r '.lastStatus // empty')" != "RUNNING" ]]; then
      echo "$app_container_json" | jq .
      fail "Application container is not RUNNING on protected task: ${task_arn}"
    fi

    # UNKNOWN is valid when the task definition has no ECS-native container
    # health check. UNHEALTHY is never accepted.
    if [[ "$app_health_status" == "UNHEALTHY" ]]; then
      echo "$app_container_json" | jq .
      fail "Application container is UNHEALTHY on protected task: ${task_arn}"
    fi

    guardduty_container_json="$(
      echo "$task_json" |
        jq -c \
          --arg agent "$GUARDDUTY_FARGATE_AGENT_CONTAINER_NAME" '
            [
              .containers[]?
              | select(.name == $agent)
            ]
          '
    )"

    if [[ "$(echo "$guardduty_container_json" | jq 'length')" -ne 1 ]]; then
      echo "$task_json" | jq '.containers'
      fail "Protected Fargate task does not contain exactly one GuardDuty aws-gd-agent sidecar: ${task_arn}"
    fi

    guardduty_container_json="$(echo "$guardduty_container_json" | jq -c '.[0]')"

    if [[ "$(echo "$guardduty_container_json" | jq -r '.lastStatus // empty')" != "RUNNING" ]]; then
      echo "$guardduty_container_json" | jq .
      fail "GuardDuty aws-gd-agent sidecar is not RUNNING: ${task_arn}"
    fi

    # The baseline task definition is application-only. On a protected running
    # task, the only additional container expected is GuardDuty's injected agent.
    unexpected_container_names_json="$(
      echo "$task_json" |
        jq -c \
          --arg service "$service_name" \
          --arg agent "$GUARDDUTY_FARGATE_AGENT_CONTAINER_NAME" '
            [
              .containers[]?.name
              | select(. != $service and . != $agent)
            ]
            | sort
            | unique
          '
    )"

    if [[ "$(echo "$unexpected_container_names_json" | jq 'length')" -ne 0 ]]; then
      echo "$unexpected_container_names_json" | jq .
      fail "Protected Fargate task contains unexpected live containers outside the application and GuardDuty agent contract: ${task_arn}"
    fi

    GUARDDUTY_RUNNING_TASKS_CHECKED=$((GUARDDUTY_RUNNING_TASKS_CHECKED + 1))
    GUARDDUTY_AGENT_CONTAINERS_RUNNING=$((GUARDDUTY_AGENT_CONTAINERS_RUNNING + 1))
    GUARDDUTY_APPLICATION_CONTAINERS_VALID=$((GUARDDUTY_APPLICATION_CONTAINERS_VALID + 1))

    success "GuardDuty aws-gd-agent is injected and RUNNING while the application container remains valid: ${task_arn}"
  done < <(echo "$tasks_json" | jq -c '.[]')
}

ecs_runtime_validate_guardduty_tasks() {
  local service_name

  section "Validating GuardDuty Fargate task instrumentation"

  GUARDDUTY_RUNNING_TASKS_CHECKED=0
  GUARDDUTY_AGENT_CONTAINERS_RUNNING=0
  GUARDDUTY_APPLICATION_CONTAINERS_VALID=0

  if [[ "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" != "true" ]]; then
    info "GuardDuty Fargate Runtime Monitoring is disabled for deployment_profile=${DEPLOYMENT_PROFILE}; injected sidecars are not required."
    return 0
  fi

  if [[ "$ECS_SERVICE_COUNT" -eq 0 ]]; then
    info "No deployable ECS services are configured; GuardDuty sidecar validation is not applicable."
    return 0
  fi

  while IFS= read -r service_name; do
    [[ -z "$service_name" ]] && continue
    validate_guardduty_service_tasks "$service_name"
  done < <(echo "$ECS_SERVICES_JSON" | jq -r 'keys[]')

  if [[ "$GUARDDUTY_RUNNING_TASKS_CHECKED" -eq 0 ]]; then
    info "No running protected ECS tasks were available for GuardDuty sidecar validation."
    return 0
  fi

  if [[ "$GUARDDUTY_AGENT_CONTAINERS_RUNNING" -ne "$GUARDDUTY_RUNNING_TASKS_CHECKED" ]]; then
    fail "GuardDuty running-agent count does not match the number of protected running tasks."
  fi

  if [[ "$GUARDDUTY_APPLICATION_CONTAINERS_VALID" -ne "$GUARDDUTY_RUNNING_TASKS_CHECKED" ]]; then
    fail "Valid application-container count does not match the number of protected running tasks."
  fi

  success "Every running protected ECS/Fargate task has one RUNNING aws-gd-agent sidecar and a valid application container"
}

ecs_runtime_resolve_guardduty_detector() {
  local detectors_json

  detectors_json="$(
    aws guardduty list-detectors \
      "${AWS_ARGS[@]}" \
      --output json
  )"

  if [[ "$(echo "$detectors_json" | jq '.DetectorIds | length')" -ne 1 ]]; then
    echo "$detectors_json" | jq .
    fail "Expected exactly one GuardDuty detector in the workload account and Region for runtime coverage validation."
  fi

  GUARDDUTY_DETECTOR_ID="$(
    echo "$detectors_json" |
      jq -r '.DetectorIds[0]'
  )"

  if [[ -z "$GUARDDUTY_DETECTOR_ID" || "$GUARDDUTY_DETECTOR_ID" == "null" ]]; then
    fail "Unable to resolve the workload GuardDuty detector ID."
  fi

  success "Resolved workload GuardDuty detector for ECS Runtime Monitoring coverage"
}

ecs_runtime_get_guardduty_cluster_coverage() {
  local filter_criteria_json

  filter_criteria_json="$(
    jq -c -n \
      --arg account_id "$ACCOUNT_ID" \
      --arg cluster_name "$EXPECTED_CLUSTER_NAME" '
        {
          FilterCriterion: [
            {
              CriterionKey: "ACCOUNT_ID",
              FilterCondition: {
                Equals: [$account_id]
              }
            },
            {
              CriterionKey: "RESOURCE_TYPE",
              FilterCondition: {
                Equals: ["ECS"]
              }
            },
            {
              CriterionKey: "ECS_CLUSTER_NAME",
              FilterCondition: {
                Equals: [$cluster_name]
              }
            }
          ]
        }
      '
  )"

  aws guardduty list-coverage \
    "${AWS_ARGS[@]}" \
    --detector-id "$GUARDDUTY_DETECTOR_ID" \
    --filter-criteria "$filter_criteria_json" \
    --output json
}

ecs_runtime_validate_guardduty_coverage() {
  local coverage_json
  local coverage_resources_json
  local coverage_count
  local coverage_resource_json
  local fargate_issues_json
  local top_level_issue

  section "Validating GuardDuty ECS/Fargate runtime coverage"

  GUARDDUTY_COVERAGE_STATUS="<not evaluated>"
  GUARDDUTY_MANAGEMENT_TYPE="<not evaluated>"
  GUARDDUTY_COVERAGE_ISSUE_COUNT=0
  GUARDDUTY_COVERAGE_UPDATED_AT="<not reported>"

  if [[ "$ECS_SERVICE_COUNT" -eq 0 ]]; then
    info "No deployable ECS services are configured; GuardDuty live coverage is not required."
    return 0
  fi

  if [[ "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" == "true" ]] &&
    [[ "$GUARDDUTY_RUNNING_TASKS_CHECKED" -eq 0 ]]; then
    info "No running protected ECS tasks exist; GuardDuty HEALTHY coverage is not required until a protected task is running."
    return 0
  fi

  ecs_runtime_resolve_guardduty_detector

  if ! coverage_json="$(ecs_runtime_get_guardduty_cluster_coverage)"; then
    fail "Unable to retrieve GuardDuty ECS Runtime Monitoring coverage for cluster ${EXPECTED_CLUSTER_NAME}."
  fi

  coverage_resources_json="$(
    echo "$coverage_json" |
      jq -c '.Resources // []'
  )"

  coverage_count="$(
    echo "$coverage_resources_json" |
      jq 'length'
  )"

  if [[ "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" != "true" ]]; then
    if [[ "$coverage_count" -eq 0 ]]; then
      GUARDDUTY_MANAGEMENT_TYPE="ABSENT"
      GUARDDUTY_COVERAGE_STATUS="<not required>"
      success "No GuardDuty ECS coverage record is present, which is valid while Runtime Monitoring is disabled."
      return 0
    fi

    if [[ "$coverage_count" -ne 1 ]]; then
      echo "$coverage_resources_json" | jq .
      fail "Expected at most one GuardDuty ECS coverage record for the disabled cluster."
    fi

    coverage_resource_json="$(echo "$coverage_resources_json" | jq -c '.[0]')"

    if ! echo "$coverage_resource_json" |
      jq -e \
        --arg detector_id "$GUARDDUTY_DETECTOR_ID" \
        --arg account_id "$ACCOUNT_ID" \
        --arg cluster_name "$EXPECTED_CLUSTER_NAME" '
          .DetectorId == $detector_id
          and .AccountId == $account_id
          and .ResourceType == "ECS"
          and .ResourceDetails.EcsClusterDetails.ClusterName == $cluster_name
          and .ResourceDetails.EcsClusterDetails.FargateDetails.ManagementType == "DISABLED"
        ' >/dev/null; then
      echo "$coverage_resource_json" | jq .
      fail "GuardDuty ECS coverage record does not reflect disabled Fargate agent management for deployment_profile=minimal."
    fi

    GUARDDUTY_MANAGEMENT_TYPE="$(
      echo "$coverage_resource_json" |
        jq -r '.ResourceDetails.EcsClusterDetails.FargateDetails.ManagementType'
    )"
    GUARDDUTY_COVERAGE_STATUS="$(
      echo "$coverage_resource_json" |
        jq -r '.CoverageStatus // "<not reported>"'
    )"
    GUARDDUTY_COVERAGE_UPDATED_AT="$(
      echo "$coverage_resource_json" |
        jq -r '.UpdatedAt // "<not reported>"'
    )"

    fargate_issues_json="$(
      echo "$coverage_resource_json" |
        jq -c '.ResourceDetails.EcsClusterDetails.FargateDetails.Issues // []'
    )"
    GUARDDUTY_COVERAGE_ISSUE_COUNT="$(echo "$fargate_issues_json" | jq 'length')"

    success "GuardDuty ECS coverage management type is DISABLED as expected for deployment_profile=minimal"
    return 0
  fi

  if [[ "$coverage_count" -ne 1 ]]; then
    echo "$coverage_resources_json" | jq .
    fail "Expected exactly one GuardDuty ECS coverage record for protected cluster ${EXPECTED_CLUSTER_NAME}; found ${coverage_count}."
  fi

  coverage_resource_json="$(echo "$coverage_resources_json" | jq -c '.[0]')"
  fargate_issues_json="$(
    echo "$coverage_resource_json" |
      jq -c '.ResourceDetails.EcsClusterDetails.FargateDetails.Issues // []'
  )"
  top_level_issue="$(
    echo "$coverage_resource_json" |
      jq -r '.Issue // empty'
  )"

  if ! echo "$coverage_resource_json" |
    jq -e \
      --arg detector_id "$GUARDDUTY_DETECTOR_ID" \
      --arg account_id "$ACCOUNT_ID" \
      --arg cluster_name "$EXPECTED_CLUSTER_NAME" '
        .DetectorId == $detector_id
        and .AccountId == $account_id
        and .ResourceType == "ECS"
        and .ResourceDetails.EcsClusterDetails.ClusterName == $cluster_name
        and .ResourceDetails.EcsClusterDetails.FargateDetails.ManagementType == "AUTO_MANAGED"
        and .CoverageStatus == "HEALTHY"
      ' >/dev/null; then
    echo "$coverage_resource_json" |
      jq '{
        DetectorId,
        AccountId,
        ResourceId,
        ResourceType,
        CoverageStatus,
        Issue,
        UpdatedAt,
        ResourceDetails
      }'
    fail "GuardDuty ECS/Fargate coverage is not HEALTHY and AUTO_MANAGED for the protected cluster."
  fi

  if [[ "$(echo "$fargate_issues_json" | jq 'length')" -ne 0 ]]; then
    echo "$fargate_issues_json" | jq .
    fail "GuardDuty reports unresolved Fargate runtime coverage issues for the protected cluster."
  fi

  if [[ -n "$top_level_issue" ]]; then
    printf '%s\n' "$top_level_issue"
    fail "GuardDuty reports an unresolved ECS runtime coverage issue for the protected cluster."
  fi

  GUARDDUTY_MANAGEMENT_TYPE="$(
    echo "$coverage_resource_json" |
      jq -r '.ResourceDetails.EcsClusterDetails.FargateDetails.ManagementType'
  )"
  GUARDDUTY_COVERAGE_STATUS="$(
    echo "$coverage_resource_json" |
      jq -r '.CoverageStatus'
  )"
  GUARDDUTY_COVERAGE_UPDATED_AT="$(
    echo "$coverage_resource_json" |
      jq -r '.UpdatedAt // "<not reported>"'
  )"
  GUARDDUTY_COVERAGE_ISSUE_COUNT=0

  success "GuardDuty ECS/Fargate coverage is HEALTHY, AUTO_MANAGED, and has no unresolved issues"
}

ecs_runtime_validate_guardduty() {
  ecs_runtime_validate_guardduty_tasks
  ecs_runtime_validate_guardduty_coverage
}