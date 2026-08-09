#!/usr/bin/env bash

# validate-security-operations.sh
#
# Validates centralized security governance for tf-secure-baseline from the
# security-operations delegated administrator account.
#
# Checks:
# - security_operations/security_services Terraform outputs and applied state
# - AWS caller identity matches the security-operations account
# - AWS Organizations structure and workload account placement
# - trusted service access and delegated-administrator registration
# - Security Hub CSPM administrator state, finding aggregation, CENTRAL
#   organization configuration, configuration policies, and associations
# - GuardDuty administrator detector, organization enrollment, protection plans,
#   and Runtime Monitoring additional configuration
# - Security Hub V2 administrator state, SECURITYHUB_POLICY attachment, and
#   effective workload policies
#
# Usage:
#   AWS_PROFILE=security-operations ./scripts/validation/validate-security-operations.sh
#
# Optional:
#   AWS_PROFILE=security-operations AWS_REGION=us-east-1 \
#     ./scripts/validation/validate-security-operations.sh
#
# Optional organization naming overrides:
#   SECURITY_OPERATIONS_ACCOUNT_NAME=security-operations
#   WORKLOADS_OU_NAME=Workloads
#   NONPROD_OU_NAME=NonProd
#   PROD_OU_NAME=Prod
#   SECURITY_OU_NAME=Security
#   NONPROD_ACCOUNT_NAMES="dev staging"
#   PROD_ACCOUNT_NAMES="prod"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"

SECURITY_OPERATIONS_ACCOUNT_NAME="${SECURITY_OPERATIONS_ACCOUNT_NAME:-security-operations}"
WORKLOADS_OU_NAME="${WORKLOADS_OU_NAME:-Workloads}"
NONPROD_OU_NAME="${NONPROD_OU_NAME:-NonProd}"
PROD_OU_NAME="${PROD_OU_NAME:-Prod}"
SECURITY_OU_NAME="${SECURITY_OU_NAME:-Security}"
NONPROD_ACCOUNT_NAMES="${NONPROD_ACCOUNT_NAMES:-dev staging}"
PROD_ACCOUNT_NAMES="${PROD_ACCOUNT_NAMES:-prod}"

read -r -a NONPROD_ACCOUNTS <<< "$NONPROD_ACCOUNT_NAMES"
read -r -a PROD_ACCOUNTS <<< "$PROD_ACCOUNT_NAMES"
WORKLOAD_ACCOUNTS=("${NONPROD_ACCOUNTS[@]}" "${PROD_ACCOUNTS[@]}")

export AWS_PAGER=""

aws_profile_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_profile_args+=(--profile "$AWS_PROFILE")
fi

aws_region_args=("${aws_profile_args[@]}" --region "$AWS_REGION")

section "${CLOUD_NAME} Security Operations Validation"

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command terraform
success "terraform found"

require_command jq
success "jq found"

require_command git
success "git found"

section "Resolving repository paths and Terraform state"

REPO_ROOT="$(get_repo_root)"
SECURITY_SERVICES_DIR="${REPO_ROOT}/bootstrap/security_operations/security_services"

info "Repository root: $REPO_ROOT"
info "Security services dir: $SECURITY_SERVICES_DIR"
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: $AWS_REGION"

require_directory "$SECURITY_SERVICES_DIR"
success "Security services directory exists"

OUTPUTS_JSON="$(terraform_output_json "$SECURITY_SERVICES_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${SECURITY_SERVICES_DIR}. Has the stack been applied?"
fi

success "Security services Terraform outputs are readable"

STATE_JSON="$(
  terraform -chdir="$SECURITY_SERVICES_DIR" show -json 2>/dev/null
)"

if [[ -z "$STATE_JSON" || "$STATE_JSON" == "null" ]]; then
  fail "Unable to read applied Terraform state for ${SECURITY_SERVICES_DIR}."
fi

if ! echo "$STATE_JSON" | jq -e '.values.root_module' >/dev/null; then
  fail "Terraform state JSON does not contain root module values."
fi

success "Security services Terraform state is readable"

REQUIRED_OUTPUTS=(
  security_operations_account_id
  securityhub_home_region
  central_security_features_enabled
  securityhub_finding_aggregator_arn
  securityhub_cspm_configuration_policy_ids
  securityhub_cspm_policy_association_target_ids
  guardduty_detector_id
  securityhub_v2_organization_policy_id
)

for output_name in "${REQUIRED_OUTPUTS[@]}"; do
  if terraform_output_exists "$OUTPUTS_JSON" "$output_name"; then
    success "Required output exists: $output_name"
  else
    fail "Missing required Terraform output: $output_name"
  fi
done

EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID="$(
  get_terraform_output_value "$OUTPUTS_JSON" security_operations_account_id
)"

SECURITYHUB_HOME_REGION="$(
  get_terraform_output_value "$OUTPUTS_JSON" securityhub_home_region
)"

SECURITYHUB_FINDING_AGGREGATOR_ARN="$(
  get_terraform_output_value "$OUTPUTS_JSON" securityhub_finding_aggregator_arn
)"

GUARDDUTY_DETECTOR_ID="$(
  get_terraform_output_value "$OUTPUTS_JSON" guardduty_detector_id
)"

SECURITYHUB_V2_ORGANIZATION_POLICY_ID="$(
  echo "$OUTPUTS_JSON" |
    jq -r '.securityhub_v2_organization_policy_id.value // empty'
)"

CENTRAL_SECURITY_FEATURES_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.central_security_features_enabled.value // {}'
)"

SECURITYHUB_CSPM_ENABLED="$(
  echo "$CENTRAL_SECURITY_FEATURES_JSON" |
    jq -r '.securityhub_cspm // false'
)"

