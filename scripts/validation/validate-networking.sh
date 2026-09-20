#!/usr/bin/env bash

# validate-networking.sh
#
# Validates core networking behavior for a deployed tf-secure-baseline
# environment based on Terraform-owned topology expectations and the effective
# egress mode.
#
# Usage:
#   ./scripts/validation/validate-networking.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-networking.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-networking.sh dev
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

normalize_route_tables_json() {
  local az_name_prefix="${1:-}"

  jq --arg az_name_prefix "$az_name_prefix" '[.RouteTables[] | {
    route_table_id: .RouteTableId,
    name: ((.Tags[]? | select(.Key == "Name") | .Value) // ""),
    az: (((.Tags[]? | select(.Key == "Name") | .Value) // "") | sub("^" + $az_name_prefix; "")),
    routes: [
      .Routes[]?
      | . + {
          target_id: (.VpcEndpointId // .GatewayId // .NatGatewayId // .TransitGatewayId // .InstanceId // .NetworkInterfaceId // "unknown"),
          target_type: (
            if ((.VpcEndpointId // .GatewayId // "") | startswith("vpce-")) then "vpc_endpoint"
            elif (.NatGatewayId // "") != "" then "nat_gateway"
            elif ((.GatewayId // "") | startswith("igw-")) then "internet_gateway"
            elif (.GatewayId // "") == "local" then "local"
            elif (.TransitGatewayId // "") != "" then "transit_gateway"
            elif (.NetworkInterfaceId // "") != "" then "network_interface"
            elif (.GatewayId // "") != "" then "gateway"
            else "unknown"
            end
          )
        }
    ]
  }]'
}

validate_subnet_family() {
  local family_label="$1"
  local tag_name_prefix="$2"
  local expected_map_json="$3"
  local live_family_json
  local live_map_json
  local expected_count
  local live_count
  local public_ip_mapping_count

  live_family_json="$(
    echo "$ALL_SUBNETS_JSON" |
      jq -c --arg prefix "$tag_name_prefix" '
        [
          .Subnets[]
          | select(
              (((.Tags[]? | select(.Key == "Name") | .Value) // "")
              | startswith($prefix))
            )
        ]
      '
  )"

  live_map_json="$(
    echo "$live_family_json" |
      jq -S -c 'reduce .[] as $subnet ({}; .[$subnet.AvailabilityZone] = $subnet.SubnetId)'
  )"

  expected_count="$(echo "$expected_map_json" | jq 'length')"
  live_count="$(echo "$live_family_json" | jq 'length')"

  if [[ "$live_count" -ne "$expected_count" || "$live_map_json" != "$expected_map_json" ]]; then
    jq -n \
      --arg family "$family_label" \
      --argjson expected "$expected_map_json" \
      --argjson live "$live_map_json" \
      --argjson expected_count "$expected_count" \
      --argjson live_count "$live_count" '
        {
          family: $family,
          expected_count: $expected_count,
          live_count: $live_count,
          expected_subnet_ids_by_az: $expected,
          live_subnet_ids_by_az: $live
        }
      '
    fail "${family_label} subnet inventory does not exactly match Terraform network_topology."
  fi

  public_ip_mapping_count="$(
    echo "$live_family_json" |
      jq '[.[] | select(.MapPublicIpOnLaunch == true)] | length'
  )"

  if [[ "$public_ip_mapping_count" -ne 0 ]]; then
    echo "$live_family_json" |
      jq '[.[] | select(.MapPublicIpOnLaunch == true) | {
        subnet_id: .SubnetId,
        availability_zone: .AvailabilityZone
      }]'
    fail "One or more ${family_label} subnets auto-assign public IPv4 addresses."
  fi

  success "${family_label} subnet inventory exactly matches Terraform: ${live_count} subnet(s)"
}

validate_route_table_az_inventory() {
  local route_table_label="$1"
  local normalized_route_tables_json="$2"
  local actual_azs_json
  local actual_count

  actual_azs_json="$(
    echo "$normalized_route_tables_json" |
      jq -c '[.[].az] | sort | unique'
  )"

  actual_count="$(echo "$normalized_route_tables_json" | jq 'length')"

  if [[ "$actual_count" -ne "$EXPECTED_AZ_COUNT" || "$actual_azs_json" != "$EXPECTED_AZS_JSON" ]]; then
    jq -n \
      --arg label "$route_table_label" \
      --argjson expected_azs "$EXPECTED_AZS_JSON" \
      --argjson actual_azs "$actual_azs_json" '
        {
          route_table_family: $label,
          expected_azs: $expected_azs,
          actual_azs: $actual_azs
        }
      '
    fail "${route_table_label} route-table AZ inventory does not match Terraform network_topology."
  fi

  success "${route_table_label} route-table AZ inventory matches Terraform: ${actual_count} route table(s)"
}

validate_default_routes_by_az() {
  local route_table_label="$1"
  local route_tables_json="$2"
  local expected_targets_json="$3"
  local expected_target_type="$4"
  local drift_json

  drift_json="$(
    jq -n \
      --argjson route_tables "$route_tables_json" \
      --argjson expected_targets "$expected_targets_json" \
      --arg expected_target_type "$expected_target_type" '
        [
          $route_tables[]
          | . as $route_table
          | ($expected_targets[$route_table.az] // null) as $expected_target
          | ([.routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")]) as $default_routes
          | select(
              $expected_target == null
              or ($default_routes | length) != 1
              or $default_routes[0].target_type != $expected_target_type
              or $default_routes[0].target_id != $expected_target
            )
          | {
              az: .az,
              route_table_id: .route_table_id,
              expected_target: $expected_target,
              expected_target_type: $expected_target_type,
              default_routes: $default_routes
            }
        ]
      '
  )"

  if [[ "$drift_json" != "[]" ]]; then
    echo "$drift_json" | jq .
    fail "${route_table_label} default routing does not use the Terraform-owned same-AZ target."
  fi

  success "${route_table_label} default routing uses the Terraform-owned same-AZ ${expected_target_type}"
}

topology_field() {
  local field="$1"

  echo "$NETWORK_TOPOLOGY_JSON" |
    jq -S -ce --arg field "$field" '
      .[$field] // error("network_topology." + $field + " is required")
    '
}

section "${CLOUD_NAME} Networking Validation"

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

for required_output in \
  network_topology \
  effective_egress_mode \
  effective_allowed_egress_domains; do
  if ! terraform_output_exists "$OUTPUTS_JSON" "$required_output"; then
    fail "Missing required Terraform output: ${required_output}"
  fi
done

DEPLOYMENT_PROFILE="$(
  if terraform_output_exists "$OUTPUTS_JSON" deployment_profile; then
    get_terraform_output_value "$OUTPUTS_JSON" deployment_profile
  else
    printf '%s' "unknown"
  fi
)"

if ! NETWORK_TOPOLOGY_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -S -ce '.network_topology.value | if type == "object" then . else error("network_topology must be an object") end'
)"; then
  fail "Unable to resolve network_topology from Terraform outputs."
fi

EXPECTED_AZS_JSON="$(topology_field availability_zones | jq -c 'sort')"
EXPECTED_AZ_COUNT="$(echo "$EXPECTED_AZS_JSON" | jq 'length')"

EXPECTED_PUBLIC_SUBNET_IDS_BY_AZ_JSON="$(topology_field public_subnet_ids_by_az)"
EXPECTED_COMPUTE_SUBNET_IDS_BY_AZ_JSON="$(topology_field compute_private_subnet_ids_by_az)"
EXPECTED_DATA_SUBNET_IDS_BY_AZ_JSON="$(topology_field data_private_subnet_ids_by_az)"
EXPECTED_SERVERLESS_SUBNET_IDS_BY_AZ_JSON="$(topology_field serverless_private_subnet_ids_by_az)"
EXPECTED_ENDPOINT_SUBNET_IDS_BY_AZ_JSON="$(topology_field endpoint_private_subnet_ids_by_az)"
EXPECTED_FIREWALL_SUBNET_IDS_BY_AZ_JSON="$(topology_field firewall_private_subnet_ids_by_az)"
EXPECTED_NAT_GATEWAY_IDS_BY_AZ_JSON="$(topology_field nat_gateway_ids_by_az)"
EXPECTED_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON="$(topology_field firewall_endpoint_ids_by_az)"

EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"
success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"

if ! EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -ce '
      .effective_allowed_egress_domains.value
      | if type == "array" and all(.[]; type == "string") then sort | unique
        else error("effective_allowed_egress_domains must be an array of strings")
        end
    '
)"; then
  fail "Unable to resolve effective_allowed_egress_domains as a Terraform domain set."
fi

EFFECTIVE_ALLOWED_EGRESS_DOMAIN_COUNT="$(echo "$EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON" | jq 'length')"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    success "Resolved ${EFFECTIVE_ALLOWED_EGRESS_DOMAIN_COUNT} effective Network Firewall domain target(s) from Terraform"
    ;;
  nat_only|vpc_endpoints_only)
    if [[ "$EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON" != "[]" ]]; then
      fail "effective_allowed_egress_domains must be empty when Network Firewall is not instantiated."
    fi

    success "effective_allowed_egress_domains is empty as expected for ${EFFECTIVE_EGRESS_MODE}"
    ;;
esac

success "Resolved Terraform network topology: ${EXPECTED_AZ_COUNT} Availability Zone(s)"
info "Expected Availability Zones: ${EXPECTED_AZS_JSON}"

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

if [[ -n "${EXPECTED_ACCOUNT_ID:-}" ]]; then
  if [[ "$AWS_ACCOUNT_ID" == "$EXPECTED_ACCOUNT_ID" ]]; then
    success "AWS account ID matches expected account: $EXPECTED_ACCOUNT_ID"
  else
    fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${AWS_ACCOUNT_ID}"
  fi
else
  warn "EXPECTED_ACCOUNT_ID not set. Skipping explicit account ID match check."
fi

section "Resolving VPC"

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
  fail "Unable to resolve VPC ID. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID"

section "Checking exact Terraform-owned subnet topology"

ALL_SUBNETS_JSON="$(
  aws ec2 describe-subnets \
    "${aws_args[@]}" \
    --filters "Name=vpc-id,Values=${VPC_ID}" \
    --output json
)"

validate_subnet_family \
  "public" \
  "${NAME_PREFIX}-Public-Subnet-" \
  "$EXPECTED_PUBLIC_SUBNET_IDS_BY_AZ_JSON"

validate_subnet_family \
  "compute-private" \
  "${NAME_PREFIX}-Compute-Private-" \
  "$EXPECTED_COMPUTE_SUBNET_IDS_BY_AZ_JSON"

validate_subnet_family \
  "data-private" \
  "${NAME_PREFIX}-Data-Private-" \
  "$EXPECTED_DATA_SUBNET_IDS_BY_AZ_JSON"

validate_subnet_family \
  "serverless-private" \
  "${NAME_PREFIX}-Serverless-Private-" \
  "$EXPECTED_SERVERLESS_SUBNET_IDS_BY_AZ_JSON"

validate_subnet_family \
  "endpoint-private" \
  "${NAME_PREFIX}-Endpoint-Private-" \
  "$EXPECTED_ENDPOINT_SUBNET_IDS_BY_AZ_JSON"

validate_subnet_family \
  "firewall-private" \
  "${NAME_PREFIX}-Firewall-Private-" \
  "$EXPECTED_FIREWALL_SUBNET_IDS_BY_AZ_JSON"

COMPUTE_SUBNETS_JSON="$(
  echo "$ALL_SUBNETS_JSON" |
    jq -c --arg prefix "${NAME_PREFIX}-Compute-Private-" '
      [
        .Subnets[]
        | select(
            (((.Tags[]? | select(.Key == "Name") | .Value) // "")
            | startswith($prefix))
          )
      ]
    '
)"

COMPUTE_SUBNET_COUNT="$(echo "$COMPUTE_SUBNETS_JSON" | jq 'length')"

COMPUTE_SUBNET_CIDRS_JSON="$(
  echo "$COMPUTE_SUBNETS_JSON" |
    jq '[.[] | {
      az: .AvailabilityZone,
      cidr: .CidrBlock,
      subnet_id: .SubnetId
    }]'
)"

