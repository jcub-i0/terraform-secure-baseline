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
# - Interface VPC Endpoints have the canonical service inventory, private DNS,
#   exact endpoint-private subnet placement, and the expected endpoint SG
# - Live Interface VPC Endpoint IDs exactly match Terraform-owned endpoint IDs
# - The GuardDuty data endpoint is unique and reuses the Terraform-owned endpoint
# - S3 Gateway Endpoint exists
# - S3 Gateway Endpoint has the exact expected private route-table associations
#
# Usage:
#   ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-vpc-endpoints.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-vpc-endpoints.sh dev
#
# shellcheck source-path=SCRIPTDIR

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

# This inventory is platform-owned by modules/vpc_endpoints and is intentionally
# not caller-overridable.
readonly EXPECTED_INTERFACE_ENDPOINT_SERVICES=(
  sts
  sqs
  logs
  ssm
  ssmmessages
  secretsmanager
  kms
  config
  sns
  ec2
  ecr.api
  ecr.dkr
  events
  securityhub
  lambda
  guardduty-data
)

export AWS_PAGER=""

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

section "${CLOUD_NAME} VPC Endpoints Validation"

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

if ! terraform_output_exists "$OUTPUTS_JSON" interface_endpoint_ids; then
  fail "Missing required Terraform output for exact Interface VPC Endpoint ownership validation: interface_endpoint_ids"
fi

INTERFACE_ENDPOINT_IDS_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -S -c '.interface_endpoint_ids.value // null'
)"

if ! echo "$INTERFACE_ENDPOINT_IDS_JSON" |
  jq -e '
    type == "object"
    and length > 0
    and all(
      to_entries[];
      (.key | type == "string" and length > 0)
      and (.value | type == "string" and test("^vpce-[0-9a-f]+$"))
    )
  ' >/dev/null; then
  echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq .
  fail "interface_endpoint_ids must be a non-empty map of service names to VPC Endpoint IDs."
fi

EXPECTED_INTERFACE_SERVICES_JSON="$(
  printf '%s\n' "${EXPECTED_INTERFACE_ENDPOINT_SERVICES[@]}" |
    jq -R . |
    jq -s -c 'sort | unique'
)"

TERRAFORM_INTERFACE_SERVICES_JSON="$(
  echo "$INTERFACE_ENDPOINT_IDS_JSON" |
    jq -c 'keys | sort'
)"

if [[ "$TERRAFORM_INTERFACE_SERVICES_JSON" != "$EXPECTED_INTERFACE_SERVICES_JSON" ]]; then
  jq -n \
    --argjson expected "$EXPECTED_INTERFACE_SERVICES_JSON" \
    --argjson terraform "$TERRAFORM_INTERFACE_SERVICES_JSON" \
    '{
      expected_services: $expected,
      terraform_services: $terraform,
      missing_from_terraform: ($expected - $terraform),
      unexpected_in_terraform: ($terraform - $expected)
    }'

  fail "interface_endpoint_ids keys do not exactly match the platform-owned Interface VPC Endpoint service inventory."
fi

TERRAFORM_INTERFACE_ENDPOINT_COUNT="$(
  echo "$INTERFACE_ENDPOINT_IDS_JSON" |
    jq 'length'
)"

TERRAFORM_UNIQUE_INTERFACE_ENDPOINT_COUNT="$(
  echo "$INTERFACE_ENDPOINT_IDS_JSON" |
    jq '[.[]] | unique | length'
)"

if [[ "$TERRAFORM_UNIQUE_INTERFACE_ENDPOINT_COUNT" -ne "$TERRAFORM_INTERFACE_ENDPOINT_COUNT" ]]; then
  echo "$INTERFACE_ENDPOINT_IDS_JSON" | jq .
  fail "interface_endpoint_ids contains a VPC Endpoint ID assigned to more than one service."
fi

