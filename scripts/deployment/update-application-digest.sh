#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

success() {
  printf '[PASS] %s/n' "$*"
}

usage() {
  cat <<'USAGE'
Usage:
  update-application-digest.sh \
    --environment <dev|staging|prod> \
    --service <service-name> \
    --image-digest <sha256:digest>

Update only ecs_services.<service>.image_digest in the canonical
container-workloads.auto.tfvars.json file.
USAGE
}

ENVIRONMENT=""
SERVICE=""
IMAGE_DIGEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --environment)
      [[ $# -ge 2 ]] || fail "--environment requires a value"
      ENVIRONMENT="$2"
      shift 2
      ;;
    --service)
      [[ $# -ge 2 ]] || fail "--service requires a value"
      SERVICE="$2"
      shift 2
      ;;
    --image-digest)
      [[ $# -ge 2 ]] || fail "--image-digest requires a value"
      IMAGE_DIGEST="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

case "$ENVIRONMENT" in
  dev|staging|prod)
    ;;
  *)
    fail "environment must be dev, staging, or prod"
    ;;
esac

if [[ ! "$SERVICE" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  fail "service has invalid syntax"
fi

if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  fail "image-digest must be sha256:<64 lowercase hexadecimal characters>"
fi

command -v git >/dev/null 2>&1 ||
  fail "Required command not found: git"

command -v jq >/dev/null 2>&1 ||
  fail "Required command not found: jq"

REPO_ROOT="$(
  git rev-parse --show-toplevel 2>/dev/null
)" || fail "Unable to resolve repository root"

REL_CONFIG_FILE="environments/${ENVIRONMENT}/container-workloads.auto.tfvars.json"
CONFIG_FILE="${REPO_ROOT}/${REL_CONFIG_FILE}"

[[ -f "$CONFIG_FILE" ]] ||
  fail "Canonical workload configuration not found: ${REL_CONFIG_FILE}"

# The release mutation must begin from a clean checkout.
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
  fail "Git working tree must be clean before updating an application digest"
fi

jq -e . "$CONFIG_FILE" >/dev/null ||
  fail "Canonical workload configuration is not valid JSON"

if ! jq -e \
  --arg service "$SERVICE" \
  '.ecs_services | type == "object" and has($service)' \
  "$CONFIG_FILE" >/dev/null; then
  fail "ECS service is not registered: ${SERVICE}"
fi

CURRENT_DIGEST="$(
  jq -r \
    --arg service "$SERVICE" \
    '.ecs_services[$service].image_digest // "null"' \
    "$CONFIG_FILE"
)"

if [[ "$CURRENT_DIGEST" != "null" &&
      ! "$CURRENT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  fail "Existing image_digest for ${SERVICE} is invalid"
fi

if [[ "$CURRENT_DIGEST" == "$IMAGE_DIGEST" ]]; then
  fail "Digest is already selected for ${SERVICE}: ${IMAGE_DIGEST}"
fi

TMP_FILE="$(mktemp "${CONFIG_FILE}.tmp.XXXXXX")"
BEFORE_NORMALIZED="$(mktemp)"
AFTER_NORMALIZED="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE" "$BEFORE_NORMALIZED" "$AFTER_NORMALIZED"
}
trap cleanup EXIT

jq \
  --arg service "$SERVICE" \
  --arg digest "$IMAGE_DIGEST" \
  '.ecs_services[$service].image_digest = $digest' \
  "$CONFIG_FILE" > "$TMP_FILE"

# Prove that the target image_digest is the only semantic change.
jq -S \
  --arg service "$SERVICE" \
  'del(.ecs_services[$service].image_digest)' \
  "$CONFIG_FILE" > "$BEFORE_NORMALIZED"

jq -S \
  --arg service "$SERVICE" \
  'del(.ecs_services[$service].image_digest)' \
  "$TMP_FILE" > "$AFTER_NORMALIZED"

if ! cmp -s "$BEFORE_NORMALIZED" "$AFTER_NORMALIZED"; then
  fail "Digest update changed configuration outside ecs_services.${SERVICE}.image_digest"
fi

if ! jq -e \
  --arg service "$SERVICE" \
  --arg digest "$IMAGE_DIGEST" \
  '.ecs_services[$service].image_digest == $digest' \
  "$TMP_FILE" >/dev/null; then
  fail "Updated configuration does not contain the requested image digest"
fi

mv "$TMP_FILE" "$CONFIG_FILE"

git -C "$REPO_ROOT" diff --check -- "$REL_CONFIG_FILE"

success "Application digest updated"
printf 'Environment:     %s\n' "$ENVIRONMENT"
printf 'Service:         %s\n' "$SERVICE"
printf 'Previous digest: %s\n' "$CURRENT_DIGEST"
printf 'New digest:      %s\n' "$IMAGE_DIGEST"
printf 'Config file:     %s\n' "$REL_CONFIG_FILE"