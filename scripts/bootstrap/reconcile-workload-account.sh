#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  reconsile-workload-account.sh <dev|staging|prod> [options]

Options:
  --apply               Apply the generated Terraform plan.
                        Without this option, the script is plan-only.
  --auto-approve        Skip the interactive confirmation before apply.
                        Requires --apply.
  --skip-validation     Skip strict bootstrap validation after apply.
  -h, --help            Show this help message.

Examples:
  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconsile-workload-account.sh dev

  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  EXPECTED_GITHUB_REPOSITORY="<OWNER>/<REPOSITORY>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev --apply

  AWS_PROFILE=dev \
  EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
  ./scripts/bootstrap/reconcile-workload-account.sh dev \
    --apply \
    --auto-approve
USAGE
}