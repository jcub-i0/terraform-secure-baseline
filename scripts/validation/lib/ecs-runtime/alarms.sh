#!/usr/bin/env bash

# Internal ECS runtime alarms helpers; sourced by validate-ecs-runtime.sh.

validate_operational_alarm_state() {
  local alarm_json="$1"
  local alarm_description="$2"
  local state

  state="$(
    echo "$alarm_json" |
      jq -r '.StateValue // empty'
  )"

  case "$state" in
    OK)
      success "${alarm_description} alarm state is OK"
      ;;

    INSUFFICIENT_DATA)
      warn "${alarm_description} alarm state is INSUFFICIENT_DATA; configuration is valid but metric evaluation is not yet complete"
      ;;

    ALARM)
      fail "${alarm_description} operational alarm is currently ALARM"
      ;;

    *)
      fail "${alarm_description} alarm has unexpected state: ${state:-<missing>}"
      ;;
  esac
}

ecs_runtime_validate_alarms() {
  local live_operational_alarms_json
  local service_name

  section "Validating ECS Operational Alarms"

  live_operational_alarms_json="$(
    aws cloudwatch describe-alarms \
      "${AWS_ARGS[@]}" \
      --alarm-name-prefix "${NAME_PREFIX}-" \
      --output json
  )"

  validate_operational_alarm_inventory "$live_operational_alarms_json"

  while IFS= read -r service_name; do
    validate_task_deficit_alarm "$service_name" "$live_operational_alarms_json"
  done < <(echo "$ECS_TASK_DEFICIT_ALARMS_JSON" | jq -r 'keys[]')

  while IFS= read -r service_name; do
    validate_ingress_unhealthy_target_alarm "$service_name" "$live_operational_alarms_json"
  done < <(echo "$ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON" | jq -r 'keys[]')

  success "ECS operational alarms exactly match Terraform"
}

validate_operational_alarm_inventory() {
  local live_operational_alarms_json="$1"
  local expected_operational_alarm_names_json
  local live_operational_alarm_names_json

  expected_operational_alarm_names_json="$(
    jq -c -n \
      --argjson task "$ECS_TASK_DEFICIT_ALARMS_JSON" \
      --argjson ingress "$ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON" '
        [
          ($task[]? | .name),
          ($ingress[]? | .name)
        ]
        | sort
        | unique
      '
  )"

  # AWS-managed target-tracking alarms are outside the operational inventory.
  live_operational_alarm_names_json="$(
    echo "$live_operational_alarms_json" |
      jq -c '
        [
          .MetricAlarms[]?
          | select(
              (.AlarmName | endswith("-ecs-task-deficit"))
              or
              (.AlarmName | endswith("-ecs-ingress-unhealthy-targets"))
            )
          | .AlarmName
        ]
        | sort
        | unique
      '
  )"

  if [[ "$expected_operational_alarm_names_json" != "$live_operational_alarm_names_json" ]]; then
    jq -n \
      --argjson expected "$expected_operational_alarm_names_json" \
      --argjson actual "$live_operational_alarm_names_json" \
      '{
        expected_operational_alarms: $expected,
        actual_operational_alarms: $actual
      }'

    fail "ECS operational alarm inventory does not exactly match Terraform"
  fi

  success "ECS operational alarm inventory exactly matches Terraform"
}

