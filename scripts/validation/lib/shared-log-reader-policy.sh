#!/usr/bin/env bash

# Source-only checks for the shared S3 log-reader policy. The optional ALB
# output may be omitted; required outputs and unexpected grants fail closed.
shared_log_reader_expected_scopes() {
  local outputs_json="$1"
  local partition="$2"
  local central_bucket alb_bucket_arn central_arn

  central_bucket="$(jq -er '.centralized_logs_bucket_name.value | select(type == "string")' <<< "$outputs_json")" ||
    return 1
  [[ "$central_bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || return 1

  alb_bucket_arn="$(
    jq -er '
      (if has("application_load_balancer") then
        if (.application_load_balancer | type) == "object"
           and (.application_load_balancer | has("value")) then
          .application_load_balancer.value
        else error("Malformed application_load_balancer output") end
      else null end) as $alb
      | if $alb == null then ""
        elif ($alb | type) != "object" then
          error("Invalid ALB metadata")
        elif $alb.access_logs.enabled == true then
          $alb.access_logs as $logs
          | if (
              ($logs.bucket_name | type) == "string"
              and ($logs.bucket_name | length) > 0
              and ($logs.bucket_arn | type) == "string"
              and ($logs.bucket_arn | endswith(":s3:::" + $logs.bucket_name))
            ) then $logs.bucket_arn
            else error("Invalid ALB access-log bucket metadata") end
        elif $alb.access_logs.enabled == false
          and $alb.access_logs.bucket_name == null
          and $alb.access_logs.bucket_arn == null then ""
        else error("Invalid disabled ALB access-log metadata") end
    ' <<< "$outputs_json"
  )" || return 1

  central_arn="arn:$partition:s3:::$central_bucket"
  jq -nc --arg central "$central_arn" --arg alb "$alb_bucket_arn" '{
    bucket_resources: ([$central] + (if $alb == "" then [] else [$alb] end) | sort),
    object_resources: ([$central + "/*"] + (if $alb == "" then [] else [$alb + "/alb/*"] end) | sort)
  }'
}

shared_log_reader_policy_matches() {
  local policy_json="$1"
  local expected_scopes_json="$2"

  jq -e --argjson expected "$expected_scopes_json" '
    def as_list: if type == "array" then . else [.] end;
    (.Statement | as_list) as $ss
    | ($ss | length) == 2
      and ([$ss[].Sid] | sort) == ["ListManagedLogBuckets","ReadManagedLogObjects"]
      and all($ss[];
        .Effect == "Allow"
        and (.Condition == null)
        and (.NotAction == null)
        and (.NotResource == null)
      )
      and ([$ss[] | select(.Sid == "ListManagedLogBuckets")][0] as $list
        | ($list.Action | as_list | sort) == (["s3:ListBucket","s3:GetBucketLocation"] | sort)
        and ($list.Resource | as_list | sort) == $expected.bucket_resources)
      and ([$ss[] | select(.Sid == "ReadManagedLogObjects")][0] as $read
        | ($read.Action | as_list | sort) ==
          (["s3:GetObject","s3:GetObjectVersion","s3:GetObjectTagging","s3:GetObjectVersionTagging"] | sort)
        and ($read.Resource | as_list | sort) == $expected.object_resources)
  ' <<< "$policy_json" >/dev/null
}
