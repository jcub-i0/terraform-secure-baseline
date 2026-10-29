#!/usr/bin/env bash
set -euo pipefail

# Offline ALB logging output/live-setting checks. AWS is mocked, never called.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../validation/lib/ecs-runtime/contract.sh
source "$root/scripts/validation/lib/ecs-runtime/contract.sh"
# shellcheck source=../validation/lib/ecs-runtime/ingress.sh
source "$root/scripts/validation/lib/ecs-runtime/ingress.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
passed=0

fail() { echo "[FAIL] $*" >&2; exit 1; }
success() { :; }
section() { :; }

AWS_ARGS=()
ACCOUNT_ID=123456789012
ALB_ARN="arn:aws:elasticloadbalancing:us-east-1:$ACCOUNT_ID:loadbalancer/app/test-prod-alb/abcdef1234567890"
BUCKET="test-prod-alb-access-logs-12345678"
BUCKET_ARN="arn:aws:s3:::$BUCKET"
LIFECYCLE_PROTECTION_JSON='{"alb_access_logs_force_destroy":false}'
ECS_SERVICES_JSON='{"api":{}}'

APPLICATION_LOAD_BALANCER_JSON="$(
  jq -nc --arg alb "$ALB_ARN" --arg bucket "$BUCKET" --arg bucket_arn "$BUCKET_ARN" '{
    arn:$alb, dns_name:"example.elb.amazonaws.com", arn_suffix:"app/test-prod-alb/abcdef1234567890",
    security_group_id:"sg-abcdef1234567890",
    https_listener:{arn:"listener-arn",certificate_arn:"certificate-arn",ssl_policy:"TLS13"},
    target_groups:{api:{arn:"target-group-arn"}},
    access_logs:{
      enabled:true, bucket_name:$bucket, bucket_arn:$bucket_arn,
      expected_bucket_name:$bucket, prefix:"alb", retention_days:90,
      force_destroy:false
    }
  }'
)"
ALB_ATTRIBUTES_JSON="$(jq -nc --arg bucket "$BUCKET" '{
  Attributes:[
    {Key:"access_logs.s3.enabled",Value:"true"},
    {Key:"access_logs.s3.bucket",Value:$bucket},
    {Key:"access_logs.s3.prefix",Value:"alb"}
  ]
}')"

