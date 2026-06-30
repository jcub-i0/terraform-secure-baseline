#!/usr/bin/env bash

# validate-networking.sh
#
# Validates core networking behavior for a deployed tf-secure-baseline
# environment based on the effective egress mode.
#
# Usage:
#   ./scripts/validation/validate-networking.sh dev
#
# Optional:
#   AWS_PROFILE=tf-secure-baseline-dev AWS_REGION=us-east-1 ./scripts/validation/validate-networking.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-networking.sh dev

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
NAME_PREFIX="${NAME_PREFIX:-tf-secure-baseline-${ENV_NAME:-unknown}}"

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

section "tf-secure-baseline Networking Validation"

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

if ! terraform_output_exists "$OUTPUTS_JSON" effective_egress_mode; then
  fail "Missing required Terraform output: effective_egress_mode"
fi

EFFECTIVE_EGRESS_MODE="$(get_terraform_output_value "$OUTPUTS_JSON" effective_egress_mode)"
require_value_in_list "$EFFECTIVE_EGRESS_MODE" "network_firewall nat_only vpc_endpoints_only" "effective_egress_mode"

success "effective_egress_mode is valid: $EFFECTIVE_EGRESS_MODE"

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
  fail "Unable to resolve VPC ID. Consider exporting NAME_PREFIX or adding a vpc_id Terraform output."
fi

success "Resolved VPC ID: $VPC_ID"

section "Checking NAT Gateways"

NAT_GATEWAYS_JSON="$(
  aws ec2 describe-nat-gateways \
    "${aws_args[@]}" \
    --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available,pending" \
    --output json
)"

NAT_GATEWAY_COUNT="$(echo "$NAT_GATEWAYS_JSON" | jq '.NatGateways | length')"

info "NAT Gateway count: $NAT_GATEWAY_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall|nat_only)
    if [[ "$NAT_GATEWAY_COUNT" -gt 0 ]]; then
      success "NAT Gateway exists as expected for ${EFFECTIVE_EGRESS_MODE}"
    else
      fail "Expected NAT Gateway for ${EFFECTIVE_EGRESS_MODE}, but none were found."
    fi
    ;;
  vpc_endpoints_only)
    if [[ "$NAT_GATEWAY_COUNT" -eq 0 ]]; then
      success "No NAT Gateway found as expected for vpc_endpoints_only"
    else
      fail "Expected no NAT Gateway for vpc_endpoints_only, but found ${NAT_GATEWAY_COUNT}."
    fi
    ;;
esac

section "Checking AWS Network Firewall"

NETWORK_FIREWALLS_JSON="$(
  aws network-firewall list-firewalls \
    "${aws_args[@]}" \
    --output json
)"

MATCHING_FIREWALL_COUNT="$(
  echo "$NETWORK_FIREWALLS_JSON" |
    jq --arg prefix "$NAME_PREFIX" '[.Firewalls[]? | select(.FirewallName | contains($prefix))] | length'
)"

info "Matching Network Firewall count: $MATCHING_FIREWALL_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    if [[ "$MATCHING_FIREWALL_COUNT" -gt 0 ]]; then
      success "Network Firewall exists as expected for network_firewall mode"
    else
      fail "Expected Network Firewall for network_firewall mode, but none were found."
    fi
    ;;
  nat_only|vpc_endpoints_only)
    if [[ "$MATCHING_FIREWALL_COUNT" -eq 0 ]]; then
      success "No Network Firewall found as expected for ${EFFECTIVE_EGRESS_MODE}"
    else
      fail "Expected no Network Firewall for ${EFFECTIVE_EGRESS_MODE}, but found ${MATCHING_FIREWALL_COUNT}."
    fi
    ;;
esac

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

success "Found compute private route tables: $COMPUTE_RT_COUNT"

