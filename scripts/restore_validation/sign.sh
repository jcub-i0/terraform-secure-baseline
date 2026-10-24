#!/usr/bin/env bash
# Sign reproducibly packaged Restore Validation Lambda ZIPs with AWS Signer.
# Requires AWS CLI v2, jq, versioned S3 signing bucket, signing profile.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dist="${repo_root}/modules/restore_validation/lambda/dist"
profile="${RESTORE_SIGNING_PROFILE_NAME:?Set RESTORE_SIGNING_PROFILE_NAME}"
bucket="${RESTORE_SIGNING_BUCKET:?Set RESTORE_SIGNING_BUCKET}"
[[ "${RESTORE_VALIDATION_RELEASE:-}" == "true" ]] || { echo 'Refusing to sign: set RESTORE_VALIDATION_RELEASE=true' >&2; exit 2; }
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { echo 'Invalid bucket name' >&2; exit 2; }
[[ "$profile" =~ ^[A-Za-z0-9_]{2,64}$ ]] || { echo 'Invalid AWS Signer profile name' >&2; exit 2; }
command -v aws >/dev/null
command -v jq >/dev/null
command -v unzip >/dev/null
[[ "$(aws s3api get-bucket-versioning --bucket "$bucket" --query Status --output text)" == "Enabled" ]] || {
  echo 'Signer S3 source bucket must have versioning Enabled' >&2; exit 2;
}
[[ -f "${dist}/unsigned-manifest.json" ]] || { echo 'Missing unsigned build manifest' >&2; exit 2; }
jq -e '.deployable == true and .format_version == 1' "${dist}/unsigned-manifest.json" >/dev/null
mkdir -p "${dist}/signed"
signing_jobs='{}'
for name in coordinator worker; do
  unsigned="${dist}/${name}.zip"
  [[ -f "$unsigned" && ! -L "$unsigned" ]] || { echo "Missing unsigned $name ZIP" >&2; exit 2; }
  expected="$(jq -r --arg name "$name" '.artifacts[$name].sha256' "${dist}/unsigned-manifest.json")"
  [[ "$(sha256sum "$unsigned" | awk '{print $1}')" == "$expected" ]] || {
    echo "Unsigned $name ZIP hash differs from manifest" >&2; exit 2;
  }
  [[ "$(unzip -l "$unsigned" | grep -c 'DO_NOT_DEPLOY.TEST_ONLY' || true)" == '0' ]] || {
    echo 'Test-only ZIP cannot be signed for deployment' >&2; exit 2;
  }
  prefix="restore-validation/unsigned/${expected}"
  key="${prefix}/${name}.zip"
  version="$(aws s3api put-object --bucket "$bucket" --key "$key" --body "$unsigned" --query VersionId --output text)"
  [[ -n "$version" && "$version" != "None" ]] || { echo 'S3 did not return an object version ID' >&2; exit 2; }
  job_id="$(aws signer start-signing-job \
     --profile-name "$profile" \
     --source "s3={bucketName=${bucket},key=${key},version=${version}}" \
     --destination "s3={bucketName=${bucket},prefix=restore-validation/signed/}" \
     --query jobId --output text)"
  [[ "$job_id" =~ ^[0-9A-Za-z-]{15,80}$ ]] || { echo 'Invalid signing job ID' >&2; exit 2; }
  status=''
  for attempt in $(seq 1 30); do
    status="$(aws signer describe-signing-job --job-id "$job_id" --query status --output text)"
    case "$status" in
      Succeeded) break ;;
      Failed|Revoked) echo "AWS Signer did not sign $name: $status" >&2; exit 1 ;;
      *) sleep 2 ;;
    esac
  done
  [[ "$status" == "Succeeded" ]] || { echo "Signing job timed out for $name" >&2; exit 1; }
  signed_info="$(aws signer describe-signing-job --job-id "$job_id" --query signedObject.s3 --output json)"
  signed_bucket="$(jq -r '.bucketName // empty' <<<"$signed_info")"
  signed_key="$(jq -r '.key // empty' <<<"$signed_info")"
  [[ "$signed_bucket" == "$bucket" && "$signed_key" == restore-validation/signed/* ]] || {
    echo 'Unexpected signed artifact location' >&2; exit 2;
  }
  target="${dist}/signed/${name}.zip"
  aws s3api get-object --bucket "$signed_bucket" --key "$signed_key" "$target" >/dev/null
  unzip -t "$target" >/dev/null
  signed_sha="$(sha256sum "$target" | awk '{print $1}')"
  signing_jobs="$(jq -cn --argjson prev "$signing_jobs" --arg name "$name" --arg job_id "$job_id" \
    --arg sha256 "$signed_sha" --arg key "$signed_key" '$prev + {($name): {signing_job_id:$job_id, sha256:$sha256, s3_key:$key}}')"
  echo "Verified signed ${name} artifact sha256=${signed_sha}"
done
jq -n --arg profile "$profile" --arg bucket "$bucket" --argjson jobs "$signing_jobs" \
   '{format_version:1,signing_profile:$profile,bucket:$bucket,artifacts:$jobs}' > "${dist}/signed-manifest.json"
