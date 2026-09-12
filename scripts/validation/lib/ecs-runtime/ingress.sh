#!/usr/bin/env bash

# Internal ECS runtime ingress helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_validate_ingress() {
  local expected_alb_arn
  local expected_alb_dns_name
  local expected_alb_listener_arn
  local expected_alb_certificate_arn
  local expected_alb_ssl_policy
  local alb_response_json
  local alb_sg_json
  local rules_response_json
  local service_name

  section "Validating conditional shared Application Load Balancer"

  if [[ "$APPLICATION_LOAD_BALANCER_JSON" == "null" ]]; then
    if [[ "${#SERVICE_TARGET_GROUP_ARNS[@]}" -ne 0 ]]; then
      fail "Service target groups were detected while application_load_balancer output is null"
    fi

    success "No ALB is configured; ALB validation skipped"

  else
    expected_alb_arn="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.arn')"
    expected_alb_dns_name="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.dns_name')"
    expected_alb_listener_arn="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.https_listener.arn')"

    expected_alb_certificate_arn="$(
      echo "$APPLICATION_LOAD_BALANCER_JSON" |
        jq -r '.https_listener.certificate_arn'
    )"

    expected_alb_ssl_policy="$(
      echo "$APPLICATION_LOAD_BALANCER_JSON" |
        jq -r '.https_listener.ssl_policy'
    )"

    alb_response_json="$(
      aws elbv2 describe-load-balancers \
        "${AWS_ARGS[@]}" \
        --load-balancer-arns "$expected_alb_arn" \
        --output json
    )"

    validate_alb_identity \
      "$alb_response_json" \
      "$expected_alb_arn" \
      "$expected_alb_dns_name"

    alb_sg_json="$(
      aws ec2 describe-security-groups \
        "${AWS_ARGS[@]}" \
        --group-ids "$ALB_SECURITY_GROUP_ID" \
        --output json
    )"

    validate_alb_security_group "$alb_sg_json"

    validate_alb_listener \
      "$expected_alb_arn" \
      "$expected_alb_listener_arn" \
      "$expected_alb_certificate_arn" \
      "$expected_alb_ssl_policy"

    rules_response_json="$(
      aws elbv2 describe-rules \
        "${AWS_ARGS[@]}" \
        --listener-arn "$expected_alb_listener_arn" \
        --output json
    )"

    while IFS= read -r service_name; do
      validate_alb_target_group \
        "$service_name" \
        "$rules_response_json" \
        "$alb_sg_json"
    done < <(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -r '.target_groups | keys[]')

    success "Shared Application Load Balancer runtime is valid"
  fi
}

validate_alb_identity() {
  local alb_response_json="$1"
  local expected_alb_arn="$2"
  local expected_alb_dns_name="$3"
  local public_subnets_json
  local expected_public_subnets_json
  local actual_alb_subnets_json

  if ! echo "$alb_response_json" |
    jq -e \
      --arg arn "$expected_alb_arn" \
      --arg dns_name "$expected_alb_dns_name" \
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

  public_subnets_json="$(
    aws ec2 describe-subnets \
      "${AWS_ARGS[@]}" \
      --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Public-*" \
      --output json
  )"

  expected_public_subnets_json="$(echo "$public_subnets_json" | jq -c '[.Subnets[].SubnetId] | sort | unique')"
  actual_alb_subnets_json="$(
    echo "$alb_response_json" |
      jq -c '[.LoadBalancers[0].AvailabilityZones[].SubnetId] | sort | unique'
  )"

  if [[ "$(echo "$expected_public_subnets_json" | jq 'length')" -eq 0 ]]; then
    fail "No public subnets were resolved for ALB placement validation"
  fi

  if [[ "$expected_public_subnets_json" != "$actual_alb_subnets_json" ]]; then
    fail "Shared ALB does not use the exact public subnet set"
  fi
}

validate_alb_security_group() {
  local alb_sg_json="$1"

  if [[ "$(echo "$alb_sg_json" | jq -r '.SecurityGroups[0].VpcId // empty')" != "$VPC_ID" ]] ||
    ! echo "$alb_sg_json" | jq -e '.SecurityGroups | length == 1' >/dev/null; then
    fail "ALB security group is missing or belongs to the wrong VPC"
  fi

  if ! echo "$alb_sg_json" |
    jq -e '.SecurityGroups[0].IpPermissions | any(.IpProtocol == "tcp" and .FromPort == 443 and .ToPort == 443 and (.IpRanges | length) > 0)' >/dev/null; then
    fail "ALB SG lacks CIDR-based HTTPS ingress"
  fi
}

validate_alb_listener() {
  local expected_alb_arn="$1"
  local expected_alb_listener_arn="$2"
  local expected_alb_certificate_arn="$3"
  local expected_alb_ssl_policy="$4"
  local listeners_response_json

  listeners_response_json="$(
    aws elbv2 describe-listeners \
      "${AWS_ARGS[@]}" \
      --load-balancer-arn "$expected_alb_arn" \
      --output json
  )"

  if ! echo "$listeners_response_json" |
    jq -e \
      --arg listener_arn "$expected_alb_listener_arn" \
      --arg certificate_arn "$expected_alb_certificate_arn" \
      --arg ssl_policy "$expected_alb_ssl_policy" '
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
}

validate_alb_target_group() {
  local service_name="$1"
  local rules_response_json="$2"
  local alb_sg_json="$3"
  local target_group_json
  local expected_target_group_arn
  local expected_target_group_name
  local target_group_response_json

  target_group_json="$(
    echo "$APPLICATION_LOAD_BALANCER_JSON" |
      jq -c --arg service "$service_name" '.target_groups[$service]'
  )"
  expected_target_group_arn="$(echo "$target_group_json" | jq -r '.arn')"
  expected_target_group_name="$(echo "$target_group_json" | jq -r '.name')"
  target_group_response_json="$(
    aws elbv2 describe-target-groups \
      "${AWS_ARGS[@]}" \
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
        | select(
            any(.Actions[]?;
              .Type == "forward"
              and (
                .TargetGroupArn == $arn
                or any(.ForwardConfig.TargetGroups[]?; .TargetGroupArn == $arn)
              )
            )
          )
        | select((.Conditions | length) > 0)
        | select(
            all(.Conditions[];
              (.Field == "host-header" or .Field == "path-pattern")
              and ((.Values // []) | length) > 0
            )
          )
      ]
      | length == 1
    ' >/dev/null; then
    echo "$rules_response_json" | jq '.Rules'
    fail "Expected exactly one meaningful listener rule forwarding to ${service_name} target group"
  fi

  if ! ecs_runtime_sg_has_group_rule \
    "$alb_sg_json" \
    egress \
    "$(echo "$TASK_SECURITY_GROUP_IDS_JSON" | jq -r --arg service "$service_name" '.[$service]')" \
    "${SERVICE_CONTAINER_PORTS[$service_name]}"; then
    fail "ALB SG lacks egress to task SG on the service container port: ${service_name}"
  fi

  success "ALB target group, listener rule, and SG relationship are valid: ${service_name}"
}