GUARDDUTY_DATA_ENDPOINT_ID="$(
  echo "$INTERFACE_ENDPOINT_IDS_JSON" |
    jq -r '."guardduty-data" // empty'
)"

if [[ -z "$GUARDDUTY_DATA_ENDPOINT_ID" ]]; then
  fail "interface_endpoint_ids does not contain the required guardduty-data endpoint."
fi

success "Terraform Interface VPC Endpoint ownership contract is valid: ${TERRAFORM_INTERFACE_ENDPOINT_COUNT} endpoints"
info "Terraform-owned guardduty-data endpoint: ${GUARDDUTY_DATA_ENDPOINT_ID}"

if terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
  require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"
  success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"
else
  warn "Missing Terraform output: effective_egress_mode"
  EFFECTIVE_EGRESS_MODE="unknown"
fi

section "Checking AWS caller identity"

info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: ${AWS_REGION}"

AWS_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
AWS_CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$AWS_ACCOUNT_ID" || "$AWS_ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

if [[ -z "$AWS_CALLER_ARN" || "$AWS_CALLER_ARN" == "None" ]]; then
  fail "Unable to resolve AWS caller ARN"
fi

success "AWS credentials are valid"
info "AWS account ID: $AWS_ACCOUNT_ID"
info "AWS caller ARN: $AWS_CALLER_ARN"

if [[ -n "$EXPECTED_ACCOUNT_ID" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
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
    jq '[.Subnets[].SubnetId] | sort | unique'
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

INTERFACE_ENDPOINT_SGS_JSON="$(
  aws ec2 describe-security-groups \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-VPC-Endpoints-SG" \
    --output json
)"

INTERFACE_ENDPOINT_SG_COUNT="$(echo "$INTERFACE_ENDPOINT_SGS_JSON" | jq '.SecurityGroups | length')"

if [[ "$INTERFACE_ENDPOINT_SG_COUNT" -ne 1 ]]; then
  echo "$INTERFACE_ENDPOINT_SGS_JSON" | jq '[.SecurityGroups[] | {group_id: .GroupId, group_name: .GroupName}]'
  fail "Expected exactly one Interface Endpoint security group, found ${INTERFACE_ENDPOINT_SG_COUNT}."
fi

INTERFACE_ENDPOINT_SG_ID="$(echo "$INTERFACE_ENDPOINT_SGS_JSON" | jq -r '.SecurityGroups[0].GroupId')"
success "Resolved Interface Endpoint security group: ${INTERFACE_ENDPOINT_SG_ID}"

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

WRONG_VPC_INTERFACE_ENDPOINT_COUNT="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --arg vpc_id "$VPC_ID" '[.VpcEndpoints[] | select(.VpcId != $vpc_id)] | length'
)"

if [[ "$WRONG_VPC_INTERFACE_ENDPOINT_COUNT" -eq 0 ]]; then
  success "All Interface VPC Endpoints belong to the expected VPC"
else
  echo "$INTERFACE_ENDPOINTS_JSON" | jq --arg vpc_id "$VPC_ID" '[.VpcEndpoints[] | select(.VpcId != $vpc_id) | {endpoint_id: .VpcEndpointId, service_name: .ServiceName, vpc_id: .VpcId}]'
  fail "One or more Interface VPC Endpoints belong to an unexpected VPC."
fi

PRIVATE_DNS_DISABLED_INTERFACE_ENDPOINT_COUNT="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq '[.VpcEndpoints[] | select(.PrivateDnsEnabled != true)] | length'
)"

if [[ "$PRIVATE_DNS_DISABLED_INTERFACE_ENDPOINT_COUNT" -eq 0 ]]; then
  success "Private DNS is enabled on every Interface VPC Endpoint"
else
  echo "$INTERFACE_ENDPOINTS_JSON" | jq '[.VpcEndpoints[] | select(.PrivateDnsEnabled != true) | {endpoint_id: .VpcEndpointId, service_name: .ServiceName, private_dns_enabled: .PrivateDnsEnabled}]'
  fail "One or more Interface VPC Endpoints do not have private DNS enabled."
