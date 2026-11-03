#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Exercise the actual backup-job block without mocking the whole validator.
awk '
  /^section "Reporting recent backup jobs"$/ { capture = 1 }
  capture && /^FAILED_BACKUP_JOB_COUNT=/ { exit }
  capture { print }
' "$root/scripts/validation/validate-backup.sh" > "$tmp/production-block.sh"

if ! grep -q '^BACKUP_JOB_COUNT=' "$tmp/production-block.sh"; then
  echo "[FAIL] Could not isolate production backup-job handling" >&2
  exit 1
fi

run_case() {
  local label="$1" expectation="$2" exit_code="$3" response="$4" expected_text="$5"
  local actual=0

  MOCK_EXIT_CODE="$exit_code" MOCK_RESPONSE="$response" \
    bash -c '
      set -euo pipefail
      BACKUP_VAULT_NAME="test-vault"
      aws_args=()
      aws() {
        [[ "$1" == backup && "$2" == list-backup-jobs ]] || return 99
        if [[ "$MOCK_EXIT_CODE" != 0 ]]; then
          echo "Simulated AWS CLI error" >&2
          return "$MOCK_EXIT_CODE"
        fi
        printf "%s\n" "$MOCK_RESPONSE"
      }
      section() { :; }
      success() { echo "[PASS] $*"; }
      warn() { echo "[WARN] $*"; }
      fail() { echo "[FAIL] $*" >&2; exit 1; }
      source "$1"
      echo "COUNT=$BACKUP_JOB_COUNT"
    ' _ "$tmp/production-block.sh" >"$tmp/output" 2>&1 || actual=$?

  if [[ "$expectation" == pass && "$actual" -ne 0 ]] ||
     [[ "$expectation" == fail && "$actual" -eq 0 ]] ||
     ! grep -Fq "$expected_text" "$tmp/output"; then
    echo "[FAIL] $label (exit=$actual)" >&2
    cat "$tmp/output" >&2
    exit 1
  fi

  echo "[PASS] $label"
}

run_case "AWS CLI error fails closed" fail 42 "" "Unable to list AWS Backup jobs"
run_case "Empty job history retains warning" pass 0 '{"BackupJobs":[]}' "[WARN] No recent backup jobs found"
run_case "Nonempty job history succeeds" pass 0 '{"BackupJobs":[{"BackupJobId":"test"}]}' "COUNT=1"
run_case "Missing BackupJobs fails" fail 0 '{"Other":[]}' "Invalid AWS Backup job response"
run_case "Malformed JSON fails" fail 0 '{invalid' "Invalid AWS Backup job response"

echo "[PASS] 5 backup-job handling scenarios"
