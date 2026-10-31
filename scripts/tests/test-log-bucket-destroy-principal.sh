#!/usr/bin/env bash
set -euo pipefail

# Fast offline negative-path tests for the live S3 bucket-policy role preflight.
# AWS and Terraform are mocks; this suite does NOT qualify real S3 destruction.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${ROOT}/scripts/deployment/validate-log-bucket-destroy-principal.sh"
cleanup="${ROOT}/scripts/deployment/cleanup-retirement-durable-data.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/terraform-root"
pass=0

assert_success() {
  if ! "$@" >"$tmp/out" 2>&1; then
    cat "$tmp/out" >&2
    printf 'Expected success: %s\n' "$*" >&2
    exit 1
  fi
  pass=$((pass + 1))
}
assert_failure() {
  if "$@" >"$tmp/out" 2>&1; then
    printf 'Unexpected success: %s\n' "$*" >&2
    exit 1
  fi
  pass=$((pass + 1))
}

# The direct apply-mode entry point must fail before any AWS mutation when the
# expected IAM role is omitted; plan mode remains free of this new input.
assert_failure bash "$cleanup" prod --mode apply \
  --confirm DELETE-DURABLE-DATA --expected-account-id 123456789012

cat >"$tmp/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -chdir=* && "$2" == output && "$3" == -json && $# -eq 3 ]] || exit 1
[[ "${MOCK_TF_OUTPUT_FAIL:-false}" != "true" ]] || exit 1
# Full output JSON. The optional ALB output is genuinely absent when requested.
jq -nc \
  --arg profile "${MOCK_TF_PROFILE:-production}" \
  --arg bucket "sample-prod-centralized-logs-12345678" \
  --arg force "${MOCK_FORCE_DESTROY:-true}" \
  --arg alb_force "${MOCK_ALB_FORCE_DESTROY:-true}" \
  --arg absent "${MOCK_ALB_OUTPUT_ABSENT:-false}" \
  --arg missing "${MOCK_TF_OMIT_BUCKET:-false}" \
  --argjson alb "${MOCK_ALB_JSON:-null}" '{
    deployment_profile:{value:$profile},
    lifecycle_protection:{value:{
      production_retirement_mode:true,
      centralized_logs_force_destroy:($force == "true"),
      alb_access_logs_force_destroy:($alb_force == "true")
    }},
    centralized_logs_bucket_name:{value:$bucket}
  }
  + (if $absent == "true" then {} else {application_load_balancer:{value:$alb}} end)
  | if $missing == "true" then del(.centralized_logs_bucket_name) else . end'
MOCK
cat >"$tmp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
# Verify the selected credential profile is explicit and is not accidentally
# overwritten by the Terraform deployment_profile=production output.
if [[ -n "${MOCK_EXPECT_PROFILE:-}" ]]; then
  [[ " $* " == *" --profile ${MOCK_EXPECT_PROFILE} "* ]] || exit 20
else
  [[ " $* " != *" --profile "* ]] || exit 21
fi
case "$1:$2" in
  sts:get-caller-identity)
    printf '{"Account":"123456789012","Arn":"%s"}\n' "${MOCK_CALLER_ARN:-arn:aws:sts::123456789012:assumed-role/TerraformApplyRole/test-run}" ;;
  s3api:get-bucket-policy)
    case " $* " in
      *" --bucket sample-prod-centralized-logs-12345678 "*) cat "$MOCK_POLICY_FILE" ;;
      *" --bucket sample-prod-alb-access-logs-12345678 "*) cat "$MOCK_ALB_POLICY_FILE" ;;
      *) exit 2 ;;
    esac ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/terraform" "$tmp/bin/aws"

cat >"$tmp/policy.json" <<'POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"DenyBucketPolicyChanges","Effect":"Deny","Principal":"*",
     "Action":["s3:PutBucketPolicy","s3:DeleteBucketPolicy"],
     "Resource":"arn:aws:s3:::sample-prod-centralized-logs-12345678",
     "Condition":{"ArnNotEquals":{"aws:PrincipalArn":[
       "arn:aws:iam::123456789012:role/TerraformApplyRole",
       "arn:aws:iam::123456789012:role/EmergencyAdmin"
     ]}}},
    {"Sid":"DenyDeleteLogs","Effect":"Deny","Principal":"*",
     "Action":["s3:DeleteObject","s3:DeleteObjectVersion"],
     "Resource":"arn:aws:s3:::sample-prod-centralized-logs-12345678/*"}
  ]
}
POLICY
export MOCK_POLICY_FILE="$tmp/policy.json"
args=(
  --working-directory "$tmp/terraform-root"
  --expected-account-id 123456789012
  --expected-role-arn arn:aws:iam::123456789012:role/TerraformApplyRole
  --region us-east-1
)
assert_success env PATH="$tmp/bin:$PATH" bash "$guard" "${args[@]}"
assert_success env PATH="$tmp/bin:$PATH" MOCK_ALB_OUTPUT_ABSENT=true bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_TF_OUTPUT_FAIL=true bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_TF_OMIT_BUCKET=true bash "$guard" "${args[@]}"
assert_success env PATH="$tmp/bin:$PATH" MOCK_EXPECT_PROFILE=target-account \
  bash "$guard" "${args[@]}" --profile target-account
