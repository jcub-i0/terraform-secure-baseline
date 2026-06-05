#!/usr/bin/env bash

# validate-logging.sh
#
# Validates logging controls for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform outputs are readable
# - VPC can be resolved
# - Centralized logs bucket exists
# - CloudTrail exists
# - CloudTrail is multi-region
# - CloudTrail is actively logging
# - CloudTrail has S3 delivery configured
# - VPC Flow Logs exist for the VPC
# - VPC Flow Logs are active
# - CloudWatch log groups exist for the baseline
# - CloudWatch log group retention matches effective_cloudwatch_retention_days where applicable
#
# Usage:
#   ./scripts/validation/validate-logging.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-logging.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-logging.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "$ENV_NAME"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline Logging Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq found"

require_command git
success "git found"

section "Resolving repository paths and Terraform outputs"

REPO_ROOT="$(get_repo_root)"
ENV_DIR="$(get_environment_dir "$REPO_ROOT" "$ENV_NAME")"

info "Repository root: $REPO_ROOT"
info "Environment: $ENV_NAME"
info "Environment dir: $ENV_DIR"
info "Name prefix: $NAME_PREFIX"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

if terraform_output_exists "$OUTPUTS_JSON" effective_cloudwatch_retention_days; then
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS="$(get_terraform_output_value "$OUTPUTS_JSON" effective_cloudwatch_retention_days)"
  success "Resolved effective_cloudwatch_retention_days: $EFFECTIVE_CLOUDWATCH_RETENTION_DAYS"
else
  warn "Missing Terraform output: effective_cloudwatch_retention_days"
  EFFECTIVE_CLOUDWATCH_RETENTION_DAYS=""
fi

section "Resolving VPC"

if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  info "Resolved VPC ID from Terraform output: $VPC_ID"
else
  warn "Terraform output vpc_id not found. Failing back to AWS tag lookup."

  VPC_ID="$(
    aws ec2 describe-vpcs \
      "${aws_args[@]}" \
      --filters \
        "Name=tag:Name,Values=${NAME_PREFIX}-Main,${NAME_PREFIX}-VPC" \
        "Name=tag:Environment,Values=${ENV_NAME}" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"
fi

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
  fail "Unable to resolve VPC ID. Expected VPC Name tag matching ${NAME_PREFIX}-Main or ${NAME_PREFIX}-VPC. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID"

section "Checking centralized logs bucket"

CENTRALIZED_LOGS_BUCKET_NAME=""

if terraform_output_exists "$OUTPUTS_JSON" centralized_logs_bucket_name; then
  CENTRALIZED_LOGS_BUCKET_NAME="$(get_terraform_output_value "$OUTPUTS_JSON" centralized_logs_bucket_name)"
  info "Resolved centralized logs bucket from Terraform output: $CENTRALIZED_LOGS_BUCKET_NAME"
else
  warn "Terraform output centralized_logs_bucket_name not found. Falling back to S3 bucket name search."

  CENTRALIZED_LOGS_BUCKET_NAME="$(
    aws s3api list-buckets \
      "${aws_args[@]}" \
      --query "Buckets[?contains(Name, \'${NAME_PREFIX}\') && contains(Name, \'logs\')].Name | [0]" \
      --output text
  )"
fi

if [[ -z "$CENTRALIZED_LOGS_BUCKET_NAME" || "$CENTRALIZED_LOGS_BUCKET_NAME" == "None" ]]; then
  fail "Unable to resolve centralized logs bucket. Consider adding centralized_logs_bucket_name as a Terraform output."
fi

aws s3api head-bucket \
  "${aws_args[@]}" \
  --bucket "$CENTRALIZED_LOGS_BUCKET_NAME" >/dev/null

success "Centralized logs bucket exists: $CENTRALIZED_LOGS_BUCKET_NAME"

section "Checking CloudTrail"

TRAILS_JSON="$(
  aws cloudtrail describe-trails \
    "${aws_args[@]}" \
    --include-shadow-trails false \
    --output json
)"