GUARDDUTY_ORGANIZATION_ENABLED="$(
  echo "$CENTRAL_SECURITY_FEATURES_JSON" |
    jq -r '.guardduty // false'
)"

SECURITYHUB_V2_POLICY_ENABLED="$(
  echo "$CENTRAL_SECURITY_FEATURES_JSON" |
    jq -r '.securityhub_v2 // false'
)"

require_value_in_list "$SECURITYHUB_CSPM_ENABLED" "true false" "central_security_features_enabled.securityhub_cspm"
require_value_in_list "$GUARDDUTY_ORGANIZATION_ENABLED" "true false" "central_security_features_enabled.guardduty"
require_value_in_list "$SECURITYHUB_V2_POLICY_ENABLED" "true false" "central_security_features_enabled.securityhub_v2"

if [[ "$SECURITYHUB_HOME_REGION" != "$AWS_REGION" ]]; then
  fail "AWS_REGION (${AWS_REGION}) does not match the Security Hub home Region from Terraform (${SECURITYHUB_HOME_REGION})."
fi

success "AWS_REGION matches the Terraform Security Hub home Region"

CSPM_POLICY_IDS_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.securityhub_cspm_configuration_policy_ids.value // {}'
)"

CSPM_ASSOCIATION_TARGET_IDS_JSON="$(
  echo "$OUTPUTS_JSON" |
    jq -c '.securityhub_cspm_policy_association_target_ids.value // {}'
)"

if ! echo "$CSPM_POLICY_IDS_JSON" | jq -e 'type == "object"' >/dev/null; then
  fail "securityhub_cspm_configuration_policy_ids is not a map/object."
fi

if ! echo "$CSPM_ASSOCIATION_TARGET_IDS_JSON" | jq -e 'type == "object"' >/dev/null; then
  fail "securityhub_cspm_policy_association_target_ids is not a map/object."
fi

EXPECTED_GUARDDUTY_ORG_JSON="$(
  echo "$STATE_JSON" |
    jq -c '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_guardduty_organization_configuration"
          )
        | .values
      ][0] // {}
    '
)"

EXPECTED_GUARDDUTY_FEATURES_JSON="$(
  echo "$STATE_JSON" |
    jq -c '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_guardduty_organization_configuration_feature"
          )
        | {
            name: .values.name,
            auto_enable: .values.auto_enable,
            additional_configuration: (.values.additional_configuration // [])
          }
      ]
    '
)"

EXPECTED_SECURITYHUB_ORG_JSON="$(
  echo "$STATE_JSON" |
    jq -c '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_securityhub_organization_configuration"
          )
        | .values
      ][0] // {}
    '
)"

EXPECTED_FINDING_AGGREGATOR_JSON="$(
  echo "$STATE_JSON" |
    jq -c '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_securityhub_finding_aggregator"
          )
        | .values
      ][0] // {}
    '
)"

EXPECTED_CSPM_POLICIES_JSON="$(
  echo "$STATE_JSON" |
    jq -c '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_securityhub_configuration_policy"
          )
        | {
            account_name: (.index | tostring),
            id: .values.id,
            name: .values.name,
            service_enabled: (.values.configuration_policy[0].service_enabled // false),
            enabled_standard_arns: (.values.configuration_policy[0].enabled_standard_arns // []),
            disabled_control_identifiers: (
              .values.configuration_policy[0].security_controls_configuration[0].disabled_control_identifiers // []
            )
          }
      ]
    '
)"

EXPECTED_V2_POLICY_CONTENT="$(
  echo "$STATE_JSON" |
    jq -r '
      [
        .values.root_module.resources[]?
        | select(
            .mode == "managed"
            and .type == "aws_organizations_policy"
            and .values.type == "SECURITYHUB_POLICY"
          )
        | .values.content
      ][0] // empty
    '
)"

section "Checking AWS caller identity"

CALLER_ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$CALLER_ACCOUNT_ID" || "$CALLER_ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID."
fi

if [[ "$CALLER_ACCOUNT_ID" != "$EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID" ]]; then
  fail "AWS account mismatch. Terraform expects security-operations account ${EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID}, but current credentials belong to ${CALLER_ACCOUNT_ID}."
fi

success "AWS credentials belong to the Terraform security-operations account"
info "AWS account ID: $CALLER_ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

section "Checking AWS Organizations"

ORGANIZATION_JSON="$(
  aws organizations describe-organization \
    "${aws_profile_args[@]}" \
    --output json
)"

ORGANIZATION_ID="$(
  echo "$ORGANIZATION_JSON" |
    jq -r '.Organization.Id // empty'
)"

ORGANIZATION_FEATURE_SET="$(
  echo "$ORGANIZATION_JSON" |
    jq -r '.Organization.FeatureSet // empty'
)"

if [[ -z "$ORGANIZATION_ID" ]]; then
  fail "Unable to resolve AWS Organizations organization ID."
fi

if [[ "$ORGANIZATION_FEATURE_SET" != "ALL" ]]; then
  fail "AWS Organizations FeatureSet must be ALL. Current value: ${ORGANIZATION_FEATURE_SET:-<empty>}"
fi

success "AWS Organizations all-features mode is enabled"
info "Organization ID: $ORGANIZATION_ID"

ROOTS_JSON="$(
  aws organizations list-roots \
    "${aws_profile_args[@]}" \
    --output json
)"

ROOT_COUNT="$(
  echo "$ROOTS_JSON" |
    jq '.Roots | length'
)"

if [[ "$ROOT_COUNT" -ne 1 ]]; then
  fail "Expected exactly one AWS Organizations root, found ${ROOT_COUNT}."
fi

ROOT_ID="$(
  echo "$ROOTS_JSON" |
    jq -r '.Roots[0].Id'
)"

