#!/usr/bin/env bash

# validate-ecr.sh
#
# Validates Terraform-managed ECR repositories for a deployed
# tf-secure-baseline workload environment.
#
# The workload-root ecr_repositories output is the authoritative repository
# inventory. An empty map is a valid configuration and requires no live ECR
# calls.
#
# Checks for configured repositories:
# - Repository name, ARN, and registry ID match Terraform output
# - Image tags are immutable
# - Repository encryption uses a configured KMS key
# - Lifecycle policy contains exactly the approved 30-day untagged expiration
#   rule and no tagged-image expiration rule

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_PROFILE="${AWS_PROFILE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

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

section "${CLOUD_NAME} ECR Validation"

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
info "AWS_PROFILE: ${AWS_PROFILE:-<default>}"
info "AWS_REGION: $AWS_REGION"

require_directory "$ENV_DIR"
success "Environment directory exists"

OUTPUTS_JSON="$(terraform_output_json "$ENV_DIR")"

if [[ -z "$OUTPUTS_JSON" || "$OUTPUTS_JSON" == "{}" ]]; then
  fail "No Terraform outputs found for ${ENV_DIR}. Has this environment been applied?"
fi

if ! terraform_output_exists "$OUTPUTS_JSON" ecr_repositories; then
  fail "Missing required Terraform output: ecr_repositories"
fi

ECR_REPOSITORIES_JSON="$(echo "$OUTPUTS_JSON" | jq -c '.ecr_repositories.value')"

if ! echo "$ECR_REPOSITORIES_JSON" |
  jq -e '
    type == "object"
    and all(
      to_entries[];
      (.key | type) == "string"
      and (.value | type) == "object"
      and (.value.name | type) == "string"
      and (.value.arn | type) == "string"
      and (.value.repository_url | type) == "string"
      and ((.value.registry_id | type) == "string")
    )
  ' >/dev/null; then
  fail "ecr_repositories is not a valid repository metadata map"
fi

ECR_REPOSITORY_COUNT="$(echo "$ECR_REPOSITORIES_JSON" | jq 'length')"
success "ecr_repositories output is valid: ${ECR_REPOSITORY_COUNT} configured"

if [[ "$ECR_REPOSITORY_COUNT" -eq 0 ]]; then
  section "ECR Validation Result"
  success "No ECR repositories are configured; live ECR validation is not required"
  exit 0
fi

if ! terraform_output_exists "$OUTPUTS_JSON" ecr_cmk_arn; then
  fail "Missing required Terraform output: ecr_cmk_arn"
fi

EXPECTED_ECR_CMK_ARN="$(get_terraform_output_value "$OUTPUTS_JSON" ecr_cmk_arn)"

if [[ -z "$EXPECTED_ECR_CMK_ARN" ]]; then
  fail "ecr_cmk_arn is empty"
fi

section "Checking AWS caller identity"

ACCOUNT_ID="$(get_aws_account_id "$AWS_PROFILE" "$AWS_REGION")"
CALLER_ARN="$(get_aws_caller_arn "$AWS_PROFILE" "$AWS_REGION")"

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  fail "Unable to resolve AWS account ID"
fi

success "AWS credentials are valid"
info "AWS account ID: $ACCOUNT_ID"
info "AWS caller ARN: $CALLER_ARN"

