#!/usr/bin/env bash

# validate-ecs-runtime.sh
#
# Validates the deployed ECS/Fargate runtime against workload-root Terraform
# outputs. The root output maps are the authoritative cluster, service, task
# definition, IAM role, task SG, log group, ECR repository, and ALB inventory.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()

if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

json_object_output() {
  local outputs_json="$1"
  local output_name="$2"
  local value

  if ! terraform_output_exists "$outputs_json" "$output_name"; then
    fail "Missing required Terraform output: ${output_name}"
  fi

  value="$(echo "$outputs_json" | jq -c --arg name "$output_name" '.[$name].value')"

  if ! echo "$value" | jq -e 'type == "object"' >/dev/null; then
    fail "Terraform output ${output_name} must be an object"
  fi

  echo "$value"
}

require_same_map_keys() {
  local expected_json="$1"
  local actual_json="$2"
  local description="$3"
  local difference_json

  difference_json="$(
    jq -n \
      --argjson expected "$expected_json" \
      --argjson actual "$actual_json" '
        {
          missing_keys: (($expected | keys) - ($actual | keys)),
          unexpected_keys: (($actual | keys) - ($expected | keys))
        }
      '
  )"

  if ! echo "$difference_json" |
    jq -e '(.missing_keys | length) == 0 and (.unexpected_keys | length) == 0' >/dev/null; then
    echo "$difference_json" | jq .
    fail "Terraform output keys do not match ecs_services for ${description}"
  fi
}

sg_has_group_rule() {
  local sg_json="$1"
  local direction="$2"
  local source_or_destination_sg_id="$3"
  local port="$4"
  local permissions_field="IpPermissions"

  if [[ "$direction" == "egress" ]]; then
    permissions_field="IpPermissionsEgress"
  fi

  echo "$sg_json" |
    jq -e \
      --arg field "$permissions_field" \
      --arg group_id "$source_or_destination_sg_id" \
      --argjson port "$port" '
        .SecurityGroups[0][$field]
        | any(
            .IpProtocol == "tcp"
            and .FromPort == $port
            and .ToPort == $port
            and any(.UserIdGroupPairs[]?; .GroupId == $group_id)
          )
      ' >/dev/null
}

sg_has_group_reference() {
  local sg_json="$1"
  local direction="$2"
  local source_or_destination_sg_id="$3"
  local permissions_field="IpPermissions"

  if [[ "$direction" == "egress" ]]; then
    permissions_field="IpPermissionsEgress"
  fi

  echo "$sg_json" |
    jq -e \
      --arg field "$permissions_field" \
      --arg group_id "$source_or_destination_sg_id" '
        .SecurityGroups[0][$field]
        | any(
            any(.UserIdGroupPairs[]?; .GroupId == $group_id)
          )
      ' >/dev/null
}

sg_has_prefix_list_rule() {
  local sg_json="$1"
  local prefix_list_id="$2"
  local port="$3"

  echo "$sg_json" |
    jq -e \
      --arg prefix_list_id "$prefix_list_id" \
      --argjson port "$port" '
        .SecurityGroups[0].IpPermissionsEgress
        | any(
            .IpProtocol == "tcp"
            and .FromPort == $port
            and .ToPort == $port
            and any(.PrefixListIds[]?; .PrefixListId == $prefix_list_id)
          )
      ' >/dev/null
}

sg_has_ipv4_cidr_rule() {
  local sg_json="$1"
  local direction="$2"
  local cidr="$3"
  local port="$4"
  local permissions_field="IpPermissions"

  if [[ "$direction" == "egress" ]]; then
    permissions_field="IpPermissionsEgress"
  fi

  echo "$sg_json" |
    jq -e \
      --arg field "$permissions_field" \
      --arg cidr "$cidr" \
      --argjson port "$port" '
        .SecurityGroups[0][$field]
        | any(
            .IpProtocol == "tcp"
            and .FromPort == $port
            and .ToPort == $port
            and any(.IpRanges[]?; .CidrIp == $cidr)
          )
      ' >/dev/null
}

section "${CLOUD_NAME} ECS Runtime Validation"

section "Checking required local commands"

require_command aws
require_command terraform
require_command jq
require_command git

