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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

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

section "Validating compute security policy rules"

EFFECTIVE_EGRESS_MODE=""

if terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  success "effective_egress_mode output found: $EFFECTIVE_EGRESS_MODE"
else
  warn "effective_egress_mode output not found. Internet HTTPS egress rule validation will be informational."
fi

DB_PORT="${DB_PORT:-5432}"

if terraform_output_exists "$OUTPUTS_JSON" db_port; then
  DB_PORT="$(get_terraform_output_value "$OUTPUTS_JSON" db_port)"
  success "db_port output found: $DB_PORT"
else
  info "db_port output not found. Using default DB_PORT: $DB_PORT"
fi

INTERFACE_ENDPOINTS_SG_ID=""

if terraform_output_exists "$OUTPUTS_JSON" interface_endpoints_sg_id; then
  INTERFACE_ENDPOINTS_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" interface_endpoints_sg_id)"
  success "interface_endpoints_sg_id output found: $INTERFACE_ENDPOINTS_SG_ID"
else
  INTERFACE_ENDPOINTS_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=tag:Name,Values=${NAME_PREFIX}-Interface-Endpoints-SG,${NAME_PREFIX}-Endpoints-SG,${NAME_PREFIX}-VPC-Endpoints-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$INTERFACE_ENDPOINTS_SG_ID" || "$INTERFACE_ENDPOINTS_SG_ID" == "None" ]]; then
    warn "Unable to resolve interface endpoints security group. Skipping endpoint SG rule validation."
  else
    success "Resolved interface endpoints security group: $INTERFACE_ENDPOINTS_SG_ID"
  fi
fi

DATA_SG_ID=""

if terraform_output_exists "$OUTPUTS_JSON" data_sg_id; then
  DATA_SG_ID="$(get_terraform_output_value "$OUTPUTS_JSON" data_sg_id)"
  success "data_sg_id output found: $DATA_SG_ID"
else
  DATA_SG_ID="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --filters \
        "Name=vpc-id,Values=${VPC_ID}" \
        "Name=tag:Name,Values=${NAME_PREFIX}-Data-SG,${NAME_PREFIX}-RDS-SG" \
      --query 'SecurityGroups[0].GroupId' \
      --output text
  )"

  if [[ -z "$DATA_SG_ID" || "$DATA_SG_ID" == "None" ]]; then
    warn "Unable to resolve data security group. Skipping DB SG rule validation."
  else
    success "Resolved data security group: $DATA_SG_ID"
  fi
fi

if [[ -n "$INTERFACE_ENDPOINTS_SG_ID" && "$INTERFACE_ENDPOINTS_SG_ID" != "None" ]]; then
  COMPUTE_EGRESS_TO_ENDPOINTS_COUNT="$(
    echo "$SECURITY_GROUPS_JSON" |
      jq --arg compute_sg_id "$COMPUTE_SG_ID" --arg endpoints_sg_id "$INTERFACE_ENDPOINTS_SG_ID" '
        [
          .SecurityGroups[]
          | select(.GroupId == $compute_sg_id)
          | .IpPermissionsEgress[]?
          | select(.IpProtocol == "tcp")
          | select(.FromPort == 443 and .ToPort == 443)
          | select(
              [.UserIdGroupPairs[]?.GroupId]
              | index($endpoints_sg_id)
            )
        ]
        | length
      '
  )"

  if [[ "$COMPUTE_EGRESS_TO_ENDPOINTS_COUNT" -gt 0 ]]; then
    success "Compute SG allows HTTPS egress to interface endpoints SG"
  else
    fail "Compute SG does not allow HTTPS egress to interface endpoints SG"
  fi

  ENDPOINTS_INGRESS_FROM_COMPUTE_COUNT="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --group-ids "$INTERFACE_ENDPOINTS_SG_ID" \
      --output json |
      jq --arg compute_sg_id "$COMPUTE_SG_ID" '
        [
          .SecurityGroups[]
          | .IpPermissions[]?
          | select(.IpProtocol == "tcp")
          | select(.FromPort == 443 and .ToPort == 443)
          | select(
              [.UserIdGroupPairs[]?.GroupId]
              | index($compute_sg_id)
            )
        ]
        | length
      '
  )"

  if [[ "$ENDPOINTS_INGRESS_FROM_COMPUTE_COUNT" -gt 0 ]]; then
    success "Interface endpoints SG allows HTTPS ingress from compute SG"
  else
    fail "Interface endpoints SG does not allow HTTPS ingress from compute SG"
  fi