if [[ -n "$EXPECTED_ACCOUNT_ID" && "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail "AWS account ID mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
fi

section "Validating configured ECR repositories"

VALIDATED_REPOSITORY_COUNT=0

while IFS= read -r repository_entry; do
  repository_key="$(echo "$repository_entry" | jq -r '.key')"
  expected_name="$(echo "$repository_entry" | jq -r '.value.name')"
  expected_arn="$(echo "$repository_entry" | jq -r '.value.arn')"
  expected_registry_id="$(echo "$repository_entry" | jq -r '.value.registry_id')"

  info "Validating ECR repository key ${repository_key}: ${expected_name}"

  if [[ "$expected_registry_id" != "$ACCOUNT_ID" ]]; then
    fail "Terraform repository ${repository_key} registry ID ${expected_registry_id} does not match the active AWS account ${ACCOUNT_ID}"
  fi

  if ! repository_json="$(
    aws ecr describe-repositories \
      "${aws_args[@]}" \
      --registry-id "$expected_registry_id" \
      --repository-names "$expected_name" \
      --output json
  )"; then
    fail "Terraform expects ECR repository ${expected_name}, but it could not be described in live AWS"
  fi

  if [[ "$(echo "$repository_json" | jq '.repositories | length')" -ne 1 ]]; then
    echo "$repository_json" | jq .
    fail "Expected exactly one live ECR repository for ${expected_name}"
  fi

  if ! echo "$repository_json" |
    jq -e \
      --arg name "$expected_name" \
      --arg arn "$expected_arn" \
      --arg registry_id "$expected_registry_id" '
        .repositories[0]
        | .repositoryName == $name
          and .repositoryArn == $arn
          and .registryId == $registry_id
      ' >/dev/null; then
    echo "$repository_json" | jq '.repositories[0] | {repositoryName, repositoryArn, registryId}'
    fail "Live ECR repository identity does not match Terraform output for key ${repository_key}"
  fi
  success "Repository identity matches Terraform output: ${expected_name}"

  image_tag_mutability="$(echo "$repository_json" | jq -r '.repositories[0].imageTagMutability // empty')"
  if [[ "$image_tag_mutability" == "IMMUTABLE" ]]; then
    success "Repository image tags are immutable: ${expected_name}"
  else
    fail "Repository ${expected_name} imageTagMutability is ${image_tag_mutability:-<missing>}, expected IMMUTABLE"
  fi

  encryption_type="$(echo "$repository_json" | jq -r '.repositories[0].encryptionConfiguration.encryptionType // empty')"
  kms_key="$(echo "$repository_json" | jq -r '.repositories[0].encryptionConfiguration.kmsKey // empty')"

  if [[ "$encryption_type" != "KMS" ]]; then
    fail "Repository ${expected_name} encryption type is ${encryption_type:-<missing>}, expected KMS"
  fi

  if [[ -z "$kms_key" ]]; then
    fail "Repository ${expected_name} uses KMS encryption but has no configured KMS key"
  fi

  if [[ "$kms_key" != "$EXPECTED_ECR_CMK_ARN" ]]; then
    fail "Repository ${expected_name} KMS key does not match Terraform ECR CMK: expected=${EXPECTED_ECR_CMK_ARN} actual=${kms_key}"
  fi

  success "Repository KMS key exactly matches Terraform ECR CMK: ${expected_name}"

  if ! lifecycle_policy_response_json="$(
    aws ecr get-lifecycle-policy \
      "${aws_args[@]}" \
      --registry-id "$expected_registry_id" \
      --repository-name "$expected_name" \
      --output json
  )"; then
    fail "Repository ${expected_name} does not have a readable lifecycle policy"
  fi

  lifecycle_policy_json="$(echo "$lifecycle_policy_response_json" | jq -er '.lifecyclePolicyText | fromjson')"

  if ! echo "$lifecycle_policy_json" |
    jq -e '
      (.rules | type) == "array"
      and (.rules | length) == 1
      and .rules[0].selection.tagStatus == "untagged"
      and .rules[0].selection.countType == "sinceImagePushed"
      and .rules[0].selection.countUnit == "days"
      and .rules[0].selection.countNumber == 30
      and .rules[0].action.type == "expire"
      and (.rules[0].selection | has("tagPrefixList") | not)
      and (.rules[0].selection | has("tagPatternList") | not)
    ' >/dev/null; then
    echo "$lifecycle_policy_json" | jq .
    fail "Repository ${expected_name} lifecycle policy does not exactly match the approved 30-day untagged-image cleanup rule"
  fi

  if echo "$lifecycle_policy_json" |
    jq -e '[.rules[] | select(.selection.tagStatus != "untagged")] | length > 0' >/dev/null; then
    echo "$lifecycle_policy_json" | jq .
    fail "Repository ${expected_name} lifecycle policy contains tagged-image expiration behavior"
  fi

  success "Lifecycle policy expires only untagged images older than 30 days: ${expected_name}"
  VALIDATED_REPOSITORY_COUNT=$((VALIDATED_REPOSITORY_COUNT + 1))
done < <(echo "$ECR_REPOSITORIES_JSON" | jq -c 'to_entries[]')

section "ECR Summary"

cat <<SUMMARY
Environment:                    ${ENV_NAME}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACCOUNT_ID}
Configured repositories:        ${ECR_REPOSITORY_COUNT}
Validated repositories:         ${VALIDATED_REPOSITORY_COUNT}
Expected ECR CMK output:        <not exposed>
SUMMARY

section "Validation Result"

success "ECR validation completed successfully for: ${ENV_NAME}"
