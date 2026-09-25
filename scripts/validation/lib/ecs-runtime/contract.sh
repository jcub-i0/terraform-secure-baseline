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
  # shellcheck disable=SC2034 # Consumed by future GuardDuty runtime validation and summary helpers.
  INTERFACE_ENDPOINT_IDS_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" interface_endpoint_ids)"
  # shellcheck disable=SC2034 # Consumed by future GuardDuty runtime validation and summary helpers.
  GUARDDUTY_RUNTIME_COVERAGE_NOTIFICATION_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" guardduty_ecs_runtime_coverage_notification)"
  NETWORK_TOPOLOGY_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" network_topology)"
  LIFECYCLE_PROTECTION_JSON="$(ecs_runtime_json_object_output "$OUTPUTS_JSON" lifecycle_protection)"

  for output_name in \
    vpc_id \
    name_prefix \
    deployment_profile \
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
  # shellcheck disable=SC2034 # Consumed by services.sh, ingress.sh, alarms.sh, and GuardDuty runtime helpers.
  NAME_PREFIX="$(get_terraform_output_value "$OUTPUTS_JSON" name_prefix)"
  # shellcheck disable=SC2034 # Consumed by GuardDuty runtime validation and summary helpers.
  DEPLOYMENT_PROFILE="$(get_terraform_output_value "$OUTPUTS_JSON" deployment_profile)"
  # shellcheck disable=SC2034 # Consumed by services.sh.
  S3_PREFIX_LIST_ID="$(get_terraform_output_value "$OUTPUTS_JSON" s3_prefix_list_id)"
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
  LOGS_CMK_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" logs_cmk_arn)"
  DATA_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" data_sg_id)"
  RDS_PORT="$(get_terraform_output_value "$OUTPUTS_JSON" rds_port)"
  # shellcheck disable=SC2034 # Consumed by alarms.sh.
  SECOPS_TOPIC_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" secops_topic_arn)"

  if ! EXPECTED_COMPUTE_SUBNET_IDS_JSON="$(
    echo "$NETWORK_TOPOLOGY_JSON" |
      jq -ce '
        .compute_private_subnet_ids_by_az
        | if type == "object" and length > 0
          then [.[]] | sort | unique
          else error("network_topology.compute_private_subnet_ids_by_az must be a non-empty object")
          end
      '
  )"; then
    fail "Unable to resolve Terraform-owned compute-private subnet set."
  fi

  info "Expected compute-private subnets: ${EXPECTED_COMPUTE_SUBNET_IDS_JSON}"

  if ! EXPECTED_PUBLIC_SUBNET_IDS_JSON="$(
    echo "$NETWORK_TOPOLOGY_JSON" |
      jq -ce '
        .public_subnet_ids_by_az
        | if type == "object" and length > 0
          then [.[]] | sort | unique
          else error("network_topology.public_subnet_ids_by_az must be a non-empty object")
          end
      '
  )"; then
    fail "Unable to resolve Terraform-owned public subnet set."
  fi

  info "Expected public subnets: ${EXPECTED_PUBLIC_SUBNET_IDS_JSON}"

  EXPECTED_ALB_DELETION_PROTECTION="$(
    echo "$LIFECYCLE_PROTECTION_JSON" |
      jq -r '.alb_deletion_protection'
  )"

  require_value_in_list \
    "$EXPECTED_ALB_DELETION_PROTECTION" \
    "true false" \
    "lifecycle_protection.alb_deletion_protection"

  info "Expected ALB deletion protection: ${EXPECTED_ALB_DELETION_PROTECTION}"

  APPLICATION_LOAD_BALANCER_JSON="$(
    echo "$OUTPUTS_JSON" |
      jq -c '
        if has("application_load_balancer")
        then .application_load_balancer.value
        else null
        end
      '
  )"

  validate_alb_output

  require_value_in_list "$DEPLOYMENT_PROFILE" "production development minimal" "deployment_profile"
  require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"

  ecs_runtime_resolve_guardduty_profile_contract
  ecs_runtime_validate_guardduty_integration_outputs

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
  info "Deployment profile: ${DEPLOYMENT_PROFILE}"
  info "GuardDuty Fargate Runtime Monitoring expected: ${EXPECTED_GUARDDUTY_RUNTIME_ENABLED}"
  info "GuardDutyManaged expected tag value: ${EXPECTED_GUARDDUTY_MANAGED_TAG_VALUE}"
  info "Configured ECS services: ${ECS_SERVICE_COUNT}"
}

