#!/usr/bin/env python3
"""Exercise the actual Organizations Plan input guard offline, using only Bash."""

import os
import re
import subprocess
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/terraform-plan.yml"
INPUTS = (
    "ENABLE_SECURITYHUB_DELEGATED_ADMINISTRATOR",
    "ENABLE_GUARDDUTY_DELEGATED_ADMINISTRATOR",
    "ENABLE_SECURITYHUB_V2_ORGANIZATION_MANAGEMENT",
)
STEP = "      - name: Validate Organizations Plan inputs\n"


def main():
    workflow = WORKFLOW.read_text()
    assert workflow.count(STEP) == 1, "Organizations input guard must exist once"
    step = workflow.split(STEP, 1)[1].split("\n      - name:", 1)[0]
    settings, script = step.split("        run: |\n", 1)
    script = textwrap.dedent(script)

    mappings = dict(re.findall(
        r"(?m)^          ([A-Z0-9_]+): \$\{\{ vars\.([A-Z0-9_]+) \}\}$",
        settings,
    ))
    assert mappings == {name: name for name in INPUTS}, "Use the canonical Organizations variables without fallbacks"
    condition = " ".join(settings.split("        if: >-\n", 1)[1].split("        env:", 1)[0].split())
    assert condition == (
        "(github.event_name != 'workflow_dispatch' || "
        "matrix.environment == inputs.target_environment) && "
        "matrix.environment == 'control-plane-organizations'"
    ), "Guard must run only for the selected Organizations job"
    assert """          - environment: control-plane-organizations
            github_environment: control-plane-plan
            working_directory: ./bootstrap/control_plane/organizations""" in workflow
    for next_step in ("Configure AWS credentials from GitHub OIDC", "Terraform Init", "Terraform Plan"):
        assert workflow.index(STEP) < workflow.index("      - name: " + next_step + "\n")

    variables = (ROOT / "bootstrap/control_plane/organizations/variables.tf").read_text()
    for name in INPUTS:
        assert re.search(r'variable "' + name.lower() + r'" \{[^}]*type\s*=\s*bool', variables)
    subprocess.run(["bash", "-n"], input=script, text=True, check=True)

    passed = 0

    def run_case(label, values, reject=None):
        nonlocal passed
        with tempfile.TemporaryDirectory(prefix="organizations-inputs-") as tmp:
            exported = Path(tmp) / "github-env"
            exported.touch()
            env = {"PATH": os.environ["PATH"], "GITHUB_ENV": str(exported), **values}
            result = subprocess.run(["bash", "-c", script], env=env, text=True, capture_output=True)
            output = exported.read_text()
            if reject is not None:
                assert result.returncode != 0, label
                assert "::error::" + reject in result.stdout, label
                assert output == "", "Rejected input must not export a partial configuration: " + label
            else:
                assert result.returncode == 0, (label, result.stdout, result.stderr)
                assert output.splitlines() == [
                    f"TF_VAR_{name.lower()}={values[name]}" for name in INPUTS
                ], label
        passed += 1

    approved = dict.fromkeys(INPUTS, "true")
    run_case("established configuration", approved)
    run_case("explicit bootstrap settings", dict.fromkeys(INPUTS, "false"))
    for name in INPUTS:
        run_case("independent explicit choice: " + name, {**approved, name: "false"})
        run_case("missing: " + name, {k: v for k, v in approved.items() if k != name}, name)
        for invalid in ("", "null"):
            run_case("invalid value: " + name, {**approved, name: invalid}, name)
    for invalid in ("TRUE", "true\nTF_VAR_unexpected=true"):
        run_case("reject non-boolean/injected input", {**approved, INPUTS[0]: invalid}, INPUTS[0])
    run_case("security-operations flags cannot replace management prerequisites", {
        "ENABLE_SECURITYHUB_ORGANIZATION_CONFIGURATION": "true",
        "ENABLE_GUARDDUTY_ORGANIZATION_CONFIGURATION": "true",
        "ENABLE_SECURITYHUB_V2_ORGANIZATION_POLICY": "true",
    }, INPUTS[0])
    print(f"[PASS] Organizations workflow mapping, scope, ordering, and {passed} offline input scenarios.")


if __name__ == "__main__":
    main()
