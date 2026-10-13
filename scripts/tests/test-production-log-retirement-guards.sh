#!/usr/bin/env bash
set -euo pipefail

# Offline checks only: AWS and Terraform are mocked; no cloud operations occur.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
auth="${ROOT}/scripts/deployment/validate-retirement-log-authorization.sh"
principal="${ROOT}/scripts/deployment/validate-log-bucket-destroy-principal.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/terraform-root"
pass=0
assert_success() {
  if ! "$@" >"$tmp/out" 2>&1; then
    cat "$tmp/out" >&2
    printf 'Expected success: %s\n' "$*" >&2; exit 1
  fi
  pass=$((pass + 1))
}
assert_failure() {
  if "$@" >"$tmp/out" 2>&1; then
    printf 'Unexpected success: %s\n' "$*" >&2; exit 1
  fi
  pass=$((pass + 1))
}

assert_success env DEPLOYMENT_PROFILE=development bash "$auth"
assert_success env -u DEPLOYMENT_PROFILE TF_VAR_deployment_profile=development bash "$auth"
assert_success env -u DEPLOYMENT_PROFILE TF_VAR_deployment_profile=production AUDIT_LOG_DISPOSITION_CONFIRMED=true AUDIT_LOG_DISPOSITION_REFERENCE=CHG-12345 bash "$auth"
assert_failure env DEPLOYMENT_PROFILE=development AUDIT_LOG_DISPOSITION_CONFIRMED=true bash "$auth"
assert_failure env DEPLOYMENT_PROFILE=development AUDIT_LOG_DISPOSITION_REFERENCE=CHG-123 bash "$auth"
assert_failure env DEPLOYMENT_PROFILE=production bash "$auth"
assert_failure env DEPLOYMENT_PROFILE=production AUDIT_LOG_DISPOSITION_CONFIRMED=true bash "$auth"
assert_failure env DEPLOYMENT_PROFILE=production AUDIT_LOG_DISPOSITION_CONFIRMED=true AUDIT_LOG_DISPOSITION_REFERENCE=TODO bash "$auth"
assert_success env DEPLOYMENT_PROFILE=production AUDIT_LOG_DISPOSITION_CONFIRMED=true AUDIT_LOG_DISPOSITION_REFERENCE=CHG-12345 bash "$auth"

cat >"$tmp/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -chdir=* && "$2" == output ]] || exit 1
case "$3:$4" in
  -raw:deployment_profile) printf '%s\n' "${MOCK_TF_PROFILE:-production}" ;;
  -raw:centralized_logs_bucket_name) printf 'sample-prod-centralized-logs-12345678\n' ;;
  -json:lifecycle_protection)
    printf '{"production_retirement_mode":true,"centralized_logs_force_destroy":%s}\n' "${MOCK_FORCE_DESTROY:-true}" ;;
  *) exit 1 ;;
esac
MOCK
cat >"$tmp/bin/aws" <<'MOCK'
#!/usr/bin/env bash
case "$1:$2" in
  sts:get-caller-identity)
    printf '{"Account":"123456789012","Arn":"%s"}\n' "${MOCK_CALLER_ARN:-arn:aws:sts::123456789012:assumed-role/TerraformApplyRole/test-run}" ;;
  s3api:get-bucket-policy)
    cat "$MOCK_POLICY_FILE" ;;
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
     "Condition":{"ForAnyValue:ArnNotEquals":{"aws:PrincipalArn":["arn:aws:iam::123456789012:role/TerraformApplyRole","arn:aws:iam::123456789012:role/EmergencyAdmin"]}}},
    {"Sid":"DenyDeleteLogs","Effect":"Deny","Principal":"*",
     "Action":["s3:DeleteObject","s3:DeleteObjectVersion"],
     "Resource":"arn:aws:s3:::sample-prod-centralized-logs-12345678/*"}
  ]
}
POLICY
export MOCK_POLICY_FILE="$tmp/policy.json"
args=(--working-directory "$tmp/terraform-root" --expected-account-id 123456789012 --expected-role-arn arn:aws:iam::123456789012:role/TerraformApplyRole --region us-east-1)
assert_success env PATH="$tmp/bin:$PATH" bash "$principal" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_TF_PROFILE=development bash "$principal" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_FORCE_DESTROY=false bash "$principal" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_CALLER_ARN=arn:aws:sts::123456789012:assumed-role/OtherRole/test bash "$principal" "${args[@]}"
assert_failure env PATH="$tmp/bin:$PATH" bash "$principal" --working-directory "$tmp/terraform-root" --expected-account-id 999999999999 --expected-role-arn arn:aws:iam::123456789012:role/TerraformApplyRole --region us-east-1

jq '(.Statement[] | select(.Sid == "DenyBucketPolicyChanges") | .Condition["ForAnyValue:ArnNotEquals"]["aws:PrincipalArn"]) = ["arn:aws:iam::123456789012:role/OtherRole"]' "$tmp/policy.json" > "$tmp/wrong-role.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/wrong-role.json" bash "$principal" "${args[@]}"
jq 'del(.Statement[] | select(.Sid == "DenyDeleteLogs"))' "$tmp/policy.json" > "$tmp/no-deny.json"
assert_failure env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/no-deny.json" bash "$principal" "${args[@]}"
jq '(.Statement[] | select(.Sid == "DenyBucketPolicyChanges") | .Condition) = {"ArnNotEquals":{"aws:PrincipalArn":"arn:aws:iam::123456789012:role/TerraformApplyRole"}}' "$tmp/policy.json" > "$tmp/standard-arn.json"
assert_success env PATH="$tmp/bin:$PATH" MOCK_POLICY_FILE="$tmp/standard-arn.json" bash "$principal" "${args[@]}"

printf '[PASS] %d offline audit-log authorization and S3 policy tests.\n' "$pass"
