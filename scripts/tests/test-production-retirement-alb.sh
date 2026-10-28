#!/usr/bin/env bash
set -euo pipefail

# Fast offline Stage-1 retirement contract tests. Terraform is mocked.
root="$(cd "$(dirname "$0")/../.." && pwd)"
guard="$root/scripts/deployment/validate-production-retirement-plan.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/root"
touch "$tmp/root/retirement.tfplan"

cat >"$tmp/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
[[ "$1" == -chdir=* && "$2" == show && "$3" == -json && "$4" == *.tfplan ]] || exit 2
cat "$MOCK_PLAN_JSON"
MOCK
chmod +x "$tmp/bin/terraform"

jq -n '{
  resource_changes: [],
  planned_values: {outputs: {
    deployment_profile: {value:"production"},
    lifecycle_protection: {value:{
      production_retirement_mode:true,
      rds_deletion_protection:false,
      alb_deletion_protection:false,
      network_firewall_delete_protection:false,
      ecr_force_delete:false,
      ecs_service_force_delete:false,
      backup_vault_force_destroy:false,
      centralized_logs_force_destroy:true,
      alb_access_logs_force_destroy:true
    }},
    ecs_service_configuration: {value:{}}
  }}
}' >"$tmp/valid.json"

passed=0
check() {
  local expected="$1" label="$2" plan="$3" rc=0
  MOCK_PLAN_JSON="$plan" PATH="$tmp/bin:$PATH" bash "$guard" \
    --working-directory "$tmp/root" --plan-file "$tmp/root/retirement.tfplan" \
    >"$tmp/out" 2>&1 || rc=$?
  if [[ "$expected" == pass && "$rc" -ne 0 ]] ||
     [[ "$expected" == fail && "$rc" -eq 0 ]]; then
    printf '[FAIL] %s (expected %s, exit=%s)\n' "$label" "$expected" "$rc" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

check pass "Complete production retirement posture" "$tmp/valid.json"
jq '.planned_values.outputs.lifecycle_protection.value.alb_access_logs_force_destroy = false' \
  "$tmp/valid.json" >"$tmp/alb-not-ready.json"
check fail "ALB bucket force_destroy=false rejected" "$tmp/alb-not-ready.json"
jq 'del(.planned_values.outputs.lifecycle_protection.value.alb_access_logs_force_destroy)' \
  "$tmp/valid.json" >"$tmp/alb-missing.json"
check fail "Missing ALB lifecycle field rejected" "$tmp/alb-missing.json"
jq '.planned_values.outputs.deployment_profile.value = "development"' \
  "$tmp/valid.json" >"$tmp/profile.json"
check fail "Production profile downgrade rejected" "$tmp/profile.json"
jq '.resource_changes = [{address:"module.baseline.aws_s3_bucket.test",change:{actions:["delete"]}}]' \
  "$tmp/valid.json" >"$tmp/destructive.json"
check fail "Stage-1 deletion rejected" "$tmp/destructive.json"

printf '[PASS] %d offline Stage-1 ALB retirement plan cases.\n' "$passed"
