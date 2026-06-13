#!/usr/bin/env bash

# validate-compute.sh
#
# Validates EC2 compute resources for a deployed tf-secure-baseline workload
# environment.
#
# Checks:
# - Terraform outputs are readable
# - AWS caller identity is valid
# - VPC is resolved
# - Compute and quarantine security groups exist
# - EC2 instances exist and are private
# - EC2 instances are in compute private subnets
# - EC2 instances have no public IPs
# - EC2 instances enforce IMDSv2
# - EC2 instances have detailed monitoring enabled
# - EC2 instances have IAM instance profiles
# - Required automation/operations tags exist
# - Root EBS volumes are encrypted, gp3, 20 GiB
# - Root EBS volumes use a KMS key
#
# Usage:
#   ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-compute.sh dev
#
# Optional:
#   EXPECTED_ACCOUNT_ID=123456789012 AWS_PROFILE=dev ./scripts/validation/validate-compute.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-compute.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[@]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SOURCE_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

export AWS_PAGER=""

if [[ -z "${ENV_NAME}" ]]; then
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

section "tf-secure-baseline Compute Validation"

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
info "Environment:     $ENV_NAME"
info "Environment dir: $ENV_DIR"
info "Name prefix:     $NAME_PREFIX"
info "AWS_PROFILE:     ${AWS_PROFILE:-<default>}"
info "AWS_REGION:      $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

success "Terraform outputs are readable"

section "Checking AWS caller identity"

ACCOUNT_ID="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Account \
    --output text
)"

CALLER_ARN="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Arn \
    --output text
)"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

success "AWS credentials are valid"
info "AWS account ID: $ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

section "Resolving VPC and expected security groups"

VPC_ID=""

if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  success "vpc_id output found: $VPC_ID"
else
  VPC_ID="$(
    aws ec2 describe-vpcs \
      "${aws_args[@]}" \
      --filters "Name=tag:Name,Values=${NAME_PREFIX}-Main,${NAME_PREFIX}-VPC" \
      --query 'Vpcs[0].VpcId' \
      --output text
  )"

  if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    fail "Unable to resolve VPC by Terraform output or expected Name tags"
  fi

  success "Resolved VPC by tag: $VPC_ID"
fi

COMPUTE_SG_ID=""
QUARANTINE_SG_ID=""

if terraform_output_exists "$OUTPUTS_JSON" compute_sg_id; then
  COMPUTE_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" compute_sg_id)"
  success "compute_sg_id output found: $COMPUTE_SG_ID"
else
  COMPUTE_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=${NAME_PREFIX}-Compute-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$COMPUTE_SG_ID" || "$COMPUTE_SG_ID" == "None" ]]; then
    fail "Unable to resolve compute security group"
  fi

  success "Resolved compute security group by name: $COMPUTE_SG_ID"
fi

if terraform_output_exists "$OUTPUTS_JSON" quarantine_sg_id; then
  QUARANTINE_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" quarantine_sg_id)"
  success "quarantine_sg_id output found: $QUARANTINE_SG_ID"
else
  QUARANTINE_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=group-name,Values=${NAME_PREFIX}-Quarantine-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$QUARANTINE_SG_ID" || "$QUARANTINE_SG_ID" == "None" ]]; then
    fail "Unable to resolve quarantine security group"
  fi

  success "Resolved quarantine security group by name: $QUARANTINE_SG_ID"
fi

section "Validating compute and quarantine security groups"

SECURITY_GROUPS_JSON="$(
  aws ec2 describe-security-groups \
    "${aws_args[@]}" \
    --group-ids "$COMPUTE_SG_ID" "$QUARANTINE_SG_ID" \
    --output json
)"

COMPUTE_SG_COUNT="$(
  echo "$SECURITY_GROUPS_JSON" |
    jq --arg sg_id "$COMPUTE_SG_ID" '[.SecurityGroups[] | select(.GroupId == $sg_id)] | length'
)"

QUARANTINE_SG_COUNT="$(
  echo "$SECURITY_GROUPS_JSON" |
    jq --arg sg_id "$QUARANTINE_SG_ID" '[.SecurityGroups[] | select(.GroupId == $sg_id)] | length'
)"

if [[ "$COMPUTE_SG_COUNT" -eq 1 ]]; then
  success "Compute security group exists: $COMPUTE_SG_ID"
else
  fail "Compute security group not found: $COMPUTE_SG_ID"
fi

if [[ "$QUARANTINE_SG_COUNT" -eq 1 ]]; then
  success "Quarantine security group exists: $QUARANTINE_SG_ID"
else
  fail "Quarantine security group not found: $QUARANTINE_SG_ID"
fi

SGS_OUTSIDE_VPC_COUNT="$(
  echo "$SECURITY_GROUPS_JSON" |
    jq --arg vpc_id "$VPC_ID" '[.SecurityGroups[] | select(.VpcId != $vpc_id)] | length'
)"