MATCHING_TRAILS_JSON="$(
  echo "$TRAILS_JSON" |
    jq --arg prefix "$NAME_PREFIX" '[.trailList[]? | select(.Name | contains($prefix))]'
)"

MATCHING_TRAIL_COUNT="$(echo "$MATCHING_TRAILS_JSON" | jq 'length')"

if [[ "$MATCHING_TRAIL_COUNT" -gt 0 ]]; then
  success "Found CloudTrail trails matching name prefix: $MATCHING_TRAIL_COUNT"
else
  echo "$TRAILS_JSON" | jq '.trailList[]? | {Name, TrailARN, HomeRegion}'
  fail "No CloudTrail trails found containing name prefix: $NAME_PREFIX"
fi

PRIMARY_TRAIL_NAME="$(echo "$MATCHING_TRAILS_JSON" | jq -r '.[0].Name')"
PRIMARY_TRAIL_ARN="$(echo "$MATCHING_TRAILS_JSON" | jq -r '.[0].TrailArn')"
PRIMARY_TRAIL_HOME_REGION="$(echo "$MATCHING_TRAILS_JSON" | jq -r '.[0].HomeRegion')"
PRIMARY_TRAIL_BUCKET="$(echo "$MATCHING_TRAILS_JSON" | jq -r '.[0].S3BucketName')"
PRIMARY_TRAIL_LOG_GROUP_ARN="$(echo "$MATCHING_TRAILS_JSON" | jq -r '.[0].CloudWatchLogsLogGroupArn // empty')"

info "Primary CloudTrail name:          $PRIMARY_TRAIL_NAME"
info "Primary CloudTrail ARN:           $PRIMARY_TRAIL_ARN"
info "Primary CloudTrail home region:   $PRIMARY_TRAIL_HOME_REGION"
info "Primary CloudTrail S3 bucket:     $PRIMARY_TRAIL_BUCKET"

MULTI_REGION_TRAIL_COUNT="$(
  echo "$MATCHING_TRAILS_JSON" |
    jq '[.[] | select(.IsMultiRegionTrail == true)] | length'
)"

if [[ "$MULTI_REGION_TRAIL_COUNT" -gt 0 ]]; then
  success "At least one matching CloudTrail is multi-region"
else
  echo "$MATCHING_TRAILS_JSON" | jq '[.[] | {Name, IsMultiRegionTrail}]'
  fail "Expected at least one matching CloudTrail to be multi-region."
fi

if [[ -n "$PRIMARY_TRAIL_BUCKET" && "$PRIMARY_TRAIL_BUCKET" != "null" ]]; then
  success "CloudTrail has S3 bucket delievery configured: $PRIMARY_TRAIL_BUCKET"
else
  fail "CloudTrail does not have S3 bucket delivery configured"
fi

if [[ "$PRIMARY_TRAIL_BUCKET" == "$CENTRALIZED_LOGS_BUCKET_NAME" ]]; then
  success "CloudTrail writes to the centralized logs bucket"
else
  warn "CloudTrail S3 bucket does not exactly match resolved centralized logs bucket."
  warn "CloudTrail bucket: $PRIMARY_TRAIL_BUCKET"
  warn "Centralized logs bucket: $CENTRALIZED_LOGS_BUCKET_NAME"
fi

TRAIL_STATUS_JSON="$(
  aws cloudtrail get-trail-status \
    "${aws_args[@]}" \
    --name "$PRIMARY_TRAIL_ARN" \
    --output json
)"

IS_LOGGING="$(echo "$TRAIL_STATUS_JSON" | jq -r '.IsLogging')"

if [[ "$IS_LOGGING" == "true" ]]; then
  success "CloudTrail is actively logging"
else
  echo "$TRAIL_STATUS_JSON" | jq .
  fail "CloudTrail is not actively logging."
fi

LATEST_DELIVERY_ERROR="$(echo "$TRAIL_STATUS_JSON" | jq -r '.LatestDeliveryError // empty')"
LATEST_CLOUDWATCH_DELIVERY_ERROR="$(echo "$TRAIL_STATUS_JSON" | jq -r '.LatestCloudWatchDeliveryError // empty')"