cat >"$tmp/policy.json" <<'POLICY'
{
  "Statement": [
    {"Sid":"AllowALBLogDelivery","Effect":"Allow",
      "Principal":{"Service":"logdelivery.elasticloadbalancing.amazonaws.com"},
      "Action":"s3:PutObject",
      "Resource":"arn:aws:s3:::test-prod-alb-access-logs-12345678/alb/AWSLogs/123456789012/*",
      "Condition":{"ArnLike":{"aws:SourceArn":"arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/*"}}},
    {"Sid":"DenyDeleteLogs","Effect":"Deny","Principal":"*",
      "Action":["s3:DeleteObject","s3:DeleteObjectVersion"],
      "Resource":"arn:aws:s3:::test-prod-alb-access-logs-12345678/*"},
    {"Sid":"DenyBucketPolicyChanges","Effect":"Deny","Principal":"*",
      "Action":["s3:PutBucketPolicy","s3:DeleteBucketPolicy"],
      "Resource":"arn:aws:s3:::test-prod-alb-access-logs-12345678",
      "Condition":{"ArnNotEquals":{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/ApplyRole"]}}},
    {"Sid":"DenyProtectedBucketConfigurationChanges","Effect":"Deny","Principal":"*",
      "Action":["s3:PutLifecycleConfiguration","s3:PutBucketPublicAccessBlock",
                "s3:DeleteBucketPublicAccessBlock","s3:PutEncryptionConfiguration",
                "s3:PutBucketOwnershipControls","s3:DeleteBucketOwnershipControls"],
      "Resource":"arn:aws:s3:::test-prod-alb-access-logs-12345678",
      "Condition":{"ArnNotEquals":{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/ApplyRole"]}}},
    {"Sid":"DenyVersioningChanges","Effect":"Deny","Principal":"*",
      "Action":"s3:PutBucketVersioning",
      "Resource":"arn:aws:s3:::test-prod-alb-access-logs-12345678",
      "Condition":{"ArnNotEquals":{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/ApplyRole"]}}},
    {"Sid":"DenyInsecureTransport","Effect":"Deny","Principal":"*",
      "Action":"s3:*",
      "Resource":["arn:aws:s3:::test-prod-alb-access-logs-12345678",
                  "arn:aws:s3:::test-prod-alb-access-logs-12345678/*"],
      "Condition":{"Bool":{"aws:SecureTransport":"false"}}}
  ]
}
POLICY

aws() {
  [[ "$1" == "s3api" ]] || fail "Unexpected AWS service: $1"
  [[ "${MOCK_NO_S3_CALLS:-false}" != "true" ]] || fail "S3 was called while logging was disabled"
  case "$2" in
    head-bucket) [[ "${MOCK_MISSING_BUCKET:-false}" != "true" ]] ;;
    get-bucket-encryption)
      printf '{"ServerSideEncryptionConfiguration":{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"%s"}}]}}\n' \
        "${MOCK_SSE:-AES256}" ;;
    get-public-access-block)
      printf '{"PublicAccessBlockConfiguration":{"BlockPublicAcls":true,"BlockPublicPolicy":%s,"IgnorePublicAcls":true,"RestrictPublicBuckets":true}}\n' \
        "${MOCK_PUBLIC_POLICY_BLOCK:-true}" ;;
    get-bucket-ownership-controls)
      printf '{"OwnershipControls":{"Rules":[{"ObjectOwnership":"%s"}]}}\n' \
        "${MOCK_OWNER:-BucketOwnerEnforced}" ;;
    get-bucket-versioning)
      printf '{"Status":"%s"}\n' "${MOCK_VERSION:-Enabled}" ;;
    get-bucket-lifecycle-configuration)
      printf '{"Rules":[{"ID":"alb-access-logs-retention","Status":"Enabled","Filter":{"Prefix":"alb/"},"Expiration":{"Days":%s},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}\n' \
        "${MOCK_RETENTION:-90}" ;;
    get-bucket-policy)
      cat "${MOCK_POLICY_FILE:-$tmp/policy.json}" ;;
    *) fail "Unexpected AWS API: $2" ;;
  esac
}

check_both() {
  validate_alb_output
  ecs_runtime_validate_alb_access_logs "$ALB_ATTRIBUTES_JSON" "$ALB_ARN"
}

expect_pass() {
  local label="$1"
  if ! (check_both) >"$tmp/out" 2>&1; then
    echo "[FAIL] Expected pass: $label" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  passed=$((passed + 1))
}
expect_fail() {
  local label="$1"
  if (check_both) >"$tmp/out" 2>&1; then
    echo "[FAIL] Expected failure: $label" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

expect_pass "Enabled ALB logging with protected S3 bucket"
MOCK_SSE="aws:kms" expect_fail "Wrong bucket encryption"
MOCK_PUBLIC_POLICY_BLOCK=false expect_fail "Public access block disabled"
MOCK_OWNER=ObjectWriter expect_fail "BucketOwnerEnforced missing"
MOCK_VERSION=Suspended expect_fail "Versioning disabled"
MOCK_RETENTION=30 expect_fail "Lifecycle expiration differs from output"
MOCK_MISSING_BUCKET=true expect_fail "Missing log bucket"

jq 'del(.Statement[] | select(.Sid == "DenyDeleteLogs"))' \
  "$tmp/policy.json" >"$tmp/bad-policy.json"
MOCK_POLICY_FILE="$tmp/bad-policy.json" expect_fail "Missing object-delete deny"

jq 'del(.Statement[] | select(.Sid == "DenyProtectedBucketConfigurationChanges"))' \
  "$tmp/policy.json" >"$tmp/missing-config-deny.json"
MOCK_POLICY_FILE="$tmp/missing-config-deny.json" expect_fail "Missing bucket-configuration deny"

jq '(.Statement[] | select(.Sid == "DenyProtectedBucketConfigurationChanges") | .Action) |=
  map(select(. != "s3:PutLifecycleConfiguration"))' \
  "$tmp/policy.json" >"$tmp/weak-config-deny.json"
MOCK_POLICY_FILE="$tmp/weak-config-deny.json" expect_fail "Lifecycle configuration change must be restricted"

jq '(.Statement[] | select(.Sid == "DenyDeleteLogs") | .Condition) =
  {"StringEquals":{"aws:PrincipalArn":"arn:aws:iam::123456789012:root"}}' \
  "$tmp/policy.json" >"$tmp/conditional-delete-deny.json"
MOCK_POLICY_FILE="$tmp/conditional-delete-deny.json" \
  expect_fail "Conditional object-delete deny is insufficient"

bad_attributes="$(jq '.Attributes[] |= if .Key == "access_logs.s3.enabled" then .Value="false" else . end' \
  <<< "$ALB_ATTRIBUTES_JSON")"
ALB_ATTRIBUTES_JSON="$bad_attributes" expect_fail "Live ALB logging disabled unexpectedly"

bad_metadata="$(jq '.access_logs.force_destroy = true' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
APPLICATION_LOAD_BALANCER_JSON="$bad_metadata" expect_fail "Logging force_destroy violates lifecycle output"

bad_metadata="$(jq '.access_logs.retention_days = 0' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
APPLICATION_LOAD_BALANCER_JSON="$bad_metadata" expect_fail "Invalid retention output"

disabled="$(jq '.access_logs |= (.enabled=false | .bucket_name=null | .bucket_arn=null | .prefix=null | .retention_days=null | .force_destroy=null)' <<< "$APPLICATION_LOAD_BALANCER_JSON")"
disabled_attributes='{"Attributes":[{"Key":"access_logs.s3.enabled","Value":"false"}]}'
APPLICATION_LOAD_BALANCER_JSON="$disabled" ALB_ATTRIBUTES_JSON="$disabled_attributes" \
  MOCK_NO_S3_CALLS=true expect_pass "Disabled logging never contacts S3"

APPLICATION_LOAD_BALANCER_JSON='null'
if ! (validate_alb_output) >"$tmp/out" 2>&1; then
  cat "$tmp/out" >&2
  fail "Null ALB output should be allowed"
fi
passed=$((passed + 1))

echo "[PASS] $passed offline ALB logging runtime validation scenarios."
