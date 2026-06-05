#!/usr/bin/env bash

# validate-vpc-endpoints.sh
#
# Validates VPC Endpoint behavior for a deployed tf-secure-baseline environment.
#
# Checks:
# - VPC can be resolved
# - Endpoint private subnets exist
# - Endpoint private route tables exist and have no default route
# - Interface VPC Endpoints exist and are available
# - Interface VPC Endpoints are deployed into endpoint private subnets
# - S3 Gateway Endpoint exists
# - S3 Gateway Endpoint is associated with expected private route tables
#
# Usage:
#   ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-vpc-endpoints.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

# Space-separated list so callers can override this later if the module becomes configurable.
EXPECTED_INTERFACE_ENDPOINT_SERVICES="${EXPECTED_INTERFACE_ENDPOINT_SERVICES:-sts logs ssm ssmmessages secretsmanager kms config sns ec2 events securityhub lambda}"

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

section "tf-secure-baseline VPC Endpoints Validation"

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

info "Repository root:  $REPO_ROOT"
info "Environment:      $ENV_NAME"
info "Environment dir:  $ENV_DIR"
info "Name prefix:      $NAME_PREFIX"
info "AWS_PROFILE:      ${AWS_PROFILE:-<default>}"
info "AWS_REGION:       $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

if terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"
  success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"
else
  warn "Missing Terraform output: effective_egress_mode"
  EFFECTIVE_EGRESS_MODE="unknown"
fi

section "Resolving VPC"

# Prefer Terraform output if present. Fall back to AWS tag lookup.
if terraform_output_exists "$OUTPUTS_JSON" vpc_id; then
  VPC_ID="$(get_terraform_output_value "$OUTPUTS_JSON" vpc_id)"
  info "Resolved VPC ID from Terraform output: $VPC_ID"
else
  warn "Terraform output vpc_id not found. Falling back to AWS tag lookup."

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

section "Checking endpoint private subnets"

ENDPOINT_SUBNETS_JSON="$(
  aws ec2 describe-subnets \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-*" \
    --output json
)"

ENDPOINT_SUBNET_COUNT="$(echo "$ENDPOINT_SUBNETS_JSON" | jq '.Subnets | length')"

if [[ "$ENDPOINT_SUBNET_COUNT" -gt 0 ]]; then
  success "Found endpoint private subnets: $ENDPOINT_SUBNET_COUNT"
else
  fail "No endpoint private subnets found using tag pattern: ${NAME_PREFIX}-Endpoint-Private-*"
fi

ENDPOINT_SUBNET_IDS_JSON="$(
  echo "$ENDPOINT_SUBNETS_JSON" |
    jq '[.Subnets[].SubnetId]'
)"

PUBLIC_IP_MAPPING_COUNT="$(
  echo "$ENDPOINT_SUBNETS_JSON" |
    jq '[.Subnets[] | select(.MapPublicIpOnLaunch == true)] | length'
)"

if [[ "$PUBLIC_IP_MAPPING_COUNT" -eq 0 ]]; then
  success "Endpoint private subnets do not auto-assign public IPs"
else
  fail "One or more endpoint private subnets have MapPublicIpOnLaunch enabled."
fi

section "Checking endpoint private route tables"

ENDPOINT_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-RT-*" \
    --output json
)"

ENDPOINT_RT_COUNT="$(echo "$ENDPOINT_ROUTE_TABLES_JSON" | jq '.RouteTables | length')"

if [[ "$ENDPOINT_RT_COUNT" -gt 0 ]]; then
  success "Found endpoint private route tables: $ENDPOINT_RT_COUNT"
else
  fail "No endpoint private route tables found using tag pattern: ${NAME_PREFIX}-Endpoint-Private-RT-*"
fi

ENDPOINT_DEFAULT_ROUTE_COUNT="$(
  echo "$ENDPOINT_ROUTE_TABLES_JSON" |
    jq '[.RouteTables[].Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")] | length'
)"

if [[ "$ENDPOINT_DEFAULT_ROUTE_COUNT" -eq 0 ]]; then
  success "Endpoint private route tables do not have default routes"
else
  echo "$ENDPOINT_ROUTE_TABLES_JSON" | jq '[.RouteTables[] | {
    route_table_id: .RouteTableId,
    name: (.Tags[]? | select(.Key == "Name") | .Value),
    default_routes: [.Routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")]
  }]'
  fail "Expected endpoint private route tables to have no 0.0.0.0/0 default routes."
fi

ENDPOINT_RT_ASSOCIATION_COUNT="$(
  echo "$ENDPOINT_ROUTE_TABLES_JSON" |
    jq '[.RouteTables[].Associations[]? | select(.SubnetId != null)] | length'
)"

