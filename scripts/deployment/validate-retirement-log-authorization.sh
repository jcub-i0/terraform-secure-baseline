#!/usr/bin/env bash
set -euo pipefail

# Fail closed on the production audit-log disposition decision before any
# durable-data cleanup. This verifies an operator attestation and record ID;
# it does NOT independently verify an external log archive or its KMS keys.

fail() { printf '[FAIL] %s\n' "$*" >&2; exit 1; }

profile="${DEPLOYMENT_PROFILE:-}"
confirmed="${AUDIT_LOG_DISPOSITION_CONFIRMED:-false}"
reference="${AUDIT_LOG_DISPOSITION_REFERENCE:-}"

case "$profile" in
  production)
    [[ "$confirmed" == "true" ]] ||
      fail 'Production destruction requires confirm_audit_log_disposition=true.'
    [[ "$reference" =~ [^[:space:]] ]] ||
      fail 'Production destruction requires an approved audit_log_disposition_reference.'
    [[ "$reference" =~ ^[A-Za-z0-9][A-Za-z0-9._:/#-]{3,199}$ ]] ||
      fail 'Audit-log disposition reference must be a 4-200 character ticket/record ID (letters, digits, . _ : / # - only).'
    case "${reference,,}" in
      todo|tbd|none|null|n/a|na|test|placeholder)
        fail 'Audit-log disposition reference cannot be a placeholder.' ;;
    esac
    printf '[PASS] Production audit-log disposition acknowledged; approved record: %s\n' "$reference"
    ;;
  development|minimal)
    [[ "$confirmed" == "false" && -z "$reference" ]] ||
      fail 'Audit-log disposition inputs are production-only and must be unset for non-production.'
    printf '[PASS] Non-production audit-log disposition inputs are unset.\n'
    ;;
  *) fail "Unknown deployment profile: $profile" ;;
esac
