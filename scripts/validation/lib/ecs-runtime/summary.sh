#!/usr/bin/env bash

# Internal ECS runtime summary helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_print_summary() {
  local autoscaled_service_count
  local cpu_scaling_policy_count
  local memory_scaling_policy_count
  local alb_request_scaling_policy_count
  local task_deficit_alarm_count
  local ingress_health_alarm_count

  autoscaled_service_count="$(
    echo "$ECS_AUTOSCALING_TARGETS_JSON" | jq 'length'
  )"

  cpu_scaling_policy_count="$(
    echo "$ECS_AUTOSCALING_CPU_POLICIES_JSON" | jq 'length'
  )"

  memory_scaling_policy_count="$(
    echo "$ECS_AUTOSCALING_MEMORY_POLICIES_JSON" | jq 'length'
  )"

  alb_request_scaling_policy_count="$(
    echo "$ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON" | jq 'length'
  )"

  task_deficit_alarm_count="$(
    echo "$ECS_TASK_DEFICIT_ALARMS_JSON" | jq 'length'
  )"

  ingress_health_alarm_count="$(
    echo "$ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON" | jq 'length'
  )"

  section "ECS Runtime Summary"

  cat <<SUMMARY
Environment:                       ${ENV_NAME}
AWS account ID:                    ${ACCOUNT_ID}
AWS region:                        ${AWS_REGION}
ECS cluster:                       ${EXPECTED_CLUSTER_NAME}
Configured ECS services:           ${ECS_SERVICE_COUNT}
Autoscaled ECS services:           ${autoscaled_service_count}
CPU scaling policies:              ${cpu_scaling_policy_count}
Memory scaling policies:           ${memory_scaling_policy_count}
ALB request scaling policies:      ${alb_request_scaling_policy_count}
Task-deficit alarms:               ${task_deficit_alarm_count}
Ingress-health alarms:             ${ingress_health_alarm_count}
Effective egress mode:             ${EFFECTIVE_EGRESS_MODE}
CloudWatch retention days:         ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}
Application Load Balancer present: $([[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]] && echo false || echo true)
SUMMARY
}