section "Checking NAT Gateways"

NAT_GATEWAYS_JSON="$(
  aws ec2 describe-nat-gateways \
    "${aws_args[@]}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --output json
)"

NAT_GATEWAY_COUNT="$(echo "$NAT_GATEWAYS_JSON" | jq '.NatGateways | length')"
LIVE_NAT_GATEWAY_IDS_JSON="$(echo "$NAT_GATEWAYS_JSON" | jq -c '[.NatGateways[].NatGatewayId] | sort | unique')"
EXPECTED_NAT_GATEWAY_IDS_JSON="$(echo "$EXPECTED_NAT_GATEWAY_IDS_BY_AZ_JSON" | jq -c '[.[]] | sort | unique')"

info "NAT Gateway count: $NAT_GATEWAY_COUNT"

if [[ "$LIVE_NAT_GATEWAY_IDS_JSON" != "$EXPECTED_NAT_GATEWAY_IDS_JSON" ]]; then
  jq -n \
    --argjson expected "$EXPECTED_NAT_GATEWAY_IDS_JSON" \
    --argjson live "$LIVE_NAT_GATEWAY_IDS_JSON" \
    '{expected_nat_gateway_ids: $expected, live_nat_gateway_ids: $live}'
  fail "Live NAT Gateway inventory does not exactly match Terraform network_topology."