success "Required commands are available"

section "Resolving repository paths and Terraform outputs"

REPO_ROOT="$(get_repo_root)"
ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$ENV_NAME")"
require_directory "$ENV_DIR"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

ECS_CLUSTER_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_cluster)"
ECS_SERVICES_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_services)"
ECS_SERVICE_CONFIGURATION_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_service_configuration)"
TASK_DEFINITION_ARNS_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_task_definition_arns)"
TASK_SECURITY_GROUP_IDS_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_task_security_group_ids)"
ECS_LOG_GROUPS_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_log_groups)"
ECS_EXECUTION_ROLES_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_task_execution_roles)"
ECS_TASK_ROLES_JSON="$(json_object_output "$OUTPUTS_JSON" ecs_task_roles)"
ECR_REPOSITORIES_JSON="$(json_object_output "$OUTPUTS_JSON" ecr_repositories)"

for output_name in \
  vpc_id \
  name_prefix \
  s3_prefix_list_id \
  effective_egress_mode \
  effective_cloudwatch_retention_days \
  logs_cmk_arn \
  data_sg_id \
  rds_port; do

  if ! terraform_output_exists "$OUTPUTS_JSON" "$output_name"; then
    fail "Missing required Terraform output: ${output_name}"
  fi
done

VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
S3_PREFIX_LIST_ID="$(get_terraform_output_value "$OUTPUTS_JSON" s3_prefix_list_id)"
EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
LOGS_CMK_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" logs_cmk_arn)"
DATA_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" data_sg_id)"
RDS_PORT="$(get_terraform_output_value "$OUTPUTS_JSON" rds_port)"

APPLICATION_LOAD_BALANCER_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '
      if has("application_load_balancer")
      then .application_load_balancer.value
      else null
      end
    '
)"

NAME_PREFIX="$(get_terraform_output_value "$OUTPUTS_JSON" name_prefix)"

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

require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"

if ! [[ "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  fail "effective_cloudwatch_retention_days is not an integer: ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}"
fi

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

success "ECS Container Insights setting matches Terraform: ${EXPECTED_CONTAINER_INSIGHTS}"

require_same_map_keys "$ECS_SERVICES_JSON" "$TASK_DEFINITION_ARNS_JSON" "task definition ARNs"
require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_SERVICE_CONFIGURATION_JSON" "ECS service configuration"
require_same_map_keys "$ECS_SERVICES_JSON" "$TASK_SECURITY_GROUP_IDS_JSON" "task security groups"
require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_LOG_GROUPS_JSON" "log groups"
require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_EXECUTION_ROLES_JSON" "task execution roles"
require_same_map_keys "$ECS_SERVICES_JSON" "$ECS_TASK_ROLES_JSON" "task roles"

if ! echo "$ECS_SERVICE_CONFIGURATION_JSON" |
  jq -e '
    all(.[];
      type == "object"
      and (.database_access | type) == "boolean"
    )
  ' >/dev/null; then
  fail "ecs_service_configuration must contain boolean database_access for every ECS service"
fi

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

section "Checking AWS caller identity"

ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

if [[ -n "$EXPECTED_ACCOUNT_ID" && "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
fi

success "AWS credentials are valid: ${CALLER_ARN}"

section "Validating environment ECS cluster"

EXPECTED_CLUSTER_ARN="$(echo "$ECS_CLUSTER_JSON" | jq -r '.arn')"
EXPECTED_CLUSTER_NAME="$(echo "$ECS_CLUSTER_JSON" | jq -r '.name')"

CLUSTER_RESPONSE_JSON="$(
  aws ecs describe-clusters \
    "${aws_args[@]}" \
    --clusters "$EXPECTED_CLUSTER_ARN" \
    --include SETTINGS \
    --output json
)"

if [[ "$(echo "$CLUSTER_RESPONSE_JSON" | jq '.clusters | length')" -ne 1 ]]; then
  echo "$CLUSTER_RESPONSE_JSON" | jq .
  fail "Expected ECS cluster was not returned by describe-clusters"
fi

if ! echo "$CLUSTER_RESPONSE_JSON" |
  jq -e \
    --arg arn "$EXPECTED_CLUSTER_ARN" \
    --arg name "$EXPECTED_CLUSTER_NAME" '
      .clusters[0].clusterArn == $arn
      and .clusters[0].clusterName == $name
      and .clusters[0].status == "ACTIVE"
    ' >/dev/null; then
  echo "$CLUSTER_RESPONSE_JSON" | jq '.clusters[0] | {clusterArn, clusterName, status}'
  fail "Live ECS cluster identity or status does not match Terraform output"
fi

success "ECS cluster exists, matches Terraform output, and is ACTIVE"

CONTAINER_INSIGHTS_LIVE_VALUE="$(
  echo "$CLUSTER_RESPONSE_JSON" |
    jq -r '.clusters[0].settings[]? | select(.name == "containerInsights") | .value' |
    head -n 1
)"

EXPECTED_CONTAINER_INSIGHTS="$(
  echo "$ECS_CLUSTER_JSON" |
    jq -r '.container_insights'
)"

