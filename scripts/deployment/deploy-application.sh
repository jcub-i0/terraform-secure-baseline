#!/usr/bin/env bash
set -euo pipefail

export AWS_PAGER=""

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------

info() {
  printf '[INFO] %s\n' "$*"
}

success() {
  printf '[PASS] %s\n' "$*"
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
# Validation helpers
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

require_non_empty() {
  local value="$1"
  local description="$2"

  if [[ -z "$value" ]]; then
    fail "${description} must not be empty"
  fi
}

require_environment() {
  local environment="$1"

  case "$environment" in
    dev|staging|prod)
      ;;
    *)
      fail \
        "Invalid environment: ${environment}. Expected one of: dev, staging, prod."
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Usage
# -----------------------------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage:
  deploy-application.sh publish [options]

Publish an application image to an existing Terraform-managed ECR repository.

Required:
  --environment <dev|staging|prod>
  --service <service-name>
  --repository-name <repository-name>
  --build-context <path>

Optional:
  --dockerfile <path>            Dockerfile path relative to the build context.
                                 Default: Dockerfile
  --image-tag <tag>              Immutable publication tag.
                                 Default: sha-<git-commit>
  --platform <platform>          Container platform.
                                 Default: linux/amd64
  --cloud-name <name>            Baseline cloud name.
                                 Default: $CLOUD_NAME or tf-secure-baseline
  --region <region>              AWS Region.
                                 Default: $AWS_REGION or us-east-1
  --profile <profile>            AWS CLI profile.
                                 Default: $AWS_PROFILE
  --expected-account-id <id>     Expected 12-digit AWS account ID.
                                 Default: $EXPECTED_ACCOUNT_ID
  --metadata-file <path>         Write machine-readable publication metadata.

Examples:
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID=955775177042 \
  ./scripts/deployment/deploy-application.sh publish \
    --environment dev \
    --service api \
    --repository-name api \
    --build-context ../my-application

  ./scripts/deployment/deploy-application.sh publish \
    --environment dev \
    --service api \
    --repository-name api \
    --build-context ../my-application \
    --dockerfile docker/Dockerfile \
    --image-tag v1.0.0 \
    --metadata-file /tmp/api-image.json
USAGE
}

# -----------------------------------------------------------------------------
# Request
# -----------------------------------------------------------------------------

OPERATION="${1:-}"

if [[ -z "$OPERATION" ]]; then
  usage
  exit 1
fi

shift

case "$OPERATION" in
  publish)
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    fail "Unsupported operation: ${OPERATION}. Expected: publish"
    ;;
esac

ENVIRONMENT=""
SERVICE=""
REPOSITORY_KEY=""
BUILD_CONTEXT=""
DOCKERFILE="Dockerfile"
IMAGE_TAG=""
PLATFORM="linux/amd64"

CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
AWS_REGION="${AWS_REGION:-us-east-1}"
AWS_PROFILE="${AWS_PROFILE:-}"
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:-}"