success "AWS Organizations root resolved: $ROOT_ID"

if [[ "$SECURITYHUB_V2_POLICY_ENABLED" == "true" ]]; then
  SECURITYHUB_POLICY_TYPE_STATUS="$(
    echo "$ROOTS_JSON" |
      jq -r '
        [
          .Roots[0].PolicyTypes[]?
          | select(.Type == "SECURITYHUB_POLICY")
          | .Status
        ][0] // "NOT_ENABLED"
      '
  )"

  if [[ "$SECURITYHUB_POLICY_TYPE_STATUS" != "ENABLED" ]]; then
    fail "SECURITYHUB_POLICY must be enabled on the organization root. Current status: ${SECURITYHUB_POLICY_TYPE_STATUS}"
  fi

  success "SECURITYHUB_POLICY is enabled on the organization root"
else
  warn "central_security_features_enabled.securityhub_v2=false. Skipping SECURITYHUB_POLICY enablement requirement."
fi

resolve_unique_ou_id() {
  local parent_id="$1"
  local ou_name="$2"
  local json=""
  local count="0"

  json="$(
    aws organizations list-organizational-units-for-parent \
      "${aws_profile_args[@]}" \
      --parent-id "$parent_id" \
      --output json
  )"

  count="$(
    echo "$json" |
      jq --arg name "$ou_name" '[.OrganizationalUnits[]? | select(.Name == $name)] | length'
  )"

  if [[ "$count" -ne 1 ]]; then
    fail "Expected exactly one OU named '${ou_name}' under parent ${parent_id}; found ${count}."
  fi

  echo "$json" |
    jq -r --arg name "$ou_name" '.OrganizationalUnits[] | select(.Name == $name) | .Id'
}

WORKLOADS_OU_ID="$(resolve_unique_ou_id "$ROOT_ID" "$WORKLOADS_OU_NAME")"
SECURITY_OU_ID="$(resolve_unique_ou_id "$ROOT_ID" "$SECURITY_OU_NAME")"
NONPROD_OU_ID="$(resolve_unique_ou_id "$WORKLOADS_OU_ID" "$NONPROD_OU_NAME")"
PROD_OU_ID="$(resolve_unique_ou_id "$WORKLOADS_OU_ID" "$PROD_OU_NAME")"

success "OU hierarchy resolved"
info "${WORKLOADS_OU_NAME}: ${WORKLOADS_OU_ID}"
info "${NONPROD_OU_NAME}: ${NONPROD_OU_ID}"
info "${PROD_OU_NAME}: ${PROD_OU_ID}"
info "${SECURITY_OU_NAME}: ${SECURITY_OU_ID}"

ORGANIZATION_ACCOUNTS_JSON="$(
  aws organizations list-accounts \
    "${aws_profile_args[@]}" \
    --output json
)"

resolve_active_account_id() {
  local account_name="$1"
  local count="0"

  count="$(
    echo "$ORGANIZATION_ACCOUNTS_JSON" |
      jq --arg name "$account_name" '
        [
          .Accounts[]?
          | select(
              .Name == $name
              and (.State // .Status) == "ACTIVE"
            )
        ]
        | length
      '
  )"

  if [[ "$count" -ne 1 ]]; then
    fail "Expected exactly one active Organizations account named '${account_name}'; found ${count}."
  fi

  echo "$ORGANIZATION_ACCOUNTS_JSON" |
    jq -r --arg name "$account_name" '
      .Accounts[]
      | select(
          .Name == $name
          and (.State // .Status) == "ACTIVE"
        )
      | .Id
    '
}

validate_account_parent() {
  local account_name="$1"
  local account_id="$2"
  local expected_parent_id="$3"
  local parents_json=""
  local actual_parent_id=""

  parents_json="$(
    aws organizations list-parents \
      "${aws_profile_args[@]}" \
      --child-id "$account_id" \
      --output json
  )"

  actual_parent_id="$(
    echo "$parents_json" |
      jq -r '.Parents[0].Id // empty'
  )"

  if [[ "$actual_parent_id" != "$expected_parent_id" ]]; then
    fail "Account '${account_name}' (${account_id}) is under ${actual_parent_id:-<unknown>}; expected ${expected_parent_id}."
  fi

  success "Account '${account_name}' is in the expected OU"
}

SECURITY_OPERATIONS_ORG_ACCOUNT_ID="$(
  resolve_active_account_id "$SECURITY_OPERATIONS_ACCOUNT_NAME"
)"

if [[ "$SECURITY_OPERATIONS_ORG_ACCOUNT_ID" != "$EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID" ]]; then
  fail "Organizations account '${SECURITY_OPERATIONS_ACCOUNT_NAME}' resolves to ${SECURITY_OPERATIONS_ORG_ACCOUNT_ID}, but Terraform expects ${EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID}."
fi

validate_account_parent \
  "$SECURITY_OPERATIONS_ACCOUNT_NAME" \
  "$SECURITY_OPERATIONS_ORG_ACCOUNT_ID" \
  "$SECURITY_OU_ID"

declare -A WORKLOAD_ACCOUNT_IDS=()

for account_name in "${NONPROD_ACCOUNTS[@]}"; do
  [[ -z "$account_name" ]] && continue

  account_id="$(resolve_active_account_id "$account_name")"
  WORKLOAD_ACCOUNT_IDS["$account_name"]="$account_id"

  validate_account_parent \
    "$account_name" \
    "$account_id" \
    "$NONPROD_OU_ID"
done

for account_name in "${PROD_ACCOUNTS[@]}"; do
  [[ -z "$account_name" ]] && continue

  account_id="$(resolve_active_account_id "$account_name")"
  WORKLOAD_ACCOUNT_IDS["$account_name"]="$account_id"

  validate_account_parent \
    "$account_name" \
    "$account_id" \
    "$PROD_OU_ID"
