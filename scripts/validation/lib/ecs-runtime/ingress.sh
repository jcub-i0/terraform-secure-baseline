#!/usr/bin/env bash

# Internal ECS runtime ingress helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_validate_ingress() {
  local expected_alb_arn
  local expected_alb_dns_name
  local expected_alb_listener_arn
  local expected_alb_certificate_arn
  local expected_alb_ssl_policy
  local alb_response_json
  local alb_attributes_json
  local alb_sg_json
  local rules_response_json
  local service_name

  LIVE_ALB_DELETION_PROTECTION="<not-applicable>"

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

    alb_attributes_json="$(
      aws elbv2 describe-load-balancer-attributes \
        "${AWS_ARGS[@]}" \
        --load-balancer-arn "$expected_alb_arn" \
        --output json
    )"

    if ! LIVE_ALB_DELETION_PROTECTION="$(
      echo "$alb_attributes_json" |
        jq -er '
          [
            .Attributes[]
            | select(.Key == "deletion_protection.enabled")
            | .Value
          ]
          | if length == 1
            then .[0]
            else error("Expected exactly one deletion_protection.enabled attribute")
            end
        '
    )"; then
      fail "Unable to resolve live ALB deletion protection."
    fi

    if [[ "$LIVE_ALB_DELETION_PROTECTION" != \
      "$EXPECTED_ALB_DELETION_PROTECTION" ]]; then

      jq -n \
        --arg expected "$EXPECTED_ALB_DELETION_PROTECTION" \
        --arg actual "$LIVE_ALB_DELETION_PROTECTION" '
          {
            expected_deletion_protection: $expected,
            live_deletion_protection: $actual
          }
        '

      fail "ALB deletion protection does not match Terraform."
    fi

    success "ALB deletion protection matches Terraform: ${LIVE_ALB_DELETION_PROTECTION}"

    ecs_runtime_validate_alb_access_logs "$alb_attributes_json" "$expected_alb_arn"

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