DEFAULT_ROUTES_JSON="$(
  echo "$COMPUTE_ROUTE_TABLES_JSON" |
    jq '[.RouteTables[] | {
      route_table_id: .RouteTableId,
      name: (.Tags[]? | select(.Key == "Name") | .Value),
      default_routes: [
        .Routes[]?
        | select(.DestinationCidrBlock == "0.0.0.0/0")
        | . + {
            target_id: (.VpcEndpointId // .GatewayId // .NatGatewayId // .TransitGatewayId // .InstanceId // "unknown"),
            target_type: (
              if ((.VpcEndpointId // .GatewayId // "") | startswith("vpce-")) then "vpc_endpoint"
              elif (.NatGatewayId // "") != "" then "nat_gateway"
              elif (.GatewayId // "") != "" then "gateway"
              else "unknown"
              end
            )
          }
      ]
    }]'
)"

DEFAULT_ROUTE_COUNT="$(
  echo "$DEFAULT_ROUTES_JSON" |
    jq '[.[] | .default_routes[]?] | length'
)"

info "Compute private default route count: $DEFAULT_ROUTE_COUNT"

case "$EFFECTIVE_EGRESS_MODE" in
  network_firewall)
    MISSING_DEFAULT_ROUTES="$(
      echo "$DEFAULT_ROUTES_JSON" |
        jq '[.[] | select((.default_routes | length) == 0)] | length'
    )"

    NON_FIREWALL_DEFAULT_ROUTES="$(
      echo "$DEFAULT_ROUTES_JSON" |
        jq '[.[] | .default_routes[]? | select(
          ((.VpcEndpointId // "") | startswith("vpce-") | not) and
          ((.GatewayId // "") | startswith("vpce-") | not)
        )] | length'
    )"

    if [[ "$MISSING_DEFAULT_ROUTES" -eq 0 && "$NON_FIREWALL_DEFAULT_ROUTES" -eq 0 ]]; then
      success "Compute private default routes point to firewall VPC endpoints as expected"
    else
      echo "$DEFAULT_ROUTES_JSON" | jq .
      fail "Expected all compute private default routes to point to firewall VPC endpoints."
    fi
    ;;

  nat_only)
    MISSING_DEFAULT_ROUTES="$(
      echo "$DEFAULT_ROUTES_JSON" |
        jq '[.[] | select((.default_routes | length) == 0)] | length'
    )"

    NON_NAT_DEFAULT_ROUTES="$(
      echo "$DEFAULT_ROUTES_JSON" |
        jq '[.[] | .default_routes[]? | select(.NatGatewayId == null)] | length'
    )"

    if [[ "$MISSING_DEFAULT_ROUTES" -eq 0 && "$NON_NAT_DEFAULT_ROUTES" -eq 0 ]]; then
      success "Compute private default routes point to NAT Gateways as expected"
    else
      echo "$DEFAULT_ROUTES_JSON" | jq .
      fail "Expected all compute private default routes to point to NAT Gateways."
    fi
    ;;

  vpc_endpoints_only)
    if [[ "$DEFAULT_ROUTE_COUNT" -eq 0 ]]; then
      success "No compute private default routes found as expected for vpc_endpoints_only"
    else
      echo "$DEFAULT_ROUTES_JSON" | jq .
      fail "Expected no 0.0.0.0/0 routes in compute private route tables for vpc_endpoints_only."
    fi
    ;;
esac

section "Checking subnet placement basics"

COMPUTE_SUBNETS_JSON="$(
  aws ec2 describe-subnets \
    "${aws_args[@]}" \
    --filters \
      "Name=vpc-id,Values=${VPC_ID}" \
      "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-*" \
    --output json
)"

COMPUTE_SUBNET_COUNT="$(echo "$COMPUTE_SUBNETS_JSON" | jq '.Subnets | length')"

if [[ "$COMPUTE_SUBNET_COUNT" -gt 0 ]]; then
  success "Found compute private subnets: $COMPUTE_SUBNET_COUNT"
else
  fail "No compute private subnets found using tag pattern: ${NAME_PREFIX}-Compute-Private-*"
fi

PUBLIC_IP_MAPPING_COUNT="$(
  echo "$COMPUTE_SUBNETS_JSON" |
    jq '[.Subnets[] | select(.MapPublicIpOnLaunch == true)] | length'
)"

if [[ "$PUBLIC_IP_MAPPING_COUNT" -eq 0 ]]; then
  success "Compute private subnets do not auto-assign public IPs"
else
  fail "One or more compute private subnets have MapPublicIpOnLaunch enabled."
fi

section "Networking Summary"

cat <<SUMMARY
Environment:                ${ENV_NAME}
AWS profile:                ${AWS_PROFILE:-<default>}
AWS region:                 ${AWS_REGION}
Name prefix:                ${NAME_PREFIX}
VPC ID:                     ${VPC_ID}
effective_egress_mode:      ${EFFECTIVE_EGRESS_MODE}

NAT Gateway count:          ${NAT_GATEWAY_COUNT}
Matching Network Firewalls: ${MATCHING_FIREWALL_COUNT}
Compute route tables:       ${COMPUTE_RT_COUNT}
Compute private subnets:    ${COMPUTE_SUBNET_COUNT}
Compute default routes:     ${DEFAULT_ROUTE_COUNT}
SUMMARY

section "Validation Result"

success "Networking validation completed successfully for: ${ENV_NAME}"