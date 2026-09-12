#!/usr/bin/env bash

# Internal ECS runtime contract helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_load_contract() {
  local repo_root
  local env_dir
  local output_name

  section "Resolving repository paths and Terraform outputs"

  repo_root="$(get_repo_root)"
  env_dir="$(get_environment_dir "$repo_root" "$ENV_NAME")"
  require_directory "$env_dir"

  OUTPUTS_JSON="$(terraform_output_json "$env_dir")"

  if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
    fail "No Terraform outputs found for ${env_dir}. Has this environment been applied?"
  fi

  ECS_CLUSTER_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_cluster)"
  ECS_SERVICES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_services)"
  ECS_SERVICE_CONFIGURATION_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_service_configuration)"
  TASK_DEFINITION_ARNS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_task_definition_arns)"
  TASK_SECURITY_GROUP_IDS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_task_security_group_ids)"
  ECS_LOG_GROUPS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_log_groups)"
  ECS_EXECUTION_ROLES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_task_execution_roles)"
  ECS_TASK_ROLES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_task_roles)"
  # Repository URLs constrain task images; repository posture stays in validate-ecr.sh.
  # shellcheck disable=SC2034 # Consumed by services.sh.
  ECR_REPOSITORIES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecr_repositories)"
  ECS_AUTOSCALING_TARGETS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_autoscaling_targets)"
  ECS_AUTOSCALING_CPU_POLICIES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_autoscaling_cpu_policies)"
  ECS_AUTOSCALING_MEMORY_POLICIES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_autoscaling_memory_policies)"
  ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_autoscaling_alb_request_policies)"
  ECS_TASK_DEFICIT_ALARMS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_task_deficit_alarms)"
  ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" ecs_ingress_unhealthy_target_alarms)"

  for output_name in \
    vpc_id \
    name_prefix \
    s3_prefix_list_id \
    effective_egress_mode \
    effective_cloudwatch_retention_days \
    logs_cmk_arn \
    data_sg_id \
    rds_port \
    secops_topic_arn; do
    if ! terraform_output_exists "$OUTPUTS_JSON" "$output_name"; then
      fail "Missing required Terraform output: ${output_name}"
    fi
  done

  # shellcheck disable=SC2034 # Consumed by services.sh and ingress.sh.
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  # shellcheck disable=SC2034 # Consumed by services.sh.
  S3_PREFIX_LIST_ID="$(get_terraform_output_value "$OUTPUTS_JSON" s3_prefix_list_id)"
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
  LOGS_CMK_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" logs_cmk_arn)"
  DATA_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" data_sg_id)"
  RDS_PORT="$(get_terraform_output_value "$OUTPUTS_JSON" rds_port)"
  # shellcheck disable=SC2034 # Consumed by alarms.sh.
  SECOPS_TOPIC_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" secops_topic_arn)"

  APPLICATION_LOAD_BALANCER_JSON="$(
    echo "$OUTPUTS_JSON" |
      jq -c '
        if has("application_load_balancer")
        then .application_load_balancer.value
        else null
        end
      '
  )"

  # shellcheck disable=SC2034 # Consumed by services.sh, ingress.sh, and alarms.sh.
  NAME_PREFIX="$(get_terraform_output_value "$OUTPUTS_JSON" name_prefix)"
  validate_alb_output

  require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"

  if ! [[ "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    fail "effective_cloudwatch_retention_days is not an integer: ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}"
  fi

  validate_cluster_output
  validate_service_outputs
  validate_scaling_output_membership

  if [[ -z "$LOGS_CMK_ARN" ]]; then
    fail "logs_cmk_arn is empty"
  fi

  if [[ -z "$DATA_SG_ID" ]]; then
    fail "data_sg_id is empty"
  fi

  if ! [[ "$RDS_PORT" =~ ^[0-9]+$ ]] || ((RDS_PORT < 1 || RDS_PORT > 65535)); then
    fail "rds_port is not a valid TCP port: ${RDS_PORT}"
  fi

  ECS_SERVICE_COUNT="$(echo "$ECS_SERVICES_JSON" | jq 'length')"
  info "Configured ECS services: ${ECS_SERVICE_COUNT}"
}

ecs_runtime_validate_alarm_output_membership() {
  local expected_container_insights="$1"
  local expected_task_deficit_alarm_services_json
  local expected_ingress_alarm_services_json

  if [[ "$expected_container_insights" == "disabled" ]]; then
    expected_task_deficit_alarm_services_json='{}'
  else
    expected_task_deficit_alarm_services_json="$ECS_SERVICE_CONFIGURATION_JSON"
  fi

  expected_ingress_alarm_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c '
        with_entries(
          select(.value.ingress_enabled == true)
        )
      '
  )"

  ecs_runtime_require_same_map_keys \
    "$expected_task_deficit_alarm_services_json" \
    "$ECS_TASK_DEFICIT_ALARMS_JSON" \
    "ECS task-deficit alarms"

  ecs_runtime_require_same_map_keys \
    "$expected_ingress_alarm_services_json" \
    "$ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON" \
    "ECS ingress unhealthy-target alarms"
}