# Validate ALB log delivery settings and bucket controls; do not require a
# delivered object here. End-to-end .log.gz delivery is qualified separately.
ecs_runtime_validate_alb_access_logs() {
  local attributes_json="$1"
  local alb_arn="$2"
  local logs_json
  local bucket_name bucket_arn retention_days partition source_arn
  local encryption_json public_json ownership_json versioning_json lifecycle_json policy_json

  section "Validating ALB access logging"

  logs_json="$(echo "$APPLICATION_LOAD_BALANCER_JSON" | jq -c '.access_logs')"

  if ! jq -e --argjson logs "$logs_json" '
    [.Attributes[] | select(.Key == "access_logs.s3.enabled") | .Value] ==
      [($logs.enabled | tostring)]
    and (if $logs.enabled then
      [.Attributes[] | select(.Key == "access_logs.s3.bucket") | .Value] ==
        [$logs.bucket_name]
      and [.Attributes[] | select(.Key == "access_logs.s3.prefix") | .Value] ==
        [$logs.prefix]
    else true end)
  ' <<< "$attributes_json" >/dev/null; then
    fail "Live ALB access logging attributes do not match Terraform."
  fi

  if [[ "$(echo "$logs_json" | jq -r '.enabled')" != "true" ]]; then
    success "ALB access logging is disabled as configured; no bucket checks required"
    return 0
  fi

  bucket_name="$(echo "$logs_json" | jq -r '.bucket_name')"
  bucket_arn="$(echo "$logs_json" | jq -r '.bucket_arn')"
  retention_days="$(echo "$logs_json" | jq -r '.retention_days')"
  partition="${alb_arn#arn:}"
  partition="${partition%%:*}"
  source_arn="${alb_arn%/*}/*"

  aws s3api head-bucket "${AWS_ARGS[@]}" --bucket "$bucket_name" >/dev/null ||
    fail "ALB access-log bucket is not accessible: $bucket_name"

  encryption_json="$(aws s3api get-bucket-encryption "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --output json)" ||
    fail "Cannot read ALB log-bucket encryption."
  jq -e '
    (.ServerSideEncryptionConfiguration.Rules | length) == 1
    and .ServerSideEncryptionConfiguration.Rules[0]
      .ApplyServerSideEncryptionByDefault.SSEAlgorithm == "AES256"
  ' <<< "$encryption_json" >/dev/null ||
    fail "ALB log bucket must use SSE-S3 (AES256)."

  public_json="$(aws s3api get-public-access-block "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --output json)" ||
    fail "Cannot read ALB log-bucket public-access controls."
  jq -e '
    .PublicAccessBlockConfiguration |
      .BlockPublicAcls == true
      and .BlockPublicPolicy == true
      and .IgnorePublicAcls == true
      and .RestrictPublicBuckets == true
  ' <<< "$public_json" >/dev/null ||
    fail "ALB log bucket does not block all public access."

  ownership_json="$(aws s3api get-bucket-ownership-controls "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --output json)" ||
    fail "Cannot read ALB log-bucket ownership controls."
  jq -e '
    (.OwnershipControls.Rules | length) == 1
    and .OwnershipControls.Rules[0].ObjectOwnership == "BucketOwnerEnforced"
  ' <<< "$ownership_json" >/dev/null ||
    fail "ALB log bucket must enforce bucket ownership."

  versioning_json="$(aws s3api get-bucket-versioning "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --output json)" ||
    fail "Cannot read ALB log-bucket versioning."
  jq -e '.Status == "Enabled"' <<< "$versioning_json" >/dev/null ||
    fail "ALB log bucket must have versioning enabled."

  lifecycle_json="$(aws s3api get-bucket-lifecycle-configuration "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --output json)" ||
    fail "Cannot read ALB log-bucket lifecycle."
  jq -e --argjson days "$retention_days" '
    (.Rules | length) == 1
    and .Rules[0].ID == "alb-access-logs-retention"
    and .Rules[0].Status == "Enabled"
    and .Rules[0].Filter.Prefix == "alb/"
    and .Rules[0].Expiration.Days == $days
    and .Rules[0].NoncurrentVersionExpiration.NoncurrentDays == 1
  ' <<< "$lifecycle_json" >/dev/null ||
    fail "ALB log-bucket lifecycle does not match Terraform retention."

  policy_json="$(aws s3api get-bucket-policy "${AWS_ARGS[@]}" \
    --bucket "$bucket_name" --query Policy --output text)" ||
    fail "Cannot read ALB log-bucket policy."

  if ! jq -e --arg arn "$bucket_arn" \
    --arg source "$source_arn" \
    --arg account "$ACCOUNT_ID" '
    def as_list: if type == "array" then . else [.] end;
    def everyone: .Principal == "*" or .Principal.AWS == "*";
    (.Statement | as_list) as $ss
    | ([$ss[] | select(.Sid == "AllowALBLogDelivery")][0]) as $allow
    | ([$ss[] | select(.Sid == "DenyDeleteLogs")][0]) as $delete
    | ([$ss[] | select(.Sid == "DenyBucketPolicyChanges")][0]) as $admin
    | ([$ss[] | select(.Sid == "DenyVersioningChanges")][0]) as $version
    | ([$ss[] | select(.Sid == "DenyInsecureTransport")][0]) as $https
    | ($ss | length) == 5
      and ($ss | map(.Sid) | unique | length) == 5
      and ($allow.Effect == "Allow")
      and ($allow.Principal.Service == "logdelivery.elasticloadbalancing.amazonaws.com")
      and ($allow.Action | as_list) == ["s3:PutObject"]
      and ($allow.Resource | as_list) == [$arn + "/alb/AWSLogs/" + $account + "/*"]
      and ($allow.Condition | keys) == ["ArnLike"]
      and ($allow.Condition.ArnLike | keys) == ["aws:SourceArn"]
      and ($allow.Condition.ArnLike["aws:SourceArn"] | as_list) == [$source]
      and ($delete.Effect == "Deny" and ($delete | everyone))
      and $delete.Condition == null
      and (($delete.Action | as_list | sort) == (["s3:DeleteObject","s3:DeleteObjectVersion"] | sort))
      and ($delete.Resource | as_list) == [$arn + "/*"]
      and ($admin.Effect == "Deny" and ($admin | everyone))
      and (($admin.Action | as_list | sort) == (["s3:PutBucketPolicy","s3:DeleteBucketPolicy"] | sort))
      and ($admin.Resource | as_list) == [$arn]
      and ($admin.Condition | keys) == ["ArnNotEquals"]
      and ($admin.Condition.ArnNotEquals | keys) == ["aws:PrincipalArn"]
      and (($admin.Condition.ArnNotEquals["aws:PrincipalArn"] | as_list) as $principals
        | ($principals | length) > 0
        and all($principals[]; type == "string" and length > 0 and (contains("*") | not)))
      and ($version.Effect == "Deny" and ($version | everyone))
      and ($version.Action | as_list) == ["s3:PutBucketVersioning"]
      and ($version.Resource | as_list) == [$arn]
      and $version.Condition.ArnNotEquals["aws:PrincipalArn"] ==
        $admin.Condition.ArnNotEquals["aws:PrincipalArn"]
      and ($https.Effect == "Deny" and ($https | everyone))
      and ($https.Action | as_list) == ["s3:*"]
      and ($https.Condition | keys) == ["Bool"]
      and ($https.Condition.Bool | keys) == ["aws:SecureTransport"]
      and (($https.Resource | as_list | sort) == ([$arn, $arn + "/*"] | sort))
      and ($https.Condition.Bool["aws:SecureTransport"] | as_list) == ["false"]
  ' <<< "$policy_json" >/dev/null; then
    fail "ALB log-bucket delivery and protection policy does not match Terraform."
  fi

  success "ALB access logging and S3 bucket protections match Terraform: $bucket_name"
}

validate_alb_identity() {
  local alb_response_json="$1"
  local expected_alb_arn="$2"
  local expected_alb_dns_name="$3"
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

  actual_alb_subnets_json="$(
    echo "$alb_response_json" |
      jq -c '
        [.LoadBalancers[0].AvailabilityZones[].SubnetId]
        | sort
        | unique
      '
  )"

  if [[ "$EXPECTED_INGRESS_PUBLIC_SUBNET_IDS_JSON" != "$actual_alb_subnets_json" ]]; then
    jq -n \
      --argjson expected "$EXPECTED_INGRESS_PUBLIC_SUBNET_IDS_JSON" \
      --argjson actual "$actual_alb_subnets_json" '
        {
          expected_ingress_public_subnets: $expected,
          actual_alb_subnets: $actual
        }
      '

    fail "Shared ALB does not use the exact Terraform-owned ingress-public subnet set."
  fi

  success "Shared ALB uses the exact Terraform-owned ingress-public subnet set"
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