ecs_runtime_resolve_guardduty_profile_contract() {
  case "$DEPLOYMENT_PROFILE" in
    production | development)
      EXPECTED_GUARDDUTY_RUNTIME_ENABLED="true"
      EXPECTED_GUARDDUTY_MANAGED_TAG_VALUE="true"
      ;;
    minimal)
      EXPECTED_GUARDDUTY_RUNTIME_ENABLED="false"
      EXPECTED_GUARDDUTY_MANAGED_TAG_VALUE="false"
      ;;
    *)
      fail "Unsupported deployment_profile for GuardDuty Runtime Monitoring contract: ${DEPLOYMENT_PROFILE}"
      ;;
  esac
}

ecs_runtime_validate_guardduty_integration_outputs() {
  local required_endpoint_service
  local expected_rule_name
  local expected_target_id

  section "Validating GuardDuty Runtime Monitoring Terraform contract"

  for required_endpoint_service in ecr.api ecr.dkr guardduty-data; do
    if ! echo "$INTERFACE_ENDPOINT_IDS_JSON" |
      jq -e \
        --arg service "$required_endpoint_service" '
          has($service)
          and (.[$service] | type == "string")
          and (.[$service] | test("^vpce-[0-9a-f]+$"))
        ' >/dev/null; then
      echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq .
      fail "interface_endpoint_ids does not contain a valid Terraform-managed '${required_endpoint_service}' endpoint ID."
    fi
  done

  if ! echo "$INTERFACE_ENDPOINT_IDS_JSON" |
    jq -e '
      [
        .["ecr.api"],
        .["ecr.dkr"],
        .["guardduty-data"]
      ]
      | unique
      | length == 3
    ' >/dev/null; then
    echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq .
    fail "Required ECR and GuardDuty Interface Endpoint IDs must resolve to three distinct Terraform resources."
  fi

  # shellcheck disable=SC2034 # Consumed by future GuardDuty runtime validation and summary helpers.
  ECR_API_ENDPOINT_ID="$(echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq -r '."ecr.api"')"
  # shellcheck disable=SC2034 # Consumed by future GuardDuty runtime validation and summary helpers.
  ECR_DKR_ENDPOINT_ID="$(echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq -r '."ecr.dkr"')"
  # shellcheck disable=SC2034 # Consumed by future GuardDuty runtime validation and summary helpers.
  GUARDDUTY_DATA_ENDPOINT_ID="$(echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq -r '."guardduty-data"')"

  expected_rule_name="${NAME_PREFIX}-guardduty-ecs-runtime-coverage"
  expected_target_id="guardduty-ecs-runtime-coverage-to-secops-sns"

  if ! echo "$GUARDDUTY_RUNTIME_COVERAGE_NOTIFICATION_JSON" |
    jq -e \
      --arg rule_name "$expected_rule_name" \
      --arg target_id "$expected_target_id" \
      --arg secops_topic_arn "$SECOPS_TOPIC_ARN" '
        type == "object"
        and (keys | sort) == [
          "dead_letter_arn",
          "rule_arn",
          "rule_name",
          "target_arn",
          "target_id"
        ]
        and .rule_name == $rule_name
        and .target_id == $target_id
        and .target_arn == $secops_topic_arn
        and (.rule_arn | type == "string" and length > 0)
        and (.dead_letter_arn | type == "string" and length > 0)
      ' >/dev/null; then
    echo "$GUARDDUTY_RUNTIME_COVERAGE_NOTIFICATION_JSON" | jq .
    fail "guardduty_ecs_runtime_coverage_notification does not match the workload Runtime Monitoring notification contract."
  fi

  success "GuardDuty Runtime Monitoring endpoint and notification integration outputs are valid"
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
      and (.guardduty_fargate_runtime_monitoring_enabled | type == "boolean")
      and (.guardduty_managed_tag_value | type == "string")
      and (.guardduty_managed_tag_value | IN("true", "false"))
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
    fail "ecs_cluster output contains invalid cluster, Container Insights, or GuardDuty Runtime Monitoring metadata"
  fi

  GUARDDUTY_FARGATE_RUNTIME_MONITORING_ENABLED="$(
    echo "$ECS_CLUSTER_JSON" |
      jq -r '.guardduty_fargate_runtime_monitoring_enabled'
  )"

  GUARDDUTY_MANAGED_TAG_VALUE="$(
    echo "$ECS_CLUSTER_JSON" |
      jq -r '.guardduty_managed_tag_value'
  )"

  if [[ "$GUARDDUTY_FARGATE_RUNTIME_MONITORING_ENABLED" != "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" ]]; then
    fail "Terraform GuardDuty Fargate Runtime Monitoring state (${GUARDDUTY_FARGATE_RUNTIME_MONITORING_ENABLED}) does not match deployment_profile=${DEPLOYMENT_PROFILE} expectation (${EXPECTED_GUARDDUTY_RUNTIME_ENABLED})."
  fi

  if [[ "$GUARDDUTY_MANAGED_TAG_VALUE" != "$EXPECTED_GUARDDUTY_MANAGED_TAG_VALUE" ]]; then
    fail "Terraform GuardDutyManaged tag value (${GUARDDUTY_MANAGED_TAG_VALUE}) does not match deployment_profile=${DEPLOYMENT_PROFILE} expectation (${EXPECTED_GUARDDUTY_MANAGED_TAG_VALUE})."
  fi

  success "Terraform ECS cluster GuardDuty Runtime Monitoring intent matches deployment_profile=${DEPLOYMENT_PROFILE}"
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
        and (.guardduty_agent_ecr_repository_arns | type) == "array"
        and all(.guardduty_agent_ecr_repository_arns[]; type == "string")
      )
    ' >/dev/null; then
    fail "ecs_service_configuration contains invalid validator metadata"
  fi

  local invalid_guardduty_services_json
  local guardduty_agent_repository_arns_json

  invalid_guardduty_services_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c \
        --argjson enabled "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" '
          [
            to_entries[]
            | select(
                if $enabled
                then (.value.guardduty_agent_ecr_repository_arns | length) != 1
                else (.value.guardduty_agent_ecr_repository_arns | length) != 0
                end
              )
            | {
                service: .key,
                guardduty_agent_ecr_repository_arns: .value.guardduty_agent_ecr_repository_arns
              }
          ]
        '
  )"

  if [[ "$(echo "$invalid_guardduty_services_json" | jq 'length')" -ne 0 ]]; then
    echo "$invalid_guardduty_services_json" | jq .
    if [[ "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" == "true" ]]; then
      fail "Each ECS service must expose exactly one GuardDuty agent ECR repository ARN when Runtime Monitoring is enabled."
    else
      fail "ECS services must not expose GuardDuty agent ECR repository ARNs when Runtime Monitoring is disabled."
    fi
  fi

  guardduty_agent_repository_arns_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c '
        [
          .[]?.guardduty_agent_ecr_repository_arns[]?
        ]
        | sort
        | unique
      '
  )"

  if [[ "$EXPECTED_GUARDDUTY_RUNTIME_ENABLED" == "true" ]] &&
    [[ "$(echo "$guardduty_agent_repository_arns_json" | jq 'length')" -gt 0 ]]; then

    if [[ "$(echo "$guardduty_agent_repository_arns_json" | jq 'length')" -ne 1 ]]; then
      echo "$guardduty_agent_repository_arns_json" | jq .
      fail "Protected ECS services must resolve to one shared regional GuardDuty agent ECR repository ARN."
    fi

    if ! echo "$guardduty_agent_repository_arns_json" |
      jq -e \
        --arg region "$AWS_REGION" '
          all(.[];
            type == "string"
            and (
              split(":") as $parts
              | ($parts | length) == 6
              and $parts[0] == "arn"
              and ($parts[1] | length) > 0
              and $parts[2] == "ecr"
              and $parts[3] == $region
              and ($parts[4] | test("^[0-9]{12}$"))
              and $parts[5] == "repository/aws-guardduty-agent-fargate"
            )
          )
        ' >/dev/null; then
      echo "$guardduty_agent_repository_arns_json" | jq .
      fail "GuardDuty agent ECR repository metadata does not match the expected regional aws-guardduty-agent-fargate repository shape."
    fi
  fi

  success "ECS service GuardDuty agent repository metadata matches the effective Runtime Monitoring contract"
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