if [[ "$ENDPOINT_RT_ASSOCIATION_COUNT" -gt 0 ]]; then
  success "Endpoint private route tables have subnet associations: $ENDPOINT_RT_ASSOCIATION_COUNT"
else
  fail "Endpoint private route tables do not appear to have subnet associations."
fi

section "Checking Interface VPC Endpoints"

INTERFACE_ENDPOINTS_JSON="$(
  aws ec2 describe-vpc-endpoints \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=vpc-endpoint-type,Values=Interface" \
    --output json
)"

INTERFACE_ENDPOINT_COUNT="$(echo "$INTERFACE_ENDPOINTS_JSON" | jq '.VpcEndpoints | length')"

if [[ "$INTERFACE_ENDPOINT_COUNT" -gt 0 ]]; then
  success "Found Interface VPC Endpoints: $INTERFACE_ENDPOINT_COUNT"
else
  fail "No Interface VPC Endpoints found."
fi

NON_AVAILABLE_INTERFACE_ENDPOINT_COUNT="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq '[.VpcEndpoints[] | select(.State != "available")] | length'
)"

if [[ "$NON_AVAILABLE_INTERFACE_ENDPOINT_COUNT" -eq 0 ]]; then
  success "All Interface VPC Endpoints are available"
else
  echo "$INTERFACE_ENDPOINTS_JSON" | jq '[.VpcEndpoints[] | select(.State != "available") | {
    service_name: .ServiceName,
    state: .State,
    endpoint_id: .VpcEndpointId
  }]'
  fail "One or more Interface VPC Endpoints are not available."
fi

INTERFACE_ENDPOINTS_OUTSIDE_ENDPOINT_SUBNETS="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --argjson allowed "$ENDPOINT_SUBNET_IDS_JSON" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            subnet_ids: .SubnetIds,
            unexpected_subnet_ids: ([.SubnetIds[]] - $allowed)
          }
        | select((.unexpected_subnet_ids | length) > 0)
      ]
      | length
    '
)"

if [[ "$INTERFACE_ENDPOINTS_OUTSIDE_ENDPOINT_SUBNETS" -eq 0 ]]; then
  success "Interface VPC Endpoints are deployed only into endpoint private subnets"
else
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --argjson allowed "$ENDPOINT_SUBNET_IDS_JSON" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            subnet_ids: .SubnetIds,
            unexpected_subnet_ids: ([.SubnetIds[]] - $allowed)
          }
        | select((.unexpected_subnet_ids | length) > 0)
      ]
    '
  fail "One or more Interface VPC Endpoints are not deployed exclusively into endpoint private subnets."
fi

section "Checking expected Interface VPC Endpoint services"

MISSING_INTERFACE_SERVICES=()

for short_service_name in $EXPECTED_INTERFACE_ENDPOINT_SERVICES; do
  full_service_name="com.amazonaws.${AWS_REGION}.${short_service_name}"

  matching_count="$(
    echo "$INTERFACE_ENDPOINTS_JSON" |
      jq --arg service "$full_service_name" '[.VpcEndpoints[] | select(.ServiceName == $service)] | length'
  )"
  
  if [[ "$matching_count" -gt 0 ]]; then
    success "Interface endpoint exists: $short_service_name"
  else
    MISSING_INTERFACE_SERVICES+=("$short_service_name")
  fi
done

if [[ "${#MISSING_INTERFACE_SERVICES[@]}" -gt 0 ]]; then
  printf '[FAIL] Missing expected Interface VPC Endpoints:' >&2
  printf ' %s' "${MISSING_INTERFACE_SERVICES[@]}" >&2
  printf '\n' >&2
  exit 1
fi

section "Checking S3 Gateway VPC Endpoint"

S3_ENDPOINTS_JSON="$(
  aws ec2 describe-vpc-endpoints \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
      "Name=vpc-endpoint-type,Values=Gateway" \
    --output json
)"

S3_ENDPOINT_COUNT="$(echo "$S3_ENDPOINTS_JSON" | jq '.VpcEndpoints | length')"

if [[ "$S3_ENDPOINT_COUNT" -gt 0 ]]; then
  success "S3 Gateway VPC Endpoint exists"
else
  fail "S3 Gateway VPC Endpoint not found."
fi

S3_ENDPOINT_STATE="$(
  echo "$S3_ENDPOINTS_JSON" |
    jq -r '.VpcEndpoints[0].State'
)"

if [[ "$S3_ENDPOINT_STATE" == "available" ]]; then
  success "S3 Gateway VPC Endpoint is available"