if [[ "$SGS_OUTSIDE_VPC_COUNT" -eq 0 ]]; then
  success "Compute and quarantine security groups are in expected VPC"
else
  echo "$SECURITY_GROUPS_JSON" | jq '.SecurityGroups[] | {GroupId,GroupName,VpcId}'
  fail "One or more compute security groups are outside expected VPC"
fi

QUARANTINE_EGRESS_443_COUNT="$(
  echo "$SECURITY_GROUPS_JSON" |
    jq --arg sg_id "$QUARANTINE_SG_ID" '
      [
        .SecurityGroups[]
        | select(.GroupId == $sg_id)
        | .IpPermissionsEgress[]?
        | select(.IpProtocol == "tcp")
        | select(.FromPort == 443 and .ToPort == 443)
      ]
      | length
    '
)"

if [[ "$QUARANTINE_EGRESS_443_COUNT" -gt 0 ]]; then
  success "Quarantine security group has HTTPS egress rule"
else
  warn "Quarantine security group does not show explicit TCP/443 egress rule"
fi

section "Discovering compute private subnets"

COMPUTE_PRIVATE_SUBNETS_JSON="$(
  aws ec2 describe-subnets \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-*" \
    --output json
)"

COMPUTE_PRIVATE_SUBNET_COUNT="$(
  echo "$COMPUTE_PRIVATE_SUBNETS_JSON" |
    jq '.Subnets | length'
)"

if [[ "$COMPUTE_PRIVATE_SUBNET_COUNT" -gt 0 ]]; then
  success "Found compute private subnets: $COMPUTE_PRIVATE_SUBNET_COUNT"
else
  fail "No compute private subnets found for name prefix: ${NAME_PREFIX}-Compute-Private-*"
fi

COMPUTE_PRIVATE_SUBNET_IDS_JSON="$(
  echo "$COMPUTE_PRIVATE_SUBNETS_JSON" |
    jq '[.Subnets[].SubnetId]'
)"

section "Discovering EC2 compute instances"

INSTANCES_JSON="$(
  aws ec2 describe-instances \
    "${aws_args[@]}" \
    --filters \
      "Name=tag:Environment,Values=${ENV_NAME}" \
      "Name=tag:Terraform,Values=true" \
      "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --output json
)"

COMPUTE_INSTANCES_JSON="$(
  echo "$INSTANCES_JSON" |
    jq --arg prefix "$NAME_PREFIX" '
      [
        .Reservations[].Instances[]
        | select(
            (
              .Tags // []
              | any(.Key == "Name" and (.Value | contains($prefix) and contains("-EC2-")))
            )
          )
      ]
    '
)"

COMPUTE_INSTANCE_COUNT="$(echo "$COMPUTE_INSTANCES_JSON" | jq 'length')"

if [[ "$COMPUTE_INSTANCE_COUNT" -gt 0 ]]; then
  success "Found compute EC2 instances: $COMPUTE_INSTANCE_COUNT"
else
  fail "No compute EC2 instances found matching environment=${ENV_NAME}, Terraform=true, Name contains ${NAME_PREFIX}-EC2-"
fi

INSTANCE_SUMMARY_ROWS=()
VOLUME_IDS=()

section "Validating EC2 instance configuration"

INVALID_PUBLIC_IP_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '[.[] | select(.PublicIpAddress != null)] | length'
)"

if [[ "$INVALID_PUBLIC_IP_COUNT" -eq 0 ]]; then
  success "No compute instances have public IP addresses"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '.[] | select(.PublicIpAddress != null) | "- " + .InstanceId + " PublicIp=" + .PublicIpAddress'
  fail "One or more compute instances have public IP addresses"
fi

INVALID_SUBNET_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq --argjson subnet_ids "$COMPUTE_PRIVATE_SUBNET_IDS_JSON" '
      [
        .[]
        | select(.SubnetId as $subnet_id | $subnet_ids | index($subnet_id) | not)
      ]
      | length
    '
)"

if [[ "$INVALID_SUBNET_COUNT" -eq 0 ]]; then
  success "All compute instances are in compute private subnets"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r --argjson subnet_ids "$COMPUTE_PRIVATE_SUBNET_IDS_JSON" '
      .[]
      | select(.SubnetId as $subnet_id | $subnet_ids | index($subnet_id) | not)
      | "- " + .InstanceId + " SubnetId=" + .SubnetId
    '
  fail "One or more compute instances are not in compute private subnets"
fi

INVALID_IMDS_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.MetadataOptions.HttpTokens != "required")
            or
            (.MetadataOptions.HttpPutResponseHopLimit != 2)
          )
      ]
      | length
    '
)"