done

section "Checking Organizations security-service integration"

AWS_SERVICE_ACCESS_JSON="$(
  aws organizations list-aws-service-access-for-organization \
    "${aws_profile_args[@]}" \
    --output json
)"

require_trusted_service_access() {
  local service_principal="$1"
  local label="$2"

  if echo "$AWS_SERVICE_ACCESS_JSON" |
    jq -e --arg principal "$service_principal" '
      any(.EnabledServicePrincipals[]?; .ServicePrincipal == $principal)
    ' >/dev/null; then
    success "${label} trusted service access is enabled"
  else
    fail "${label} trusted service access is not enabled (${service_principal})."
  fi
}

require_trusted_service_access \
  "securityhub.amazonaws.com" \
  "Security Hub"

require_trusted_service_access \
  "guardduty.amazonaws.com" \
  "GuardDuty"

if echo "$EXPECTED_GUARDDUTY_FEATURES_JSON" |
  jq -e 'any(.[]; .name == "EBS_MALWARE_PROTECTION")' >/dev/null; then
  require_trusted_service_access \
    "malware-protection.guardduty.amazonaws.com" \
    "GuardDuty malware protection"
fi

validate_delegated_administrator() {
  local service_principal="$1"
  local label="$2"
  local json=""
  local matching_count="0"

  json="$(
    aws organizations list-delegated-administrators \
      "${aws_profile_args[@]}" \
      --service-principal "$service_principal" \
      --output json
  )"

  matching_count="$(
    echo "$json" |
      jq --arg account_id "$EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID" '
        [
          .DelegatedAdministrators[]?
          | select(
              .Id == $account_id
              and (.State // .Status) == "ACTIVE"
            )
        ]
        | length
      '
  )"

  if [[ "$matching_count" -ne 1 ]]; then
    echo "$json" | jq .
    fail "${label} delegated administrator is not the expected security-operations account."
  fi

  success "${label} delegated administrator is the security-operations account"
}

validate_delegated_administrator \
  "securityhub.amazonaws.com" \
  "Security Hub"

validate_delegated_administrator \
  "guardduty.amazonaws.com" \
  "GuardDuty"

section "Checking Security Hub CSPM administrator state"

SECURITY_HUB_JSON="$(
  aws securityhub describe-hub \
    "${aws_region_args[@]}" \
    --output json
)"

SECURITY_HUB_ARN="$(
  echo "$SECURITY_HUB_JSON" |
    jq -r '.HubArn // empty'
)"

if [[ -z "$SECURITY_HUB_ARN" ]]; then
  echo "$SECURITY_HUB_JSON" | jq .
  fail "Security Hub CSPM is not enabled in the security-operations account."
fi

success "Security Hub CSPM is enabled"
info "Security Hub ARN: $SECURITY_HUB_ARN"

FINDING_AGGREGATOR_JSON="$(
  aws securityhub get-finding-aggregator \
    "${aws_region_args[@]}" \
    --finding-aggregator-arn "$SECURITYHUB_FINDING_AGGREGATOR_ARN" \
    --output json
)"

ACTUAL_FINDING_AGGREGATOR_ARN="$(
  echo "$FINDING_AGGREGATOR_JSON" |
    jq -r '.FindingAggregatorArn // empty'
)"

ACTUAL_FINDING_HOME_REGION="$(
  echo "$FINDING_AGGREGATOR_JSON" |
    jq -r '.FindingAggregationRegion // empty'
)"

ACTUAL_FINDING_LINKING_MODE="$(
  echo "$FINDING_AGGREGATOR_JSON" |
    jq -r '.RegionLinkingMode // empty'
)"

EXPECTED_FINDING_LINKING_MODE="$(
  echo "$EXPECTED_FINDING_AGGREGATOR_JSON" |
    jq -r '.linking_mode // "NO_REGIONS"'
)"

if [[ "$ACTUAL_FINDING_AGGREGATOR_ARN" != "$SECURITYHUB_FINDING_AGGREGATOR_ARN" ]]; then
  fail "Security Hub finding aggregator ARN does not match Terraform output."
fi

if [[ "$ACTUAL_FINDING_HOME_REGION" != "$SECURITYHUB_HOME_REGION" ]]; then
  fail "Security Hub finding aggregator home Region is ${ACTUAL_FINDING_HOME_REGION}; expected ${SECURITYHUB_HOME_REGION}."
fi

if [[ "$ACTUAL_FINDING_LINKING_MODE" != "$EXPECTED_FINDING_LINKING_MODE" ]]; then
  fail "Security Hub finding aggregator linking mode is ${ACTUAL_FINDING_LINKING_MODE}; expected ${EXPECTED_FINDING_LINKING_MODE}."
fi

success "Security Hub finding aggregator matches Terraform state"

CSPM_POLICY_COUNT="$(
  echo "$CSPM_POLICY_IDS_JSON" |
    jq 'length'
)"

CSPM_ASSOCIATION_COUNT="$(
  echo "$CSPM_ASSOCIATION_TARGET_IDS_JSON" |
    jq 'length'
)"