if [[ -z "$LATEST_DELIVERY_ERROR" ]]; then
  success "CloudTrail does not report an S3 delivery error"
else
  warn "CloudTrail reports latest S3 delivery error: $LATEST_DELIVERY_ERROR"
fi

if [[ -n "$PRIMARY_TRAIL_LOG_GROUP_ARN" ]]; then
  success "CloudTrail has CloudWatch Logs ingestion configured"
  info "CloudTrail CloudWatch Logs log group ARN: $PRIMARY_TRAIL_LOG_GROUP_ARN"

  if [[ -z "$LATEST_CLOUDWATCH_DELIVERY_ERROR" ]]; then
    success "CloudTrail does not report a CloudWatch Logs delivery error"
  else
    warn "CloudTrail reports latest CloudWatch Logs delivery error: $LATEST_CLOUDWATCH_DELIVERY_ERROR"
  fi
else
  warn "CloudTrail does not show CloudWatch Logs integration in describe-trails output."
fi

section "Checking VPC Flow Logs"

FLOW_LOGS_JSON="$(
  aws ec2 describe-flow-logs \
    "${aws_args[@]}" \
    --filter "Name=resource-id,Values=${VPC_ID}" \
    --output json
)"

FLOW_LOG_COUNT="$(echo "$FLOW_LOGS_JSON" | jq '.FlowLogs | length')"

if [[ "$FLOW_LOG_COUNT" -gt 0 ]]; then
  success "Found VPC Flow Logs for VPC: $FLOW_LOG_COUNT"
else
  fail "No VPC Flow Logs found for VPC: $VPC_ID"
fi

ACTIVE_FLOW_LOG_COUNT="$(
  echo "$FLOW_LOGS_JSON" |
    jq '[.FlowLogs[] | select(.FlowLogStatus == "ACTIVE")] | length'
)"

if [[ "$ACTIVE_FLOW_LOG_COUNT" -gt 0 ]]; then
  success "At least one VPC Flow Log is ACTIVE"
else
  echo "$FLOW_LOGS_JSON" | jq '[.FlowLogs[] | {FlowLogId, FlowLogStatus, DeliverLogStatus, LogDestinationType, LogDestination}]'
  fail "No ACTIVE VPC Flow Logs found for VPC: $VPC_ID"
fi

FLOW_LOG_DELIVERY_ISSUE_COUNT="$(
  echo "$FLOW_LOGS_JSON" |
    jq '[.FlowLogs[] | select(.DeliverLogsStatus != null and .DeliverLogsStatus != "SUCCESS")] | length'
)"

if [[ "$FLOW_LOG_DELIVERY_ISSUE_COUNT" -eq 0 ]]; then
  success "No VPC Flow Log delivery issues reported"
else
  echo "$FLOW_LOGS_JSON" | jq '[.FlowLogs[] | select(.DeliverLogsStatus != null and .DeliverLogsStatus != "SUCCESS") | {
    FlowLogId,
    FlowLogStatus,
    DeliverLogStatus,
    DeliverLogsErrorMessage,
    LogDestinationType,
    LogDestination
  }]'
  warn "One or more VPC Flow Logs report delivery issues."
fi

section "Checking CloudWatch log groups"

LOG_GROUPS_JSON="$(
  aws logs describe-log-groups \
    "${aws_args[@]}" \
    --output json
)"

MATCHING_LOG_GROUPS_JSON="$(
  echo "$LOG_GROUPS_JSON" |
    jq --arg prefix "$NAME_PREFIX" '[.logGroups[]? | select(.logGroupName | contains($prefix))]'
)"

MATCHING_LOG_GROUP_COUNT="$(echo "$MATCHING_LOG_GROUPS_JSON" | jq 'length')"

if [[ "$MATCHING_LOG_GROUP_COUNT" -gt 0 ]]; then
  success "Found CloudWatch log groups matching name prefix: $MATCHING_LOG_GROUP_COUNT"
else
  warn "No CloudWatch log groups found containing name prefix: $NAME_PREFIX"
fi

