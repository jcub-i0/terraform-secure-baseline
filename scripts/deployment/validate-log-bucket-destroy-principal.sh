#!/usr/bin/env bash
set -euo pipefail

# Read-only preflight for the role used in a production Terraform destroy.
# Checks identity and the live S3 policy's explicit bucket-policy-change deny.
# Does not prove that IAM, SCPs, permissions boundaries, or S3 delete succeed.

export AWS_PAGER=""

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

working_dir=""
expected_account=""
expected_role=""
region=""
aws_profile="${AWS_PROFILE:-}"

while (( $# )); do
  case "$1" in
    --working-directory|--expected-account-id|--expected-role-arn|--region|--profile)
      (( $# >= 2 )) || fail "Missing value for $1"
      case "$1" in
        --working-directory) working_dir="$2" ;;
        --expected-account-id) expected_account="$2" ;;
        --expected-role-arn) expected_role="$2" ;;
        --region) region="$2" ;;
        --profile) aws_profile="$2" ;;
      esac
      shift 2 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -d "$working_dir" ]] || fail 'Terraform working directory is unavailable.'
[[ "$expected_account" =~ ^[0-9]{12}$ ]] || fail 'Invalid expected AWS account ID.'
[[ "$region" =~ ^[a-z0-9]+(-[a-z0-9]+)+-[0-9]+$ ]] || fail 'Invalid AWS Region.'

if [[ "$expected_role" =~ ^arn:([^:]+):iam::([0-9]{12}):role/(.+)$ ]]; then
  partition="${BASH_REMATCH[1]}"
  role_account="${BASH_REMATCH[2]}"
  role_name="${BASH_REMATCH[3]##*/}"
else
  fail 'Expected Apply role must be an IAM role ARN.'
fi

[[ "$role_account" == "$expected_account" ]] || fail 'Apply role is in the wrong account.'

for command in aws terraform jq; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

# Read one complete Terraform output snapshot. Null root outputs can be omitted,
# and querying an absent optional output by name would fail.
outputs_json="$(terraform -chdir="$working_dir" output -json)" ||
  fail 'Cannot read applied Terraform outputs.'
[[ -n "$outputs_json" ]] &&
  jq -e 'type == "object"' <<< "$outputs_json" >/dev/null ||
  fail 'Terraform outputs must be a JSON object.'

deployment_profile="$(jq -er '.deployment_profile.value | select(type == "string")' <<< "$outputs_json")" ||
  fail 'Cannot read applied deployment profile.'

[[ "$deployment_profile" == production ]] || fail 'Log-bucket preflight requires applied production profile.'

lifecycle="$(jq -ce '.lifecycle_protection.value | select(type == "object")' <<< "$outputs_json")" ||
  fail 'Cannot read applied lifecycle posture.'

jq -e '.production_retirement_mode == true and .centralized_logs_force_destroy == true and .alb_access_logs_force_destroy == true' \
  <<< "$lifecycle" >/dev/null || fail 'Production log force_destroy is not enabled in applied outputs.'

bucket="$(jq -er '.centralized_logs_bucket_name.value | select(type == "string")' <<< "$outputs_json")" ||
  fail 'Cannot read centralized logs bucket name.'