fi

INTERFACE_ENDPOINT_SUBNET_MISMATCH_COUNT="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --argjson expected "$ENDPOINT_SUBNET_IDS_JSON" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            subnet_ids: ([.SubnetIds[]] | sort | unique),
            missing_subnet_ids: ($expected - ([.SubnetIds[]] | sort | unique)),
            unexpected_subnet_ids: (([.SubnetIds[]] | sort | unique) - $expected)
          }
        | select(
            (.missing_subnet_ids | length) > 0
            or (.unexpected_subnet_ids | length) > 0
          )
      ]
      | length
    '
)"

if [[ "$INTERFACE_ENDPOINT_SUBNET_MISMATCH_COUNT" -eq 0 ]]; then
  success "Every Interface VPC Endpoint uses the exact endpoint-private subnet set"
else
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --argjson expected "$ENDPOINT_SUBNET_IDS_JSON" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            subnet_ids: ([.SubnetIds[]] | sort | unique),
            missing_subnet_ids: ($expected - ([.SubnetIds[]] | sort | unique)),
            unexpected_subnet_ids: (([.SubnetIds[]] | sort | unique) - $expected)
          }
        | select(
            (.missing_subnet_ids | length) > 0
            or (.unexpected_subnet_ids | length) > 0
          )
      ]
    '
  fail "One or more Interface VPC Endpoints do not use the exact endpoint-private subnet set."
fi

INTERFACE_ENDPOINT_SG_MISMATCH_COUNT="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --arg expected_sg_id "$INTERFACE_ENDPOINT_SG_ID" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            security_group_ids: ([.Groups[].GroupId] | sort | unique)
          }
        | select(.security_group_ids != [$expected_sg_id])
      ]
      | length
    '
)"

if [[ "$INTERFACE_ENDPOINT_SG_MISMATCH_COUNT" -eq 0 ]]; then
  success "Every Interface VPC Endpoint uses exactly the Interface Endpoint security group"
else
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --arg expected_sg_id "$INTERFACE_ENDPOINT_SG_ID" '
      [
        .VpcEndpoints[]
        | {
            service_name: .ServiceName,
            endpoint_id: .VpcEndpointId,
            expected_security_group_ids: [$expected_sg_id],
            actual_security_group_ids: ([.Groups[].GroupId] | sort | unique)
          }
        | select(.actual_security_group_ids != .expected_security_group_ids)
      ]
    '
  fail "One or more Interface VPC Endpoints do not use exactly the expected Interface Endpoint security group."
fi

section "Checking expected Interface VPC Endpoint services"

MISSING_INTERFACE_SERVICES=()
DUPLICATE_INTERFACE_SERVICES=()

for short_service_name in "${EXPECTED_INTERFACE_ENDPOINT_SERVICES[@]}"; do
  full_service_name="com.amazonaws.${AWS_REGION}.${short_service_name}"

  matching_count="$(
    echo "$INTERFACE_ENDPOINTS_JSON" |
      jq --arg service "$full_service_name" '[.VpcEndpoints[] | select(.ServiceName == $service)] | length'
  )"
  
  if [[ "$matching_count" -eq 1 ]]; then
    success "Interface endpoint exists: $short_service_name"
  elif [[ "$matching_count" -gt 1 ]]; then
    DUPLICATE_INTERFACE_SERVICES+=("$short_service_name")
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

if [[ "${#DUPLICATE_INTERFACE_SERVICES[@]}" -gt 0 ]]; then
  printf '[FAIL] Duplicate Interface VPC Endpoints found for services:' >&2
  printf ' %s' "${DUPLICATE_INTERFACE_SERVICES[@]}" >&2
  printf '\n' >&2
  exit 1
fi

