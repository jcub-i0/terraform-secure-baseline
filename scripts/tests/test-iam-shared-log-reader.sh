#!/usr/bin/env bash
set -euo pipefail

# Offline shared log-reader checks; these are the pure predicates used by IAM.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../validation/lib/shared-log-reader-policy.sh
source "$root/scripts/validation/lib/shared-log-reader-policy.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0

verify() {
  local outputs_json="$1"
  local policy_json="$2"
  local scopes_json

  scopes_json="$(shared_log_reader_expected_scopes "$outputs_json" aws)" || return 1
  shared_log_reader_policy_matches "$policy_json" "$scopes_json"
}

expect_pass() {
  local label="$1"
  shift
  if ! verify "$@" >"$tmp/result" 2>&1; then
    echo "[FAIL] Expected pass: $label" >&2
    cat "$tmp/result" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

expect_fail() {
  local label="$1"
  shift
  if verify "$@" >"$tmp/result" 2>&1; then
    echo "[FAIL] Expected rejection: $label" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

central_bucket="example-prod-centralized-logs-12345678"
alb_bucket="example-prod-alb-access-logs-12345678"
central_arn="arn:aws:s3:::$central_bucket"
alb_arn="arn:aws:s3:::$alb_bucket"

no_alb="$(jq -nc --arg name "$central_bucket" '{centralized_logs_bucket_name:{value:$name}}')"
explicit_null="$(jq -c '.application_load_balancer = {value:null}' <<< "$no_alb")"
enabled="$(jq -nc --argjson base "$no_alb" --arg name "$alb_bucket" --arg arn "$alb_arn" '
  $base + {application_load_balancer:{value:{access_logs:{
    enabled:true,bucket_name:$name,bucket_arn:$arn
  }}}}
')"
disabled="$(jq -c '.application_load_balancer.value.access_logs =
  {enabled:false,bucket_name:null,bucket_arn:null}' <<< "$enabled")"

central_policy="$(jq -nc --arg arn "$central_arn" '{
  Statement:[
    {Sid:"ListManagedLogBuckets",Effect:"Allow",
     Action:["s3:ListBucket","s3:GetBucketLocation"],Resource:[$arn]},
    {Sid:"ReadManagedLogObjects",Effect:"Allow",
     Action:["s3:GetObject","s3:GetObjectVersion","s3:GetObjectTagging","s3:GetObjectVersionTagging"],
     Resource:[$arn + "/*"]}
  ]
}')"
both_policy="$(jq --arg arn "$alb_arn" '
  (.Statement[] | select(.Sid=="ListManagedLogBuckets").Resource) += [$arn] |
  (.Statement[] | select(.Sid=="ReadManagedLogObjects").Resource) += [$arn + "/alb/*"]
' <<< "$central_policy")"

expect_pass "Missing ALB output permits only centralized log access" "$no_alb" "$central_policy"
expect_pass "Explicit null ALB output" "$explicit_null" "$central_policy"
expect_pass "ALB logging disabled" "$disabled" "$central_policy"
expect_pass "Enabled ALB expects both exact bucket scopes" "$enabled" "$both_policy"

expect_fail "Missing ALB must not authorize extra ALB log access" "$no_alb" "$both_policy"
expect_fail "Enabled ALB requires its exact IAM permissions" "$enabled" "$central_policy"
expect_fail "Required centralized log-bucket output missing" '{}' "$central_policy"
expect_fail "Malformed ALB output wrapper" "$(jq -c '.application_load_balancer={}' <<< "$no_alb")" "$central_policy"
expect_fail "Enabled ALB output missing bucket ARN" "$(jq -c 'del(.application_load_balancer.value.access_logs.bucket_arn)' <<< "$enabled")" "$both_policy"
expect_fail "Disabled ALB output unexpectedly advertises bucket" "$(jq -c '.application_load_balancer.value.access_logs.enabled=false' <<< "$enabled")" "$both_policy"

echo "[PASS] $passed offline shared log-reader IAM policy scope cases."