if [[ "$SECURITYHUB_CSPM_ENABLED" == "true" ]]; then
  SECURITY_HUB_ORG_JSON="$(
    aws securityhub describe-organization-configuration \
      "${aws_region_args[@]}" \
      --output json
  )"

  ACTUAL_CSPM_CONFIGURATION_TYPE="$(
    echo "$SECURITY_HUB_ORG_JSON" |
      jq -r '.OrganizationConfiguration.ConfigurationType // empty'
  )"

  ACTUAL_CSPM_CONFIGURATION_STATUS="$(
    echo "$SECURITY_HUB_ORG_JSON" |
      jq -r '.OrganizationConfiguration.Status // empty'
  )"

  ACTUAL_CSPM_AUTO_ENABLE="$(
    echo "$SECURITY_HUB_ORG_JSON" |
      jq -r '.AutoEnable | tostring'
  )"

  ACTUAL_CSPM_AUTO_ENABLE_STANDARDS="$(
    echo "$SECURITY_HUB_ORG_JSON" |
      jq -r '.AutoEnableStandards // empty'
  )"

  EXPECTED_CSPM_CONFIGURATION_TYPE="$(
    echo "$EXPECTED_SECURITYHUB_ORG_JSON" |
      jq -r '.organization_configuration[0].configuration_type // "CENTRAL"'
  )"

  EXPECTED_CSPM_AUTO_ENABLE="$(
    echo "$EXPECTED_SECURITYHUB_ORG_JSON" |
      jq -r '(.auto_enable // false) | tostring'
  )"

  EXPECTED_CSPM_AUTO_ENABLE_STANDARDS="$(
    echo "$EXPECTED_SECURITYHUB_ORG_JSON" |
      jq -r '.auto_enable_standards // "NONE"'
  )"

  if [[ "$ACTUAL_CSPM_CONFIGURATION_TYPE" != "$EXPECTED_CSPM_CONFIGURATION_TYPE" ]]; then
    fail "Security Hub CSPM organization configuration type is ${ACTUAL_CSPM_CONFIGURATION_TYPE}; expected ${EXPECTED_CSPM_CONFIGURATION_TYPE}."
  fi

  if [[ "$ACTUAL_CSPM_CONFIGURATION_STATUS" != "ENABLED" ]]; then
    echo "$SECURITY_HUB_ORG_JSON" | jq .
    fail "Security Hub CSPM central configuration is not enabled. Current status: ${ACTUAL_CSPM_CONFIGURATION_STATUS}"
  fi

  if [[ "$ACTUAL_CSPM_AUTO_ENABLE" != "$EXPECTED_CSPM_AUTO_ENABLE" ]]; then
    fail "Security Hub CSPM AutoEnable is ${ACTUAL_CSPM_AUTO_ENABLE}; expected ${EXPECTED_CSPM_AUTO_ENABLE}."
  fi

  if [[ "$ACTUAL_CSPM_AUTO_ENABLE_STANDARDS" != "$EXPECTED_CSPM_AUTO_ENABLE_STANDARDS" ]]; then
    fail "Security Hub CSPM AutoEnableStandards is ${ACTUAL_CSPM_AUTO_ENABLE_STANDARDS}; expected ${EXPECTED_CSPM_AUTO_ENABLE_STANDARDS}."
  fi

  success "Security Hub CSPM CENTRAL organization configuration matches Terraform state"

  while IFS= read -r account_name; do
    [[ -z "$account_name" ]] && continue

    policy_id="$(
      echo "$CSPM_POLICY_IDS_JSON" |
        jq -r --arg account_name "$account_name" '.[$account_name]'
    )"

    expected_policy_json="$(
      echo "$EXPECTED_CSPM_POLICIES_JSON" |
        jq -c --arg account_name "$account_name" '
          [
            .[]
            | select(.account_name == $account_name)
          ][0] // {}
        '
    )"

    if [[ "$expected_policy_json" == "{}" ]]; then
      fail "Terraform state does not contain the expected CSPM configuration policy for '${account_name}'."
    fi

    policy_json="$(
      aws securityhub get-configuration-policy \
        "${aws_region_args[@]}" \
        --identifier "$policy_id" \
        --output json
    )"

    actual_policy_id="$(
      echo "$policy_json" |
        jq -r '.Id // empty'
    )"

    actual_policy_name="$(
      echo "$policy_json" |
        jq -r '.Name // empty'
    )"

    actual_service_enabled="$(
      echo "$policy_json" |
        jq -r '(.ConfigurationPolicy.SecurityHub.ServiceEnabled // false) | tostring'
    )"

    expected_policy_name="$(
      echo "$expected_policy_json" |
        jq -r '.name'
    )"

    expected_service_enabled="$(
      echo "$expected_policy_json" |
        jq -r '.service_enabled | tostring'
    )"

    actual_standard_arns="$(
      echo "$policy_json" |
        jq -c '.ConfigurationPolicy.SecurityHub.EnabledStandardIdentifiers // [] | sort'
    )"

    expected_standard_arns="$(
      echo "$expected_policy_json" |
        jq -c '.enabled_standard_arns // [] | sort'
    )"

    actual_disabled_controls="$(
      echo "$policy_json" |
        jq -c '.ConfigurationPolicy.SecurityHub.SecurityControlsConfiguration.DisabledSecurityControlIdentifiers // [] | sort'
    )"

    expected_disabled_controls="$(
      echo "$expected_policy_json" |
        jq -c '.disabled_control_identifiers // [] | sort'
    )"

    if [[ "$actual_policy_id" != "$policy_id" ]]; then
      fail "Security Hub CSPM policy '${account_name}' ID does not match Terraform output."
    fi

    if [[ "$actual_policy_name" != "$expected_policy_name" ]]; then
      fail "Security Hub CSPM policy '${account_name}' name is '${actual_policy_name}'; expected '${expected_policy_name}'."
    fi

    if [[ "$actual_service_enabled" != "$expected_service_enabled" ]]; then
      fail "Security Hub CSPM policy '${account_name}' ServiceEnabled=${actual_service_enabled}; expected ${expected_service_enabled}."
    fi

    if [[ "$actual_standard_arns" != "$expected_standard_arns" ]]; then
      echo "Expected standards: $expected_standard_arns"
      echo "Actual standards:   $actual_standard_arns"
      fail "Security Hub CSPM policy '${account_name}' enabled standards do not match Terraform state."
    fi

    if [[ "$actual_disabled_controls" != "$expected_disabled_controls" ]]; then
      echo "Expected disabled controls: $expected_disabled_controls"
      echo "Actual disabled controls:   $actual_disabled_controls"
      fail "Security Hub CSPM policy '${account_name}' disabled controls do not match Terraform state."
    fi

    success "Security Hub CSPM policy '${account_name}' matches Terraform state"
  done < <(echo "$CSPM_POLICY_IDS_JSON" | jq -r 'keys[]')

  while IFS= read -r account_name; do
    [[ -z "$account_name" ]] && continue

    target_account_id="$(
      echo "$CSPM_ASSOCIATION_TARGET_IDS_JSON" |
        jq -r --arg account_name "$account_name" '.[$account_name]'
    )"

    policy_id="$(
      echo "$CSPM_POLICY_IDS_JSON" |
        jq -r --arg account_name "$account_name" '.[$account_name] // empty'
    )"

    if [[ -z "$policy_id" ]]; then
      fail "CSPM association '${account_name}' has no corresponding Terraform policy ID."
    fi

    organization_account_id="$(resolve_active_account_id "$account_name")"

    if [[ "$target_account_id" != "$organization_account_id" ]]; then
      fail "CSPM association target for '${account_name}' is ${target_account_id}; Organizations resolves the account to ${organization_account_id}."
    fi

    association_json="$(
      aws securityhub get-configuration-policy-association \
        "${aws_region_args[@]}" \
        --target "AccountId=${target_account_id}" \
        --output json
    )"

    actual_association_policy_id="$(
      echo "$association_json" |
        jq -r '.ConfigurationPolicyId // empty'
    )"

    actual_association_target_id="$(
      echo "$association_json" |
        jq -r '.TargetId // empty'
    )"

    actual_association_target_type="$(
      echo "$association_json" |
        jq -r '.TargetType // empty'
    )"

    actual_association_type="$(
      echo "$association_json" |
        jq -r '.AssociationType // empty'
    )"

    actual_association_status="$(
      echo "$association_json" |
        jq -r '.AssociationStatus // empty'
    )"

    if [[ "$actual_association_policy_id" != "$policy_id" ]]; then
      fail "CSPM association '${account_name}' references policy ${actual_association_policy_id}; expected ${policy_id}."
    fi

    if [[ "$actual_association_target_id" != "$target_account_id" ]]; then
      fail "CSPM association '${account_name}' target ID does not match Terraform output."
    fi

    if [[ "$actual_association_target_type" != "ACCOUNT" ]]; then
      fail "CSPM association '${account_name}' target type is ${actual_association_target_type}; expected ACCOUNT."
    fi

    if [[ "$actual_association_type" != "APPLIED" ]]; then
      fail "CSPM association '${account_name}' association type is ${actual_association_type}; expected APPLIED."
    fi

    if [[ "$actual_association_status" != "SUCCESS" ]]; then
      echo "$association_json" | jq .
      fail "CSPM association '${account_name}' status is ${actual_association_status}; expected SUCCESS."
    fi

    success "Security Hub CSPM policy association '${account_name}' is applied successfully"
  done < <(echo "$CSPM_ASSOCIATION_TARGET_IDS_JSON" | jq -r 'keys[]')