fi

NAT_PLACEMENT_DRIFT_JSON="$(
  jq -n \
    --argjson live "$NAT_GATEWAYS_JSON" \
    --argjson expected_nats "$EXPECTED_NAT_GATEWAY_IDS_BY_AZ_JSON" \
    --argjson expected_public_subnets "$EXPECTED_PUBLIC_SUBNET_IDS_BY_AZ_JSON" '
      [
        $expected_nats
        | to_entries[]
        | . as $expected
        | (
            $live.NatGateways[]
            | select(.NatGatewayId == $expected.value)
          ) as $actual
        | select($actual.SubnetId != $expected_public_subnets[$expected.key])
        | {
            az: $expected.key,
            nat_gateway_id: $expected.value,
            expected_public_subnet_id: $expected_public_subnets[$expected.key],
            actual_subnet_id: $actual.SubnetId
          }
      ]
    '
)"

if [[ "$NAT_PLACEMENT_DRIFT_JSON" != "[]" ]]; then
  echo "$NAT_PLACEMENT_DRIFT_JSON" | jq .
  fail "One or more NAT Gateways are not in the Terraform-owned public subnet for the same AZ."
fi

success "Live NAT Gateway inventory and placement exactly match Terraform"

section "Checking AWS Network Firewall"

NETWORK_FIREWALLS_JSON="$(
  aws network-firewall list-firewalls \
    "${aws_args[@]}" \
    --output json
)"