validate_alb_output() {
  local unexpected_target_group_keys_json

  if [[ "$APPLICATION_LOAD_BALANCER_JSON" != "null" ]]; then
    if ! echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -e '
        type == "object"
        and (.arn | type == "string" and length > 0)
        and (.dns_name | type == "string" and length > 0)
        and (.security_group_id | type == "string" and length > 0)
        and (.https_listener | type == "object")
        and (.https_listener.arn | type == "string" and length > 0)
        and (.https_listener.certificate_arn | type == "string" and length > 0)
        and (.https_listener.ssl_policy | type == "string" and length > 0)
        and (.target_groups | type == "object" and length > 0)
        and (.arn_suffix | type == "string" and length > 0)
      ' >/dev/null; then
      fail "application_load_balancer output is not null and lacks required runtime metadata"
    fi

    unexpected_target_group_keys_json="$(
      jq -n \
        --argjson services "$ECS_SERVICES_JSON" \
        --argjson alb "$APPLICATION_LOAD_BALANCER_JSON" \
        '($alb.target_groups | keys) - ($services | keys)'
    )"
    if [[ "$(echo "$unexpected_target_group_keys_json" | jq 'length')" -ne 0 ]]; then
      echo "$unexpected_target_group_keys_json" | jq .
      fail "application_load_balancer target groups contain keys absent from ecs_services"
    fi
  fi
}

validate_cluster_output() {
  if ! echo "$ECS_CLUSTER_JSON" |
    jq -e '
      type == "object"
      and (.arn | type == "string" and length > 0)
      and (.name | type == "string" and length > 0)
      and (.container_insights | type == "string" and length > 0)
      and has("container_insights_log_group")
      and (
        (
          .container_insights == "disabled"
          and .container_insights_log_group == null
        )
        or
        (
          .container_insights != "disabled"
          and (.container_insights_log_group | type == "object")
          and (.container_insights_log_group.arn | type == "string" and length > 0)
          and (.container_insights_log_group.name | type == "string" and length > 0)
          and (.container_insights_log_group.retention_in_days | type == "number")
          and (.container_insights_log_group.kms_key_id | type == "string" and length > 0)
        )
      )
    ' >/dev/null; then
    fail "ecs_cluster output contains invalid cluster or Container Insights log-group metadata"
  fi
}

validate_service_outputs() {
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$TASK_DEFINITION_ARNS_JSON" "task definition ARNs"
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_SERVICE_CONFIGURATION_JSON" "ECS service configuration"
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$TASK_SECURITY_GROUP_IDS_JSON" "task security groups"
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_LOG_GROUPS_JSON" "log groups"
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_EXECUTION_ROLES_JSON" "task execution roles"
  ecs_runtime_require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_TASK_ROLES_JSON" "task roles"

  if ! echo "$ECS_SERVICE_CONFIGURATION_JSON" |
    jq -e '
      all(.[];
        type == "object"

        and (.desired_count | type) == "number"

        and (
          .scaling == null
          or (
            (.scaling | type) == "object"
            and (.scaling.min_capacity | type) == "number"
            and (.scaling.max_capacity | type) == "number"
          )
        )

        and (.deployment | type) == "object"
        and (.deployment.minimum_healthy_percent | type) == "number"
        and (.deployment.maximum_percent | type) == "number"
        and (.deployment.health_check_grace_period_seconds | type) == "number"

        and (.ingress_enabled | type) == "boolean"
        and (.database_access | type) == "boolean"

        and (.task_execution_kms_key_arns | type) == "array"
      )
    ' >/dev/null; then
    fail "ecs_service_configuration contains invalid validator metadata"
  fi
}

validate_scaling_output_membership() {
  local expected_autoscaled_services_json
  local expected_cpu_scaling_services_json
  local expected_memory_scaling_services_json
  local expected_alb_request_scaling_services_json

  expected_autoscaled_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c 'with_entries(select(.value.scaling != null))'
  )"

  expected_cpu_scaling_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c '
        with_entries(
          select(
            .value.scaling != null
            and .value.scaling.cpu_target_percent != null
          )
        )
      '
  )"

  expected_memory_scaling_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c '
        with_entries(
          select(
            .value.scaling != null
            and .value.scaling.memory_target_percent != null
          )
        )
      '
  )"

  expected_alb_request_scaling_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c '
        with_entries(
          select(
            .value.scaling != null
            and .value.scaling.alb_requests_per_target != null
          )
        )
      '
  )"

  ecs_runtime_require_same_map_keys \
    "$expected_autoscaled_services_json" \
    "$ECS_AUTOSCALING_TARGETS_JSON" \
    "Application Auto Scaling targets"
  ecs_runtime_require_same_map_keys \
    "$expected_cpu_scaling_services_json" \
    "$ECS_AUTOSCALING_CPU_POLICIES_JSON" \
    "CPU target-tracking policies"
  ecs_runtime_require_same_map_keys \
    "$expected_memory_scaling_services_json" \
    "$ECS_AUTOSCALING_MEMORY_POLICIES_JSON" \
    "memory target-tracking policies"
  ecs_runtime_require_same_map_keys \
    "$expected_alb_request_scaling_services_json" \
    "$ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON" \
    "ALB request-count target-tracking policies"
}