ACTUAL_INTERFACE_SERVICES_JSON="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq --arg prefix "com.amazonaws.${AWS_REGION}." '
      [.VpcEndpoints[].ServiceName | ltrimstr($prefix)] | sort | unique
    '
)"

UNEXPECTED_INTERFACE_SERVICES_JSON="$(
  jq -n \
    --argjson expected "$EXPECTED_INTERFACE_SERVICES_JSON" \
    --argjson actual "$ACTUAL_INTERFACE_SERVICES_JSON" \
    '$actual - $expected'
)"

if [[ "$(echo "$UNEXPECTED_INTERFACE_SERVICES_JSON" | jq 'length')" -eq 0 ]]; then
  success "Interface VPC Endpoint service inventory exactly matches the platform-owned set"
else
  echo "$UNEXPECTED_INTERFACE_SERVICES_JSON" | jq '{unexpected_interface_endpoint_services: .}'
  fail "Unexpected Interface VPC Endpoint services are present."
fi

section "Checking Terraform-owned Interface VPC Endpoint identities"

LIVE_INTERFACE_ENDPOINT_IDS_JSON="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq -S -c \
      --arg prefix "com.amazonaws.${AWS_REGION}." '
        reduce .VpcEndpoints[] as $endpoint ({};
          .[($endpoint.ServiceName | ltrimstr($prefix))] = $endpoint.VpcEndpointId
        )
      '
)"

if [[ "$LIVE_INTERFACE_ENDPOINT_IDS_JSON" != "$INTERFACE_ENDPOINT_IDS_JSON" ]]; then
  INTERFACE_ENDPOINT_ID_DRIFT_JSON="$(
    jq -n \
      --argjson terraform "$INTERFACE_ENDPOINT_IDS_JSON" \
      --argjson live "$LIVE_INTERFACE_ENDPOINT_IDS_JSON" '
        (($terraform | keys) + ($live | keys) | unique) as $services
        | [
            $services[] as $service
            | select($terraform[$service] != $live[$service])
            | {
                service: $service,
                terraform_endpoint_id: ($terraform[$service] // null),
                live_endpoint_id: ($live[$service] // null)
              }
          ]
      '
  )"

  echo "$INTERFACE_ENDPOINT_ID_DRIFT_JSON" | jq .
  fail "Live Interface VPC Endpoint identities do not exactly match Terraform output interface_endpoint_ids."
fi

success "Every live Interface VPC Endpoint ID exactly matches Terraform ownership state"

GUARDDUTY_DATA_ENDPOINTS_JSON="$(
  echo "$INTERFACE_ENDPOINTS_JSON" |
    jq -c \
      --arg service "com.amazonaws.${AWS_REGION}.guardduty-data" '
        [
          .VpcEndpoints[]
          | select(.ServiceName == $service)
        ]
      '
)"

GUARDDUTY_DATA_ENDPOINT_COUNT="$(
  echo "$GUARDDUTY_DATA_ENDPOINTS_JSON" |
    jq 'length'
)"

if [[ "$GUARDDUTY_DATA_ENDPOINT_COUNT" -ne 1 ]]; then
  echo "$GUARDDUTY_DATA_ENDPOINTS_JSON" | jq .
  fail "Expected exactly one guardduty-data Interface VPC Endpoint; found ${GUARDDUTY_DATA_ENDPOINT_COUNT}."
fi

LIVE_GUARDDUTY_DATA_ENDPOINT_ID="$(
  echo "$GUARDDUTY_DATA_ENDPOINTS_JSON" |
    jq -r '.[0].VpcEndpointId // empty'
)"

if [[ "$LIVE_GUARDDUTY_DATA_ENDPOINT_ID" != "$GUARDDUTY_DATA_ENDPOINT_ID" ]]; then
  fail "Live guardduty-data endpoint ${LIVE_GUARDDUTY_DATA_ENDPOINT_ID:-<missing>} does not match Terraform-owned endpoint ${GUARDDUTY_DATA_ENDPOINT_ID}."