METADATA_FILE=""

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
    --repository-name)
      [[ $# -ge 2 ]] || fail "--repository-name requires a value"
      REPOSITORY_KEY="$2"
      shift 2
      ;;
    --build-context)
      [[ $# -ge 2 ]] || fail "--build-context requires a value"
      BUILD_CONTEXT="$2"
      shift 2
      ;;
    --dockerfile)
      [[ $# -ge 2 ]] || fail "--dockerfile requires a value"
      DOCKERFILE="$2"
      shift 2
      ;;
    --image-tag)
      [[ $# -ge 2 ]] || fail "--image-tag requires a value"
      IMAGE_TAG="$2"
      shift 2
      ;;
    --platform)
      [[ $# -ge 2 ]] || fail "--platform requires a value"
      PLATFORM="$2"
      shift 2
      ;;
    --cloud-name)
      [[ $# -ge 2 ]] || fail "--cloud-name requires a value"
      CLOUD_NAME="$2"
      shift 2
      ;;
    --region)
      [[ $# -ge 2 ]] || fail "--region requires a value"
      AWS_REGION="$2"
      shift 2
      ;;
    --profile)
      [[ $# -ge 2 ]] || fail "--profile requires a value"
      AWS_PROFILE="$2"
      shift 2
      ;;
    --expected-account-id)
      [[ $# -ge 2 ]] || fail "--expected-account-id requires a value"
      EXPECTED_ACCOUNT_ID="$2"
      shift 2
      ;;
    --metadata-file)
      [[ $# -ge 2 ]] || fail "--metadata-file requires a value"
      METADATA_FILE="$2"
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

# -----------------------------------------------------------------------------
# Validate request
# -----------------------------------------------------------------------------

section "Validating application publication request"

require_non_empty "$ENVIRONMENT" "environment"
require_non_empty "$SERVICE" "service"
require_non_empty "$REPOSITORY_KEY" "repository-name"
require_non_empty "$BUILD_CONTEXT" "build-context"
require_non_empty "$CLOUD_NAME" "cloud-name"
require_non_empty "$AWS_REGION" "region"

require_environment "$ENVIRONMENT"

if [[ ! "$SERVICE" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  fail \
    "service must use lowercase letters and numbers separated only by periods, underscores, or hyphens"
fi

if [[ ! "$REPOSITORY_KEY" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  fail \
    "repository-name must use lowercase letters and numbers separated only by periods, underscores, or hyphens"
fi

if [[ ! "$CLOUD_NAME" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]]; then
  fail \
    "cloud-name must use lowercase letters and numbers separated only by periods, underscores, or hyphens"
fi

case "$PLATFORM" in
  linux/amd64|linux/arm64)
    ;;
  *)
    fail "platform must be linux/amd64 or linux/arm64"
    ;;
esac

if [[ -n "$EXPECTED_ACCOUNT_ID" &&
      ! "$EXPECTED_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  fail "expected-account-id must contain exactly 12 digits"
fi

require_directory "$BUILD_CONTEXT"

BUILD_CONTEXT="$(
  cd "$BUILD_CONTEXT"
  pwd
)"

if [[ "$DOCKERFILE" = /* ]]; then
  DOCKERFILE_PATH="$DOCKERFILE"
else
  DOCKERFILE_PATH="${BUILD_CONTEXT}/${DOCKERFILE}"
fi

require_file "$DOCKERFILE_PATH"

success "Application publication request is valid"

# -----------------------------------------------------------------------------
# Required commands
# -----------------------------------------------------------------------------

section "Checking required local commands"

require_command aws
success "aws CLI found"

require_command docker
success "docker found"

require_command jq
success "jq found"

# -----------------------------------------------------------------------------
# Source provenance / default tag
# -----------------------------------------------------------------------------

SOURCE_COMMIT=""
SOURCE_DIRTY="false"

if command -v git >/dev/null 2>&1 &&
   git -C "$BUILD_CONTEXT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_COMMIT="$(
    git -C "$BUILD_CONTEXT" rev-parse HEAD
  )"

  if [[ -n "$(git -C "$BUILD_CONTEXT" status --porcelain)" ]]; then
    SOURCE_DIRTY="true"
  fi
fi

if [[ -z "$IMAGE_TAG" ]]; then
  if [[ -z "$SOURCE_COMMIT" ]]; then
    fail \
      "Unable to derive an image tag because the build context is not a Git repository. Supply --image-tag explicitly."
  fi

  if [[ "$SOURCE_DIRTY" == "true" ]]; then
    fail \
      "Build-context Git working tree is dirty. Commit the source or supply --image-tag explicitly."
  fi

  IMAGE_TAG="sha-${SOURCE_COMMIT}"
fi

if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; then
  fail "image-tag is not a valid Docker image tag"
fi

info "Source commit: ${SOURCE_COMMIT:-<not available>}"
info "Source dirty: ${SOURCE_DIRTY}"
info "Image tag: ${IMAGE_TAG}"

# -----------------------------------------------------------------------------
# AWS identity
# -----------------------------------------------------------------------------

AWS_ARGS=()

if [[ -n "$AWS_PROFILE" ]]; then
  AWS_ARGS+=(--profile "$AWS_PROFILE")
fi

AWS_ARGS+=(--region "$AWS_REGION")

section "Checking AWS caller identity"

ACCOUNT_ID="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query Account \
    --output text
)"

CALLER_ARN="$(
  aws sts get-caller-identity \
    "${AWS_ARGS[@]}" \
    --query Arn \
    --output text
)"

if [[ ! "$ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  fail "Unable to resolve a valid AWS account ID"
fi

if [[ -n "$EXPECTED_ACCOUNT_ID" &&
      "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail \
    "AWS account mismatch. Expected ${EXPECTED_ACCOUNT_ID}, got ${ACCOUNT_ID}"
fi

success "AWS credentials are valid"
info "AWS account ID: ${ACCOUNT_ID}"
info "AWS caller ARN: ${CALLER_ARN}"
info "AWS Region: ${AWS_REGION}"

# -----------------------------------------------------------------------------
# Resolve Terraform-owned ECR repository
# -----------------------------------------------------------------------------

ECR_REPOSITORY_NAME="${CLOUD_NAME}-${ENVIRONMENT}-${REPOSITORY_KEY}"

section "Resolving existing ECR repository"

info "Repository key: ${REPOSITORY_KEY}"
info "Expected repository name: ${ECR_REPOSITORY_NAME}"

if ! REPOSITORY_JSON="$(
  aws ecr describe-repositories \
    "${AWS_ARGS[@]}" \
    --repository-names "$ECR_REPOSITORY_NAME" \
    --output json
)"; then
  fail \
    "ECR repository ${ECR_REPOSITORY_NAME} does not exist or is not accessible. Provision the repository through Terraform before publishing an image."
fi

if [[ "$(jq '.repositories | length' <<< "$REPOSITORY_JSON")" -ne 1 ]]; then
  fail \
    "Expected exactly one ECR repository for ${ECR_REPOSITORY_NAME}"
fi

REGISTRY_ID="$(
  jq -r '.repositories[0].registryId // empty' \
    <<< "$REPOSITORY_JSON"
)"

REPOSITORY_URI="$(
  jq -r '.repositories[0].repositoryUri // empty' \
    <<< "$REPOSITORY_JSON"
)"

require_non_empty "$REGISTRY_ID" "ECR registry ID"
require_non_empty "$REPOSITORY_URI" "ECR repository URI"

if [[ "$REGISTRY_ID" != "$ACCOUNT_ID" ]]; then
  fail \
    "ECR repository belongs to account ${REGISTRY_ID}, but active AWS account is ${ACCOUNT_ID}"
fi

REGISTRY_HOST="${REPOSITORY_URI%%/*}"

success "Terraform-owned ECR repository exists"
info "Repository URI: ${REPOSITORY_URI}"

# -----------------------------------------------------------------------------
# Enforce immutable publication tag
# -----------------------------------------------------------------------------

section "Checking immutable image tag"

TAG_LOOKUP_JSON="$(
  aws ecr batch-get-image \
    "${AWS_ARGS[@]}" \
    --repository-name "$ECR_REPOSITORY_NAME" \
    --image-ids "imageTag=${IMAGE_TAG}" \
    --output json
)"

if jq -e '.images | length > 0' \
  <<< "$TAG_LOOKUP_JSON" >/dev/null; then

  EXISTING_DIGEST="$(
    jq -r '.images[0].imageId.imageDigest // "<unknown>"' \
      <<< "$TAG_LOOKUP_JSON"
  )"

  fail \
    "Image tag ${IMAGE_TAG} already exists in ${ECR_REPOSITORY_NAME} with digest ${EXISTING_DIGEST}. ECR tags are immutable; use a new tag."
fi

if ! jq -e '
  (.failures | length == 0) or
  all(.failures[]; .failureCode == "ImageNotFound")
' <<< "$TAG_LOOKUP_JSON" >/dev/null; then
  jq . <<< "$TAG_LOOKUP_JSON" >&2
  fail "Unable to prove that image tag ${IMAGE_TAG} is unused"
fi

success "Image tag is available: ${IMAGE_TAG}"

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

TAGGED_IMAGE_URI="${REPOSITORY_URI}:${IMAGE_TAG}"

section "Building application image"

info "Service: ${SERVICE}"
info "Build context: ${BUILD_CONTEXT}"
info "Dockerfile: ${DOCKERFILE_PATH}"
info "Platform: ${PLATFORM}"
info "Image: ${TAGGED_IMAGE_URI}"

docker build \
  --platform "$PLATFORM" \
  --file "$DOCKERFILE_PATH" \
  --tag "$TAGGED_IMAGE_URI" \
  "$BUILD_CONTEXT"

success "Application image built successfully"

# -----------------------------------------------------------------------------
# Authenticate and push
# -----------------------------------------------------------------------------

section "Authenticating Docker to Amazon ECR"

aws ecr get-login-password \
  "${AWS_ARGS[@]}" |
  docker login \
    --username AWS \
    --password-stdin \
    "$REGISTRY_HOST"

success "Docker authenticated to ECR"

section "Publishing application image"

docker push "$TAGGED_IMAGE_URI"

success "Application image pushed to ECR"

# -----------------------------------------------------------------------------
# Resolve authoritative ECR digest
# -----------------------------------------------------------------------------

section "Resolving authoritative ECR image digest"

IMAGE_DIGEST=""

for ((attempt = 1; attempt <= 10; attempt++)); do
  candidate_digest="$(
    aws ecr describe-images \
      "${AWS_ARGS[@]}" \
      --repository-name "$ECR_REPOSITORY_NAME" \
      --image-ids "imageTag=${IMAGE_TAG}" \
      --query 'imageDetails[0].imageDigest' \
      --output text \
      2>/dev/null ||
      true
  )"

  if [[ "$candidate_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    IMAGE_DIGEST="$candidate_digest"
    break
  fi

  if [[ "$attempt" -lt 10 ]]; then
    sleep 2
  fi
done

if [[ ! "$IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  fail \
    "Unable to resolve an authoritative sha256 digest from ECR for ${ECR_REPOSITORY_NAME}:${IMAGE_TAG}"
fi

DIGEST_IMAGE_URI="${REPOSITORY_URI}@${IMAGE_DIGEST}"

success "Authoritative ECR digest resolved"
info "Image digest: ${IMAGE_DIGEST}"
info "Digest-pinned image URI: ${DIGEST_IMAGE_URI}"

# -----------------------------------------------------------------------------
# Machine-readable metadata
# -----------------------------------------------------------------------------

PUBLISHED_AT_UTC="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ -n "$METADATA_FILE" ]]; then
  METADATA_DIRECTORY="$(dirname "$METADATA_FILE")"
  mkdir -p "$METADATA_DIRECTORY"

  jq -n \
    --arg environment "$ENVIRONMENT" \
    --arg service "$SERVICE" \
    --arg cloud_name "$CLOUD_NAME" \
    --arg repository_key "$REPOSITORY_KEY" \
    --arg ecr_repository_name "$ECR_REPOSITORY_NAME" \
    --arg repository_uri "$REPOSITORY_URI" \
    --arg registry_id "$REGISTRY_ID" \
    --arg aws_region "$AWS_REGION" \
    --arg source_commit "$SOURCE_COMMIT" \
    --argjson source_dirty "$SOURCE_DIRTY" \
    --arg build_context "$BUILD_CONTEXT" \
    --arg dockerfile "$DOCKERFILE_PATH" \
    --arg platform "$PLATFORM" \
    --arg image_tag "$IMAGE_TAG" \
    --arg image_digest "$IMAGE_DIGEST" \
    --arg tagged_image_uri "$TAGGED_IMAGE_URI" \
    --arg digest_image_uri "$DIGEST_IMAGE_URI" \
    --arg published_at_utc "$PUBLISHED_AT_UTC" \
    '{
      environment: $environment,
      service: $service,
      cloud_name: $cloud_name,
      repository_key: $repository_key,
      ecr_repository_name: $ecr_repository_name,
      repository_uri: $repository_uri,
      registry_id: $registry_id,
      aws_region: $aws_region,
      source_commit: (
        if $source_commit == ""
        then null
        else $source_commit
        end
      ),
      source_dirty: $source_dirty,
      build_context: $build_context,
      dockerfile: $dockerfile,
      platform: $platform,
      image_tag: $image_tag,
      image_digest: $image_digest,
      tagged_image_uri: $tagged_image_uri,
      digest_image_uri: $digest_image_uri,
      published_at_utc: $published_at_utc
    }' > "$METADATA_FILE"

  success "Publication metadata written: ${METADATA_FILE}"
fi

# -----------------------------------------------------------------------------
# Result
# -----------------------------------------------------------------------------

section "Application Image Publish Result"

cat <<RESULT
Environment:             ${ENVIRONMENT}
Service:                 ${SERVICE}
Repository key:          ${REPOSITORY_KEY}
ECR repository:          ${ECR_REPOSITORY_NAME}
Image tag:               ${IMAGE_TAG}
Image digest:            ${IMAGE_DIGEST}
Digest-pinned image URI: ${DIGEST_IMAGE_URI}
AWS account:             ${ACCOUNT_ID}
AWS Region:              ${AWS_REGION}
Platform:                ${PLATFORM}
Metadata file:           ${METADATA_FILE:-<not requested>}
RESULT

success "Application image publication completed successfully"