if [[ -n "$PRIMARY_TRAIL_LOG_GROUP_ARN" ]]; then
  CLOUDTRAIL_LOG_GROUP_NAME="$(
    echo "$PRIMARY_TRAIL_LOG_GROUP_ARN" |
      sed -E 's#^arn:aws:logs:[^:]+:[^:]+:log-group:##' |
      sed -E 's#:log-stream:.*$##'
  )"

  CLOUDTRAIL_LOG_GROUP_MATCH_COUNT="$(
    echo "$LOG_GROUPS_JSON" |
      jq --arg name "$CLOUDTRAIL_LOG_GROUP_NAME" '[.logGroups[]? | select(.logGroupName == $name)] | length'
  )"

  if [[ "$CLOUDTRAIL_LOG_GROUP_MATCH_COUNT" -gt 0 ]]; then
    success "CloudTrail CloudWatch log group exists: $CLOUDTRAIL_LOG_GROUP_NAME"
  else
    warn "CloudTrail CloudWatch log group ARN was configured, but the log group was not found: $CLOUDTRAIL_LOG_GROUP_NAME"
  fi
fi

if [[ -n "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" && "$MATCHING_LOG_GROUP_COUNT" -gt 0 ]]; then
  LOG_GROUPS_WITH_UNEXPECTED_RETENTION="$(
    echo "$MATCHING_LOG_GROUPS_JSON" |
      jq --argjson expected "$EFFECTIVE_CLOUDWATCH_RETENTION_DAYS" '
        [
          .[]
          | select(.retentionInDays != null and .retentionInDays != $expected)
          | {
              logGroupName,
              retentionInDays,
              expectedRetentionInDays: $expected
            }
        ]
      '
  )"

  UNEXPECTED_RETENTION_COUNT="$(echo "$LOG_GROUPS_WITH_UNEXPECTED_RETENTION" | jq 'length')"

  if [[ "$UNEXPECTED_RETENTION_COUNT" -eq 0 ]]; then
    success "Matching CloudWatch log groups with explicit retention match expected retention days"
  else
    echo "$LOG_GROUPS_WITH_UNEXPECTED_RETENTION" | jq .
    fail "One or more matching CloudWatch log groups have unexpected retention."
  fi

  LOG_GROUPS_WITH_NO_RETENTION_COUNT="$(
    echo "$MATCHING_LOG_GROUPS_JSON" |
      jq '[.[] | select(.retentionInDays == null)] length'
  )"

  if [[ "$LOG_GROUPS_WITH_NO_RETENTION_COUNT" -eq 0 ]]; then
    success "All matching CloudWatch log groups have explicit retention configured"
  else
    echo "$MATCHING_LOG_GROUPS_JSON" |
      jq '[.[] | select(.retentionInDays == null) | {logGroupName}]'
    warn "One or more matching CloudWatch log groups have no explicit retention. This may be acceptable for AWS-manged groups, but should be reviewed."
  fi
fi

section "Logging Summary"

cat <<SUMMARY
Environment:                        ${ENV_NAME}
AWS profile:                        ${AWS_PROFILE:-<default>}
AWS region:                         ${AWS_REGION}
Name prefix:                        ${NAME_PREFIX}
VPC ID:                             ${VPC_ID}

Centralized logs bucket:            ${CENTRALIZED_LOGS_BUCKET_NAME}

CloudTrail count:                   ${MATCHING_TRAIL_COUNT}
Primary CloudTrail:                 ${PRIMARY_TRAIL_NAME}
CloudTrail home region:             ${PRIMARY_TRAIL_HOME_REGION}
CloudTrail is logging:              ${IS_LOGGING}
CloudTrail S3 bucket:               ${PRIMARY_TRAIL_BUCKET}

VPC Flow Log count:                 ${FLOW_LOG_COUNT}
ACTIVE VPC Flow Log count:          ${ACTIVE_FLOW_LOG_COUNT}

Matching CloudWatch log groups:     ${MATCHING_LOG_GROUP_COUNT}
Expected CloudWatch retention days: ${EFFECTIVE_CLOUDWATCH_RETENTION_DAYS:-<unknown>}
SUMMARY

section "Validation Result"

success "Logging validation completed successfully for: ${ENV_NAME}"