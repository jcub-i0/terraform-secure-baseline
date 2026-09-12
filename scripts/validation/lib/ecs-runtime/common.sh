#!/usr/bin/env bash

# Internal ECS runtime common helpers; sourced by validate-ecs-runtime.sh.

ecs_runtime_json_object_output() {
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

ecs_runtime_require_same_map_keys() {
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

ecs_runtime_sg_has_group_rule() {
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

ecs_runtime_sg_has_group_reference() {
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

ecs_runtime_sg_has_prefix_list_rule() {
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

ecs_runtime_sg_has_ipv4_cidr_rule() {
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

ecs_runtime_validate_identity() {
  local caller_arn

  section "Checking AWS caller identity"

  ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
  caller_arn="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

  if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    fail "Unable to resolve AWS account ID"
  fi

  if [[ -n "$EXPECTED_ACCOUNT_ID" && "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi

  success "AWS credentials are valid: ${caller_arn}"
}
