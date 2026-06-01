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