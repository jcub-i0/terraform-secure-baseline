#!/usr/bin/env bash

# Internal ECS runtime services helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_validate_services() {
  local service_name

  section "Validating ECS services, task definitions, logs, and task security groups"

  while IFS= read -r service_name; do
    validate_service "$service_name"
  done < <(echo "$ECS_SERVICES_JSON" | jq -r 'keys[]')
}

ecs_runtime_resolve_service_networking() {
  local compute_subnets_json

  section "Resolving accepted live networking identities"

  compute_subnets_json="$(
    aws ec2 describe-subnets \
      "${AWS_ARGS[@]}" \
      --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-*" \
      --output json
  )"

  COMPUTE_SUBNET_IDS_JSON="$(echo "$compute_subnets_json" | jq -c '[.Subnets[].SubnetId] | sort | unique')"

  if [[ "$(echo "$COMPUTE_SUBNET_IDS_JSON" | jq 'length')" -eq 0 ]]; then
    fail "No compute-private subnets were resolved for ECS service placement validation"
  fi

  INTERFACE_ENDPOINT_SGS_JSON="$(
    aws ec2 describe-security-groups \
      "${AWS_ARGS[@]}" \
      --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-VPC-Endpoints-SG" \
      --output json
  )"

  if [[ "$(echo "$INTERFACE_ENDPOINT_SGS_JSON" | jq '.SecurityGroups | length')" -ne 1 ]]; then
    fail "Expected exactly one shared Interface Endpoint security group"
  fi

  DATA_SG_JSON="$(
    aws ec2 describe-security-groups \
      "${AWS_ARGS[@]}" \
      --group-ids "$DATA_SG_ID" \
      --output json
  )"

  if [[ "$(echo "$DATA_SG_JSON" | jq '.SecurityGroups | length')" -ne 1 ]] ||
    [[ "$(echo "$DATA_SG_JSON" | jq -r '.SecurityGroups[0].VpcId')" != "$VPC_ID" ]]; then
    fail "Database security group is missing or belongs to the wrong VPC"
  fi

  INTERFACE_ENDPOINT_SG_ID="$(echo "$INTERFACE_ENDPOINT_SGS_JSON" | jq -r '.SecurityGroups[0].GroupId')"

  ALB_SECURITY_GROUP_ID=""

  if [[ "$APPLICATION_LOAD_BALANCER_JSON" != "null" ]]; then
    ALB_SECURITY_GROUP_ID="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.security_group_id // empty')"
  fi
}

validate_service_identity() {
  local service_name="$1"
  local service_response_json="$2"
  local expected_service_arn="$3"
  local expected_service_name="$4"
  local expected_platform_version="$5"
  local expected_task_definition_arn="$6"

  if [[ "$(echo "$service_response_json" | jq '.services | length')" -ne 1 ]]; then
    echo "$service_response_json" | jq .
    fail "Expected ECS service was not returned: ${service_name}"
  fi

  if ! echo "$service_response_json" |
    jq -e \
      --arg arn "$expected_service_arn" \
      --arg name "$expected_service_name" \
      --arg platform_version "$expected_platform_version" \
      --arg cluster_arn "$EXPECTED_CLUSTER_ARN" \
      --arg task_definition_arn "$expected_task_definition_arn" '
        .services[0].serviceArn == $arn
        and .services[0].serviceName == $name
        and .services[0].clusterArn == $cluster_arn
        and .services[0].status == "ACTIVE"
        and .services[0].taskDefinition == $task_definition_arn
        and .services[0].launchType == "FARGATE"
        and .services[0].platformVersion == $platform_version
        and .services[0].deploymentConfiguration.deploymentCircuitBreaker.enable == true
        and .services[0].deploymentConfiguration.deploymentCircuitBreaker.rollback == true

        and .services[0].runningCount == .services[0].desiredCount
        and .services[0].pendingCount == 0

        and any(
          .services[0].deployments[]?;
          .status == "PRIMARY"
          and .rolloutState == "COMPLETED"
        )
      ' >/dev/null; then
    echo "$service_response_json" |
      jq '
        .services[0]
        | {
            serviceArn, serviceName, clusterArn, status, taskDefinition,
            launchType, platformVersion, desiredCount, runningCount,
            pendingCount, deployments, deploymentConfiguration
          }
      '
    fail "ECS service identity, Fargate settings, or deployment safeguards are invalid: ${service_name} (expected platform version ${expected_platform_version})"
  fi
}