fi

if [[ -n "$DATA_SG_ID" && "$DATA_SG_ID" != "None" ]]; then
  COMPUTE_EGRESS_TO_DB_COUNT="$(
    echo "$SECURITY_GROUPS_JSON" |
      jq --arg compute_sg_id "$COMPUTE_SG_ID" --arg data_sg_id "$DATA_SG_ID" --argjson db_port "$DB_PORT" '
        [
          .SecurityGroups[]
          | select(.GroupId == $compute_sg_id)
          | .IpPermissionsEgress[]?
          | select(.IpProtocol == "tcp")
          | select(.FromPort == $db_port and .ToPort == $db_port)
          | select(
              [.UserIdGroupPairs[]?.GroupId]
              | index($data_sg_id)
            )
        ]
        | length
      '
  )"

  if [[ "$COMPUTE_EGRESS_TO_DB_COUNT" -gt 0 ]]; then
    success "Compute SG allows DB egress to data SG on TCP/${DB_PORT}"
  else
    fail "Compute SG does not allow DB egress to data SG on TCP/${DB_PORT}"
  fi

  DATA_INGRESS_FROM_COMPUTE_COUNT="$(
    aws ec2 describe-security-groups \
      "${aws_args[@]}" \
      --group-ids "$DATA_SG_ID" \
      --output json |
      jq --arg compute_sg_id "$COMPUTE_SG_ID" --argjson db_port "$DB_PORT" '
        [
          .SecurityGroups[]
          | .IpPermissions[]?
          | select(.IpProtocol == "tcp")
          | select(.FromPort == $db_port and .ToPort == $db_port)
          | select(
              [.UserIdGroupPairs[]?.GroupId]
              | index($compute_sg_id)
            )
        ]
        | length
      '
  )"

  if [[ "$DATA_INGRESS_FROM_COMPUTE_COUNT" -gt 0 ]]; then
    success "Data SG allows DB ingress from compute SG on TCP/${DB_PORT}"
  else
    fail "Data SG does not allow DB ingress from compute SG on TCP/${DB_PORT}"
  fi
fi

COMPUTE_HTTPS_EGRESS_TO_INTERNET_COUNT="$(
  echo "$SECURITY_GROUPS_JSON" |
    jq --arg compute_sg_id "$COMPUTE_SG_ID" '
      [
        .SecurityGroups[]
        | select(.GroupId == $compute_sg_id)
        | .IpPermissionsEgress[]?
        | select(.IpProtocol == "tcp")
        | select(.FromPort == 443 and .ToPort == 443)
        | select(
            [.IpRanges[]?.CidrIp]
            | index("0.0.0.0/0")
          )
      ]
      | length
    '
)"

if [[ "$EFFECTIVE_EGRESS_MODE" == "vpc_endpoints_only" ]]; then
  if [[ "$COMPUTE_HTTPS_EGRESS_TO_INTERNET_COUNT" -eq 0 ]]; then
    success "Compute SG does not allow internet HTTPS egress in vpc_endpoints_only mode"
  else
    fail "Compute SG allows internet HTTPS egress even though effective_egress_mode=vpc_endpoints_only"
  fi
elif [[ -n "$EFFECTIVE_EGRESS_MODE" ]]; then
  if [[ "$COMPUTE_HTTPS_EGRESS_TO_INTERNET_COUNT" -gt 0 ]]; then
    success "Compute SG allows HTTPS egress through configured egress path for mode: ${EFFECTIVE_EGRESS_MODE}"
  else
    fail "Compute SG does not allow HTTPS egress even though effective_egress_mode=${EFFECTIVE_EGRESS_MODE}"
  fi
