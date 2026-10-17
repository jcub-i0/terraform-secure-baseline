#!/usr/bin/env bash
# Exact attachment inventory validation, not effective IAM policy evaluation.
# Requires fail()/success() from the sourcing validator or offline tests.
validate_task_role_managed_policy_inventory() {
  local service_name="$1"
  local expected_json="$2"
  local actual_json="$3"
  local partition="$4"
  local account_id="$5"

  if ! jq -e --arg partition "$partition" --arg account_id "$account_id" '
    type == "array"
    and (length == (unique | length))
    and all(.[]; type == "string"
      and test("^arn:" + $partition + ":iam::(aws|" + $account_id + "):policy/[A-Za-z0-9+=,.@_/-]+$")
    )
  ' <<<"$expected_json" >/dev/null; then
    fail "Invalid configured task-role managed policy ARN set: ${service_name}"
  fi

  if ! jq -e '
    type == "object"
    and (.AttachedPolicies | type == "array")
    and all(.AttachedPolicies[];
      type == "object" and (.PolicyArn | type == "string" and length > 0)
    )
  ' <<<"$actual_json" >/dev/null; then
    fail "Invalid live application task-role managed policy inventory: ${service_name}"
  fi

  local expected_sorted actual_sorted
  expected_sorted="$(jq -c 'sort' <<<"$expected_json")"
  actual_sorted="$(jq -c '[.AttachedPolicies[].PolicyArn] | sort' <<<"$actual_json")"

  if [[ "$actual_sorted" != "$expected_sorted" ]]; then
    jq -n --arg service "$service_name" \
      --argjson expected "$expected_sorted" --argjson actual "$actual_sorted" \
      '{service: $service, expected_managed_policy_arns: $expected, actual_managed_policy_arns: $actual}'
    fail "Unexpected or missing ECS application task-role managed policy attachments: ${service_name}"
  fi

  success "ECS task-role managed policy attachment inventory matches Terraform: ${service_name}"
}