if [[ "$INVALID_IMDS_COUNT" -eq 0 ]]; then
  success "All compute instances enforce IMDSv2 with hop limit 2"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '
      .[]
      | select((.MetadataOptions.HttpTokens != "required") or (.MetadataOptions.HttpPutResponseHopLimit != 2))
      | "- " + .InstanceId
        + " HttpTokens=" + (.MetadataOptions.HttpTokens // "null")
        + " HopLimit=" + ((.MetadataOptions.HttpPutResponseHopLimit // 0) | tostring)
    '
  fail "One or more compute instances do not enforce expected IMDSv2 settings"
fi

DISABLED_MONITORING_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '[.[] | select(.Monitoring.State != "enabled")] | length'
)"

if [[ "$DISABLED_MONITORING_COUNT" -eq 0 ]]; then
  success "Detailed monitoring is enabled for all compute instances"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '.[] | select(.Monitoring.State != "enabled") | "- " + .InstanceId + " Monitoring=" + .Monitoring.State'
  fail "Detailed monitoring is not enabled for one or more compute instances"
fi

MISSING_INSTANCE_PROFILE_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '[.[] | select(.IamInstanceProfile.Arn == null)] | length'
)"

if [[ "$MISSING_INSTANCE_PROFILE_COUNT" -eq 0 ]]; then
  success "All compute instances have IAM instance profiles"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '.[] | select(.IamInstanceProfile.Arn == null) | "- " + .InstanceId'
  fail "One or more compute instances are missing IAM instance profiles"
fi

BAD_COMPUTE_SG_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq --arg compute_sg_id "$COMPUTE_SG_ID" '
      [
        .[]
        | select(
            [
              .SecurityGroups[]?.GroupId
            ]
            | index($compute_sg_id)
            | not
          )
      ]
      | length
    '
)"

if [[ "$BAD_COMPUTE_SG_COUNT" -eq 0 ]]; then
  success "All compute instances have the compute security group attached"
else
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r --arg compute_sg_id "$COMPUTE_SG_ID" '
      .[]
      | select(([.SecurityGroups[]?.GroupId] | index($compute_sg_id) | not))
      | "- " + .InstanceId + " SecurityGroups=" + ([.SecurityGroups[]?.GroupId] | join(","))
    '
  fail "One or more compute instances are missing the compute security group"
fi

section "Validating required EC2 instance tags"

REQUIRED_TAGS=(
  "Name"
  "Environment"
  "Terraform"
  "Purpose"
  "IsolationAllowed"
  "PatchGroup"
  "Backup"
)

for tag_key in "${REQUIRED_TAGS[@]}"; do
  missing_count="$(
    echo "$COMPUTE_INSTANCES_JSON" |
      jq --arg tag_key "$tag_key" '
        [
          .[]
          | select(
              (.Tags // [])
              | any(.Key == $tag_key)
              | not
            )
        ]
        | length
      '
  )"

  if [[ "$missing_count" -eq 0 ]]; then
    success "All compute instances have required tag: ${tag_key}"
  else
    echo "$COMPUTE_INSTANCES_JSON" |
      jq -r --arg tag_key "$tag_key" '
        .[]
        | select((.Tags // []) | any(.Key == $tag_key) | not)
        | "- " + .InstanceId
      '
    fail "One or more compute instances are missing required tag: ${tag_key}"
  fi
done

BAD_ENV_TAG_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq --arg env_name "$ENV_NAME" '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "Environment" and .Value == $env_name)
            | not
          )
      ]
      | length
    '
)"

if [[ "$BAD_ENV_TAG_COUNT" -eq 0 ]]; then
  success "All compute instances have expected Environment tag: ${ENV_NAME}"
else
  fail "One or more compute instances have unexpected Environment tag"
fi

BAD_TERRAFORM_TAG_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "Terraform" and .Value == "true")
            | not
          )
      ]
      | length
    '
)"

if [[ "$BAD_TERRAFORM_TAG_COUNT" -eq 0 ]]; then
  success "All compute instances have Terraform=true tag"
else
  fail "One or more compute instances have unexpected Terraform tag"
fi

BAD_ISOLATION_TAG_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "IsolationAllowed" and .Value == "true")
            | not
          )
      ]
      | length
    '
)"

if [[ "$BAD_ISOLATION_TAG_COUNT" -eq 0 ]]; then
  success "All compute instances have IsolationAllowed=true tag"
else
  fail "One or more compute instances have unexpected IsolationAllowed tag"
fi

BAD_BACKUP_TAG_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "Backup" and .Value == "true")
            | not
          )
      ]
      | length
    '
)"

if [[ "$BAD_BACKUP_TAG_COUNT" -eq 0 ]]; then
  success "All compute instances have Backup=true tag"
else
  fail "One or more compute instances have unexpected Backup tag"
fi

section "Collecting EBS volume IDs"

while IFS= read -r volume_id; do
  [[ -z "$volume_id" ]] && continue
  VOLUME_IDS+=("$volume_id")
done < <(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '.[] | .BlockDeviceMappings[]?.Ebs.VolumeId // empty'
)

VOLUME_COUNT="${#VOLUME_IDS[@]}"

if [[ "$VOLUME_COUNT" -gt 0 ]]; then
  success "Collected EBS volume IDs from compute instances: $VOLUME_COUNT"
else
  fail "No EBS volume IDs found for compute instances"
fi