else
  if [[ "$COMPUTE_HTTPS_EGRESS_TO_INTERNET_COUNT" -gt 0 ]]; then
    info "Compute SG has HTTPS egress to 0.0.0.0/0"
  else
    info "Compute SG does not have HTTPS egress to 0.0.0.0/0"
  fi
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

ISOLATION_ALLOWED_FALSE_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "IsolationAllowed" and .Value == "false")
          )
      ]
      | length
    '
)"

ISOLATION_ALLOWED_UNEXPECTED_COUNT="$(
  echo "$COMPUTE_INSTANCES_JSON" |
    jq '
      [
        .[]
        | select(
            (.Tags // [])
            | any(.Key == "IsolationAllowed" and (.Value != "true" and .Value != "false"))
          )
      ]
      | length
    '
)"

if [[ "$ISOLATION_ALLOWED_UNEXPECTED_COUNT" -gt 0 ]]; then
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '
      .[]
      | select(
          (.Tags // [])
          | any(.Key == "IsolationAllowed" and (.Value != "true" and .Value != "false"))
        )
      | "- " + .InstanceId
        + " IsolationAllowed="
        + ((.Tags // [] | map(select(.Key == "IsolationAllowed")) | first | .Value) // "<missing>")
    '
  fail "One or more compute instances have unexpected IsolationAllowed values"
elif [[ "$ISOLATION_ALLOWED_FALSE_COUNT" -gt 0 ]]; then
  echo "$COMPUTE_INSTANCES_JSON" |
    jq -r '
      .[]
      | select(
          (.Tags // [])
          | any(.Key == "IsolationAllowed" and .Value == "false")
        )
      | "- " + .InstanceId + " IsolationAllowed=false"
    '
  warn "One or more compute instances have IsolationAllowed=false. Isolation automation will intentionally skip these instances."
else
  success "All compute instances have IsolationAllowed=true tag"
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

section "Validating EBS volume encryption and root volume settings"

VOLUMES_JSON="$(
  aws ec2 describe-volumes \
    "${aws_args[@]}" \
    --volume-ids "${VOLUME_IDS[@]}" \
    --output json
)"

UNENCRYPTED_VOLUME_COUNT="$(
  echo "$VOLUMES_JSON" |
    jq '[.Volumes[] | select(.Encrypted != true)] | length'
)"

if [[ "$UNENCRYPTED_VOLUME_COUNT" -eq 0 ]]; then
  success "All compute EBS volumes are encrypted"
else
  echo "$VOLUMES_JSON" |
    jq -r '.Volumes[] | select(.Encrypted != true) | "- " + .VolumeId'
  fail "One or more compute EBS volumes are not encrypted"
fi

MISSING_KMS_VOLUME_COUNT="$(
  echo "$VOLUMES_JSON" |
    jq '[.Volumes[] | select(.KmsKeyId == null)] | length'
)"

if [[ "$MISSING_KMS_VOLUME_COUNT" -eq 0 ]]; then
  success "All compute EBS volumes have KMS key IDs"
else
  echo "$VOLUMES_JSON" |
    jq -r '.Volumes[] | select(.KmsKeyId == null) | "- " + .VolumeId'
  fail "One or more compute EBS volumes are missing KMS key IDs"
fi

BAD_VOLUME_TYPE_COUNT="$(
  echo "$VOLUMES_JSON" |
    jq '[.Volumes[] | select(.VolumeType != "gp3")] | length'
)"

if [[ "$BAD_VOLUME_TYPE_COUNT" -eq 0 ]]; then
  success "All compute EBS volumes use gp3"
else
  echo "$VOLUMES_JSON" |
    jq -r '.Volumes[] | select(.VolumeType != "gp3") | "- " + .VolumeId + " Type=" + .VolumeType'
  fail "One or more compute EBS volumes are not gp3"
fi

BAD_VOLUME_SIZE_COUNT="$(
  echo "$VOLUMES_JSON" |
    jq '[.Volumes[] | select(.Size != 20)] | length'
)"