if [[ "$CONTAINER_INSIGHTS_LIVE_VALUE" != "$EXPECTED_CONTAINER_INSIGHTS" ]]; then
  fail "ECS Container Insights setting does not match Terraform: expected=${EXPECTED_CONTAINER_INSIGHTS} actual=${CONTAINER_INSIGHTS_LIVE_VALUE:-<missing>}"
fi

success "ECS Container Insights setting matches Terraform: ${EXPECTED_CONTAINER_INSIGHTS}"

LIVE_SERVICE_ARNS_JSON="$(
  aws ecs list-services \
    "${aws_args[@]}" \
    --cluster "$EXPECTED_CLUSTER_ARN" \
    --output json |
    jq -c '[.serviceArns[]?] | sort | unique'
)"

EXPECTED_SERVICE_ARNS_JSON="$(echo "$ECS_SERVICES_JSON" | jq -c '[.[].arn] | sort | unique')"

SERVICE_INVENTORY_DIFFERENCE_JSON="$(
  jq -n \
    --argjson expected "$EXPECTED_SERVICE_ARNS_JSON" \
    --argjson actual "$LIVE_SERVICE_ARNS_JSON" '
      {missing_service_arns: ($expected - $actual), unexpected_service_arns: ($actual - $expected)}
    '
)"

if ! echo "$SERVICE_INVENTORY_DIFFERENCE_JSON" |
  jq -e '(.missing_service_arns | length) == 0 and (.unexpected_service_arns | length) == 0' >/dev/null; then
  echo "$SERVICE_INVENTORY_DIFFERENCE_JSON" | jq .
  fail "Live ECS service inventory does not exactly match ecs_services output"
fi

success "Live ECS service inventory exactly matches Terraform output"

if [[ "$ECS_SERVICE_COUNT" -eq 0 ]]; then
  if [[ "$APPLICATION_LOAD_BALANCER_JSON" != "null" ]]; then
    fail "ecs_services is empty, but application_load_balancer output is not null"
  fi
  section "Validation Result"
  success "ECS cluster is valid and no ECS services are configured; per-service and ALB checks skipped"
  exit 0
fi

section "Resolving accepted live networking identities"

COMPUTE_SUBNETS_JSON="$(
  aws ec2 describe-subnets \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-*" \
    --output json
)"

COMPUTE_SUBNET_IDS_JSON="$(echo "$COMPUTE_SUBNETS_JSON" | jq -c '[.Subnets[].SubnetId] | sort | unique')"

if [[ "$(echo "$COMPUTE_SUBNET_IDS_JSON" | jq 'length')" -eq 0 ]]; then
  fail "No compute-private subnets were resolved for ECS service placement validation"
fi

INTERFACE_ENDPOINT_SGS_JSON="$(
  aws ec2 describe-security-groups \
    "${aws_args[@]}" \
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
    "${aws_args[@]}" \
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

declare -A SERVICE_CONTAINER_PORTS=()
declare -A SERVICE_TARGET_GROUP_ARNS=()

section "Validating ECS services, task definitions, logs, and task security groups"

