#!/usr/bin/env bash
set -euo pipefail
# Offline fixture tests. No AWS calls or IAM mutations.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../validation/lib/ecs-task-role-managed-policies.sh
source "${root}/scripts/validation/lib/ecs-task-role-managed-policies.sh"
fail() { echo "[FAIL] $*" >&2; exit 1; }
success() { :; }
count=0
pass() {
  if ! (validate_task_role_managed_policy_inventory test "$1" "$2" aws 123456789012) >/dev/null 2>&1; then
    echo "Unexpected failure: $1 / $2" >&2; exit 1
  fi
  count=$((count + 1))
}
deny() {
  if (validate_task_role_managed_policy_inventory test "$1" "$2" aws 123456789012) >/dev/null 2>&1; then
    echo "Unexpected success: $1 / $2" >&2; exit 1
  fi
  count=$((count + 1))
}
empty='{"AttachedPolicies":[]}'
both='{"AttachedPolicies":[{"PolicyArn":"arn:aws:iam::123456789012:policy/app/ReadOrders"},{"PolicyArn":"arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"}]}'
pass '[]' "$empty"
pass '["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess","arn:aws:iam::123456789012:policy/app/ReadOrders"]' "$both"
deny '[]' "$both"
deny '["arn:aws:iam::123456789012:policy/app/ReadOrders"]' "$empty"
deny '["arn:aws:iam::123456789012:policy/app/ReadOrders"]' "$both"
deny '["arn:aws:iam::123456789012:policy/app/ReadOrders","arn:aws:iam::123456789012:policy/app/ReadOrders"]' "$both"
deny '["arn:aws:iam::999999999999:policy/app/ReadOrders"]' "$empty"
deny '["arn:aws-us-gov:iam::123456789012:policy/app/ReadOrders"]' "$empty"
deny '["arn:aws:iam::123456789012:role/not-a-policy"]' "$empty"
deny '["arn:aws:iam::123456789012:policy/*"]' "$empty"
deny '[]' '{"AttachedPolicies":[{"PolicyArn":"arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"}]}'
deny '[]' '{}'
deny '[]' '{"AttachedPolicies":[{"PolicyName":"NoArn"}]}'
echo "[PASS] $count offline ECS task-role managed-policy inventory cases."