else
  warn "central_security_features_enabled.securityhub_cspm=false. Skipping central CSPM organization-policy validation."
fi

section "Checking GuardDuty centralized administration"

GUARDDUTY_DETECTORS_JSON="$(
  aws guardduty list-detectors \
    "${aws_region_args[@]}" \
    --output json
)"

if ! echo "$GUARDDUTY_DETECTORS_JSON" |
  jq -e --arg detector_id "$GUARDDUTY_DETECTOR_ID" '
    any(.DetectorIds[]?; . == $detector_id)
  ' >/dev/null; then
  echo "$GUARDDUTY_DETECTORS_JSON" | jq .
  fail "Terraform GuardDuty detector ID was not found in the security-operations account."
fi

GUARDDUTY_DETECTOR_JSON="$(
  aws guardduty get-detector \
    "${aws_region_args[@]}" \
    --detector-id "$GUARDDUTY_DETECTOR_ID" \
    --output json
)"

GUARDDUTY_STATUS="$(
  echo "$GUARDDUTY_DETECTOR_JSON" |
    jq -r '.Status // empty'
)"

if [[ "$GUARDDUTY_STATUS" != "ENABLED" ]]; then
  echo "$GUARDDUTY_DETECTOR_JSON" | jq .
  fail "GuardDuty administrator detector is not enabled. Current status: ${GUARDDUTY_STATUS}"
fi

success "GuardDuty administrator detector exists and is enabled"

GUARDDUTY_FEATURE_COUNT="$(
  echo "$EXPECTED_GUARDDUTY_FEATURES_JSON" |
    jq 'length'
)"

