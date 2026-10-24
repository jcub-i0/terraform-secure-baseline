#!/usr/bin/env python3
"""Offline checks of the actual protected Plan/Apply ZIP handling."""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from zipfile import ZipFile

MODULE = Path(__file__).resolve().parents[1]
REPO = MODULE.parents[1]
WORKFLOW = REPO / ".github/workflows/terraform-apply.yml"
AUTOMATION = ("ec2_isolation", "ec2_rollback", "ip_enrichment")
RESTORE = ("coordinator", "worker")


def workflow_script(name: str) -> str:
    lines = WORKFLOW.read_text().splitlines()
    header = next(i for i, line in enumerate(lines)
                  if line.strip() == f"- name: {name}")
    run_line = next(i for i in range(header + 1, len(lines))
                    if lines[i].strip() == "run: |")
    indent = len(lines[run_line]) - len(lines[run_line].lstrip())
    body = []
    for line in lines[run_line + 1:]:
        if line.strip() and len(line) - len(line.lstrip()) <= indent:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body))


def run_bash(script: str, workspace: Path, enabled: bool) -> subprocess.CompletedProcess:
    env = {**os.environ,
           "GITHUB_WORKSPACE": str(workspace),
           "PLAN_ARTIFACT_DIR": "terraform-plan-artifact",
           "PLAN_BASENAME": "baseline"}
    script = script.replace("${{ inputs.restore_validation_enabled }}", str(enabled).lower())
    return subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)


def create_package(path: Path, name: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(path, "w") as archive:
        archive.writestr(f"{name}.py", f"# fixture for {name}\n")


@unittest.skipUnless(shutil.which("bash") and shutil.which("sha256sum") and
                     shutil.which("unzip"), "requires bash, sha256sum and unzip")
class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.plan = Path(self.temp.name) / "plan"
        self.apply = Path(self.temp.name) / "apply"
        self.stage = self.plan / "terraform-plan-artifact"
        self.stage.mkdir(parents=True)
        (self.stage / "baseline-plan.sha256").write_text("")
        for name in AUTOMATION:
            create_package(self.plan / f"modules/automation/lambda/{name}.zip", name)
        self.bundle = workflow_script("Bundle Lambda ZIPs with saved plan")
        apply_script = workflow_script("Verify and apply exact saved plan")
        self.assertIn("terraform-plan-artifact.sh verify", apply_script)
        self.assertLess(apply_script.index("terraform-plan-artifact.sh verify"),
                        apply_script.index("artifact_lambda_dir="))
        self.restore = "artifact_lambda_dir=" + apply_script.split("artifact_lambda_dir=", 1)[1].split(
            "terraform -chdir=", 1)[0]

    def plan_artifacts(self, enabled: bool):
        if enabled:
            for name in RESTORE:
                create_package(self.plan / f"modules/restore_validation/lambda/{name}.zip", name)
        result = run_bash(self.bundle, self.plan, enabled)
        self.assertEqual(result.returncode, 0, result.stderr)

    def verify_manifest(self, workspace: Path, *, expect_success=True):
        directory = workspace / "terraform-plan-artifact"
        result = subprocess.run(["sha256sum", "--check", "baseline-plan.sha256"],
                                cwd=directory, capture_output=True, text=True)
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)

    def test_optional_archives_preserved_exactly_across_runners(self):
        self.plan_artifacts(True)
        self.verify_manifest(self.plan)
        shutil.copytree(self.stage, self.apply / "terraform-plan-artifact")
        (self.apply / "modules/automation/lambda").mkdir(parents=True)
        (self.apply / "modules/restore_validation/lambda").mkdir(parents=True)
        self.verify_manifest(self.apply)
        result = run_bash(self.restore, self.apply, True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in RESTORE:
            self.assertEqual(
                (self.apply / f"modules/restore_validation/lambda/{name}.zip").read_bytes(),
                (self.plan / f"modules/restore_validation/lambda/{name}.zip").read_bytes(),
            )

    def test_disabled_does_not_require_restore_archives(self):
        self.plan_artifacts(False)
        self.assertFalse((self.stage / "lambda/restore_validation").exists())
        self.verify_manifest(self.plan)
        shutil.copytree(self.stage, self.apply / "terraform-plan-artifact")
        (self.apply / "modules/automation/lambda").mkdir(parents=True)
        result = run_bash(self.restore, self.apply, False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_modified_archive_breaks_manifest(self):
        self.plan_artifacts(True)
        archive = self.stage / "lambda/restore_validation/worker.zip"
        archive.write_bytes(b"tampered")
        self.verify_manifest(self.plan, expect_success=False)

    def test_terraform_paths_match_staged_archives(self):
        terraform = (MODULE / "main.tf").read_text()
        for name in RESTORE:
            self.assertIn(f'${{path.module}}/lambda/{name}.zip', terraform)
            self.assertIn(f'data.archive_file.{name}.output_path', terraform)
            self.assertIn(f'lambda/restore_validation/{name}.zip', self.bundle)
        self.assertNotIn("RESTORE_SIGNING_", WORKFLOW.read_text())


if __name__ == "__main__":
    unittest.main(verbosity=2)