validate_service_deployment() {
  local service_name="$1"
  local service_response_json="$2"
  local expected_deployment_minimum_healthy_percent="$3"
  local expected_deployment_maximum_percent="$4"
  local expected_health_check_grace_period_seconds="$5"
  local live_deployment_minimum_healthy_percent
  local live_deployment_maximum_percent
  local live_health_check_grace_period_seconds

  live_deployment_minimum_healthy_percent="$(
    echo "$service_response_json" |
      jq -r '.services[0].deploymentConfiguration.minimumHealthyPercent'
  )"

  live_deployment_maximum_percent="$(
    echo "$service_response_json" |
      jq -r '.services[0].deploymentConfiguration.maximumPercent'
  )"

  live_health_check_grace_period_seconds="$(
    echo "$service_response_json" |
      jq -r '.services[0].healthCheckGracePeriodSeconds'
  )"

  if [[ "$live_deployment_minimum_healthy_percent" -ne "$expected_deployment_minimum_healthy_percent" ]]; then
    fail "ECS deployment minimum healthy percent does not match Terraform: ${service_name} expected=${expected_deployment_minimum_healthy_percent} actual=${live_deployment_minimum_healthy_percent}"
  fi

  if [[ "$live_deployment_maximum_percent" -ne "$expected_deployment_maximum_percent" ]]; then
    fail "ECS deployment maximum percent does not match Terraform: ${service_name} expected=${expected_deployment_maximum_percent} actual=${live_deployment_maximum_percent}"
  fi

  if [[ "$live_health_check_grace_period_seconds" -ne "$expected_health_check_grace_period_seconds" ]]; then
    fail "ECS health-check grace period does not match Terraform: ${service_name} expected=${expected_health_check_grace_period_seconds} actual=${live_health_check_grace_period_seconds}"
  fi

  success "ECS deployment-health settings exactly match Terraform: ${service_name}"
}

validate_service_count_ownership() {
  local service_name="$1"
  local service_response_json="$2"
  local expected_scaling_json="$3"
  local expected_bootstrap_desired_count="$4"
  local live_desired_count
  local expected_min_capacity
  local expected_max_capacity

  live_desired_count="$(
    echo "$service_response_json" |
      jq -r '.services[0].desiredCount'
  )"

  # Autoscaling owns the live count within bounds; Terraform owns fixed counts.
  if [[ "$expected_scaling_json" == "null" ]]; then
    if [[ "$live_desired_count" -ne "$expected_bootstrap_desired_count" ]]; then
      fail "Fixed-count ECS service desiredCount does not match Terraform: ${service_name} expected=${expected_bootstrap_desired_count} actual=${live_desired_count}"
    fi

    success "Terraform owns desiredCount for fixed ECS service: ${service_name}"

  else
    expected_min_capacity="$(
      echo "$expected_scaling_json" |
        jq -r '.min_capacity'
    )"

    expected_max_capacity="$(
      echo "$expected_scaling_json" |
        jq -r '.max_capacity'
    )"

    if ((live_desired_count < expected_min_capacity || \
      live_desired_count > expected_max_capacity)); then
      fail "Autoscaled ECS service desiredCount is outside Terraform scaling bounds: ${service_name} desired=${live_desired_count} min=${expected_min_capacity} max=${expected_max_capacity}"
    fi

    success "Application Auto Scaling owns desiredCount within configured bounds: ${service_name}"
  fi
}

validate_service_networking() {
  local service_name="$1"
  local service_response_json="$2"
  local expected_task_sg_id="$3"
  local service_subnet_ids_json
  local service_sg_ids_json
  local assign_public_ip

  service_subnet_ids_json="$(
    echo "$service_response_json" |
      jq -c '[.services[0].networkConfiguration.awsvpcConfiguration.subnets[]?] | sort | unique'
  )"
  service_sg_ids_json="$(
    echo "$service_response_json" |
      jq -c '[.services[0].networkConfiguration.awsvpcConfiguration.securityGroups[]?] | sort | unique'
  )"
  assign_public_ip="$(
    echo "$service_response_json" |
      jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // empty'
  )"

  if [[ "$service_subnet_ids_json" != "$COMPUTE_SUBNET_IDS_JSON" ]]; then
    jq -n \
      --argjson expected "$COMPUTE_SUBNET_IDS_JSON" \
      --argjson actual "$service_subnet_ids_json" \
      '{expected_compute_subnets: $expected, actual_service_subnets: $actual}'
    fail "ECS service does not use the exact compute-private subnet set: ${service_name}"
  fi

  if [[ "$service_sg_ids_json" != "[\"${expected_task_sg_id}\"]" ]]; then
    jq -n \
      --arg expected "$expected_task_sg_id" \
      --argjson actual "$service_sg_ids_json" \
      '{expected_task_sg: $expected, actual_service_sgs: $actual}'
    fail "ECS service does not use exactly its Terraform task SG: ${service_name}"
  fi

  if [[ "$assign_public_ip" != "DISABLED" ]]; then
    fail "ECS service assignPublicIp is ${assign_public_ip:-<missing>}, expected DISABLED: ${service_name}"
  fi
}

