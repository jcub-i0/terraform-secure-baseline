#!/usr/bin/env bash
set -euo pipefail

# M1-A3 regression: execute the actual baseline variable validations and locals
# in a provider-free Terraform fixture. Tests run plan-only without AWS
# credentials, deployed state, or resource mutations.
# Usage: bash scripts/tests/test-rds-restore-opt-in.sh

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
command -v terraform >/dev/null || { echo '[FAIL] Terraform CLI is required' >&2; exit 1; }
command -v python3 >/dev/null || { echo '[FAIL] Python 3 is required' >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tests"

python3 - "$root" "$tmp" <<'PY'
from pathlib import Path
import re
import sys

root, temp = map(Path, sys.argv[1:])
variables = (root / "baseline/variables.tf").read_text()
locals_hcl = (root / "baseline/locals.tf").read_text()


def extract_block(text: str, marker: str, open_char: str, close_char: str) -> str:
    lines = text.splitlines(keepends=True)
    indexes = [i for i, line in enumerate(lines) if line.startswith(marker)]
    if len(indexes) != 1:
        raise SystemExit(f"[FAIL] Expected exactly one declaration: {marker}")
    result = []
    depth = 0
    for line in lines[indexes[0]:]:
        result.append(line)
        depth += line.count(open_char) - line.count(close_char)
        if depth == 0:
            return "".join(result)
    raise SystemExit(f"[FAIL] Unclosed declaration: {marker}")


var_names = (
    "deployment_profile", "backup_enabled", "restore_testing_enabled", "restore_testing_schedule"
)
blocks = [extract_block(variables, f'variable "{name}" {{', "{", "}") for name in var_names]

is_production = re.findall(r"(?m)^  is_production_profile\s*=.*$", locals_hcl)
if len(is_production) != 1:
    raise SystemExit("[FAIL] Cannot find unique is_production_profile definition")

local_names = (
    "effective_backup_enabled", "effective_restore_testing_enabled", "effective_restore_testing_schedule"
)
expressions = [extract_block(locals_hcl, f"  {name} = (", "(", ")") for name in local_names]

(temp / "main.tf").write_text(
    'terraform { required_version = ">= 1.9.0" }\n\n'
    + "\n".join(blocks)
    + "\nlocals {\n"
    + is_production[0]
    + "\n"
    + "".join(expressions)
    + "}\n\n"
    + 'output "enabled" { value = local.effective_restore_testing_enabled }\n'
    + 'output "schedule" { value = local.effective_restore_testing_schedule }\n'
)
PY

cat > "$tmp/tests/restore-opt-in.tftest.hcl" <<'TEST'
run "production_default" {
  command = plan
  variables { deployment_profile = "production" }
  assert {
    condition     = output.enabled == true && output.schedule == "cron(0 8 ? * SUN *)"
    error_message = "Production defaults must preserve weekly Restore Testing"
  }
}

run "development_default" {
  command = plan
  variables { deployment_profile = "development" }
  assert {
    condition     = output.enabled == false && output.schedule == null
    error_message = "Development defaults must disable Restore Testing"
  }
}

run "minimal_default" {
  command = plan
  variables { deployment_profile = "minimal" }
  assert {
    condition     = output.enabled == false && output.schedule == null
    error_message = "Minimal defaults must disable Restore Testing"
  }
}

run "nonproduction_backups_only" {
  command = plan
  variables {
    deployment_profile = "development"
    backup_enabled     = true
  }
  assert {
    condition     = output.enabled == false && output.schedule == null
    error_message = "Enabling backups alone must not enable Restore Testing"
  }
}

run "development_explicit_opt_in" {
  command = plan
  variables {
    deployment_profile       = "development"
    backup_enabled           = true
    restore_testing_enabled  = true
    restore_testing_schedule = "cron(0 9 ? * MON *)"
  }
  assert {
    condition     = output.enabled == true && output.schedule == "cron(0 9 ? * MON *)"
    error_message = "Explicit development opt-in and schedule must be honored"
  }
}

run "minimal_explicit_opt_in" {
  command = plan
  variables {
    deployment_profile      = "minimal"
    backup_enabled          = true
    restore_testing_enabled = true
  }
  assert {
    condition     = output.enabled == true && output.schedule == "cron(0 8 ? * SUN *)"
    error_message = "Explicit minimal opt-in must use the existing weekly default"
  }
}

run "production_explicit_opt_out" {
  command = plan
  variables {
    deployment_profile      = "production"
    restore_testing_enabled = false
  }
  assert {
    condition     = output.enabled == false && output.schedule == null
    error_message = "Explicit production opt-out must disable Restore Testing"
  }
}

run "production_backup_disabled" {
  command = plan
  variables {
    deployment_profile = "production"
    backup_enabled     = false
  }
  assert {
    condition     = output.enabled == false && output.schedule == null
    error_message = "Disabling backups must disable default Restore Testing"
  }
}

run "reject_nonprod_optin_without_backup" {
  command = plan
  variables {
    deployment_profile      = "development"
    restore_testing_enabled = true
  }
  expect_failures = [var.restore_testing_enabled]
}

run "reject_production_optin_without_backup" {
  command = plan
  variables {
    deployment_profile      = "production"
    backup_enabled          = false
    restore_testing_enabled = true
  }
  expect_failures = [var.restore_testing_enabled]
}

run "reject_schedule_with_restore_testing_off" {
  command = plan
  variables {
    deployment_profile       = "development"
    restore_testing_schedule = "cron(0 9 ? * MON *)"
  }
  expect_failures = [var.restore_testing_schedule]
}

run "reject_malformed_cron" {
  command = plan
  variables {
    deployment_profile       = "development"
    backup_enabled           = true
    restore_testing_enabled  = true
    restore_testing_schedule = "every Monday"
  }
  expect_failures = [var.restore_testing_schedule]
}
TEST

terraform -chdir="$tmp" init -backend=false -input=false -no-color >/dev/null
terraform -chdir="$tmp" test -no-color
