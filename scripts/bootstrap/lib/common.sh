# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

info()      { printf '[INFO] %s\n' "$*"; }

success()   { printf '[PASS] %s\n' "$*"; }

warn()      { printf '[WARN] %s\n' "$*" >&2; }

fail()      { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

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
  command -v "$1" >/dev/null 2>&1 ||
    fail "Required command not found: $1"
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

get_backend_string_value() {
  local backend_file="$1"
  local attribute_name="$2"

  sed -nE \
    "s/^[[:space:]]*${attribute_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" \
    "$backend_file" |
    head -n 1
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

get_aws_account_id() {
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

get_required_terraform_output() {
  local stack_dir="$1"
  local output_name="$2"
  local output_value

  output_value="$(
    terraform -chdir="$stack_dir" output -raw "$output_name" 2>/dev/null ||
      true
  )"

  if [[ -z "$output_value" ||
        "$output_value" == "null" ||
        "$output_value" == "None" ]]; then
    fail "Unable to read required Terraform output '${output_name}' from ${stack_dir}"
  fi

  printf '%s\n' "$output_value"
}