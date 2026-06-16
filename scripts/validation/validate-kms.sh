#!/usr/bin/env bash

# validate-kms.sh
#
# Validates KMS keys and aliases for a deployed tf-secure-baseline environment.
#
# Checks:
# - Terraform outputs are readable
# - KMS aliases matching the environment exist
# - Expected workload CMK aliases exist:
#   - logs
#   - lambda
#   - ebs
#   - secrets manager
# - Backup CMK alias is validated only when effective_backup_enabled=true
# - Matching KMS keys are enabled
# - Key rotation status is checked and reported
#
# Usage:
#   ./scripts/validation/validate-kms.sh dev
#
# Optional:
#   AWS_PROFILE=dev AWS_REGION=us-east-1 ./scripts/validation/validate-kms.sh dev
#
# Optional override:
#   NAME_PREFIX=tf-secure-baseline-dev ./scripts/validation/validate-kms.sh dev

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

if [[ -z "$ENV_NAME" ]]; then
  fail "Usage: $0 <dev|staging|prod>"
fi

require_env_name "${ENV_NAME}"

aws_args=()
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

if [[ -n "$AWS_REGION" ]]; then
  aws_args+=(--region "$AWS_REGION")
fi

section "tf-secure-baseline KMS Validation"

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

EFFECTIVE_BACKUP_ENABLED="false"

if terraform_output_exists "$OUTPUTS_JSON" effective_backup_enabled; then
  EFFECTIVE_BACKUP_ENABLED="$(get_terraform_output_value "$OUTPUTS_JSON" effective_backup_enabled)"
  require_value_in_list "$EFFECTIVE_BACKUP_ENABLED" "true false" "effective_backup_enabled"
  success "effective_backup_enabled is valid: $EFFECTIVE_BACKUP_ENABLED"
else
  warn "Missing Terraform output: effective_backup_enabled. Backup CMK validation will be skipped."
fi

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

# -----------------------------------------------------------------------------
# KMS helper functions
# -----------------------------------------------------------------------------

find_alias_by_keyword() {
  local keyword="$1"

  echo "$ALIASES_JSON" |
    jq -r --arg prefix "$NAME_PREFIX" --arg keyword "$keyword" '
      [
        .Aliases[]
        | select(.TargetKeyId != null)
        | select(.AliasName | contains($prefix))
        | select((.AliasName | ascii_downcase) | contains($keyword))
        | .AliasName
      ]
      | first // empty
    '
}

validate_alias_and_key() {
  local label="$1"
  local keyword="$2"
  local required="$3"

  local alias_name
  local key_id
  local key_metadata_json
  local key_state
  local key_manager
  local key_rotation_enabled

  alias_name="$(find_alias_by_keyword "$keyword")"

  if [[ -z "$alias_name" ]]; then
    if [[ "$required" == "true" ]]; then
      fail "Required KMS alias not found for ${label}. Expected alias containing prefix '${NAME_PREFIX}' and keyword '${keyword}'."
    else
      warn "Optional KMS alias not found for ${label}. Expected alias containing prefix '${NAME_PREFIX}' and keyword '${keyword}'."
      return 0
    fi
  fi

  success "KMS alias exists for ${label}: ${alias_name}"

  key_id="$(
    echo "$ALIASES_JSON" |
      jq -r --arg alias_name "$alias_name" '
        .Aliases[]
        | select(.AliasName == $alias_name)
        | .TargetKeyId
      '
  )"

  if [[ -z "$key_id" || "$key_id" == "null" ]]; then
    fail "KMS alias ${alias_name} does not have a TargetKeyId."
  fi

  key_metadata_json="$(
    aws kms describe-key \
      "${aws_args[@]}" \
      --key-id "$alias_name" \
      --output json
  )"

  key_state="$(
    echo "$key_metadata_json" |
      jq -r '.KeyMetadata.KeyState'
  )"

  key_manager="$(
    echo "$key_metadata_json" |
      jq -r '.KeyMetadata.KeyManager'
  )"

  if [[ "$key_state" == "Enabled" ]]; then
    success "KMS key for ${label} is enabled"
  else
    echo "$key_metadata_json" | jq '.KeyMetadata'
    fail "KMS key for ${label} is not enabled. Current state: ${key_state}"
  fi

  if [[ "$key_manager" == "CUSTOMER" ]]; then
    success "KMS key for ${label} is customer managed"
  else
    warn "KMS key for ${label} is not customer managed. KeyManager=${key_manager}"
  fi

  if key_rotation_enabled="$(
    aws kms get-key-rotation-status \
      "${aws_args[@]}" \
      --key-id "$key_id" \
      --query 'KeyRotationEnabled' \
      --output text 2>/dev/null
  )"; then
    if [[ "$key_rotation_enabled" == "True" || "$key_rotation_enabled" == "true" ]]; then
      success "KMS key rotation is enabled for ${label}"
    else
      warn "KMS key rotation is not enabled for ${label}"
    fi
  else
    warn "Unable to read key rotation status for ${label}. This may be expected for some key types."
    key_rotation_enabled="unknown"
  fi

  VALIDATED_KEY_COUNT=$((VALIDATED_KEY_COUNT + 1))
  VALIDATED_ALIASES+=("$alias_name")

  if [[ "$required" == "true" ]]; then
    REQUIRED_KEY_COUNT=$((REQUIRED_KEY_COUNT + 1))
  else
    OPTIONAL_KEY_COUNT=$((OPTIONAL_KEY_COUNT + 1))
  fi

  alias_short="${alias_name#alias/${NAME_PREFIX}/}"

  KMS_SUMMARY_ROWS+=("${label}|${alias_short}|${key_id}|${key_state}|${key_manager}|${key_rotation_enabled}")
}