fi

success "GuardDuty Runtime Monitoring reuses the unique Terraform-owned guardduty-data endpoint: ${GUARDDUTY_DATA_ENDPOINT_ID}"

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

if [[ "$S3_ENDPOINT_COUNT" -eq 1 ]]; then
  success "Exactly one S3 Gateway VPC Endpoint exists"
else
  fail "Expected exactly one S3 Gateway VPC Endpoint, found ${S3_ENDPOINT_COUNT}."
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
  fail "S3 Gateway VPC Endpoint has no route table associations."
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
ENDPOINT_RT_IDS_JSON="$(echo "$ENDPOINT_ROUTE_TABLES_JSON" | jq '[.RouteTables[].RouteTableId]')"

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

if [[ "$SERVERLESS_RT_COUNT" -eq 0 ]]; then
  fail "No serverless private route tables found for S3 Gateway Endpoint coverage check."
fi

EXPECTED_S3_ROUTE_TABLE_IDS_JSON="$(
  jq -n \
    --argjson endpoint "$ENDPOINT_RT_IDS_JSON" \
    --argjson compute "$COMPUTE_RT_IDS_JSON" \
    --argjson serverless "$SERVERLESS_RT_IDS_JSON" \
    '$endpoint + $compute + $serverless | sort | unique'
)"

NORMALIZED_S3_ROUTE_TABLE_IDS_JSON="$(echo "$S3_ROUTE_TABLE_IDS_JSON" | jq 'sort | unique')"

S3_ROUTE_TABLE_SET_DIFFERENCE_JSON="$(
  jq -n \
    --argjson expected "$EXPECTED_S3_ROUTE_TABLE_IDS_JSON" \
    --argjson actual "$NORMALIZED_S3_ROUTE_TABLE_IDS_JSON" \
    '{missing_route_table_ids: ($expected - $actual), unexpected_route_table_ids: ($actual - $expected)}'
)"

if echo "$S3_ROUTE_TABLE_SET_DIFFERENCE_JSON" |
  jq -e '(.missing_route_table_ids | length) == 0 and (.unexpected_route_table_ids | length) == 0' >/dev/null; then
  success "S3 Gateway Endpoint route-table associations exactly match endpoint, compute, and serverless private route tables"
else
  echo "$S3_ROUTE_TABLE_SET_DIFFERENCE_JSON" | jq .
  fail "S3 Gateway Endpoint route-table associations do not exactly match the expected private route-table set."
fi

section "VPC Endpoints Summary"

cat <<SUMMARY
Environment:                          ${ENV_NAME}
AWS profile:                          ${AWS_PROFILE:-<default>}
AWS region:                           ${AWS_REGION}
Name prefix:                          ${NAME_PREFIX}
VPC ID:                               ${VPC_ID}
effective_egress_mode:                ${EFFECTIVE_EGRESS_MODE}

Endpoint private subnets:             ${ENDPOINT_SUBNET_COUNT}
Endpoint private route tables:        ${ENDPOINT_RT_COUNT}
Interface VPC Endpoints:              ${INTERFACE_ENDPOINT_COUNT}
Terraform-owned endpoint IDs:         ${TERRAFORM_INTERFACE_ENDPOINT_COUNT}
Interface Endpoint security group:    ${INTERFACE_ENDPOINT_SG_ID}
GuardDuty data endpoint:              ${GUARDDUTY_DATA_ENDPOINT_ID}
S3 Gateway Endpoint count:            ${S3_ENDPOINT_COUNT}
S3 Gateway route table associations:  ${S3_ROUTE_TABLE_COUNT}
Compute private route tables:         ${COMPUTE_RT_COUNT}
Serverless private route tables:      ${SERVERLESS_RT_COUNT}
SUMMARY

section "Validation Result"

success "VPC Endpoints validation completed successfully for: ${ENV_NAME}"
