#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  migrate-state-stack.sh <dev|staging|prod|control-plane> [--verify-only]

Examples:
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/migrate-state-stack.sh dev

  AWS_PROFILE=control-plane \
  EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
  ./scripts/bootstrap/migrate-state-stack.sh control-plane

  AWS_PROFILE=dev \
  ./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
USAGE
}

info()    { printf '[INFO] %s\n' "$*"; }
success() { printf '[PASS] %s\n' "$*"; }
warn()    { printf '[WARN] %s\n' "$*" >&2; }
fail()    { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

get_backend_string_value() {
  local backend_file="$1"
  local attribute_name="$2"

  sed -nE \
    "s/^[[:space:]]*${attribute_name}[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\1/p" \
    "$backend_file" |
    head -n 1
}

TARGET="${1:-}"
MODE="${2:-}"

[[ -n "$TARGET" ]] || { usage; exit 1; }

case "$MODE" in
  ""|--verify-only) ;;
  *) usage; fail "Unknown option: ${MODE}" ;;
esac

case "$TARGET" in
  dev|staging|prod)
    STACK_PATH_COMPONENT="$TARGET"
    DISPLAY_TARGET="$TARGET"
    ;;
  control-plane|control_plane)
    STACK_PATH_COMPONENT="control_plane"
    DISPLAY_TARGET="control-plane"
    ;;
  *)
    usage
    fail "Unsupported target: ${TARGET}"
    ;;
esac

for cmd in terraform aws git sed sort diff cp mkdir date cmp mktemp; do
  require_command "$cmd"
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  fail "Unable to resolve repository root"

STATE_DIR="${REPO_ROOT}/bootstrap/${STACK_PATH_COMPONENT}/state"
BACKEND_TEMPLATE="${STATE_DIR}/backend.tf.migrated.example"
ACTIVE_BACKEND="${STATE_DIR}/backend.tf"
LOCAL_STATE_FILE="${STATE_DIR}/terraform.tfstate"

[[ -d "$STATE_DIR" ]] || fail "State stack directory not found: ${STATE_DIR}"
[[ -f "$BACKEND_TEMPLATE" ]] || fail "Backend template not found: ${BACKEND_TEMPLATE}"

BACKEND_BUCKET="$(get_backend_string_value "$BACKEND_TEMPLATE" bucket)"
BACKEND_KEY="$(get_backend_string_value "$BACKEND_TEMPLATE" key)"
BACKEND_REGION="$(get_backend_string_value "$BACKEND_TEMPLATE" region)"
USE_LOCKFILE="$(
  sed -nE \
    's/^[[:space:]]*use_lockfile[[:space:]]*=[[:space:]]*(true|false).*/\1/p' \
    "$BACKEND_TEMPLATE" |
    head -n 1
)"

[[ -n "$BACKEND_BUCKET" ]] || fail "Unable to resolve backend bucket"
[[ -n "$BACKEND_KEY" ]] || fail "Unable to resolve backend key"
[[ -n "$BACKEND_REGION" ]] || fail "Unable to resolve backend region"
[[ "$USE_LOCKFILE" == "true" ]] || fail "Backend template must set use_lockfile = true"

AWS_REGION="${AWS_REGION:-$BACKEND_REGION}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"
BACKUP_DIR="${BACKUP_DIR:-${HOME}/.tf-secure-baseline/state-backups}"

[[ "$AWS_REGION" == "$BACKEND_REGION" ]] ||
  fail "AWS_REGION (${AWS_REGION}) does not match backend region (${BACKEND_REGION})"

aws_args=(--region "$AWS_REGION")
if [[ -n "$AWS_PROFILE" ]]; then
  aws_args+=(--profile "$AWS_PROFILE")
fi

timestamp="$(date -u +'%Y%m%dT%H%M%SZ')"
stack_backup_dir="${BACKUP_DIR}/${DISPLAY_TARGET}/${timestamp}"

info "Target: ${DISPLAY_TARGET}"
info "State stack: ${STATE_DIR}"
info "Backend bucket: ${BACKEND_BUCKET}"
info "Backend key: ${BACKEND_KEY}"
info "Backend region: ${BACKEND_REGION}"
info "AWS profile: ${AWS_PROFILE:-default credential chain}"

active_account_id="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Account \
    --output text
)"
caller_arn="$(
  aws sts get-caller-identity \
    "${aws_args[@]}" \
    --query Arn \
    --output text
)"

success "AWS credentials are valid"
info "AWS account ID: ${active_account_id}"
info "AWS caller ARN: ${caller_arn}"