EXPECTED_FIREWALL_NAME="${NAME_PREFIX}-egress-firewall"

MATCHING_FIREWALL_COUNT="$(
  echo "$NETWORK_FIREWALLS_JSON" |
    jq --arg name "$EXPECTED_FIREWALL_NAME" '[.Firewalls[]? | select(.FirewallName == $name)] | length'
)"

info "Matching Network Firewall count: $MATCHING_FIREWALL_COUNT"

LIVE_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON="{}"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    if [[ "$MATCHING_FIREWALL_COUNT" -ne 1 ]]; then
      fail "Expected exactly one Network Firewall for network_firewall mode, found ${MATCHING_FIREWALL_COUNT}."
    fi

    NETWORK_FIREWALL_DESCRIPTION_JSON="$(
      aws network-firewall describe-firewall \
        "${aws_args[@]}" \
        --firewall-name "$EXPECTED_FIREWALL_NAME" \
        --output json
    )"

    if ! echo "$NETWORK_FIREWALL_DESCRIPTION_JSON" |
      jq -e \
        --arg vpc_id "$VPC_ID" '
          .Firewall.VpcId == $vpc_id
          and .FirewallStatus.Status == "READY"
          and .FirewallStatus.ConfigurationSyncStateSummary == "IN_SYNC"
        ' >/dev/null; then
      echo "$NETWORK_FIREWALL_DESCRIPTION_JSON" |
        jq '{firewall: .Firewall, firewall_status: .FirewallStatus}'
      fail "Network Firewall is not READY/IN_SYNC in the expected VPC."
    fi

    LIVE_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON="$(
      echo "$NETWORK_FIREWALL_DESCRIPTION_JSON" |
        jq -S -c '
          .FirewallStatus.SyncStates
          | to_entries
          | map({key: .key, value: (.value.Attachment.EndpointId // "")})
          | from_entries
        '
    )"

    FIREWALL_ATTACHMENT_DRIFT_JSON="$(
      echo "$NETWORK_FIREWALL_DESCRIPTION_JSON" |
        jq \
          --argjson expected_subnets "$EXPECTED_FIREWALL_SUBNET_IDS_BY_AZ_JSON" '
            [
              .FirewallStatus.SyncStates
              | to_entries[]
              | {
                  az: .key,
                  endpoint_id: .value.Attachment.EndpointId,
                  endpoint_status: .value.Attachment.Status,
                  expected_firewall_subnet_id: $expected_subnets[.key],
                  actual_firewall_subnet_id: .value.Attachment.SubnetId
                }
              | select(
                  .endpoint_status != "READY"
                  or .actual_firewall_subnet_id != .expected_firewall_subnet_id
                )
            ]
          '
    )"

    if [[ "$FIREWALL_ATTACHMENT_DRIFT_JSON" != "[]" ]]; then
      echo "$FIREWALL_ATTACHMENT_DRIFT_JSON" | jq .
      fail "One or more Network Firewall endpoints are not READY in the Terraform-owned same-AZ firewall subnet."
    fi

    success "Network Firewall status and subnet placement match Terraform"
    ;;
  nat_only|vpc_endpoints_only)
    if [[ "$MATCHING_FIREWALL_COUNT" -ne 0 ]]; then
      fail "Expected no Network Firewall for ${EFFECTIVE_EGRESS_MODE}, found ${MATCHING_FIREWALL_COUNT}."
    fi

    success "No Network Firewall found as expected for ${EFFECTIVE_EGRESS_MODE}"
    ;;