if [[ "$BAD_VOLUME_SIZE_COUNT" -eq 0 ]]; then
  success "All compute EBS volumes are 20 GiB"
else
  echo "$VOLUMES_JSON" |
    jq -r '.Volumes[] | select(.Size != 20) | "- " + .VolumeId + " Size=" + (.Size | tostring)'
  fail "One or more compute EBS volumes are not 20 GiB"
fi

section "Building compute summary"

while IFS= read -r instance; do
  [[ -z "$instance" ]] && continue

  instance_id="$(echo "$instance" | jq -r '.InstanceId')"
  name_tag="$(echo "$instance" | jq -r '(.Tags // [] | map(select(.Key == "Name")) | first | .Value) // "<none>"')"
  state="$(echo "$instance" | jq -r '.State.Name')"
  instance_type="$(echo "$instance" | jq -r '.InstanceType')"
  subnet_id="$(echo "$instance" | jq -r '.SubnetId')"
  private_ip="$(echo "$instance" | jq -r '.PrivateIpAddress // "<none>"')"
  public_ip="$(echo "$instance" | jq -r '.PublicIpAddress // "<none>"')"
  imds_tokens="$(echo "$instance" | jq -r '.MetadataOptions.HttpTokens // "<none>"')"
  monitoring="$(echo "$instance" | jq -r '.Monitoring.State // "<none>"')"
  profile_arn="$(echo "$instance" | jq -r '.IamInstanceProfile.Arn // "<none>"')"

  INSTANCE_SUMMARY_ROWS+=("${instance_id}|${name_tag}|${state}|${instance_type}|${subnet_id}|${private_ip}|${public_ip}|${imds_tokens}|${monitoring}|${profile_arn}")
done < <(echo "$COMPUTE_INSTANCES_JSON" | jq -c '.[]')

section "Compute Summary"

cat <<SUMMARY
Environment:                    ${ENV_NAME}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACCOUNT_ID}
Name prefix:                    ${NAME_PREFIX}

VPC ID:                         ${VPC_ID}
Compute security group ID:      ${COMPUTE_SG_ID}
Quarantine security group ID:   ${QUARANTINE_SG_ID}
Compute private subnets:        ${COMPUTE_PRIVATE_SUBNET_COUNT}
Compute EC2 instances:          ${COMPUTE_INSTANCE_COUNT}
Compute EBS volumes:            ${VOLUME_COUNT}

Effective egress mode:          ${EFFECTIVE_EGRESS_MODE:-<unknown>}
Interface endpoints SG ID:      ${INTERFACE_ENDPOINTS_SG_ID:-<unknown>}
Data security group ID:         ${DATA_SG_ID:-<unknown>}
DB port:                        ${DB_PORT}
SUMMARY

if [[ "${#INSTANCE_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Compute instances:"
  printf '%s\n' "${INSTANCE_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-22s %-42s %-10s %-12s %-22s %-16s %-16s %-10s %-12s %-80s\n", "InstanceId", "Name", "State", "Type", "SubnetId", "PrivateIp", "PublicIp", "IMDSv2", "Monitoring", "InstanceProfile"
        printf "%-22s %-42s %-10s %-12s %-22s %-16s %-16s %-10s %-12s %-80s\n", "----------", "----", "-----", "----", "--------", "---------", "--------", "------", "----------", "---------------"
      }
      {
        printf "%-22s %-42s %-10s %-12s %-22s %-16s %-16s %-10s %-12s %-80s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
      }
    '
fi

echo
echo "Compute EBS volumes:"
echo "$VOLUMES_JSON" |
  jq -r '
    .Volumes[]
    | "- " + .VolumeId
      + " Type=" + .VolumeType
      + " SizeGiB=" + (.Size | tostring)
      + " Encrypted=" + (.Encrypted | tostring)
      + " KmsKeyId=" + (.KmsKeyId // "<none>")
      + " State=" + .State
  '

section "Validation Result"

success "Compute validation completed successfully for: ${ENV_NAME}"