section "Listing KMS aliases"

ALIASES_JSON="$(
  aws kms list-aliases \
    "${aws_args[@]}" \
    --output json
)"

MATCHING_ALIAS_COUNT="$(
  echo "$ALIASES_JSON" |
    jq --arg prefix "$NAME_PREFIX" '
      [
        .Aliases[]
        | select(.TargetKeyId != null)
        | select(.AliasName | contains($prefix))
      ]
      | length
    '
)"

if [[ "$MATCHING_ALIAS_COUNT" -gt 0 ]]; then
  success "Found KMS aliases matching name prefix: $MATCHING_ALIAS_COUNT"
else
  fail "No KMS aliases found containing name prefix: ${NAME_PREFIX}"
fi

info "Matching aliases:"
echo "$ALIASES_JSON" |
  jq -r --arg prefix "$NAME_PREFIX" '
    .Aliases[]
    | select(.TargetKeyId != null)
    | select(.AliasName | contains($prefix))
    | "- " + .AliasName
  '

section "Validating expected KMS aliases and keys"

VALIDATED_KEY_COUNT=0
REQUIRED_KEY_COUNT=0
OPTIONAL_KEY_COUNT=0
VALIDATED_ALIASES=()
KMS_SUMMARY_ROWS=()

# Required workload/environment keys.
validate_alias_and_key "logs" "logs" "true"
validate_alias_and_key "lambda" "lambda" "true"
validate_alias_and_key "ebs" "ebs" "true"
validate_alias_and_key "secrets manager" "secrets" "true"

# Backup is profile/override dependent.
if [[ "$EFFECTIVE_BACKUP_ENABLED" == "true" ]]; then
  validate_alias_and_key "backup" "backup" "true"
else
  warn "effective_backup_enabled=false. Skipping required Backup CMK validation."
  validate_alias_and_key "backup" "backup" "false"
fi

UNIQUE_VALIDATED_ALIAS_COUNT="$(
  printf '%s\n' "${VALIDATED_ALIASES[@]}" |
    sort -u |
    sed '/^$/d' |
    wc -l |
    tr -d ' '
)"

UNVALIDATED_ALIAS_COUNT=$((MATCHING_ALIAS_COUNT - UNIQUE_VALIDATED_ALIAS_COUNT))

if [[ "$UNVALIDATED_ALIAS_COUNT" -lt 0 ]]; then
  UNVALIDATED_ALIAS_COUNT=0
fi

section "KMS Summary"

cat <<SUMMARY
Environment:                    ${ENV_NAME}
AWS profile:                    ${AWS_PROFILE:-<default>}
AWS region:                     ${AWS_REGION}
AWS account ID:                 ${ACCOUNT_ID}
Name prefix:                    ${NAME_PREFIX}

Matching environment aliases:   ${MATCHING_ALIAS_COUNT}
Required KMS keys validated:    ${REQUIRED_KEY_COUNT}
Optional KMS keys validated:    ${OPTIONAL_KEY_COUNT}
Total KMS keys validated:       ${VALIDATED_KEY_COUNT}
Unvalidated matching aliases:   ${UNVALIDATED_ALIAS_COUNT}
effective_backup_enabled:       ${EFFECTIVE_BACKUP_ENABLED}
SUMMARY

if [[ "${#KMS_SUMMARY_ROWS[@]}" -gt 0 ]]; then
  echo
  echo "Validated keys:"
  printf '%s\n' "${KMS_SUMMARY_ROWS[@]}" |
    awk -F'|' '
      BEGIN {
        printf "%-18s %-18s %-38s %-10s %-10s %-10s\n", "Label", "Alias", "KeyId", "State", "Manager", "Rotation"
        printf "%-18s %-18s %-38s %-10s %-10s %-10s\n", "-----", "-----", "-----", "-----", "-------", "--------"
      }
      {
        printf "%-18s %-18s %-38s %-10s %-10s %-10s\n", $1, $2, $3, $4, $5, $6
      }
    '
fi

echo
echo "Unvalidated matching aliases:"
echo "$ALIASES_JSON" |
  jq -r --arg prefix "$NAME_PREFIX" '
    .Aliases[]
    | select(.TargetKeyId != null)
    | select(.AliasName | contains($prefix))
    | .AliasName
  ' |
  while read -r alias_name; do
    found="false"

    for validated_alias in "${VALIDATED_ALIASES[@]}"; do
      if [[ "$alias_name" == "$validated_alias" ]]; then
        found="true"
        break
      fi
    done

    if [[ "$found" == "false" ]]; then
      echo "- ${alias_name}"
    fi
  done

section "Validation Result"

success "KMS validation completed successfully for: ${ENV_NAME}"