esac

if [[ "$LIVE_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" != "$EXPECTED_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" ]]; then
  jq -n \
    --argjson expected "$EXPECTED_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" \
    --argjson live "$LIVE_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" '
      {
        expected_firewall_endpoint_ids_by_az: $expected,
        live_firewall_endpoint_ids_by_az: $live
      }
    '
  fail "Live Network Firewall endpoint inventory does not exactly match Terraform network_topology."
fi

if [[ "$EFFECTIVE_EGRESS_MODE" == "network_firewall" ]]; then
  EXPECTED_RULE_GROUP_NAME="${NAME_PREFIX}-egress-stateful-domains"

  if ! FIREWALL_RULE_GROUP_JSON="$(
    aws network-firewall describe-rule-group \
      "${aws_args[@]}" \
      --rule-group-name "$EXPECTED_RULE_GROUP_NAME" \
      --type STATEFUL \
      --output json
  )"; then
    fail "Unable to describe Network Firewall rule group: ${EXPECTED_RULE_GROUP_NAME}"
  fi

  if ! LIVE_FIREWALL_DOMAIN_TARGETS_JSON="$(
    echo "$FIREWALL_RULE_GROUP_JSON" |
      jq -ce '
        .RuleGroup.RulesSource.RulesSourceList.Targets
        | if type == "array" and all(.[]; type == "string") then sort | unique
          else error("live Network Firewall targets must be an array of strings")
          end
      '
  )"; then
    fail "Unable to resolve live domain targets from Network Firewall rule group: ${EXPECTED_RULE_GROUP_NAME}"
  fi

  MISSING_LIVE_FIREWALL_DOMAINS_JSON="$(
    jq -cn \
      --argjson expected "$EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON" \
      --argjson live "$LIVE_FIREWALL_DOMAIN_TARGETS_JSON" \
      '$expected - $live'
  )"

  UNEXPECTED_LIVE_FIREWALL_DOMAINS_JSON="$(
    jq -cn \
      --argjson expected "$EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON" \
      --argjson live "$LIVE_FIREWALL_DOMAIN_TARGETS_JSON" \
      '$live - $expected'
  )"

  if [[ "$MISSING_LIVE_FIREWALL_DOMAINS_JSON" != "[]" || "$UNEXPECTED_LIVE_FIREWALL_DOMAINS_JSON" != "[]" ]]; then
    info "Terraform effective firewall domain targets: $EFFECTIVE_ALLOWED_EGRESS_DOMAINS_JSON"
    info "Live firewall domain targets: $LIVE_FIREWALL_DOMAIN_TARGETS_JSON"
    info "Domains missing from live AWS: $MISSING_LIVE_FIREWALL_DOMAINS_JSON"
    info "Unexpected domains in live AWS: $UNEXPECTED_LIVE_FIREWALL_DOMAINS_JSON"
    fail "Live Network Firewall domain targets do not exactly match effective_allowed_egress_domains."
  fi

  success "Live Network Firewall domain targets exactly match effective_allowed_egress_domains"
