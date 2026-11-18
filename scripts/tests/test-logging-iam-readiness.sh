#!/usr/bin/env bash
set -euo pipefail

# Regression: replacing IAM output dependencies with local role ARNs must not
# let a logging service start before its inline delivery policy is attached.
# Run after `terraform -chdir=baseline init -backend=false -lockfile=readonly`.
# `graph -type=plan` builds the configuration graph; it does not execute a plan,
# refresh state, or call AWS. Graph construction also rejects dependency cycles.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
graph="$(mktemp)"
trap 'rm -f "$graph"' EXIT

terraform -chdir="$repo_root/baseline" graph -type=plan >"$graph"

while read -r service policy; do
  edge="\"[root] module.logging.${service} (expand)\" -> \"[root] module.logging.aws_iam_role_policy.${policy} (expand)\""
  if ! grep -Fq -- "$edge" "$graph"; then
    echo "[FAIL] ${service} must depend on its inline IAM policy (${policy})." >&2
    exit 1
  fi
done <<'EDGES'
aws_cloudtrail.cloudtrail cloudtrail
aws_flow_log.flowlogs flowlogs
aws_kinesis_firehose_delivery_stream.flowlogs firehose_flow_logs
aws_cloudwatch_log_subscription_filter.flowlogs cw_to_firehose
EDGES

echo "[PASS] Four logging IAM policy-readiness dependencies; baseline graph is acyclic."
