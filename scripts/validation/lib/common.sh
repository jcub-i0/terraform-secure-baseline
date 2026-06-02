cat > scripts/validation/lib/common.sh <<'EOF'
#!/usr/bin/env bash

# Common helper functions for tf-secure-baseline validation scripts.
#
# This file is intended to be sourced by validation scripts, not executed directly.

set -euo pipefail

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

info() {
  echo "[INFO] $*"
}

success() {
  echo "[PASS] $*"
}

warn() {
  echo "$[WARN] $*"
}

fail() {
  echo "$[FAIL] $*" >&2
  exit 1
}

section() {
  echo
  echo "================================================================================"
  echo "$*"
  echo "================================================================================"
}

# -----------------------------------------------------------------------------
# Basic command / input validation
# -----------------------------------------------------------------------------

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>$1; then
    fail "Required command not found: $cmd"
  fi
}

require_env_name() {
  local env_name="$1"

  case "$env_name" in
    dev|staging|prod)
      return 0
      ;;
    *)
      fail "Invalid environment: $env_name. Expected one of: dev, staging, prod."
      ;;
  esac
}

require_directory() {
  local dir="$1"

  if [[ ! -d "$dir" ]]; then
    fail "Required directory not found: $dir"
  fi
}

require_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    fail "Required file not found: $file"
  fi
}

# -----------------------------------------------------------------------------
# Repo / path helpers
# -----------------------------------------------------------------------------

get_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

get_environment_dir() {
  local repo_root="$1"
  local env_name="$2"

  echo "${repo_root}/environments/${env_name}"
}

# -----------------------------------------------------------------------------
# AWS helpers
# -----------------------------------------------------------------------------

aws_cli_base_args() {
  local aws_profile="$1"
  local aws_region="$2"

  local args=()

  if [[ -n "$aws_profile" ]]; then
    args+=(--profile "$aws_profile")
  fi

  if [[ -n "$aws_region" ]]; then
    args+=(--region "$aws_region")
  fi

  printf '%q ' "${args[@]}"
}

get_aws_accounts_id() {
  local aws_profile="$1"
  local aws_region="$2"

  if [[ -n "$aws_profile" && -n "$aws_region" ]]; then
    aws sts get-caller-identity \
      --profile "$aws_profile" \
      --region "$aws_region" \
      --query Account \
      --output text
  elif [[ -n "$aws_profile" ]]; then
    aws sts get-caller-identity \
      --profile "$aws_profile" \
      --query Account \
      --output text
  elif [[ -n "$aws_region" ]]; then
    aws sts get-caller-identity \
      --region "$aws_region" \
      --query Account \
      --output text
  else
    aws sts get-caller-identity \
      --query Account \
      --output text
  fi
}

get_aws_caller_arn() {
  local aws_profile="$1"
  local aws_region="$2"

  if [[ -n "$aws_profile" && -n "$aws_region" ]]; then
    aws sts get-caller-identity \
      --profile "$aws_profile" \
      --region "$aws_region" \
      --query Arn \
      --output text
  elif [[ -n "$aws_profile" ]]; then
    aws sts get-caller-identity \
      --profile "$aws_profile" \
      --query Arn \
      --output text
  elif [[ -n "$aws_region" ]]; then
    aws sts get-caller-identity \
      --region "$aws_region" \
      --query Arn \
      --output text
  else
    aws sts get-caller-identity \
      --query Arn \
      --output text
  fi
}

# -----------------------------------------------------------------------------
# Terraform helpers
# -----------------------------------------------------------------------------

terraform_output_json() {
  local env_dir="$1"

  terraform -chdir="$env_dir" output -json
}

terraform_output_raw() {
  local env_dir="$1"
  local output_name="$2"

  terraform -chdir="$env_dir" output -raw "$output_name"
}

terraform_output_exists() {
  local outputs_json="$1"
  local output_name="$2"

  echo "$outputs_json" | jq -e --arg name "$output_name" 'has($name)' >/dev/null
}

get_terraform_output_value() {
  local outputs_json="$1"
  local output_name="$2"

  echo "$outputs_json" | jq -r --arg name "$output_name" '.[$name].value'
}