fi

section "Checking compute private route tables"

COMPUTE_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
    --output json
)"

COMPUTE_RT_COUNT="$(echo "$COMPUTE_ROUTE_TABLES_JSON" | jq '.RouteTables | length')"

if [[ "$COMPUTE_RT_COUNT" -eq 0 ]]; then
  fail "No compute private route tables found using tag pattern: ${NAME_PREFIX}-Compute-Private-RT-*"
fi

COMPUTE_ROUTE_TABLES_NORMALIZED_JSON="$(
  echo "$COMPUTE_ROUTE_TABLES_JSON" |
    normalize_route_tables_json "${NAME_PREFIX}-Compute-Private-RT-"
)"

validate_route_table_az_inventory "compute-private" "$COMPUTE_ROUTE_TABLES_NORMALIZED_JSON"

DEFAULT_ROUTE_COUNT="$(
  echo "$COMPUTE_ROUTE_TABLES_NORMALIZED_JSON" |
    jq '[.[] | .routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")] | length'
)"

info "Compute private default route count: $DEFAULT_ROUTE_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    validate_default_routes_by_az \
      "Compute-private" \
      "$COMPUTE_ROUTE_TABLES_NORMALIZED_JSON" \
      "$EXPECTED_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" \
      "vpc_endpoint"
    ;;
  nat_only)
    validate_default_routes_by_az \
      "Compute-private" \
      "$COMPUTE_ROUTE_TABLES_NORMALIZED_JSON" \
      "$EXPECTED_NAT_GATEWAY_IDS_BY_AZ_JSON" \
      "nat_gateway"
    ;;
  vpc_endpoints_only)
    if [[ "$DEFAULT_ROUTE_COUNT" -eq 0 ]]; then
      success "No compute private default routes found as expected for vpc_endpoints_only"
    else
      echo "$COMPUTE_ROUTE_TABLES_NORMALIZED_JSON" | jq .
      fail "Expected no 0.0.0.0/0 routes in compute private route tables for vpc_endpoints_only."
    fi
    ;;
esac

section "Checking firewall private route tables"

FIREWALL_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Firewall-Private-RT-*" \
    --output json
)"