validate_service_logging() {
  local service_name="$1"
  local primary_container_json="$2"
  local expected_log_group_name="$3"
  local expected_log_group_arn="$4"
  local log_groups_response_json
  local live_log_group_json
  local live_log_group_arn
  local normalized_expected_log_group_arn
  local live_log_group_kms_key_arn

  if ! echo "$primary_container_json" |
    jq -e \
      --arg group "$expected_log_group_name" \
      --arg region "$AWS_REGION" '
        .logConfiguration.logDriver == "awslogs"
        and .logConfiguration.options["awslogs-group"] == $group
        and .logConfiguration.options["awslogs-region"] == $region
        and .logConfiguration.options["awslogs-stream-prefix"] == "ecs"
        and .logConfiguration.options.mode == "non-blocking"
        and (.logConfiguration.options | has("awslogs-create-group") | not)
      ' >/dev/null; then
    echo "$primary_container_json" | jq '.logConfiguration'
    fail "Primary container awslogs configuration is invalid: ${service_name}"
  fi

  log_groups_response_json="$(
    aws logs describe-log-groups \
      "${AWS_ARGS[@]}" \
      --log-group-name-prefix "$expected_log_group_name" \
      --output json
  )"

  live_log_group_json="$(
    echo "$log_groups_response_json" |
      jq -c --arg name "$expected_log_group_name" '[.logGroups[] | select(.logGroupName == $name)]'
  )"

  if [[ "$(echo "$live_log_group_json" | jq 'length')" -ne 1 ]]; then
    fail "Expected ECS CloudWatch log group was not found: ${expected_log_group_name}"
  fi

  live_log_group_json="$(echo "$live_log_group_json" | jq -c '.[0]')"
  live_log_group_arn="$(echo "$live_log_group_json" | jq -r '.arn // empty | rtrimstr(":*")')"
  normalized_expected_log_group_arn="$(jq -nr --arg arn "$expected_log_group_arn" '$arn | rtrimstr(":*")')"

  if [[ "$live_log_group_arn" != "$normalized_expected_log_group_arn" ]]; then
    fail "CloudWatch log-group ARN does not match Terraform output: ${service_name}"
  fi

  if [[ "$(echo "$live_log_group_json" | jq -r '.retentionInDays // 0')" -ne "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" ]]; then
    fail "CloudWatch log-group retention does not match effective_cloudwatch_retention_days: ${service_name}"
  fi

  live_log_group_kms_key_arn="$(
    echo "$live_log_group_json" |
      jq -r '.kmsKeyId // empty'
  )"

  if [[ "$live_log_group_kms_key_arn" != "$LOGS_CMK_ARN" ]]; then
    fail "CloudWatch log-group KMS key does not match Terraform logs CMK: ${service_name} expected=${LOGS_CMK_ARN} actual=${live_log_group_kms_key_arn:-<missing>}"
  fi

  success "Task definition image, port, awslogs configuration, and log group are valid: ${service_name}"
}