if [[ "$GUARDDUTY_ORGANIZATION_ENABLED" == "true" ]]; then
  if [[ "$EXPECTED_GUARDDUTY_ORG_JSON" == "{}" ]]; then
    fail "GuardDuty organization configuration is enabled in Terraform outputs, but no managed organization configuration exists in Terraform state."
  fi

  GUARDDUTY_ORG_JSON="$(
    aws guardduty describe-organization-configuration \
      "${aws_region_args[@]}" \
      --detector-id "$GUARDDUTY_DETECTOR_ID" \
      --output json
  )"

  ACTUAL_GUARDDUTY_MEMBER_MODE="$(
    echo "$GUARDDUTY_ORG_JSON" |
      jq -r '.AutoEnableOrganizationMembers // empty'
  )"

  EXPECTED_GUARDDUTY_MEMBER_MODE="$(
    echo "$EXPECTED_GUARDDUTY_ORG_JSON" |
      jq -r '.auto_enable_organization_members // empty'
  )"

  if [[ "$ACTUAL_GUARDDUTY_MEMBER_MODE" != "$EXPECTED_GUARDDUTY_MEMBER_MODE" ]]; then
    fail "GuardDuty organization member auto-enrollment is ${ACTUAL_GUARDDUTY_MEMBER_MODE}; expected ${EXPECTED_GUARDDUTY_MEMBER_MODE}."
  fi

  success "GuardDuty organization member auto-enrollment matches Terraform state"

  while IFS= read -r feature_json; do
    [[ -z "$feature_json" ]] && continue

    feature_name="$(
      echo "$feature_json" |
        jq -r '.name'
    )"

    expected_auto_enable="$(
      echo "$feature_json" |
        jq -r '.auto_enable'
    )"

    actual_feature_json="$(
      echo "$GUARDDUTY_ORG_JSON" |
        jq -c --arg feature_name "$feature_name" '
          [
            .Features[]?
            | select(.Name == $feature_name)
          ][0] // {}
        '
    )"

    if [[ "$actual_feature_json" == "{}" ]]; then
      fail "GuardDuty organization feature '${feature_name}' is missing."
    fi

    actual_auto_enable="$(
      echo "$actual_feature_json" |
        jq -r '.AutoEnable // empty'
    )"

    if [[ "$actual_auto_enable" != "$expected_auto_enable" ]]; then
      fail "GuardDuty feature '${feature_name}' AutoEnable=${actual_auto_enable}; expected ${expected_auto_enable}."
    fi

    while IFS= read -r additional_json; do
      [[ -z "$additional_json" ]] && continue

      additional_name="$(
        echo "$additional_json" |
          jq -r '.name'
      )"

      expected_additional_auto_enable="$(
        echo "$additional_json" |
          jq -r '.auto_enable'
      )"

      actual_additional_auto_enable="$(
        echo "$actual_feature_json" |
          jq -r --arg additional_name "$additional_name" '
            [
              .AdditionalConfiguration[]?
              | select(.Name == $additional_name)
              | .AutoEnable
            ][0] // empty
          '
      )"

      if [[ -z "$actual_additional_auto_enable" ]]; then
        echo "$actual_feature_json" | jq .
        fail "GuardDuty feature '${feature_name}' additional configuration '${additional_name}' is missing."
      fi

      if [[ "$actual_additional_auto_enable" != "$expected_additional_auto_enable" ]]; then
        fail "GuardDuty '${feature_name}/${additional_name}' AutoEnable=${actual_additional_auto_enable}; expected ${expected_additional_auto_enable}."
      fi

      success "GuardDuty '${feature_name}/${additional_name}' matches Terraform state"
    done < <(echo "$feature_json" | jq -c '.additional_configuration[]?')

    success "GuardDuty organization feature '${feature_name}' matches Terraform state"
  done < <(echo "$EXPECTED_GUARDDUTY_FEATURES_JSON" | jq -c '.[]')
else
  warn "central_security_features_enabled.guardduty=false. Skipping GuardDuty organization configuration validation."
fi

section "Checking Security Hub V2 centralized governance"

SECURITY_HUB_V2_JSON="$(
  aws securityhub describe-security-hub-v2 \
    "${aws_region_args[@]}" \
    --output json
)"

SECURITY_HUB_V2_ARN="$(
  echo "$SECURITY_HUB_V2_JSON" |
    jq -r '.HubV2Arn // empty'
)"

if [[ -z "$SECURITY_HUB_V2_ARN" ]]; then
  echo "$SECURITY_HUB_V2_JSON" | jq .
  fail "Security Hub V2 is not enabled in the security-operations account."
fi

success "Security Hub V2 is enabled in the security-operations account"
info "Security Hub V2 ARN: $SECURITY_HUB_V2_ARN"