FIREWALL_RT_COUNT="$(echo "$FIREWALL_ROUTE_TABLES_JSON" | jq '.RouteTables | length')"

if [[ "$FIREWALL_RT_COUNT" -eq 0 ]]; then
  fail "No firewall private route tables found using tag pattern: ${NAME_PREFIX}-Firewall-Private-RT-*"
fi

FIREWALL_ROUTE_TABLES_NORMALIZED_JSON="$(
  echo "$FIREWALL_ROUTE_TABLES_JSON" |
    normalize_route_tables_json "${NAME_PREFIX}-Firewall-Private-RT-"
)"

validate_route_table_az_inventory "firewall-private" "$FIREWALL_ROUTE_TABLES_NORMALIZED_JSON"

FIREWALL_DEFAULT_ROUTE_COUNT="$(
  echo "$FIREWALL_ROUTE_TABLES_NORMALIZED_JSON" |
    jq '[.[] | .routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")] | length'
)"

info "Firewall private default route count: $FIREWALL_DEFAULT_ROUTE_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    validate_default_routes_by_az \
      "Firewall-private" \
      "$FIREWALL_ROUTE_TABLES_NORMALIZED_JSON" \
      "$EXPECTED_NAT_GATEWAY_IDS_BY_AZ_JSON" \
      "nat_gateway"
    ;;
  nat_only|vpc_endpoints_only)
    if [[ "$FIREWALL_DEFAULT_ROUTE_COUNT" -eq 0 ]]; then
      success "No firewall private default routes found as expected for ${EFFECTIVE_EGRESS_MODE}"
    else
      echo "$FIREWALL_ROUTE_TABLES_NORMALIZED_JSON" | jq .
      fail "Expected no 0.0.0.0/0 routes in firewall private route tables for ${EFFECTIVE_EGRESS_MODE}."
    fi
    ;;
esac

section "Checking public route tables"

PUBLIC_ROUTE_TABLES_JSON="$(
  aws ec2 describe-route-tables \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Public-Route-Table-*" \
    --output json
)"

PUBLIC_RT_COUNT="$(echo "$PUBLIC_ROUTE_TABLES_JSON" | jq '.RouteTables | length')"

if [[ "$PUBLIC_RT_COUNT" -eq 0 ]]; then
  fail "No public route tables found using tag pattern: ${NAME_PREFIX}-Public-Route-Table-*"
fi

PUBLIC_ROUTE_TABLES_NORMALIZED_JSON="$(
  echo "$PUBLIC_ROUTE_TABLES_JSON" |
    normalize_route_tables_json "${NAME_PREFIX}-Public-Route-Table-"
)"

validate_route_table_az_inventory "public" "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON"

PUBLIC_DEFAULT_ROUTE_DRIFT_JSON="$(
  jq -n \
    --argjson route_tables "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON" '
      [
        $route_tables[]
        | . as $route_table
        | ([.routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")]) as $default_routes
        | select(
            ($default_routes | length) != 1
            or $default_routes[0].target_type != "internet_gateway"
          )
        | {
            az: .az,
            route_table_id: .route_table_id,
            default_routes: $default_routes
          }
      ]
    '
)"

PUBLIC_DEFAULT_ROUTE_COUNT="$(
  echo "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON" |
    jq '[.[] | .routes[]? | select(.DestinationCidrBlock == "0.0.0.0/0")] | length'
)"

if [[ "$PUBLIC_DEFAULT_ROUTE_DRIFT_JSON" != "[]" ]]; then
  echo "$PUBLIC_DEFAULT_ROUTE_DRIFT_JSON" | jq .
  fail "Every public route table must have exactly one Internet Gateway default route."
fi

success "Every public route table has exactly one Internet Gateway default route"

PUBLIC_COMPUTE_RETURN_ROUTE_COUNT="$(
  jq -n \
    --argjson route_tables "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON" \
    --argjson compute_subnets "$COMPUTE_SUBNET_CIDRS_JSON" \
    '[$compute_subnets[].cidr] as $compute_cidrs |
     [$route_tables[] | .routes[]? | select(.DestinationCidrBlock as $dest | $compute_cidrs | index($dest))] | length'
)"