validate_task_deficit_alarm() {
  local service_name="$1"
  local live_operational_alarms_json="$2"
  local expected_alarm_json
  local expected_alarm_name
  local expected_alarm_arn
  local expected_service_name
  local live_alarm_matches_json
  local live_alarm_json

  expected_alarm_json="$(
    echo "$ECS_TASK_DEFICIT_ALARMS_JSON" |
      jq -c --arg service "$service_name" '.[$service]'
  )"

  expected_alarm_name="$(
    echo "$expected_alarm_json" |
      jq -r '.name'
  )"

  expected_alarm_arn="$(
    echo "$expected_alarm_json" |
      jq -r '.arn'
  )"

  expected_service_name="$(
    echo "$ECS_SERVICES_JSON" |
      jq -r --arg service "$service_name" '.[$service].name'
  )"

  live_alarm_matches_json="$(
    echo "$live_operational_alarms_json" |
      jq -c \
        --arg name "$expected_alarm_name" '
          [
            .MetricAlarms[]?
            | select(.AlarmName == $name)
          ]
        '
  )"

  if [[ "$(echo "$live_alarm_matches_json" | jq 'length')" -ne 1 ]]; then
    echo "$live_alarm_matches_json" | jq .
    fail "Expected exactly one ECS task-deficit alarm: ${service_name}"
  fi

  live_alarm_json="$(
    echo "$live_alarm_matches_json" |
      jq -c '.[0]'
  )"

  if ! echo "$live_alarm_json" |
    jq -e \
      --arg arn "$expected_alarm_arn" \
      --arg name "$expected_alarm_name" \
      --arg topic "$SECOPS_TOPIC_ARN" \
      --arg cluster "$EXPECTED_CLUSTER_NAME" \
      --arg service "$expected_service_name" '
        .AlarmArn == $arn
        and .AlarmName == $name
        and .ActionsEnabled == true

        and (.AlarmActions | sort) == [$topic]
        and (.OKActions | sort) == [$topic]
        and ((.InsufficientDataActions // []) | length) == 0

        and .ComparisonOperator == "GreaterThanThreshold"
        and .Threshold == 0
        and .EvaluationPeriods == 3
        and .DatapointsToAlarm == 3
        and .TreatMissingData == "notBreaching"

        and (.Metrics | length) == 3

        and any(
          .Metrics[];
          .Id == "desired"
          and .ReturnData == false
          and .MetricStat.Metric.Namespace == "ECS/ContainerInsights"
          and .MetricStat.Metric.MetricName == "DesiredTaskCount"
          and .MetricStat.Period == 60
          and .MetricStat.Stat == "Average"
          and (.MetricStat.Metric.Dimensions | length) == 2
          and any(.MetricStat.Metric.Dimensions[]; .Name == "ClusterName" and .Value == $cluster)
          and any(.MetricStat.Metric.Dimensions[]; .Name == "ServiceName" and .Value == $service)
        )

        and any(
          .Metrics[];
          .Id == "running"
          and .ReturnData == false
          and .MetricStat.Metric.Namespace == "ECS/ContainerInsights"
          and .MetricStat.Metric.MetricName == "RunningTaskCount"
          and .MetricStat.Period == 60
          and .MetricStat.Stat == "Average"
          and (.MetricStat.Metric.Dimensions | length) == 2
          and any(.MetricStat.Metric.Dimensions[]; .Name == "ClusterName" and .Value == $cluster)
          and any(.MetricStat.Metric.Dimensions[]; .Name == "ServiceName" and .Value == $service)
        )

        and any(
          .Metrics[];
          .Id == "deficit"
          and .Expression == "desired - running"
          and .Label == "ECS task deficit"
          and .ReturnData == true
        )
      ' >/dev/null; then
    echo "$live_alarm_json" | jq .
    fail "ECS task-deficit alarm does not exactly match Terraform baseline semantics: ${service_name}"
  fi

  success "ECS task-deficit alarm exactly matches Terraform baseline semantics: ${service_name}"

  validate_operational_alarm_state \
    "$live_alarm_json" \
    "ECS task-deficit ${service_name}"
}

validate_ingress_unhealthy_target_alarm() {
  local service_name="$1"
  local live_operational_alarms_json="$2"
  local expected_alarm_json
  local expected_alarm_name
  local expected_alarm_arn
  local expected_load_balancer_suffix
  local expected_target_group_suffix
  local live_alarm_matches_json
  local live_alarm_json

  expected_alarm_json="$(
    echo "$ECS_INGRESS_UNHEALTHY_TARGET_ALARMS_JSON" |
      jq -c --arg service "$service_name" '.[$service]'
  )"

  expected_alarm_name="$(
    echo "$expected_alarm_json" |
      jq -r '.name'
  )"

  expected_alarm_arn="$(
    echo "$expected_alarm_json" |
      jq -r '.arn'
  )"

  expected_load_balancer_suffix="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -r '.arn_suffix'
  )"

  expected_target_group_suffix="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -r --arg service "$service_name" '.target_groups[$service].arn_suffix'
  )"

  live_alarm_matches_json="$(
    echo "$live_operational_alarms_json" |
      jq -c \
        --arg name "$expected_alarm_name" '
          [
            .MetricAlarms[]?
            | select(.AlarmName == $name)
          ]
        '
  )"

  if [[ "$(echo "$live_alarm_matches_json" | jq 'length')" -ne 1 ]]; then
    echo "$live_alarm_matches_json" | jq .
    fail "Expected exactly one ECS ingress unhealthy-target alarm: ${service_name}"
  fi

  live_alarm_json="$(
    echo "$live_alarm_matches_json" |
      jq -c '.[0]'
  )"

  if ! echo "$live_alarm_json" |
    jq -e \
      --arg arn "$expected_alarm_arn" \
      --arg name "$expected_alarm_name" \
      --arg topic "$SECOPS_TOPIC_ARN" \
      --arg lb "$expected_load_balancer_suffix" \
      --arg tg "$expected_target_group_suffix" '
        .AlarmArn == $arn
        and .AlarmName == $name
        and .ActionsEnabled == true

        and (.AlarmActions | sort) == [$topic]
        and (.OKActions | sort) == [$topic]
        and ((.InsufficientDataActions // []) | length) == 0

        and .Namespace == "AWS/ApplicationELB"
        and .MetricName == "UnHealthyHostCount"
        and .Statistic == "Maximum"
        and .Period == 60
        and .EvaluationPeriods == 3
        and .DatapointsToAlarm == 3
        and .Threshold == 0
        and .ComparisonOperator == "GreaterThanThreshold"
        and .TreatMissingData == "notBreaching"

        and (.Dimensions | length) == 2
        and any(.Dimensions[]; .Name == "LoadBalancer" and .Value == $lb)
        and any(.Dimensions[]; .Name == "TargetGroup" and .Value == $tg)
      ' >/dev/null; then
    echo "$live_alarm_json" | jq .
    fail "ECS ingress unhealthy-target alarm does not exactly match Terraform baseline semantics: ${service_name}"
  fi

  success "ECS ingress unhealthy-target alarm exactly matches Terraform baseline semantics: ${service_name}"

  validate_operational_alarm_state \
    "$live_alarm_json" \
    "ECS ingress unhealthy-target ${service_name}"
}