else
  fail "S3 Gateway VPC Endpoint is ${S3_ENDPOINT_STATE}, expected available."
fi

S3_ROUTE_TABLE_IDS_JSON="$(
  echo "$S3_ENDPOINTS_JSON" |
    jq '[.VpcEndpoints[0].RouteTableIds[]?]'
)"

S3_ROUTE_TABLE_COUNT="$(
  echo "$S3_ROUTE_TABLE_IDS_JSON" |
    jq 'length'
)"

if [[ "$S3_ROUTE_TABLE_COUNT" -gt 0 ]]; then
  success "S3 Gateway VPC Endpoint has route table associations: $S3_ROUTE_TABLE_COUNT"
else
  fail "S3 Gateway VPC Endpoitn has no route table associations."
fi

section "Checking S3 Gateway route table coverage"

COMPUTE_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
    --output json
)"

SERVERLESS_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Serverless-Private-RT-*" \
    --output json
)"

COMPUTE_RT_IDS_JSON="$(echo "$COMPUTE_ROUTE_TABLES_JSON" | jq '[.RouteTables[].RouteTableId]')"
SERVERLESS_RT_IDS_JSON="$(echo "$SERVERLESS_ROUTE_TABLES_JSON" | jq '[.RouteTables[].RouteTableId]')"

COMPUTE_RT_COUNT="$(echo "$COMPUTE_RT_IDS_JSON" | jq 'length')"
SERVERLESS_RT_COUNT="$(echo "$SERVERLESS_RT_IDS_JSON" | jq 'length')"

if [[ "$COMPUTE_RT_COUNT" -eq 0 ]]; then
  fail "No compute private route tables found for S3 Gateway Endpoint coverage check."
fi

MISSING_COMPUTE_S3_ASSOCIATIONS="$(
  jq -n \
    --argjson expected "$COMPUTE_RT_IDS_JSON" \
    --argjson actual "$S3_ROUTE_TABLE_IDS_JSON" \
    '$expected - $actual | length'
)"

if [[ "$MISSING_COMPUTE_S3_ASSOCIATIONS" -eq 0 ]]; then
  success "S3 Gateway Endpoint is associated with all compute private route tables"
else
  jq -n \
    --argjson expected "$COMPUTE_RT_IDS_JSON" \
    --argjson actual "$S3_ROUTE_TABLE_IDS_JSON" \
    '{missing_compute_route_table_ids: ($expected - $actual)}'
  fail "S3 Gateway Endpoint is missing one or more compute private route table associations."
fi

if [[ "$SERVERLESS_RT_COUNT" -gt 0 ]]; then
  MISSING_SERVERLESS_S3_ASSOCIATIONS="$(
    jq -n \
      --argjson expected "$SERVERLESS_RT_IDS_JSON" \
      --argjson actual "$S3_ROUTE_TABLE_IDS_JSON" \
      '$expected - $actual | length'
  )"

  if [[ "$MISSING_SERVERLESS_S3_ASSOCIATIONS" -eq 0 ]]; then
    success "S3 Gateway Endpoint is associated with all serverless private route tables"
  else
    jq -n \
      --argjson expected "$SERVERLESS_RT_IDS_JSON" \
      --argjson actual "$S3_ROUTE_TABLE_IDS_JSON" \
      '{missing_serverless_route_table_ids: ($expected - $actual)}'
    fail "S3 Gateway Endpoint is missing one or more serverless private route table associations."
  fi
else
  warn "No serverless private route tables found. Skipping serverless S3 Gateway coverage check."
fi

section "VPC Endpoints Summary"

cat <<SUMMARY
Environment: ${ENV_NAME}
AWS profile: ${AWS_PROFILE:-<default>}
AWS region: ${AWS_REGION}
Name prefix: ${NAME_PREFIX}
VPC ID: ${VPC_ID}
effective_egress_mode: ${EFFECTIVE_EGRESS_MODE}

Endpoint private subnets: ${ENDPOINT_SUBNET_COUNT}
Endpoint private route tables: ${ENDPOITN_RT_COUNT}
Interface VPC Endpoints: ${INTERFACE_ENDPOINT_COUNT}
S3 Gateway Endpoint count: ${S3_ENDPOINT_COUNT}
S3 Gateway route table associations: ${S3_ROUTE_TABLE_COUNT}
Compute private route tables: ${COMPUTE_RT_COUNT}
Serverless private route tables: ${SERVERLESS_RT_COUNT}
SUMMARY

section "Validation Result"

success "VPC Endpoints validation copmleted successfully for: ${ENV_NAME}"