while IFS= read -r service_name; do
  expected_service_json="$(echo "$ECS_SERVICES_JSON" | jq -c --arg service "$service_name" '.[$service]')"
  expected_service_arn="$(echo "$expected_service_json" | jq -r '.arn')"
  expected_service_name="$(echo "$expected_service_json" | jq -r '.name')"
  expected_platform_version="$(echo "$expected_service_json" | jq -r '.platform_version')"
  expected_task_definition_arn="$(echo "$TASK_DEFINITION_ARNS_JSON" | jq -r --arg service "$service_name" '.[$service]')"
  expected_task_sg_id="$(echo "$TASK_SECURITY_GROUP_IDS_JSON" | jq -r --arg service "$service_name" '.[$service]')"
  database_access="$(
    echo "$ECS_SERVICE_CONFIGURATION_JSON" |
      jq -r --arg service "$service_name" '.[$service].database_access'
  )"

  expected_log_group_json="$(echo "$ECS_LOG_GROUPS_JSON" | jq -c --arg service "$service_name" '.[$service]')"
  expected_log_group_name="$(echo "$expected_log_group_json" | jq -r '.name')"
  expected_log_group_arn="$(echo "$expected_log_group_json" | jq -r '.arn')"
  expected_execution_role_arn="$(echo "$ECS_EXECUTION_ROLES_JSON" | jq -r --arg service "$service_name" '.[$service].arn')"
  expected_task_role_arn="$(echo "$ECS_TASK_ROLES_JSON" | jq -r --arg service "$service_name" '.[$service].arn')"

  info "Validating ECS service: ${service_name}"

  service_response_json="$(
    aws ecs describe-services \
      "${aws_args[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" \
      --services "$expected_service_arn" \
      --output json
  )"

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
    echo "$service_response_json" | jq '.services[0] | {serviceArn, serviceName, clusterArn, status, taskDefinition, launchType, platformVersion, desiredCount, runningCount, pendingCount, deployments, deploymentConfiguration}'
    fail "ECS service identity, Fargate settings, or deployment safeguards are invalid: ${service_name} (expected platform version ${expected_platform_version})"
  fi

  service_subnet_ids_json="$(echo "$service_response_json" | jq -c '[.services[0].networkConfiguration.awsvpcConfiguration.subnets[]?] | sort | unique')"
  service_sg_ids_json="$(echo "$service_response_json" | jq -c '[.services[0].networkConfiguration.awsvpcConfiguration.securityGroups[]?] | sort | unique')"
  assign_public_ip="$(echo "$service_response_json" | jq -r '.services[0].networkConfiguration.awsvpcConfiguration.assignPublicIp // empty')"

  if [[ "$service_subnet_ids_json" != "$COMPUTE_SUBNET_IDS_JSON" ]]; then
    jq -n --argjson expected "$COMPUTE_SUBNET_IDS_JSON" --argjson actual "$service_subnet_ids_json" '{expected_compute_subnets: $expected, actual_service_subnets: $actual}'
    fail "ECS service does not use the exact compute-private subnet set: ${service_name}"
  fi

  if [[ "$service_sg_ids_json" != "[\"${expected_task_sg_id}\"]" ]]; then
    jq -n --arg expected "$expected_task_sg_id" --argjson actual "$service_sg_ids_json" '{expected_task_sg: $expected, actual_service_sgs: $actual}'
    fail "ECS service does not use exactly its Terraform task SG: ${service_name}"
  fi

  if [[ "$assign_public_ip" != "DISABLED" ]]; then
    fail "ECS service assignPublicIp is ${assign_public_ip:-<missing>}, expected DISABLED: ${service_name}"
  fi

  task_definition_response_json="$(
    aws ecs describe-task-definition \
      "${aws_args[@]}" \
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
    echo "$task_definition_response_json" | jq '.taskDefinition | {taskDefinitionArn, status, requiresCompatibilities, networkMode, runtimePlatform, executionRoleArn, taskRoleArn}'
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
      "${aws_args[@]}" \
      --log-group-name-prefix "$expected_log_group_name" \
      --output json
  )"

  live_log_group_json="$(echo "$log_groups_response_json" | jq -c --arg name "$expected_log_group_name" '[.logGroups[] | select(.logGroupName == $name)]')"
  
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

  task_sg_json="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --group-ids "$expected_task_sg_id" \
      --output json
  )"

  if [[ "$(echo "$task_sg_json" | jq '.SecurityGroups | length')" -ne 1 ]] ||
    [[ "$(echo "$task_sg_json" | jq -r '.SecurityGroups[0].VpcId')" != "$VPC_ID" ]]; then
    fail "Task security group is missing or belongs to the wrong VPC: ${service_name}"
  fi

  if [[ "$database_access" == "true" ]]; then
    if ! sg_has_group_rule "$task_sg_json" egress "$DATA_SG_ID" "$RDS_PORT"; then
      fail "Task SG lacks database egress required by database_access=true: ${service_name}"
    fi

    if ! sg_has_group_rule "$DATA_SG_JSON" ingress "$expected_task_sg_id" "$RDS_PORT"; then
      fail "Database SG lacks ingress from task SG required by database_access=true: ${service_name}"
    fi

    success "Database SG relationships match database_access=true: ${service_name}"

  else
    if sg_has_group_reference "$task_sg_json" egress "$DATA_SG_ID"; then
      fail "Task SG unexpectedly references database SG while database_access=false: ${service_name}"
    fi

    if sg_has_group_reference "$DATA_SG_JSON" ingress "$expected_task_sg_id"; then
      fail "Database SG unexpectedly allows task SG while database_access=false: ${service_name}"
    fi

    success "No database SG relationships exist for database_access=false: ${service_name}"
  fi

  if ! sg_has_group_rule "$task_sg_json" egress "$INTERFACE_ENDPOINT_SG_ID" 443; then
    fail "Task SG lacks HTTPS egress to the Interface Endpoint SG: ${service_name}"
  fi

  if ! sg_has_group_rule "$INTERFACE_ENDPOINT_SGS_JSON" ingress "$expected_task_sg_id" 443; then
    fail "Interface Endpoint SG lacks HTTPS ingress from task SG: ${service_name}"
  fi

  if ! sg_has_prefix_list_rule "$task_sg_json" "$S3_PREFIX_LIST_ID" 443; then
    fail "Task SG lacks HTTPS egress to the S3 managed prefix list: ${service_name}"
  fi

  internet_https_present="false"

  if sg_has_ipv4_cidr_rule "$task_sg_json" egress "0.0.0.0/0" 443; then
    internet_https_present="true"
  fi

  if [[ "$EFFECTIVE_EGRESS_MODE" == "vpc_endpoints_only" && "$internet_https_present" == "true" ]]; then
    fail "Task SG has generic HTTPS internet egress in vpc_endpoints_only mode: ${service_name}"
  fi

  if [[ "$EFFECTIVE_EGRESS_MODE" != "vpc_endpoints_only" && "$internet_https_present" != "true" ]]; then
    fail "Task SG lacks HTTPS application egress required by effective egress mode ${EFFECTIVE_EGRESS_MODE}: ${service_name}"
  fi

  has_target_group="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r --arg service "$service_name" 'if type == "object" and (.target_groups | has($service)) then "true" else "false" end')"
  live_load_balancers_json="$(echo "$service_response_json" | jq -c '.services[0].loadBalancers // []')"

  if [[ "$has_target_group" == "true" ]]; then

    expected_target_group_arn="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r --arg service "$service_name" '.target_groups[$service].arn')"
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
      ! sg_has_group_rule "$task_sg_json" ingress "$ALB_SECURITY_GROUP_ID" "$container_port"; then
      fail "Task SG lacks ALB ingress on the primary container port: ${service_name}"
    fi

  elif [[ "$(echo "$live_load_balancers_json" | jq 'length')" -ne 0 ]]; then
    fail "ECS service has an unexpected load-balancer attachment: ${service_name}"
  fi

  success "ECS service is healthy at steady state and runtime-critical task SG relationships are valid: ${service_name}"