validate_task_definition() {
  local service_name="$1"
  local expected_task_definition_arn="$2"
  local expected_execution_role_arn="$3"
  local expected_task_role_arn="$4"
  local expected_log_group_name="$5"
  local expected_log_group_arn="$6"
  local task_definition_response_json
  local primary_container_json
  local image_reference
  local image_repository_url
  local repository_match_count
  local port_mappings_json
  local container_port

  task_definition_response_json="$(
    aws ecs describe-task-definition \
      "${AWS_ARGS[@]}" \
      --task-definition "$expected_task_definition_arn" \
      --output json
  )"

  if ! echo "$task_definition_response_json" |
    jq -e \
      --arg arn "$expected_task_definition_arn" \
      --arg execution_role "$expected_execution_role_arn" \
      --arg task_role "$expected_task_role_arn" '
        .taskDefinition.taskDefinitionArn == $arn
        and .taskDefinition.status == "ACTIVE"
        and (.taskDefinition.requiresCompatibilities | index("FARGATE") != null)
        and .taskDefinition.networkMode == "awsvpc"
        and .taskDefinition.runtimePlatform.operatingSystemFamily == "LINUX"
        and (.taskDefinition.runtimePlatform.cpuArchitecture | IN("X86_64", "ARM64"))
        and .taskDefinition.executionRoleArn == $execution_role
        and .taskDefinition.taskRoleArn == $task_role
      ' >/dev/null; then
    echo "$task_definition_response_json" |
      jq '
        .taskDefinition
        | {
            taskDefinitionArn, status, requiresCompatibilities, networkMode,
            runtimePlatform, executionRoleArn, taskRoleArn
          }
      '
    fail "Task definition platform or IAM role contract is invalid: ${service_name}"
  fi

  if ! echo "$task_definition_response_json" |
    jq -e \
      --arg service "$service_name" '
        (.taskDefinition.containerDefinitions | length) == 1
        and .taskDefinition.containerDefinitions[0].name == $service
        and .taskDefinition.containerDefinitions[0].essential == true
      ' >/dev/null; then
    echo "$task_definition_response_json" |
      jq '.taskDefinition.containerDefinitions'

    fail "Task definition must contain exactly one essential container named ${service_name}"
  fi

  primary_container_json="$(
    echo "$task_definition_response_json" |
      jq -c '.taskDefinition.containerDefinitions[0]'
  )"

  image_reference="$(echo "$primary_container_json" | jq -r '.image // empty')"

  if ! [[ "$image_reference" =~ ^.+@sha256:[0-9a-f]{64}$ ]]; then
    fail "Task definition image is not digest pinned: ${service_name} image=${image_reference:-<missing>}"
  fi

  image_repository_url="${image_reference%@sha256:*}"
  repository_match_count="$(
    echo "$ECR_REPOSITORIES_JSON" |
      jq --arg url "$image_repository_url" '[to_entries[] | select(.value.repository_url == $url)] | length'
  )"

  if [[ "$repository_match_count" -ne 1 ]]; then
    fail "Task image repository URL does not match exactly one ecr_repositories output: ${service_name}"
  fi

  port_mappings_json="$(echo "$primary_container_json" | jq -c '.portMappings // []')"

  if ! echo "$port_mappings_json" |
    jq -e '
      length == 1
      and .[0].containerPort >= 1
      and .[0].containerPort <= 65535
      and .[0].hostPort == .[0].containerPort
      and .[0].protocol == "tcp"
    ' >/dev/null; then
    echo "$port_mappings_json" | jq .
    fail "Primary container port mapping is invalid for awsvpc: ${service_name}"
  fi

  container_port="$(echo "$port_mappings_json" | jq -r '.[0].containerPort')"
  SERVICE_CONTAINER_PORTS["$service_name"]="$container_port"

  validate_service_logging \
    "$service_name" \
    "$primary_container_json" \
    "$expected_log_group_name" \
    "$expected_log_group_arn"
}

validate_service_database_access() {
  local service_name="$1"
  local database_access="$2"
  local task_sg_json="$3"
  local expected_task_sg_id="$4"

  if [[ "$database_access" == "true" ]]; then
    if ! ecs_runtime_sg_has_group_rule "$task_sg_json" egress "$DATA_SG_ID" "$RDS_PORT"; then
      fail "Task SG lacks database egress required by database_access=true: ${service_name}"
    fi

    if ! ecs_runtime_sg_has_group_rule "$DATA_SG_JSON" ingress "$expected_task_sg_id" "$RDS_PORT"; then
      fail "Database SG lacks ingress from task SG required by database_access=true: ${service_name}"
    fi

    success "Database SG relationships match database_access=true: ${service_name}"

  else
    if ecs_runtime_sg_has_group_reference "$task_sg_json" egress "$DATA_SG_ID"; then
      fail "Task SG unexpectedly references database SG while database_access=false: ${service_name}"
    fi

    if ecs_runtime_sg_has_group_reference "$DATA_SG_JSON" ingress "$expected_task_sg_id"; then
      fail "Database SG unexpectedly allows task SG while database_access=false: ${service_name}"
    fi

    success "No database SG relationships exist for database_access=false: ${service_name}"
  fi
}

