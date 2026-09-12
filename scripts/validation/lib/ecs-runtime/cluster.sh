#!/usr/bin/env bash

# Internal ECS runtime cluster helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_validate_cluster() {
  local cluster_response_json

  section "Validating environment ECS cluster"

  EXPECTED_CLUSTER_ARN="$(echo "$ECS_CLUSTER_JSON" | jq -r '.arn')"
  EXPECTED_CLUSTER_NAME="$(echo "$ECS_CLUSTER_JSON" | jq -r '.name')"

  cluster_response_json="$(
    aws ecs describe-clusters \
      "${AWS_ARGS[@]}" \
      --clusters "$EXPECTED_CLUSTER_ARN" \
      --include SETTINGS \
      --output json
  )"

  if [[ "$(echo "$cluster_response_json" | jq '.clusters | length')" -ne 1 ]]; then
    echo "$cluster_response_json" | jq .
    fail "Expected ECS cluster was not returned by describe-clusters"
  fi

  if ! echo "$cluster_response_json" |
    jq -e \
      --arg arn "$EXPECTED_CLUSTER_ARN" \
      --arg name "$EXPECTED_CLUSTER_NAME" '
        .clusters[0].clusterArn == $arn
        and .clusters[0].clusterName == $name
        and .clusters[0].status == "ACTIVE"
      ' >/dev/null; then
    echo "$cluster_response_json" | jq '.clusters[0] | {clusterArn, clusterName, status}'
    fail "Live ECS cluster identity or status does not match Terraform output"
  fi

  success "ECS cluster exists, matches Terraform output, and is ACTIVE"

  validate_container_insights "$cluster_response_json"
  validate_service_inventory

  # Preserve the cluster-only success path when Terraform configures no services.
  if [[ "$ECS_SERVICE_COUNT" -eq 0 ]]; then
    if [[ "$APPLICATION_LOAD_BALANCER_JSON" != "null" ]]; then
      fail "ecs_services is empty, but application_load_balancer output is not null"
    fi
    section "Validation Result"
    success "ECS cluster is valid and no ECS services are configured; per-service and ALB checks skipped"
    exit 0
  fi
}