info "Public compute return route count: $PUBLIC_COMPUTE_RETURN_ROUTE_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    PUBLIC_RETURN_ROUTE_DRIFT_JSON="$(
      jq -n \
        --argjson route_tables "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON" \
        --argjson compute_subnets "$COMPUTE_SUBNET_CIDRS_JSON" \
        --argjson expected_targets "$EXPECTED_FIREWALL_ENDPOINT_IDS_BY_AZ_JSON" '
          [
            $compute_subnets[] as $subnet
            | ($route_tables[] | select(.az == $subnet.az)) as $route_table
            | ($expected_targets[$subnet.az] // null) as $expected_target
            | ([
                $route_table.routes[]?
                | select(.DestinationCidrBlock == $subnet.cidr)
              ]) as $matching_routes
            | select(
                $expected_target == null
                or ($matching_routes | length) != 1
                or $matching_routes[0].target_type != "vpc_endpoint"
                or $matching_routes[0].target_id != $expected_target
              )
            | {
                az: $subnet.az,
                compute_cidr: $subnet.cidr,
                public_route_table_id: $route_table.route_table_id,
                expected_firewall_endpoint_id: $expected_target,
                matching_routes: $matching_routes
              }
          ]
        '
    )"

    if [[ "$PUBLIC_RETURN_ROUTE_DRIFT_JSON" != "[]" ]]; then
      echo "$PUBLIC_RETURN_ROUTE_DRIFT_JSON" | jq .
      fail "Public return routing for compute-private CIDRs is not AZ-local through the Terraform-owned Network Firewall endpoints."
    fi

    success "Public route tables return each compute CIDR through the Terraform-owned same-AZ Network Firewall endpoint"
    ;;
  nat_only|vpc_endpoints_only)
    if [[ "$PUBLIC_COMPUTE_RETURN_ROUTE_COUNT" -eq 0 ]]; then
      success "No public compute return routes found as expected for ${EFFECTIVE_EGRESS_MODE}"
    else
      echo "$PUBLIC_ROUTE_TABLES_NORMALIZED_JSON" | jq .
      fail "Expected no explicit public compute return routes for ${EFFECTIVE_EGRESS_MODE}."
    fi
    ;;
esac

section "Networking Summary"

cat <<SUMMARY
Environment:                ${ENV_NAME}
Deployment profile:         ${DEPLOYMENT_PROFILE}
AWS profile:                ${AWS_PROFILE:-<default>}
AWS region:                 ${AWS_REGION}
Name prefix:                ${NAME_PREFIX}
VPC ID:                     ${VPC_ID}
effective_egress_mode:      ${EFFECTIVE_EGRESS_MODE}
Expected AZ count:          ${EXPECTED_AZ_COUNT}
Expected AZs:               ${EXPECTED_AZS_JSON}
Effective firewall domains: ${EFFECTIVE_ALLOWED_EGRESS_DOMAIN_COUNT}

NAT Gateway count:          ${NAT_GATEWAY_COUNT}
Matching Network Firewalls: ${MATCHING_FIREWALL_COUNT}
Compute route tables:       ${COMPUTE_RT_COUNT}
Compute private subnets:    ${COMPUTE_SUBNET_COUNT}
Compute default routes:     ${DEFAULT_ROUTE_COUNT}
Firewall route tables:      ${FIREWALL_RT_COUNT}
Firewall default routes:    ${FIREWALL_DEFAULT_ROUTE_COUNT}
Public route tables:        ${PUBLIC_RT_COUNT}
Public default routes:      ${PUBLIC_DEFAULT_ROUTE_COUNT}
Public compute returns:     ${PUBLIC_COMPUTE_RETURN_ROUTE_COUNT}
SUMMARY

section "Validation Result"

success "Networking validation completed successfully for: ${ENV_NAME}"