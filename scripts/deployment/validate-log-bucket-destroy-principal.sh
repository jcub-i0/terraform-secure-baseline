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

deployment_profile="$(terraform -chdir="$working_dir" output -raw deployment_profile)" ||
  fail 'Cannot read applied deployment profile.'
[[ "$deployment_profile" == production ]] || fail 'Log-bucket preflight requires applied production profile.'
lifecycle="$(terraform -chdir="$working_dir" output -json lifecycle_protection)" ||
  fail 'Cannot read applied lifecycle posture.'
jq -e '.production_retirement_mode == true and .centralized_logs_force_destroy == true' \
  <<< "$lifecycle" >/dev/null || fail 'Production log force_destroy is not enabled in applied outputs.'

bucket="$(terraform -chdir="$working_dir" output -raw centralized_logs_bucket_name)" ||
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

policy="$(aws s3api get-bucket-policy --bucket "$bucket" "${aws_args[@]}" \
  --query Policy --output text)" ||
  fail 'Cannot read the live centralized logs bucket policy.'

# Require precisely the expected policy SIDs and ArnNotEquals role exception.
# aws:PrincipalArn is single-valued; reject obsolete ForAnyValue:ArnNotEquals
# rather than treating that incorrect IAM condition operator as equivalent.
jq -e --arg role "$expected_role" --arg bucket "arn:${partition}:s3:::${bucket}" '
  def as_list: if type == "array" then . else [.] end;
  (.Statement | as_list) as $statements
  | ([$statements[] | select(
      .Sid == "DenyBucketPolicyChanges" and .Effect == "Deny"
      and (.Action | as_list | index("s3:DeleteBucketPolicy") != null)
      and (.Resource | as_list | index($bucket) != null)
      and (.Condition.ArnNotEquals["aws:PrincipalArn"]
           | as_list | index($role) != null)
    )] | length == 1)
  and ([$statements[] | select(
      .Sid == "DenyDeleteLogs" and .Effect == "Deny"
      and (.Action | as_list | index("s3:DeleteObject") != null)
      and (.Action | as_list | index("s3:DeleteObjectVersion") != null)
      and (.Resource | as_list | index($bucket + "/*") != null)
    )] | length == 1)
' <<< "$policy" >/dev/null ||
  fail 'Live S3 policy does not contain the expected log-delete deny and Apply-role exception.'

printf '[PASS] Live log bucket %s policy allows the expected Apply-role exception; caller identity matches.\n' "$bucket"
printf '[WARN] This read-only check cannot prove s3:DeleteBucketPolicy authorization or successful provider teardown.\n'