validate_container_insights_log_group() {
  local expected_container_insights="$1"
  local expected_container_insights_log_group_json
  local expected_container_insights_log_group_name
  local expected_container_insights_log_group_arn
  local expected_container_insights_log_group_retention
  local expected_container_insights_log_group_kms_key_arn
  local container_insights_log_groups_response_json
  local live_container_insights_log_group_json
  local live_container_insights_log_group_arn
  local normalized_expected_container_insights_log_group_arn
  local live_container_insights_retention
  local live_container_insights_kms_key_arn

  expected_container_insights_log_group_json="$(
    echo "$ECS_CLUSTER_JSON" |
      jq -c '.container_insights_log_group'
  )"

  if [[ "$expected_container_insights" == "disabled" ]]; then
    if [[ "$expected_container_insights_log_group_json" != "null" ]]; then
      fail "Container Insights is disabled but Terraform exposes a managed performance log group"
    fi

    success "Container Insights performance log group is absent as expected when disabled"

  else
    expected_container_insights_log_group_name="$(
      echo "$expected_container_insights_log_group_json" |
        jq -r '.name'
    )"

    expected_container_insights_log_group_arn="$(
      echo "$expected_container_insights_log_group_json" |
        jq -r '.arn'
    )"

    expected_container_insights_log_group_retention="$(
      echo "$expected_container_insights_log_group_json" |
        jq -r '.retention_in_days'
    )"

    expected_container_insights_log_group_kms_key_arn="$(
      echo "$expected_container_insights_log_group_json" |
        jq -r '.kms_key_id'
    )"

    if [[ "$expected_container_insights_log_group_retention" -ne "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" ]]; then
      fail "Container Insights log-group Terraform retention does not match effective_cloudwatch_retention_days"
    fi

    if [[ "$expected_container_insights_log_group_kms_key_arn" != "$LOGS_CMK_ARN" ]]; then
      fail "Container Insights log-group Terraform KMS key does not match logs_cmk_arn"
    fi

    container_insights_log_groups_response_json="$(
      aws logs describe-log-groups \
        "${AWS_ARGS[@]}" \
        --log-group-name-prefix "$expected_container_insights_log_group_name" \
        --output json
    )"

    live_container_insights_log_group_json="$(
      echo "$container_insights_log_groups_response_json" |
        jq -c \
          --arg name "$expected_container_insights_log_group_name" \
          '[.logGroups[]? | select(.logGroupName == $name)]'
    )"

    if [[ "$(echo "$live_container_insights_log_group_json" | jq 'length')" -ne 1 ]]; then
      echo "$live_container_insights_log_group_json" | jq .
      fail "Expected exactly one Container Insights performance log group"
    fi

    live_container_insights_log_group_json="$(
      echo "$live_container_insights_log_group_json" |
        jq -c '.[0]'
    )"

    live_container_insights_log_group_arn="$(
      echo "$live_container_insights_log_group_json" |
        jq -r '.arn // empty | rtrimstr(":*")'
    )"

    normalized_expected_container_insights_log_group_arn="$(
      jq -nr \
        --arg arn "$expected_container_insights_log_group_arn" \
        '$arn | rtrimstr(":*")'
    )"

    if [[ "$live_container_insights_log_group_arn" != "$normalized_expected_container_insights_log_group_arn" ]]; then
      fail "Container Insights performance log-group ARN does not match Terraform output"
    fi

    live_container_insights_retention="$(
      echo "$live_container_insights_log_group_json" |
        jq -r '.retentionInDays // 0'
    )"

    if [[ "$live_container_insights_retention" -ne "$expected_container_insights_log_group_retention" ]]; then
      fail "Container Insights performance log-group retention does not match Terraform"
    fi

    live_container_insights_kms_key_arn="$(
      echo "$live_container_insights_log_group_json" |
        jq -r '.kmsKeyId // empty'
    )"

    if [[ "$live_container_insights_kms_key_arn" != "$expected_container_insights_log_group_kms_key_arn" ]]; then
      fail "Container Insights performance log-group KMS key does not match Terraform"
    fi

    success "Container Insights performance log group retention and KMS encryption match Terraform"
  fi
}

validate_container_insights() {
  local cluster_response_json="$1"
  local container_insights_live_value
  local expected_container_insights

  container_insights_live_value="$(
    echo "$cluster_response_json" |
      jq -r '.clusters[0].settings[]? | select(.name == "containerInsights") | .value' |
      head -n 1
  )"

  expected_container_insights="$(
    echo "$ECS_CLUSTER_JSON" |
      jq -r '.container_insights'
  )"

  # Keep contract membership checks at the original Container Insights stage.
  ecs_runtime_validate_alarm_output_membership "$expected_container_insights"

  if [[ "$container_insights_live_value" != "$expected_container_insights" ]]; then
    fail "ECS Container Insights setting does not match Terraform: expected=${expected_container_insights} actual=${container_insights_live_value:-<missing>}"
  fi

  success "ECS Container Insights setting matches Terraform: ${expected_container_insights}"

  validate_container_insights_log_group "$expected_container_insights"
}

validate_service_inventory() {
  local live_service_arns_json
  local expected_service_arns_json
  local service_inventory_difference_json

  live_service_arns_json="$(
    aws ecs list-services \
      "${AWS_ARGS[@]}" \
      --cluster "$EXPECTED_CLUSTER_ARN" \
      --output json |
      jq -c '[.serviceArns[]?] | sort | unique'
  )"

  expected_service_arns_json="$(echo "$ECS_SERVICES_JSON" | jq -c '[.[].arn] | sort | unique')"

  service_inventory_difference_json="$(
    jq -n \
      --argjson expected "$expected_service_arns_json" \
      --argjson actual "$live_service_arns_json" '
        {missing_service_arns: ($expected - $actual), unexpected_service_arns: ($actual - $expected)}
      '
  )"

  if ! echo "$service_inventory_difference_json" |
    jq -e '(.missing_service_arns | length) == 0 and (.unexpected_service_arns | length) == 0' >/dev/null; then
    echo "$service_inventory_difference_json" | jq .
    fail "Live ECS service inventory does not exactly match ecs_services output"
  fi

  success "Live ECS service inventory exactly matches Terraform output"
}
