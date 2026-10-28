#!/usr/bin/env bash
set -euo pipefail

# Read-only guard for the exact saved Terraform Apply plan.
# Protects Terraform-managed ALB access logs without affecting the approved
# standalone Destroy workflow. Stage-1 is permitted only when the caller passes
# the EXISTING production_retirement_mode workflow input as --retirement-mode.
# This is plan validation, not proof of S3 delivery or Terraform delete order.

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }
success() { printf '[PASS] %s\n' "$*"; }

usage() {
  cat <<'USAGE'
Usage:
  validate-alb-access-logging-plan.sh \
    --working-directory <path> --plan-file <path> \
    [--retirement-mode true|false]

--retirement-mode defaults to false. Pass the existing protected Apply workflow
input, not an independently supplied authorization. Stage-1 also requires the
separate validate-production-retirement-plan.sh check of the SAME saved plan.
USAGE
}

working_directory=""
plan_file=""
retirement_mode=false
plan_json=""
trap '[[ -z "$plan_json" ]] || rm -f -- "$plan_json"' EXIT

while (( $# )); do
  case "$1" in
    --working-directory|--plan-file|--retirement-mode)
      (( $# >= 2 )) || fail "Missing value for $1"
      case "$1" in
        --working-directory) working_directory="$2" ;;
        --plan-file) plan_file="$2" ;;
        --retirement-mode) retirement_mode="$2" ;;
      esac
      shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unsupported argument: $1" ;;
  esac
done

[[ -d "$working_directory" ]] || fail 'Terraform working directory is unavailable.'
[[ -f "$plan_file" && ! -L "$plan_file" ]] || fail 'Saved plan is missing or is not a regular file.'
[[ "$retirement_mode" == true || "$retirement_mode" == false ]] || fail 'Retirement mode must be true or false.'
for command in terraform jq mktemp; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

plan_json="$(mktemp)"
chmod 600 "$plan_json"
terraform -chdir="$working_directory" show -json "$plan_file" >"$plan_json" ||
  fail 'Cannot decode the exact saved Terraform plan.'

jq -e '
  type == "object"
  and (.format_version | type == "string" and (split(".")[0] == "1"))
  and .errored != true
  and .complete != false
  and (.resource_changes | type == "array")
  and (.planned_values.outputs.deployment_profile.value | IN("minimal", "development", "production"))
  and (.planned_values.outputs.lifecycle_protection.value.production_retirement_mode | type == "boolean")
' "$plan_json" >/dev/null || fail 'Missing or malformed plan, deployment profile, or lifecycle outputs.'

# A retirement output alone is NOT authorization. Require agreement with the
# existing GitHub workflow input, which also controls the separate Stage-1 gate.
jq -e --argjson requested "$retirement_mode" '
  .planned_values.outputs.lifecycle_protection.value.production_retirement_mode == $requested
  and (if $requested then .planned_values.outputs.deployment_profile.value == "production" else true end)
' "$plan_json" >/dev/null || fail 'Planned retirement posture does not match the authorized Apply workflow input.'

