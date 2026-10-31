#!/usr/bin/env bash

# Internal ECS runtime summary helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_print_summary() {
  local autoscaled_service_count
  local cpu_scaling_policy_count
  local memory_scaling_policy_count
  local alb_request_scaling_policy_count
  local task_deficit_alarm_count
  local ingress_health_alarm_count
  local guardduty_runtime_state

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

  case "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" in
    true)
      guardduty_runtime_state="enabled"
      ;;
    false)
      guardduty_runtime_state="disabled"
      ;;
    *)
      guardduty_runtime_state="<unknown>"
      ;;
  esac

  local waf_enabled="false"
  local waf_mode="n/a"
  local waf_acl_arn="n/a"
  local waf_rate_limit="disabled"
  local waf_sampling="n/a"

  if [[ "$APPLICATION_LOAD_BALANCER_JSON" != "null" ]]; then
    waf_enabled="$(jq -r '.waf.enabled' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
    if [[ "$waf_enabled" == "true" ]]; then
      waf_mode="$(jq -r '.waf.mode' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
      waf_acl_arn="$(jq -r '.waf.web_acl_arn' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
      waf_rate_limit="$(jq -r 'if .waf.rate_limit_requests == null then "disabled" else (.waf.rate_limit_requests | tostring) end' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
      waf_sampling="$(jq -r '.waf.sampled_requests_enabled' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
    fi
  fi

  section "ECS Runtime Summary"


  cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS account ID:                     ${ACCOUNT_ID}
AWS region:                         ${AWS_REGION}
Deployment profile:                 ${DEPLOYMENT_PROFILE}
ECS cluster:                        ${EXPECTED_CLUSTER_NAME}

Configured ECS services:              ${ECS_SERVICE_COUNT}
Native health-check services:         ${ECS_NATIVE_HEALTH_SERVICES_CONFIGURED}
Healthy application tasks validated:  ${ECS_NATIVE_HEALTH_RUNNING_TASKS_VALIDATED}
Zero-capacity health checks skipped:  ${ECS_NATIVE_HEALTH_ZERO_CAPACITY_SKIPPED}
Autoscaled ECS services:              ${autoscaled_service_count}
CPU scaling policies:                 ${cpu_scaling_policy_count}
Memory scaling policies:              ${memory_scaling_policy_count}
ALB request scaling policies:         ${alb_request_scaling_policy_count}
Task-deficit alarms:                  ${task_deficit_alarm_count}
Ingress-health alarms:                ${ingress_health_alarm_count}

Expected compute subnets:           ${EXPECTED_COMPUTE_SUBNET_IDS_JSON}
Expected ingress-public subnets:    ${EXPECTED_INGRESS_PUBLIC_SUBNET_IDS_JSON}
Expected ALB deletion protection:   ${EXPECTED_ALB_DELETION_PROTECTION}
Live ALB deletion protection:       ${LIVE_ALB_DELETION_PROTECTION}

Effective egress mode:              ${EFFECTIVE_EGRESS_MODE}
CloudWatch retention days:          ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}
Application Load Balancer present:  $([[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]] && echo false || echo true)

AWS WAF enabled:                   ${waf_enabled}
AWS WAF mode:                      ${waf_mode}
AWS WAF Web ACL:                   ${waf_acl_arn}
AWS WAF rate limiting:             ${waf_rate_limit}
AWS WAF sampled requests:          ${waf_sampling}
AWS WAF validation:                ${WAF_VALIDATION_STATUS}

GuardDuty Runtime Monitoring:       ${guardduty_runtime_state}
GuardDutyManaged Terraform value:   ${GUARDDUTY_MANAGED_TAG_VALUE}
GuardDutyManaged live value:        ${LIVE_GUARDDUTY_MANAGED_TAG_VALUE}
GuardDuty data endpoint ID:         ${GUARDDUTY_DATA_ENDPOINT_ID}

Protected running tasks checked:    ${GUARDDUTY_RUNNING_TASKS_CHECKED}
GuardDuty agents running:           ${GUARDDUTY_AGENT_CONTAINERS_RUNNING}
Application containers valid:       ${GUARDDUTY_APPLICATION_CONTAINERS_VALID}

GuardDuty management type:          ${GUARDDUTY_MANAGEMENT_TYPE}
GuardDuty ECS coverage status:      ${GUARDDUTY_COVERAGE_STATUS}
GuardDuty coverage issue count:     ${GUARDDUTY_COVERAGE_ISSUE_COUNT}
GuardDuty coverage updated at:      ${GUARDDUTY_COVERAGE_UPDATED_AT}
SUMMARY
}