done < <(echo "$ECS_SERVICES_JSON" | jq -r 'keys[]')

section "Validating conditional shared Application Load Balancer"

if [[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]]; then
  if [[ "${#SERVICE_TARGET_GROUP_ARNS[@]}" -ne 0 ]]; then
    fail "Service target groups were detected while application_load_balancer output is null"
  fi

  success "No ALB is configured; ALB validation skipped"

else
  EXPECTED_ALB_ARN="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.arn')"
  EXPECTED_ALB_DNS_NAME="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.dns_name')"
  EXPECTED_ALB_LISTENER_ARN="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.https_listener.arn')"

  EXPECTED_ALB_CERTIFICATE_ARN="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -r '.https_listener.certificate_arn'
  )"

  EXPECTED_ALB_SSL_POLICY="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -r '.https_listener.ssl_policy'
  )"

  alb_response_json="$(
    aws elbv2 describe-load-balancers \
      "${aws_args[@]}" \
      --load-balancer-arns "$EXPECTED_ALB_ARN" \
      --output json
  )"

  if ! echo "$alb_response_json" |
    jq -e \
      --arg arn "$EXPECTED_ALB_ARN" \
      --arg dns_name "$EXPECTED_ALB_DNS_NAME" \
      --arg vpc "$VPC_ID" \
      --arg sg "$ALB_SECURITY_GROUP_ID" '
        (.LoadBalancers | length) == 1
        and .LoadBalancers[0].LoadBalancerArn == $arn
        and .LoadBalancers[0].DNSName == $dns_name
        and .LoadBalancers[0].Type == "application"
        and .LoadBalancers[0].Scheme == "internet-facing"
        and .LoadBalancers[0].VpcId == $vpc
        and .LoadBalancers[0].State.Code == "active"
        and ([.LoadBalancers[0].SecurityGroups[]] | sort | unique) == [$sg]
      ' >/dev/null; then
    echo "$alb_response_json" | jq '.LoadBalancers[0]'
    fail "Shared ALB identity, type, scheme, VPC, state, or SG is invalid"
  fi

  PUBLIC_SUBNETS_JSON="$(
    aws ec2 describe-subnets \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=tag:Name,Values=${NAME_PREFIX}-Public-*" \
      --output json
  )"

  expected_public_subnets_json="$(echo "$PUBLIC_SUBNETS_JSON" | jq -c '[.Subnets[].SubnetId] | sort | unique')"
  actual_alb_subnets_json="$(echo "$alb_response_json" | jq -c '[.LoadBalancers[0].AvailabilityZones[].SubnetId] | sort | unique')"

  if [[ "$(echo "$expected_public_subnets_json" | jq 'length')" -eq 0 ]]; then
    fail "No public subnets were resolved for ALB placement validation"
  fi

  if [[ "$expected_public_subnets_json" != "$actual_alb_subnets_json" ]]; then
    fail "Shared ALB does not use the exact public subnet set"
  fi

  alb_sg_json="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --group-ids "$ALB_SECURITY_GROUP_ID" \
      --output json
  )"

  if [[ "$(echo "$alb_sg_json" | jq -r '.SecurityGroups[0].VpcId // empty')" != "$VPC_ID" ]] ||
    ! echo "$alb_sg_json" | jq -e '.SecurityGroups | length == 1' >/dev/null; then
    fail "ALB security group is missing or belongs to the wrong VPC"
  fi

  if ! echo "$alb_sg_json" |
    jq -e '.SecurityGroups[0].IpPermissions | any(.IpProtocol == "tcp" and .FromPort == 443 and .ToPort == 443 and (.IpRanges | length) > 0)' >/dev/null; then
    fail "ALB SG lacks CIDR-based HTTPS ingress"
  fi

  listeners_response_json="$(
    aws elbv2 describe-listeners \
      "${aws_args[@]}" \
      --load-balancer-arn "$EXPECTED_ALB_ARN" \
      --output json
  )"

  if ! echo "$listeners_response_json" |
    jq -e \
      --arg listener_arn "$EXPECTED_ALB_LISTENER_ARN" \
      --arg certificate_arn "$EXPECTED_ALB_CERTIFICATE_ARN" \
      --arg ssl_policy "$EXPECTED_ALB_SSL_POLICY" '
        (.Listeners | length) == 1
        and .Listeners[0].ListenerArn == $listener_arn
        and .Listeners[0].Port == 443
        and .Listeners[0].Protocol == "HTTPS"
        and (.Listeners[0].Certificates | length) == 1
        and .Listeners[0].Certificates[0].CertificateArn == $certificate_arn
        and .Listeners[0].SslPolicy == $ssl_policy
        and (.Listeners[0].DefaultActions | length) == 1
        and .Listeners[0].DefaultActions[0].Type == "fixed-response"
        and .Listeners[0].DefaultActions[0].FixedResponseConfig.StatusCode == "404"
      ' >/dev/null; then
    echo "$listeners_response_json" | jq '.Listeners'
    fail "ALB HTTPS listener ARN, certificate, TLS policy, or fixed 404 default action does not match Terraform"
  fi

  rules_response_json="$(
    aws elbv2 describe-rules \
      "${aws_args[@]}" \
      --listener-arn "$EXPECTED_ALB_LISTENER_ARN" \
      --output json
  )"

  while IFS= read -r service_name; do
    target_group_json="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -c --arg service "$service_name" '.target_groups[$service]')"
    expected_target_group_arn="$(echo "$target_group_json" | jq -r '.arn')"
    expected_target_group_name="$(echo "$target_group_json" | jq -r '.name')"
    target_group_response_json="$(
      aws elbv2 describe-target-groups \
        "${aws_args[@]}" \
        --target-group-arns "$expected_target_group_arn" \
        --output json
    )"

    if ! echo "$target_group_response_json" |
      jq -e \
        --arg arn "$expected_target_group_arn" \
        --arg name "$expected_target_group_name" \
        --arg vpc "$VPC_ID" \
        --argjson port "${SERVICE_CONTAINER_PORTS[$service_name]}" '
          (.TargetGroups | length) == 1
          and .TargetGroups[0].TargetGroupArn == $arn
          and .TargetGroups[0].TargetGroupName == $name
          and .TargetGroups[0].TargetType == "ip"
          and .TargetGroups[0].VpcId == $vpc
          and .TargetGroups[0].Protocol == "HTTP"
          and .TargetGroups[0].Port == $port
          and .TargetGroups[0].HealthCheckEnabled == true
          and .TargetGroups[0].HealthCheckProtocol == "HTTP"
          and .TargetGroups[0].HealthCheckPort == "traffic-port"
        ' >/dev/null; then
      echo "$target_group_response_json" | jq '.TargetGroups'
      fail "ALB target group is invalid for service ${service_name}"
    fi

    if ! echo "$rules_response_json" |
      jq -e --arg arn "$expected_target_group_arn" '
        [
          .Rules[]
          | select(.IsDefault != true)
          | select(any(.Actions[]?; .Type == "forward" and (.TargetGroupArn == $arn or any(.ForwardConfig.TargetGroups[]?; .TargetGroupArn == $arn))))
          | select((.Conditions | length) > 0)
          | select(all(.Conditions[]; (.Field == "host-header" or .Field == "path-pattern") and ((.Values // []) | length) > 0))
        ]
        | length == 1
      ' >/dev/null; then
      echo "$rules_response_json" | jq '.Rules'
      fail "Expected exactly one meaningful listener rule forwarding to ${service_name} target group"
    fi

    if ! sg_has_group_rule "$alb_sg_json" egress "$(echo "$TASK_SECURITY_GROUP_IDS_JSON" | jq -r --arg service "$service_name" '.[$service]')" "${SERVICE_CONTAINER_PORTS[$service_name]}"; then
      fail "ALB SG lacks egress to task SG on the service container port: ${service_name}"
    fi

    success "ALB target group, listener rule, and SG relationship are valid: ${service_name}"

  done < <(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.target_groups | keys[]')

  success "Shared Application Load Balancer runtime is valid"

fi

section "ECS Runtime Summary"
cat <<SUMMARY
Environment:                       ${ENV_NAME}
AWS account ID:                    ${ACCOUNT_ID}
AWS region:                        ${AWS_REGION}
ECS cluster:                       ${EXPECTED_CLUSTER_NAME}
Configured ECS services:           ${ECS_SERVICE_COUNT}
Effective egress mode:             ${EFFECTIVE_EGRESS_MODE}
CloudWatch retention days:         ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS}
Application Load Balancer present: $([[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]] && echo false || echo true)
SUMMARY

section "Validation Result"

success "ECS runtime validation completed successfully for: ${ENV_NAME}"