validate_service_security_groups() {
  local service_name="$1"
  local expected_task_sg_id="$2"
  local database_access="$3"
  local service_response_json="$4"
  local expected_ingress_enabled="$5"
  local container_port="$6"
  local task_sg_json
  local internet_https_present
  local has_target_group
  local live_load_balancers_json
  local expected_target_group_arn

  task_sg_json="$(
    aws ec2 describe-security-groups \
      "${AWS_ARGS[@]}" \
      --group-ids "$expected_task_sg_id" \
      --output json
  )"

  if [[ "$(echo "$task_sg_json" | jq '.SecurityGroups | length')" -ne 1 ]] ||
    [[ "$(echo "$task_sg_json" | jq -r '.SecurityGroups[0].VpcId')" != "$VPC_ID" ]]; then
    fail "Task security group is missing or belongs to the wrong VPC: ${service_name}"
  fi
  validate_service_database_access \
    "$service_name" \
    "$database_access" \
    "$task_sg_json" \
    "$expected_task_sg_id"

  if ! ecs_runtime_sg_has_group_rule "$task_sg_json" egress "$INTERFACE_ENDPOINT_SG_ID" 443; then
    fail "Task SG lacks HTTPS egress to the Interface Endpoint SG: ${service_name}"
  fi

  if ! ecs_runtime_sg_has_group_rule "$INTERFACE_ENDPOINT_SGS_JSON" ingress "$expected_task_sg_id" 443; then
    fail "Interface Endpoint SG lacks HTTPS ingress from task SG: ${service_name}"
  fi

  if ! ecs_runtime_sg_has_prefix_list_rule "$task_sg_json" "$S3_PREFIX_LIST_ID" 443; then
    fail "Task SG lacks HTTPS egress to the S3 managed prefix list: ${service_name}"
  fi

  internet_https_present="false"

  if ecs_runtime_sg_has_ipv4_cidr_rule "$task_sg_json" egress "0.0.0.0/0" 443; then
    internet_https_present="true"
  fi

  if [[ "$EFFECTIVE_EGRESS_MODE" == "vpc_endpoints_only" && "$internet_https_present" == "true" ]]; then
    fail "Task SG has generic HTTPS internet egress in vpc_endpoints_only mode: ${service_name}"
  fi

  if [[ "$EFFECTIVE_EGRESS_MODE" != "vpc_endpoints_only" && "$internet_https_present" != "true" ]]; then
    fail "Task SG lacks HTTPS application egress required by effective egress mode ${EFFECTIVE_EGRESS_MODE}: ${service_name}"
  fi

  has_target_group="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -r --arg service "$service_name" 'if type == "object" and (.target_groups | has($service)) then "true" else "false" end'
  )"
  live_load_balancers_json="$(echo "$service_response_json" | jq -c '.services[0].loadBalancers // []')"

  if [[ "$expected_ingress_enabled" == "true" && "$has_target_group" != "true" ]]; then
    fail "ECS service config enables ingress but Terraform exposes no target group: ${service_name}"
  fi

  if [[ "$expected_ingress_enabled" == "false" && "$has_target_group" == "true" ]]; then
    fail "Terraform exposes an ALB target group while ingress_enabled=false: ${service_name}"
  fi

  if [[ "$has_target_group" == "true" ]]; then
    expected_target_group_arn="$(
      echo "$APPLICATION_LOAD_BALANCER_JSON" |
        jq -r --arg service "$service_name" '.target_groups[$service].arn'
    )"
    # shellcheck disable=SC2034 # Consumed by ingress.sh.
    SERVICE_TARGET_GROUP_ARNS["$service_name"]="$expected_target_group_arn"

    if ! echo "$live_load_balancers_json" |
      jq -e --arg arn "$expected_target_group_arn" --arg name "$service_name" --argjson port "$container_port" '
        length == 1
        and .[0].targetGroupArn == $arn
        and .[0].containerName == $name
        and .[0].containerPort == $port
      ' >/dev/null; then
      echo "$live_load_balancers_json" | jq .
      fail "ECS service ALB attachment does not match Terraform target group: ${service_name}"
    fi

    if [[ -z "$ALB_SECURITY_GROUP_ID" ]] ||
      ! ecs_runtime_sg_has_group_rule "$task_sg_json" ingress "$ALB_SECURITY_GROUP_ID" "$container_port"; then
      fail "Task SG lacks ALB ingress on the primary container port: ${service_name}"
    fi

  elif [[ "$(echo "$live_load_balancers_json" | jq 'length')" -ne 0 ]]; then
    fail "ECS service has an unexpected load-balancer attachment: ${service_name}"
  fi

  success "ECS service is healthy at steady state and runtime-critical task SG relationships are valid: ${service_name}"
}

