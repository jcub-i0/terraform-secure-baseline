#!/usr/bin/env bash
# Pair the exact signed Lambda artifacts with the reviewed Terraform saved plan.
# Plan: stage hashes into the saved plan's sha256 manifest.
# Apply: only after the saved-plan verifier succeeds, restore verified ZIPs.
set -euo pipefail

mode="${1:?Expected plan or apply}"
artifact_dir="${2:?Expected saved-plan artifact directory}"
plan_basename="${3:?Expected saved-plan basename}"
restore_validation_enabled="${4:?Expected explicit restore-validation enabled flag true or false}"
case "$restore_validation_enabled" in
  true|false) ;;
  *) echo "Restore Validation flag must be true or false" >&2; exit 2 ;;
esac
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source_dir="${RESTORE_VALIDATION_SIGNED_DIR:-${repo_root}/modules/restore_validation/lambda/dist/signed}"
staged="${artifact_dir}/lambda/restore_validation"

verify_signed() {
  local folder="$1"
  [[ -f "${folder}/signed-manifest.json" && ! -L "${folder}/signed-manifest.json" ]] || {
    echo 'Missing signed manifest' >&2; exit 1;
  }
  jq -e '.format_version == 1 and (.signing_profile | type == "string") and
     (.artifacts | keys | sort == ["coordinator", "worker"])' "${folder}/signed-manifest.json" >/dev/null
  local name sha
  for name in coordinator worker; do
    [[ -f "${folder}/${name}.zip" && ! -L "${folder}/${name}.zip" ]] || {
      echo "Missing signed ${name}.zip" >&2; exit 1;
    }
    sha="$(jq -r --arg name "$name" '.artifacts[$name].sha256' "${folder}/signed-manifest.json")"
    [[ "${sha}" =~ ^[a-f0-9]{64}$ ]] || { echo "Invalid ${name} checksum" >&2; exit 1; }
    [[ "$(sha256sum "${folder}/${name}.zip" | awk '{print $1}')" == "$sha" ]] || {
      echo "Signed ${name} artifact checksum mismatch" >&2; exit 1;
    }
    unzip -t "${folder}/${name}.zip" >/dev/null
  done
}

# Never infer feature activation from the presence or absence of artifacts.
# Disabled deployments must not silently ship leftover signed packages.
if [[ "$restore_validation_enabled" == "false" ]]; then
  case "$mode" in plan|apply) ;; *) echo "Mode must be plan or apply" >&2; exit 2 ;; esac
  if [[ -e "$source_dir" || -L "$source_dir" || -e "$staged" || -L "$staged" ]]; then
    echo "Restore Validation disabled but signed artifacts exist; refusing ambiguous artifact state" >&2
    exit 1
  fi
  exit 0
fi

case "$mode" in
  plan)
    [[ -d "$source_dir" && ! -L "$source_dir" ]] || { echo "Enabled restore validation requires signed Plan artifacts" >&2; exit 1; }
    verify_signed "$source_dir"
    [[ -f "${artifact_dir}/${plan_basename}-plan.sha256" ]] || exit 1
    mkdir -p "$staged"
    for name in coordinator worker; do
      install -m 0600 "${source_dir}/${name}.zip" "${staged}/${name}.zip"
    done
    install -m 0600 "${source_dir}/signed-manifest.json" "${staged}/signed-manifest.json"
    (
      cd "$artifact_dir"
      sha256sum \
        lambda/restore_validation/coordinator.zip \
        lambda/restore_validation/worker.zip \
        lambda/restore_validation/signed-manifest.json >> "${plan_basename}-plan.sha256"
      sha256sum --check "${plan_basename}-plan.sha256" >/dev/null
    )
    ;;
  apply)
    [[ -d "$staged" && ! -L "$staged" ]] || { echo "Enabled restore validation requires signed artifacts in the reviewed plan" >&2; exit 1; }
    # The parent protected workflow MUST verify saved plan manifest first.
    verify_signed "$staged"
    mkdir -p "$source_dir"
    for name in coordinator worker; do
      install -m 0600 "${staged}/${name}.zip" "${source_dir}/${name}.zip"
    done
    install -m 0600 "${staged}/signed-manifest.json" "${source_dir}/signed-manifest.json"
    ;;
  *) echo 'Mode must be plan or apply' >&2; exit 2 ;;
esac
