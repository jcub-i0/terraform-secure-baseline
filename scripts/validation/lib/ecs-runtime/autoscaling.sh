#!/usr/bin/env bash

# Internal ECS runtime autoscaling helpers; sourced by validate-ecs-runtime.sh.

validate_target_tracking_policy() {
  local service_name="$1"
  local policy_description="$2"
  local expected_policy_json="$3"
  local live_policies_json="$4"

  local expected_policy_name
  local expected_resource_id
  local live_policy_matches_json
  local live_policy_json

  expected_policy_name="$(
    echo "$expected_policy_json" |
      jq -r '.name'
  )"

  expected_resource_id="$(
    echo "$expected_policy_json" |
      jq -r '.resource_id'
  )"

  live_policy_matches_json="$(
    echo "$live_policies_json" |
      jq -c \
        --arg name "$expected_policy_name" \
        --arg resource_id "$expected_resource_id" '
          [
            .ScalingPolicies[]?
            | select(
                .PolicyName == $name
                and .ResourceId == $resource_id
              )
          ]
        '
  )"

  if [[ "$(echo "$live_policy_matches_json" | jq 'length')" -ne 1 ]]; then
    echo "$live_policy_matches_json" | jq .
    fail "Expected exactly one ${policy_description} scaling policy for ${service_name}"
  fi

  live_policy_json="$(
    echo "$live_policy_matches_json" |
      jq -c '.[0]'
  )"

  if ! echo "$live_policy_json" |
    jq -e \
      --argjson expected "$expected_policy_json" '
        .PolicyARN == $expected.arn
        and .PolicyName == $expected.name
        and .PolicyType == $expected.policy_type
        and .ResourceId == $expected.resource_id
        and .ScalableDimension == $expected.scalable_dimension
        and .ServiceNamespace == $expected.service_namespace

        and (
          .TargetTrackingScalingPolicyConfiguration.TargetValue
          == $expected.target_value
        )

        and (
          .TargetTrackingScalingPolicyConfiguration.ScaleInCooldown
          == $expected.scale_in_cooldown
        )

        and (
          .TargetTrackingScalingPolicyConfiguration.ScaleOutCooldown
          == $expected.scale_out_cooldown
        )

        and (
          .TargetTrackingScalingPolicyConfiguration
          .PredefinedMetricSpecification
          .PredefinedMetricType
          == $expected.predefined_metric_type
        )

        and (
          (
            .TargetTrackingScalingPolicyConfiguration
            .PredefinedMetricSpecification
            .ResourceLabel // null
          )
          ==
          ($expected.resource_label // null)
        )

        and (
          .TargetTrackingScalingPolicyConfiguration
          .CustomizedMetricSpecification // null
        ) == null
      ' >/dev/null; then
    echo "$live_policy_json" |
      jq '{
        PolicyARN,
        PolicyName,
        PolicyType,
        ResourceId,
        ScalableDimension,
        ServiceNamespace,
        TargetTrackingScalingPolicyConfiguration
      }'

    fail "${policy_description} scaling policy does not exactly match Terraform: ${service_name}"
  fi

  success "${policy_description} scaling policy exactly matches Terraform: ${service_name}"
}

ecs_runtime_validate_autoscaling() {
  local live_scalable_targets_json
  local live_scaling_policies_json
  local service_name

  section "Validating ECS Application Auto Scaling"

  live_scalable_targets_json="$(
    aws application-autoscaling describe-scalable-targets \
      "${AWS_ARGS[@]}" \
      --service-namespace ecs \
      --output json
  )"

  validate_scalable_target_inventory "$live_scalable_targets_json"

  while IFS= read -r service_name; do
    validate_scalable_target "$service_name" "$live_scalable_targets_json"
  done < <(echo "$ECS_AUTOSCALING_TARGETS_JSON" | jq -r 'keys[]')

  live_scaling_policies_json="$(
    aws application-autoscaling describe-scaling-policies \
      "${AWS_ARGS[@]}" \
      --service-namespace ecs \
      --output json
  )"

  validate_scaling_policy_inventory "$live_scaling_policies_json"

  validate_scaling_policies "$live_scaling_policies_json"

  success "ECS Application Auto Scaling runtime exactly matches Terraform"
}

validate_scalable_target_inventory() {
  local live_scalable_targets_json="$1"
  local expected_scalable_resource_ids_json
  local live_cluster_scalable_resource_ids_json

  expected_scalable_resource_ids_json="$(
    echo "$ECS_AUTOSCALING_TARGETS_JSON" |
      jq -c '[.[].resource_id] | sort | unique'
  )"

  live_cluster_scalable_resource_ids_json="$(
    echo "$live_scalable_targets_json" |
      jq -c \
        --arg prefix "service/${EXPECTED_CLUSTER_NAME}/" '
          [
            .ScalableTargets[]?
            | select(.ResourceId | startswith($prefix))
            | select(.ScalableDimension == "ecs:service:DesiredCount")
            | .ResourceId
          ]
          | sort
          | unique
        '
  )"

  if [[ "$expected_scalable_resource_ids_json" != "$live_cluster_scalable_resource_ids_json" ]]; then
    jq -n \
      --argjson expected "$expected_scalable_resource_ids_json" \
      --argjson actual "$live_cluster_scalable_resource_ids_json" \
      '{
        expected_scalable_targets: $expected,
        actual_scalable_targets: $actual
      }'

    fail "Application Auto Scaling target inventory does not exactly match Terraform"
  fi

  success "Application Auto Scaling target inventory exactly matches Terraform"
}