validate_service() {
  local service_name="$1"
  local expected_service_json
  local expected_service_configuration_json
  local expected_bootstrap_desired_count
  local expected_scaling_json
  local expected_deployment_minimum_healthy_percent
  local expected_deployment_maximum_percent
  local expected_health_check_grace_period_seconds
  local expected_service_arn
  local expected_service_name
  local expected_platform_version
  local expected_task_definition_arn
  local expected_task_sg_id
  local database_access
  local expected_ingress_enabled
  local expected_log_group_json
  local expected_log_group_name
  local expected_log_group_arn
  local expected_execution_role_arn
  local expected_task_role_arn
  local service_response_json
  local container_port

  expected_service_json="$(echo "$ECS_SERVICES_JSON" | jq -c --arg service "$service_name" '.[$service]')"

  expected_service_configuration_json="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -c --arg service "$service_name" '.[$service]'
  )"

  expected_bootstrap_desired_count="$(
    echo "$expected_service_configuration_json" |
      jq -r '.desired_count'
  )"

  expected_scaling_json="$(
    echo "$expected_service_configuration_json" |
      jq -c '.scaling'
  )"

  expected_deployment_minimum_healthy_percent="$(
    echo "$expected_service_configuration_json" |
      jq -r '.deployment.minimum_healthy_percent'
  )"

  expected_deployment_maximum_percent="$(
    echo "$expected_service_configuration_json" |
      jq -r '.deployment.maximum_percent'
  )"

  expected_health_check_grace_period_seconds="$(
    echo "$expected_service_configuration_json" |
      jq -r '.deployment.health_check_grace_period_seconds'
  )"

  expected_service_arn="$(echo "$expected_service_json" | jq -r '.arn')"
  expected_service_name="$(echo "$expected_service_json" | jq -r '.name')"
  expected_platform_version="$(echo "$expected_service_json" | jq -r '.platform_version')"
  expected_task_definition_arn="$(
    echo "$TASK_DEFINITION_ARNS_JSON" |
      jq -r --arg service "$service_name" '.[$service]'
  )"
  expected_task_sg_id="$(echo "$TASK_SECURITY_GROUP_IDS_JSON" | jq -r --arg service "$service_name" '.[$service]')"

  database_access="$(
    echo "$expected_service_configuration_json" |
      jq -r '.database_access'
  )"

  expected_ingress_enabled="$(echo "$expected_service_configuration_json" | jq -r '.ingress_enabled')"

  expected_log_group_json="$(echo "$ECS_LOG_GROUPS_JSON" | jq -c --arg service "$service_name" '.[$service]')"
  expected_log_group_name="$(echo "$expected_log_group_json" | jq -r '.name')"
  expected_log_group_arn="$(echo "$expected_log_group_json" | jq -r '.arn')"
  expected_execution_role_arn="$(
    echo "$ECS_EXECUTION_ROLES_JSON" |
      jq -r --arg service "$service_name" '.[$service].arn'
  )"
  expected_task_role_arn="$(echo "$ECS_TASK_ROLES_JSON" | jq -r --arg service "$service_name" '.[$service].arn')"

  info "Validating ECS service: ${service_name}"

  service_response_json="$(
    aws ecs describe-services \
      "${AWS_ARGS[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" \
      --services "$expected_service_arn" \
      --output json
  )"

  validate_service_identity \
    "$service_name" \
    "$service_response_json" \
    "$expected_service_arn" \
    "$expected_service_name" \
    "$expected_platform_version" \
    "$expected_task_definition_arn"

  validate_service_deployment \
    "$service_name" \
    "$service_response_json" \
    "$expected_deployment_minimum_healthy_percent" \
    "$expected_deployment_maximum_percent" \
    "$expected_health_check_grace_period_seconds"

  validate_service_count_ownership \
    "$service_name" \
    "$service_response_json" \
    "$expected_scaling_json" \
    "$expected_bootstrap_desired_count"

  validate_service_networking \
    "$service_name" \
    "$service_response_json" \
    "$expected_task_sg_id"

  validate_task_definition \
    "$service_name" \
    "$expected_task_definition_arn" \
    "$expected_execution_role_arn" \
    "$expected_task_role_arn" \
    "$expected_log_group_name" \
    "$expected_log_group_arn"

  container_port="${SERVICE_CONTAINER_PORTS[$service_name]}"

  validate_service_security_groups \
    "$service_name" \
    "$expected_task_sg_id" \
    "$database_access" \
    "$service_response_json" \
    "$expected_ingress_enabled" \
    "$container_port"
}