if [[ "$SECURITYHUB_V2_POLICY_ENABLED" == "true" ]]; then
  if [[ -z "$SECURITYHUB_V2_ORGANIZATION_POLICY_ID" ]]; then
    fail "Security Hub V2 organization policy is enabled, but Terraform output securityhub_v2_organization_policy_id is null."
  fi

  SECURITYHUB_POLICIES_JSON="$(
    aws organizations list-policies \
      "${aws_profile_args[@]}" \
      --filter SECURITYHUB_POLICY \
      --output json
  )"

  if ! echo "$SECURITYHUB_POLICIES_JSON" |
    jq -e --arg policy_id "$SECURITYHUB_V2_ORGANIZATION_POLICY_ID" '
      any(.Policies[]?; .Id == $policy_id)
    ' >/dev/null; then
    echo "$SECURITYHUB_POLICIES_JSON" | jq .
    fail "Terraform Security Hub V2 organization policy ID was not found in AWS Organizations."
  fi

  V2_POLICY_JSON="$(
    aws organizations describe-policy \
      "${aws_profile_args[@]}" \
      --policy-id "$SECURITYHUB_V2_ORGANIZATION_POLICY_ID" \
      --output json
  )"

  ACTUAL_V2_POLICY_TYPE="$(
    echo "$V2_POLICY_JSON" |
      jq -r '.Policy.PolicySummary.Type // empty'
  )"

  ACTUAL_V2_POLICY_CONTENT="$(
    echo "$V2_POLICY_JSON" |
      jq -r '.Policy.Content // empty'
  )"

  if [[ "$ACTUAL_V2_POLICY_TYPE" != "SECURITYHUB_POLICY" ]]; then
    fail "Security Hub V2 policy type is ${ACTUAL_V2_POLICY_TYPE}; expected SECURITYHUB_POLICY."
  fi

  if [[ -n "$EXPECTED_V2_POLICY_CONTENT" ]]; then
    EXPECTED_V2_POLICY_NORMALIZED="$(
      printf '%s' "$EXPECTED_V2_POLICY_CONTENT" |
        jq -S -c .
    )"

    ACTUAL_V2_POLICY_NORMALIZED="$(
      printf '%s' "$ACTUAL_V2_POLICY_CONTENT" |
        jq -S -c .
    )"

    if [[ "$ACTUAL_V2_POLICY_NORMALIZED" != "$EXPECTED_V2_POLICY_NORMALIZED" ]]; then
      echo "Expected policy: $EXPECTED_V2_POLICY_NORMALIZED"
      echo "Actual policy:   $ACTUAL_V2_POLICY_NORMALIZED"
      fail "Security Hub V2 organization policy content does not match Terraform state."
    fi
  fi

  success "Security Hub V2 organization policy matches Terraform state"

  WORKLOADS_POLICY_ATTACHMENTS_JSON="$(
    aws organizations list-policies-for-target \
      "${aws_profile_args[@]}" \
      --target-id "$WORKLOADS_OU_ID" \
      --filter SECURITYHUB_POLICY \
      --output json
  )"

  if ! echo "$WORKLOADS_POLICY_ATTACHMENTS_JSON" |
    jq -e --arg policy_id "$SECURITYHUB_V2_ORGANIZATION_POLICY_ID" '
      any(.Policies[]?; .Id == $policy_id)
    ' >/dev/null; then
    echo "$WORKLOADS_POLICY_ATTACHMENTS_JSON" | jq .
    fail "Security Hub V2 organization policy is not directly attached to the ${WORKLOADS_OU_NAME} OU."
  fi

  success "Security Hub V2 organization policy is attached to the ${WORKLOADS_OU_NAME} OU"

  for account_name in "${WORKLOAD_ACCOUNTS[@]}"; do
    [[ -z "$account_name" ]] && continue

    account_id="${WORKLOAD_ACCOUNT_IDS[$account_name]:-}"

    if [[ -z "$account_id" ]]; then
      account_id="$(resolve_active_account_id "$account_name")"
      WORKLOAD_ACCOUNT_IDS["$account_name"]="$account_id"
    fi

    EFFECTIVE_POLICY_JSON="$(
      aws organizations describe-effective-policy \
        "${aws_profile_args[@]}" \
        --policy-type SECURITYHUB_POLICY \
        --target-id "$account_id" \
        --output json
    )"

    EFFECTIVE_POLICY_CONTENT="$(
      echo "$EFFECTIVE_POLICY_JSON" |
        jq -r '.EffectivePolicy.PolicyContent // empty'
    )"

    if [[ -z "$EFFECTIVE_POLICY_CONTENT" ]]; then
      echo "$EFFECTIVE_POLICY_JSON" | jq .
      fail "No effective SECURITYHUB_POLICY was returned for workload account '${account_name}'."
    fi

    if ! printf '%s' "$EFFECTIVE_POLICY_CONTENT" |
      jq -e --arg region "$SECURITYHUB_HOME_REGION" '
        (.securityhub.enable_in_regions."@@assign" // [])
        | index($region) != null
      ' >/dev/null; then
      echo "$EFFECTIVE_POLICY_CONTENT" | jq .
      fail "Effective Security Hub V2 policy for '${account_name}' does not enable ${SECURITYHUB_HOME_REGION}."
    fi

    if ! printf '%s' "$EFFECTIVE_POLICY_CONTENT" |
      jq -e '
        (.securityhub.disable_in_regions."@@assign" // [])
        | length == 0
      ' >/dev/null; then
      echo "$EFFECTIVE_POLICY_CONTENT" | jq .
      fail "Effective Security Hub V2 policy for '${account_name}' disables one or more Regions unexpectedly."
    fi

    success "Effective Security Hub V2 policy is correct for workload account '${account_name}'"
  done
else
  warn "central_security_features_enabled.securityhub_v2=false. Skipping Security Hub V2 organization-policy validation."
fi

section "Security Operations Summary"

cat <<SUMMARY
Security-operations account:            ${EXPECTED_SECURITY_OPERATIONS_ACCOUNT_ID}
AWS profile:                            ${AWS_PROFILE:-<default>}
AWS region:                             ${AWS_REGION}
Organization ID:                        ${ORGANIZATION_ID}
Organization root:                      ${ROOT_ID}

Workloads OU:                           ${WORKLOADS_OU_ID}
NonProd OU:                             ${NONPROD_OU_ID}
Prod OU:                                ${PROD_OU_ID}
Security OU:                            ${SECURITY_OU_ID}

Central Security Hub CSPM enabled:      ${SECURITYHUB_CSPM_ENABLED}
CSPM configuration policy count:        ${CSPM_POLICY_COUNT}
CSPM policy association count:          ${CSPM_ASSOCIATION_COUNT}
Security Hub finding aggregator:        ${SECURITYHUB_FINDING_AGGREGATOR_ARN}

Central GuardDuty enabled:              ${GUARDDUTY_ORGANIZATION_ENABLED}
GuardDuty detector ID:                  ${GUARDDUTY_DETECTOR_ID}
GuardDuty organization feature count:   ${GUARDDUTY_FEATURE_COUNT}

Security Hub V2 policy enabled:         ${SECURITYHUB_V2_POLICY_ENABLED}
Security Hub V2 organization policy:    ${SECURITYHUB_V2_ORGANIZATION_POLICY_ID:-<not managed>}
SUMMARY

section "Validation Result"

success "Security operations validation completed successfully"