[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
  fail 'Invalid centralized logs bucket name.'

aws_args=(--region "$region")

[[ -z "$aws_profile" ]] || aws_args+=(--profile "$aws_profile")

caller="$(aws sts get-caller-identity "${aws_args[@]}" --output json)" ||
  fail 'Cannot resolve the active AWS caller identity.'

caller_account="$(jq -er '.Account' <<< "$caller")" || fail 'Caller has no AWS account.'
caller_arn="$(jq -er '.Arn' <<< "$caller")" || fail 'Caller has no AWS ARN.'

[[ "$caller_account" == "$expected_account" ]] || fail 'AWS caller account mismatch.'

expected_session_prefix="arn:${partition}:sts::${expected_account}:assumed-role/${role_name}/"

[[ "$caller_arn" == "$expected_session_prefix"* ]] ||
  fail 'AWS caller is not a session of the expected Apply role.'

verify_log_bucket_policy() {
  local bucket_name="$1"
  local policy_json

  policy_json="$(aws s3api get-bucket-policy \
    --bucket "$bucket_name" "${aws_args[@]}" \
    --query Policy --output text)" ||
    fail "Cannot read live log-bucket policy: $bucket_name"

  # Both buckets must exempt the actual Apply role from their policy-change
  # denial and prohibit direct deletion of objects and versions.
  jq -e --arg role "$expected_role" --arg bucket "arn:$partition:s3:::$bucket_name" '
    def as_list: if type == "array" then . else [.] end;
    def everyone: .Principal == "*" or .Principal.AWS == "*";
    (.Statement | as_list) as $statements
    | ([$statements[] | select(
        .Sid == "DenyBucketPolicyChanges" and .Effect == "Deny"
        and everyone
        and (.Action | as_list | index("s3:PutBucketPolicy") != null)
        and (.Action | as_list | index("s3:DeleteBucketPolicy") != null)
        and (.Resource | as_list | index($bucket) != null)
        and (.Condition.ArnNotEquals["aws:PrincipalArn"]
             | as_list | index($role) != null)
      )] | length == 1)
    and ([$statements[] | select(
        .Sid == "DenyDeleteLogs" and .Effect == "Deny"
        and everyone
        and (.Action | as_list | index("s3:DeleteObject") != null)
        and (.Action | as_list | index("s3:DeleteObjectVersion") != null)
        and (.Resource | as_list | index($bucket + "/*") != null)
      )] | length == 1)
  ' <<< "$policy_json" >/dev/null ||
    fail "Log-bucket policy lacks required denies or Apply-role exception: $bucket_name"

  printf '[PASS] Live log-bucket policy and Apply-role exception verified: %s\n' "$bucket_name"
}

verify_log_bucket_policy "$bucket"

alb_json="$(jq -c '
  if has("application_load_balancer") then
    if (.application_load_balancer | type) == "object"
       and (.application_load_balancer | has("value")) then
      .application_load_balancer.value
    else error("Malformed application_load_balancer output") end
  else null end
' <<< "$outputs_json")" ||
  fail 'Cannot resolve optional Application Load Balancer metadata.'

if [[ "$alb_json" != "null" ]]; then
  if ! jq -e '
    .access_logs as $logs
    | ($logs | type) == "object" and ($logs.enabled | type) == "boolean"
  ' <<< "$alb_json" >/dev/null; then
    fail 'Applied ALB output contains malformed logging metadata.'
  fi

  alb_logging_enabled="$(jq -r '.access_logs.enabled' <<< "$alb_json")"
  if [[ "$alb_logging_enabled" == "true" ]]; then
    alb_bucket="$(
      jq -er '
        .access_logs as $logs
        | if (
            ($logs.bucket_name | type) == "string"
            and ($logs.bucket_name | length) > 0
            and ($logs.bucket_arn | type) == "string"
            and ($logs.bucket_arn | endswith(":s3:::" + $logs.bucket_name))
            and $logs.prefix == "alb"
            and $logs.force_destroy == true
          ) then $logs.bucket_name
          else error("ALB log bucket metadata is not retirement-ready") end
      ' <<< "$alb_json"
    )" || fail 'Cannot resolve the protected ALB access-log bucket.'

    [[ "$alb_bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
      fail 'Invalid ALB access-log bucket name.'

    verify_log_bucket_policy "$alb_bucket"
  else
    jq -e '
      .access_logs.bucket_name == null
      and .access_logs.bucket_arn == null
    ' <<< "$alb_json" >/dev/null ||
      fail 'Disabled ALB access logging unexpectedly references a bucket.'
  fi
fi

printf '[WARN] Policy inspection does not prove effective S3 deletion permissions or a successful Terraform Destroy.\n'