assert_failure env PATH="$tmp/bin:$PATH" MOCK_TF_PROFILE=development bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_FORCE_DESTROY=false bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_CALLER_ARN=arn:aws:sts::123456789012:assumed-role/OtherRole/test bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" bash "$guard" \
  --working-directory "$tmp/terraform-root" --expected-account-id 999999999999 \
  --expected-role-arn arn:aws:iam::123456789012:role/TerraformApplyRole \
  --region us-east-1

jq '(.Statement[] | select(.Sid == "DenyBucketPolicyChanges") | .Condition.ArnNotEquals["aws:PrincipalArn"]) = ["arn:aws:iam::123456789012:role/OtherRole"]' \
  "$tmp/policy.json" > "$tmp/wrong-role.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/wrong-role.json" bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_ALB_OUTPUT_ABSENT=true MOCK_POLICY_FILE="$tmp/wrong-role.json" bash "$guard" "${args[@]}"

jq 'del(.Statement[] | select(.Sid == "DenyDeleteLogs"))' \
  "$tmp/policy.json" > "$tmp/no-deny.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/no-deny.json" bash "$guard" "${args[@]}"

jq '(.Statement[] | select(.Sid == "DenyBucketPolicyChanges") | .Condition) = {
  "ForAnyValue:ArnNotEquals":{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/TerraformApplyRole"]}
}' "$tmp/policy.json" > "$tmp/legacy-set-operator.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/legacy-set-operator.json" bash "$guard" "${args[@]}"

jq '(.Statement[] | select(.Sid == "DenyDeleteLogs") | .Action) = ["s3:DeleteObject"]' \
  "$tmp/policy.json" > "$tmp/missing-version-deny.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/missing-version-deny.json" bash "$guard" "${args[@]}"


# When an ALB log bucket is deployed, verify both live policies.
cat >"$tmp/alb-policy.json" <<'ALB_POLICY'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid":"DenyBucketPolicyChanges","Effect":"Deny","Principal":"*",
     "Action":["s3:PutBucketPolicy","s3:DeleteBucketPolicy"],
     "Resource":"arn:aws:s3:::sample-prod-alb-access-logs-12345678",
     "Condition":{"ArnNotEquals":{"aws:PrincipalArn":[
       "arn:aws:iam::123456789012:role/TerraformApplyRole"
     ]}}},
    {"Sid":"DenyDeleteLogs","Effect":"Deny","Principal":"*",
     "Action":["s3:DeleteObject","s3:DeleteObjectVersion"],
     "Resource":"arn:aws:s3:::sample-prod-alb-access-logs-12345678/*"}
  ]
}
ALB_POLICY

export MOCK_ALB_POLICY_FILE="$tmp/alb-policy.json"
export MOCK_ALB_JSON='{"access_logs":{"enabled":true,"bucket_name":"sample-prod-alb-access-logs-12345678","bucket_arn":"arn:aws:s3:::sample-prod-alb-access-logs-12345678","prefix":"alb","force_destroy":true}}'

assert_success env PATH="$tmp/bin:$PATH" bash "$guard" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_ALB_FORCE_DESTROY=false bash "$guard" "${args[@]}"

jq 'del(.Statement[] | select(.Sid == "DenyDeleteLogs"))' \
  "$tmp/alb-policy.json" > "$tmp/alb-no-delete-deny.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_ALB_POLICY_FILE="$tmp/alb-no-delete-deny.json" bash "$guard" "${args[@]}"

jq '(.Statement[] | select(.Sid == "DenyBucketPolicyChanges") |
  .Condition.ArnNotEquals["aws:PrincipalArn"]) =
  ["arn:aws:iam::123456789012:role/OtherRole"]' \
  "$tmp/alb-policy.json" > "$tmp/alb-wrong-role.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_ALB_POLICY_FILE="$tmp/alb-wrong-role.json" bash "$guard" "${args[@]}"

assert_failure env PATH="$tmp/bin:$PATH" MOCK_ALB_JSON='{"access_logs":{"enabled":true,"bucket_name":null}}' \
  bash "$guard" "${args[@]}"

assert_success env PATH="$tmp/bin:$PATH" \
  MOCK_ALB_JSON='{"access_logs":{"enabled":false,"bucket_name":null,"bucket_arn":null}}' \
  bash "$guard" "${args[@]}"

unset MOCK_ALB_JSON

printf '[PASS] %d offline log-bucket role preflight cases.\n' "$pass"