# A single jq pass evaluates the exact plan and its embedded prior state.
# Resource identity is scoped to the existing application_load_balancer module;
# unrelated S3 buckets and other Terraform components are intentionally ignored.
violations="$(jq -r --argjson retirement "$retirement_mode" '
  def is_alb_bucket_resource:
    .mode == "managed" and .name == "access_logs"
    and (.type | startswith("aws_s3_bucket"))
    and ((.address // "") | test("(^|\\.)module\\.application_load_balancer\\[[0-9]+\\]\\.aws_s3_bucket"));

  def is_alb:
    .mode == "managed" and .type == "aws_lb" and .name == "load_balancer"
    and ((.address // "") | test("(^|\\.)module\\.application_load_balancer\\[[0-9]+\\]\\.aws_lb\\.load_balancer$"));

  def item($resources; $type):
    [$resources[] | select(.type == $type)] | if length == 1 then .[0] else null end;

  def kept($r):
    $r != null and (
      $r.change.actions == ["create"] or
      $r.change.actions == ["no-op"] or
      $r.change.actions == ["update"]
    );

  def retention($r): $r.change.after.rule[0].expiration[0].days;
  def old_retention($r): $r.change.before.rule[0].expiration[0].days;

  def lifecycle_ok($r):
    kept($r)
    and ($r.change.after.rule | type == "array" and length == 1)
    and $r.change.after.rule[0].id == "alb-access-logs-retention"
    and $r.change.after.rule[0].status == "Enabled"
    and $r.change.after.rule[0].filter[0].prefix == "alb/"
    and (retention($r) | type == "number" and . >= 1 and . == floor)
    and $r.change.after.rule[0].noncurrent_version_expiration[0].noncurrent_days == 1;

  def as_list: if type == "array" then . else [.] end;
  def statement($ss; $sid):
    [$ss[] | select(.Sid == $sid)] | if length == 1 then .[0] else null end;
  def includes($actual; $needed):
    ($actual | as_list) as $items
    | all($needed[]; . as $need | ($items | index($need) != null));
  def all_principals($s):
    $s.Principal == "*" or $s.Principal.AWS == "*";

  # Validate the five existing M2 statements whenever the policy JSON is
  # known. An initial create may leave it unknown until the bucket ARN exists;
  # require that case to be a genuine policy creation, not an existing update.
  def policy_ok($r; $bucket_name; $alb_name):
    kept($r) and (
      if ($r.change.after.policy | type) == "string" then
        try (
          ($r.change.after.policy | fromjson | .Statement) as $ss
          | (statement($ss; "AllowALBLogDelivery")) as $allow
          | (statement($ss; "DenyDeleteLogs")) as $delete
          | (statement($ss; "DenyBucketPolicyChanges")) as $admin
          | (statement($ss; "DenyVersioningChanges")) as $version
          | (statement($ss; "DenyInsecureTransport")) as $https
          | ($admin.Resource | as_list | .[0]) as $arn
          | ($allow.Condition.ArnLike["aws:SourceArn"] | as_list | .[0]
             | capture("^arn:(?<partition>aws|aws-us-gov|aws-cn):elasticloadbalancing:(?<region>[a-z0-9-]+):(?<account>[0-9]{12}):loadbalancer/app/(?<name>[^/]+)/\\*$")) as $source
          | ($ss | type == "array" and length == 5)
            and ($arn == "arn:" + $source.partition + ":s3:::" + $bucket_name)
            and ($source.name == $alb_name)
            and ($allow.Effect == "Allow")
            and ($allow.Principal.Service == "logdelivery.elasticloadbalancing.amazonaws.com")
            and (($allow.Action | as_list) == ["s3:PutObject"])
            and (($allow.Resource | as_list) == [$arn + "/alb/AWSLogs/" + $source.account + "/*"])
            and ($delete.Effect == "Deny" and all_principals($delete))
            and includes($delete.Action; ["s3:DeleteObject", "s3:DeleteObjectVersion"])
            and (($delete.Resource | as_list) == [$arn + "/*"])
            and ($admin.Effect == "Deny" and all_principals($admin))
            and includes($admin.Action; ["s3:PutBucketPolicy", "s3:DeleteBucketPolicy"])
            and (($admin.Resource | as_list) == [$arn])
            and ($admin.Condition.ArnNotEquals["aws:PrincipalArn"] | as_list
                 | length > 0 and all(.[]; type == "string" and (contains("*") | not)))
            and ($version.Effect == "Deny" and all_principals($version))
            and includes($version.Action; ["s3:PutBucketVersioning"])
            and (($version.Resource | as_list) == [$arn])
            and ($version.Condition.ArnNotEquals["aws:PrincipalArn"] ==
                 $admin.Condition.ArnNotEquals["aws:PrincipalArn"])
            and ($https.Effect == "Deny" and all_principals($https))
            and includes($https.Action; ["s3:*"])
            and (($https.Resource | as_list | sort) == ([$arn, $arn + "/*"] | sort))
            and includes($https.Condition.Bool["aws:SecureTransport"]; ["false"])
        ) catch false
      else
        $r.change.actions == ["create"] and $r.change.after_unknown.policy == true
      end
    );

  . as $p
  | ([.resource_changes[] | select(is_alb_bucket_resource)]) as $resources
  | ([.resource_changes[] | select(is_alb)]) as $lbs
  | ([.prior_state.values.root_module | recurse(.child_modules[]?)
       | .resources[]? | select(is_alb_bucket_resource and .type == "aws_s3_bucket")]) as $previous
  | ([$resources[] | select(.type == "aws_s3_bucket" and .change.before != null)]) as $previous_changes
  | ($p.prior_state.values.outputs.deployment_profile.value // null) as $old_profile
  | $p.planned_values.outputs.deployment_profile.value as $new_profile
  | (item($resources; "aws_s3_bucket")) as $bucket
  | (item($resources; "aws_s3_bucket_public_access_block")) as $public
  | (item($resources; "aws_s3_bucket_server_side_encryption_configuration")) as $encryption
  | (item($resources; "aws_s3_bucket_ownership_controls")) as $ownership
  | (item($resources; "aws_s3_bucket_versioning")) as $versioning
  | (item($resources; "aws_s3_bucket_lifecycle_configuration")) as $lifecycle
  | (item($resources; "aws_s3_bucket_policy")) as $policy
  | ($lbs | if length == 1 then .[0] else null end) as $lb
  | (($previous | length) == 1 and $old_profile == "production") as $protected
  | (kept($bucket)) as $bucket_stays
  | (($lb.change.after.access_logs[0].enabled // false) == true) as $alb_logging
  | ($protected or $bucket_stays or $alb_logging) as $requires_bucket
  | [
      if ($previous | length) > 1 then "Multiple prior ALB log buckets found" else empty end,
      if ($previous_changes | length) > 0 and ($previous | length) == 0 then "Saved plan lacks prior ALB bucket state" else empty end,
      if ($previous | length) > 0 and (($old_profile | IN("minimal", "development", "production")) | not) then "Cannot determine prior deployment profile" else empty end,
      if ($protected and $new_profile != "production") then "Production profile downgrade would bypass protected ALB logging" else empty end,
      if ([ $resources[].type ] | length) != ([ $resources[].type ] | unique | length) then "Multiple ALB log resources of the same type found" else empty end,
      if ($lbs | length) > 1 then "Multiple managed ALBs found" else empty end,
      if ($requires_bucket and (kept($bucket) | not)) then "ALB log bucket would be deleted or replaced" else empty end,
      if ($requires_bucket and ($alb_logging | not)) then "Protected ALB logging must remain enabled" else empty end,
      if ($requires_bucket and $lb.change.after.access_logs[0].prefix != "alb") then "ALB log prefix must remain alb" else empty end,
      if ($requires_bucket and $lb.change.after.access_logs[0].bucket != $bucket.change.after.bucket) then "ALB logging bucket must match the managed S3 bucket" else empty end,
      if ($requires_bucket and ((
        $bucket.change.after.force_destroy == (
          if $new_profile == "production" then $retirement else true end
        )
      ) | not)) then "ALB log bucket force_destroy conflicts with deployment profile or retirement mode" else empty end,
      if ($retirement and $bucket.change.actions == ["create"]) then "Retirement Stage-1 cannot create an ALB log bucket" else empty end,
      if ($requires_bucket and ((
        kept($public) and $public.change.after.block_public_acls == true
        and $public.change.after.block_public_policy == true
        and $public.change.after.ignore_public_acls == true
        and $public.change.after.restrict_public_buckets == true
      ) | not)) then "All four S3 public access blocks must remain enabled" else empty end,
      if ($requires_bucket and ((
        kept($encryption) and $encryption.change.after.rule[0].apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
      ) | not)) then "ALB bucket must retain SSE-S3 encryption" else empty end,
      if ($requires_bucket and ((
        kept($versioning) and $versioning.change.after.versioning_configuration[0].status == "Enabled"
      ) | not)) then "ALB bucket versioning must remain enabled" else empty end,
      if ($requires_bucket and ((
        kept($ownership) and $ownership.change.after.rule[0].object_ownership == "BucketOwnerEnforced"
      ) | not)) then "ALB bucket must retain BucketOwnerEnforced ownership" else empty end,
      if ($requires_bucket and (lifecycle_ok($lifecycle) | not)) then "ALB lifecycle rule or noncurrent expiration is unsafe" else empty end,
      if ($requires_bucket and (policy_ok($policy; $bucket.change.after.bucket; $lb.change.after.name) | not)) then "ALB bucket policy is missing or lacks expected statements" else empty end,
      if ($protected and (old_retention($lifecycle) | type) != "number") then "Cannot establish existing production retention" else empty end,
      if ($protected and (retention($lifecycle) < old_retention($lifecycle))) then "Existing production log retention cannot be shortened" else empty end,
      # Changes to a protected policy require deliberately reviewing this guard;
      # this also prevents silently widening the approved bucket-admin exception.
      if ($protected and $policy.change.actions != ["no-op"]) then "Protected production ALB bucket policy cannot be changed by ordinary Apply" else empty end
    ]
  | .[]
' "$plan_json")" || fail 'Unable to evaluate the saved ALB logging plan.'

if [[ -n "$violations" ]]; then
  while IFS= read -r violation; do
    printf '[FAIL] %s\n' "$violation" >&2
  done <<<"$violations"
  exit 1
fi

success 'Saved ALB access-logging plan satisfies production lifecycle safeguards.'
