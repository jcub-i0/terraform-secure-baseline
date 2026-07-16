#!/usr/bin/env bash

# Common helper functions for tf-secure-baseline bootstrap scripts.
#
# This file is intended to be sourced by bootstrap scripts, not executed
# directly.

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

info() {
  printf '[INFO] %s\n' "$*"
}

success() {
  printf '[PASS] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

section() {
  printf '\n'
  printf '%s\n' \
    '================================================================================'
  printf '%s\n' "$*"
  printf '%s\n' \
    '================================================================================'
}

# -----------------------------------------------------------------------------
# Basic command / input validation
# -----------------------------------------------------------------------------

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    fail "Required command not found: ${command_name}"
  fi
}

require_directory() {
  local directory="$1"

  if [[ ! -d "$directory" ]]; then
    fail "Required directory not found: ${directory}"
  fi
}

require_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    fail "Required file not found: ${file}"
  fi
}

require_env_name() {
  local environment="$1"

  case "$environment" in
    dev|staging|prod)
      return 0
      ;;
    *)
      fail \
        "Invalid environment: ${environment}. Expected one of: dev, staging, prod."
      ;;
  esac
}

require_non_empty() {
  local value="$1"
  local description="$2"

  if [[ -z "$value" ||
        "$value" == "null" ||
        "$value" == "None" ]]; then
    fail "Unable to resolve ${description}"
  fi
}

# -----------------------------------------------------------------------------
# Repository / path helpers
# -----------------------------------------------------------------------------

get_repo_root() {
  local anchor_directory="$1"

  git -C "$anchor_directory" rev-parse --show-toplevel 2>/dev/null
}

get_environment_dir() {
  local repo_root="$1"
  local environment="$2"

  printf '%s\n' "${repo_root}/environments/${environment}"
}

get_bootstrap_account_dir() {
  local repo_root="$1"
  local environment="$2"

  printf '%s\n' "${repo_root}/bootstrap/${environment}/account"
}

# -----------------------------------------------------------------------------
# AWS helpers
# -----------------------------------------------------------------------------

get_aws_account_id() {
  local aws_profile="$1"
  local aws_region="$2"
  local aws_args=()

  if [[ -n "$aws_profile" ]]; then
    aws_args+=(--profile "$aws_profile")
  fi

  if [[ -n "$aws_region" ]]; then
    aws_args+=(--region "$aws_region")
  fi

  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Account \
    --output text
}

get_aws_caller_arn() {
  local aws_profile="$1"
  local aws_region="$2"
  local aws_args=()

  if [[ -n "$aws_profile" ]]; then
    aws_args+=(--profile "$aws_profile")
  fi

  if [[ -n "$aws_region" ]]; then
    aws_args+=(--region "$aws_region")
  fi

  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Arn \
    --output text
}

# -----------------------------------------------------------------------------
# Terraform / backend helpers
# -----------------------------------------------------------------------------

get_backend_string_value() {
  local backend_file="$1"
  local attribute_name="$2"

  sed -nE \
    "s/^[[:space:]]*${attribute_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" \
    "$backend_file" |
    head -n 1
}

get_required_terraform_output() {
  local stack_directory="$1"
  local output_name="$2"
  local output_value

  output_value="$(
    terraform \
      -chdir="$stack_directory" \
      output \
      -raw \
      "$output_name" \
      2>/dev/null ||
      true
  )"

  require_non_empty \
    "$output_value" \
    "Terraform output '${output_name}' from ${stack_directory}"

  printf '%s\n' "$output_value"
}