if [[ -n "$EXPECTED_ACCOUNT_ID" && "$active_account_id" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${active_account_id}"
fi

verify_remote_state() {
  local expected_addresses_file="${1:-}"
  local remote_state_file
  local remote_addresses_file

  [[ -f "$ACTIVE_BACKEND" ]] || fail "Active backend file not found: ${ACTIVE_BACKEND}"
  cmp -s "$BACKEND_TEMPLATE" "$ACTIVE_BACKEND" ||
    fail "backend.tf differs from backend.tf.migrated.example"

  terraform -chdir="$STATE_DIR" init -input=false -no-color >/dev/null

  aws s3api head-object \
    "${aws_args[@]}" \
    --bucket "$BACKEND_BUCKET" \
    --key "$BACKEND_KEY" >/dev/null

  remote_state_file="$(mktemp)"
  remote_addresses_file="$(mktemp)"
  terraform -chdir="$STATE_DIR" state pull > "$remote_state_file"
  [[ -s "$remote_state_file" ]] || fail "terraform state pull returned empty state"

  state_output_bucket="$(
    terraform -chdir="$STATE_DIR" output -raw tf_state_bucket_name 2>/dev/null || true
  )"
  [[ -n "$state_output_bucket" ]] ||
    fail "Unable to read tf_state_bucket_name from remote state"
  [[ "$state_output_bucket" == "$BACKEND_BUCKET" ]] ||
    fail "Backend bucket mismatch. Template: ${BACKEND_BUCKET}; output: ${state_output_bucket}"

  terraform -chdir="$STATE_DIR" state list | sort > "$remote_addresses_file"

  if [[ -n "$expected_addresses_file" ]]; then
    diff -u "$expected_addresses_file" "$remote_addresses_file" ||
      fail "Resource addresses changed during migration"
    success "Remote state resource addresses match pre-migration state"
  fi

  success "Remote S3 state object exists and is readable"
  success "terraform state pull succeeded"
  success "Backend bucket matches tf_state_bucket_name"

  rm -f "$remote_state_file" "$remote_addresses_file"
}

if [[ "$MODE" == "--verify-only" ]]; then
  verify_remote_state
  success "Remote state verification completed: ${DISPLAY_TARGET}"
  exit 0
fi

[[ ! -e "$ACTIVE_BACKEND" ]] ||
  fail "backend.tf already exists. Use --verify-only for an already-migrated stack."

[[ -s "$LOCAL_STATE_FILE" ]] ||
  fail "Local state not found or empty: ${LOCAL_STATE_FILE}. Apply the state stack locally first."

terraform -chdir="$STATE_DIR" init -input=false -no-color >/dev/null

mkdir -p "$stack_backup_dir"

LOCAL_STATE_BACKUP="${stack_backup_dir}/terraform.tfstate.pre-migration"
LOCAL_STATE_PULL="${stack_backup_dir}/terraform-state-pull.pre-migration.json"
LOCAL_ADDRESS_LIST="${stack_backup_dir}/terraform-state-addresses.pre-migration.txt"

cp "$LOCAL_STATE_FILE" "$LOCAL_STATE_BACKUP"
terraform -chdir="$STATE_DIR" state pull > "$LOCAL_STATE_PULL"
terraform -chdir="$STATE_DIR" state list | sort > "$LOCAL_ADDRESS_LIST"

[[ -s "$LOCAL_STATE_PULL" ]] || fail "Unable to create pre-migration state backup"
info "Pre-migration backups written to: ${stack_backup_dir}"

state_output_bucket="$(
  terraform -chdir="$STATE_DIR" output -raw tf_state_bucket_name 2>/dev/null || true
)"
[[ -n "$state_output_bucket" ]] || fail "Unable to read tf_state_bucket_name"
[[ "$state_output_bucket" == "$BACKEND_BUCKET" ]] ||
  fail "Backend template bucket mismatch. Template: ${BACKEND_BUCKET}; output: ${state_output_bucket}"

success "Backend template bucket matches tf_state_bucket_name"

aws s3api head-bucket \
  "${aws_args[@]}" \
  --bucket "$BACKEND_BUCKET" >/dev/null
success "Target S3 bucket exists"

if aws s3api head-object \
  "${aws_args[@]}" \
  --bucket "$BACKEND_BUCKET" \
  --key "$BACKEND_KEY" >/dev/null 2>&1; then
  fail "Remote state object already exists: s3://${BACKEND_BUCKET}/${BACKEND_KEY}"
fi

success "Target remote state key is unused"

cp "$BACKEND_TEMPLATE" "$ACTIVE_BACKEND"
success "Created active backend file: ${ACTIVE_BACKEND}"

cat <<NOTICE

Terraform will now migrate local state to:

  s3://${BACKEND_BUCKET}/${BACKEND_KEY}

Review the Terraform prompt and answer "yes" only if the destination is correct.
This script intentionally does not use -force-copy.

NOTICE

if ! terraform -chdir="$STATE_DIR" init -migrate-state -no-color; then
  warn "Migration failed. backend.tf remains in place."
  warn "Pre-migration backups remain at: ${stack_backup_dir}"
  fail "Resolve the error before retrying."
fi

verify_remote_state "$LOCAL_ADDRESS_LIST"

REMOTE_STATE_BACKUP="${stack_backup_dir}/terraform-state-pull.post-migration.json"
terraform -chdir="$STATE_DIR" state pull > "$REMOTE_STATE_BACKUP"

success "Post-migration state backup written to: ${REMOTE_STATE_BACKUP}"
success "State stack migration completed successfully: ${DISPLAY_TARGET}"

cat <<NEXT

Next steps:
  1. Keep backend.tf locally; it is ignored by Git.
  2. Keep backend.tf.migrated.example tracked.
  3. Run validation with REQUIRE_STATE_STACK_REMOTE=true.
  4. Retain this backup directory until independently verified:

     ${stack_backup_dir}

NEXT