validate_scalable_target() {
  local service_name="$1"
  local live_scalable_targets_json="$2"
  local expected_target_json
  local expected_resource_id
  local live_target_matches_json
  local live_target_json

  expected_target_json="$(
    echo "$ECS_AUTOSCALING_TARGETS_JSON" |
      jq -c --arg service "$service_name" '.[$service]'
  )"

  expected_resource_id="$(
    echo "$expected_target_json" |
      jq -r '.resource_id'
  )"

  live_target_matches_json="$(
    echo "$live_scalable_targets_json" |
      jq -c \
        --arg resource_id "$expected_resource_id" '
          [
            .ScalableTargets[]?
            | select(.ResourceId == $resource_id)
          ]
        '
  )"

  if [[ "$(echo "$live_target_matches_json" | jq 'length')" -ne 1 ]]; then
    echo "$live_target_matches_json" | jq .
    fail "Expected exactly one Application Auto Scaling target: ${service_name}"
  fi

  live_target_json="$(
    echo "$live_target_matches_json" |
      jq -c '.[0]'
  )"

  if ! echo "$live_target_json" |
    jq -e \
      --argjson expected "$expected_target_json" '
        .ScalableTargetARN == $expected.arn
        and .ResourceId == $expected.resource_id
        and .ScalableDimension == $expected.scalable_dimension
        and .ServiceNamespace == $expected.service_namespace
        and .MinCapacity == $expected.min_capacity
        and .MaxCapacity == $expected.max_capacity

        and (.SuspendedState.DynamicScalingInSuspended // false) == false
        and (.SuspendedState.DynamicScalingOutSuspended // false) == false
        and (.SuspendedState.ScheduledScalingSuspended // false) == false
      ' >/dev/null; then
    echo "$live_target_json" | jq .
    fail "Application Auto Scaling target does not exactly match Terraform: ${service_name}"
  fi

  success "Application Auto Scaling target exactly matches Terraform: ${service_name}"
}

validate_scaling_policy_inventory() {
  local live_scaling_policies_json="$1"
  local expected_scaling_policy_identities_json
  local live_cluster_scaling_policy_identities_json

  expected_scaling_policy_identities_json="$(
    jq -c -n \
      --argjson cpu "$ECS_AUTOSCALING_CPU_POLICIES_JSON" \
      --argjson memory "$ECS_AUTOSCALING_MEMORY_POLICIES_JSON" \
      --argjson alb "$ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON" '
        [
          ($cpu[]?    | "\(.resource_id)|\(.name)"),
          ($memory[]? | "\(.resource_id)|\(.name)"),
          ($alb[]?    | "\(.resource_id)|\(.name)")
        ]
        | sort
        | unique
      '
  )"

  live_cluster_scaling_policy_identities_json="$(
    echo "$live_scaling_policies_json" |
      jq -c \
        --arg prefix "service/${EXPECTED_CLUSTER_NAME}/" '
          [
            .ScalingPolicies[]?
            | select(.ResourceId | startswith($prefix))
            | select(.ScalableDimension == "ecs:service:DesiredCount")
            | "\(.ResourceId)|\(.PolicyName)"
          ]
          | sort
          | unique
        '
  )"

  if [[ "$expected_scaling_policy_identities_json" != "$live_cluster_scaling_policy_identities_json" ]]; then
    jq -n \
      --argjson expected "$expected_scaling_policy_identities_json" \
      --argjson actual "$live_cluster_scaling_policy_identities_json" \
      '{
        expected_scaling_policies: $expected,
        actual_scaling_policies: $actual
      }'

    fail "Application Auto Scaling policy inventory does not exactly match Terraform"
  fi

  success "Application Auto Scaling policy inventory exactly matches Terraform"
}

validate_scaling_policies() {
  local live_scaling_policies_json="$1"
  local expected_policy_json
  local service_name

  while IFS= read -r service_name; do
    expected_policy_json="$(
      echo "$ECS_AUTOSCALING_CPU_POLICIES_JSON" |
        jq -c --arg service "$service_name" '.[$service]'
    )"

    validate_target_tracking_policy \
      "$service_name" \
      "CPU target-tracking" \
      "$expected_policy_json" \
      "$live_scaling_policies_json"

  done < <(echo "$ECS_AUTOSCALING_CPU_POLICIES_JSON" | jq -r 'keys[]')

  while IFS= read -r service_name; do
    expected_policy_json="$(
      echo "$ECS_AUTOSCALING_MEMORY_POLICIES_JSON" |
        jq -c --arg service "$service_name" '.[$service]'
    )"

    validate_target_tracking_policy \
      "$service_name" \
      "memory target-tracking" \
      "$expected_policy_json" \
      "$live_scaling_policies_json"

  done < <(echo "$ECS_AUTOSCALING_MEMORY_POLICIES_JSON" | jq -r 'keys[]')

  while IFS= read -r service_name; do
    expected_policy_json="$(
      echo "$ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON" |
        jq -c --arg service "$service_name" '.[$service]'
    )"

    validate_target_tracking_policy \
      "$service_name" \
      "ALB request-count target-tracking" \
      "$expected_policy_json" \
      "$live_scaling_policies_json"

  done < <(echo "$ECS_AUTOSCALING_ALB_REQUEST_POLICIES_JSON" | jq -r 'keys[]')
}
