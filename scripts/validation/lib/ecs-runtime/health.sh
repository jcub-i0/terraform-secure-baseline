#!/usr/bin/env bash

# Independent ECS-native application health validation. No checks are queried
# for services without health_check. A configured, zero-capacity service is
# explicitly skipped (not counted as a live HEALTHY result).
#
# Default bounded startup polling: 13 checks, five seconds apart. Customize
# ECS_NATIVE_HEALTH_MAX_ATTEMPTS and ECS_NATIVE_HEALTH_POLL_INTERVAL_SECONDS
# for slow-starting applications or qualification exercises.

ecs_runtime_validate_service_native_health() {
  local service_key="$1"
  local service_arn service_name task_definition_arn
  local max_attempts poll_interval attempt
  local service_json desired_count running_count pending_count
  local task_arns_json task_count tasks_json described_count
  local invalid_json unhealthy_json unresolved_json='[]'

  service_arn="$(echo "$ECS_SERVICES_JSON" | jq -er --arg service "$service_key" '.[$service].arn')"
  service_name="$(echo "$ECS_SERVICES_JSON" | jq -er --arg service "$service_key" '.[$service].name')"
  task_definition_arn="$(echo "$TASK_DEFINITION_ARNS_JSON" | jq -er --arg service "$service_key" '.[$service]')"

  max_attempts="${ECS_NATIVE_HEALTH_MAX_ATTEMPTS:-13}"
  poll_interval="${ECS_NATIVE_HEALTH_POLL_INTERVAL_SECONDS:-5}"

  if ! [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || ((max_attempts > 60)); then
    fail "ECS_NATIVE_HEALTH_MAX_ATTEMPTS must be an integer from 1 to 60"
  fi
  if ! [[ "$poll_interval" =~ ^[0-9]+$ ]] || ((poll_interval > 60)); then
    fail "ECS_NATIVE_HEALTH_POLL_INTERVAL_SECONDS must be an integer from 0 to 60"
  fi

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    service_json="$(
      aws ecs describe-services "${AWS_ARGS[@]}" \
        --cluster "$EXPECTED_CLUSTER_ARN" --services "$service_arn" --output json
    )"

    if ! echo "$service_json" | jq -e \
      --arg arn "$service_arn" --arg name "$service_name" \
      --arg cluster "$EXPECTED_CLUSTER_ARN" '
        (.failures // [] | length) == 0
        and (.services | length) == 1
        and .services[0].serviceArn == $arn
        and .services[0].serviceName == $name
        and .services[0].clusterArn == $cluster
        and .services[0].status == "ACTIVE"
      ' >/dev/null; then
      echo "$service_json" | jq .
      fail "ECS service identity is invalid for native health validation: $service_key"
    fi

    desired_count="$(echo "$service_json" | jq -r '.services[0].desiredCount')"
    running_count="$(echo "$service_json" | jq -r '.services[0].runningCount')"
    pending_count="$(echo "$service_json" | jq -r '.services[0].pendingCount')"

    if ((desired_count == 0 && running_count == 0 && pending_count == 0)); then
      ECS_NATIVE_HEALTH_ZERO_CAPACITY_SKIPPED=$((ECS_NATIVE_HEALTH_ZERO_CAPACITY_SKIPPED + 1))
      info "Native health configured but not exercised at zero desired capacity: $service_key"
      return 0
    fi

    # Recheck the service count because tasks may change after the earlier
    # ECS steady-state validator inspected the service.
    if ((desired_count > 0 && running_count == desired_count && pending_count == 0)); then
      task_arns_json="$(
        aws ecs list-tasks "${AWS_ARGS[@]}" \
          --cluster "$EXPECTED_CLUSTER_ARN" --service-name "$service_name" \
          --desired-status RUNNING --output json |
          jq -c '[.taskArns[]?] | sort | unique'
      )"
      task_count="$(echo "$task_arns_json" | jq 'length')"

      if ((task_count == desired_count)); then
        tasks_json="$(ecs_runtime_describe_tasks_json "$task_arns_json")"
        described_count="$(echo "$tasks_json" | jq 'length')"

        if ((described_count == desired_count)); then
          invalid_json="$(
            echo "$tasks_json" | jq -c \
              --arg cluster "$EXPECTED_CLUSTER_ARN" \
              --arg definition "$task_definition_arn" \
              --arg group "service:$service_name" \
              --arg service "$service_key" '
                [.[] | select(
                  .clusterArn != $cluster or .taskDefinitionArn != $definition
                  or .group != $group or .launchType != "FARGATE"
                  or .desiredStatus != "RUNNING"
                  or (.lastStatus == "RUNNING"
                    and ([.containers[]? | select(.name == $service)] | length) != 1)
                ) | {taskArn, taskDefinitionArn, group, launchType, desiredStatus, lastStatus, containers}]
              '
          )"
          if [[ "$(echo "$invalid_json" | jq 'length')" -gt 0 ]]; then
            echo "$invalid_json" | jq .
            fail "ECS native-health task identity or application-container inventory is invalid: $service_key"
          fi

          unhealthy_json="$(
            echo "$tasks_json" | jq -c --arg service "$service_key" '
              [.[] | select(any(.containers[]?;
                .name == $service and .healthStatus == "UNHEALTHY"
              )) | .taskArn]
            '
          )"
          if [[ "$(echo "$unhealthy_json" | jq 'length')" -gt 0 ]]; then
            echo "$unhealthy_json" | jq .
            fail "ECS application container reported UNHEALTHY: $service_key"
          fi

          unresolved_json="$(
            echo "$tasks_json" | jq -c --arg service "$service_key" '
              [.[] | select(
                .lastStatus != "RUNNING"
                or ([.containers[]? | select(
                  .name == $service and .lastStatus == "RUNNING"
                  and .healthStatus == "HEALTHY"
                )] | length) != 1
              ) | {taskArn, lastStatus,
                   application: [.containers[]? | select(.name == $service)
                     | {lastStatus, healthStatus}]}]
            '
          )"
          if [[ "$(echo "$unresolved_json" | jq 'length')" -eq 0 ]]; then
            ECS_NATIVE_HEALTH_RUNNING_TASKS_VALIDATED=$((ECS_NATIVE_HEALTH_RUNNING_TASKS_VALIDATED + desired_count))
            success "All $desired_count running ECS application containers report HEALTHY: $service_key"
            return 0
          fi
        fi
      fi
    fi

    if ((attempt < max_attempts)); then
      info "Awaiting ECS native health ($attempt/$max_attempts): $service_key; desired=$desired_count running=$running_count pending=$pending_count"
      sleep "$poll_interval"
    fi
  done

  jq -n --arg service "$service_key" --argjson unresolved "$unresolved_json" \
    '{service: $service, unresolved_application_tasks: $unresolved}'
  fail "ECS application health did not converge to HEALTHY in $max_attempts checks: $service_key"
}

ecs_runtime_validate_application_health() {
  local service_key

  section "Validating ECS-native application health"
  ECS_NATIVE_HEALTH_SERVICES_CONFIGURED=0
  ECS_NATIVE_HEALTH_RUNNING_TASKS_VALIDATED=0
  ECS_NATIVE_HEALTH_ZERO_CAPACITY_SKIPPED=0

  while IFS= read -r service_key; do
    [[ -z "$service_key" ]] && continue
    ECS_NATIVE_HEALTH_SERVICES_CONFIGURED=$((ECS_NATIVE_HEALTH_SERVICES_CONFIGURED + 1))
    ecs_runtime_validate_service_native_health "$service_key"
  done < <(echo "$ECS_SERVICE_CONFIGURATION_JSON" |
    jq -r 'to_entries[] | select(.value | has("health_check")) | .key')

  if ((ECS_NATIVE_HEALTH_SERVICES_CONFIGURED == 0)); then
    info "No ECS-native health checks configured; no additional AWS task queries."
  else
    success "Native health: $ECS_NATIVE_HEALTH_RUNNING_TASKS_VALIDATED healthy tasks; $ECS_NATIVE_HEALTH_ZERO_CAPACITY_SKIPPED zero-capacity skips."
  fi
}
