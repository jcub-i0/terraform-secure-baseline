#!/usr/bin/env python3
"""Offline saved-plan signed artifact staging tests (requires jq, unzip)."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from unittest import TestCase, main, skipUnless
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/restore_validation/stage-artifacts.sh"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


@skipUnless(shutil.which("jq") and shutil.which("unzip"), "needs jq and unzip")
class StageTests(TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.artifacts = base / "saved-plan"
        self.stage = base / "signed"
        self.artifacts.mkdir()
        (self.artifacts / "demo-plan.sha256").write_text("")
        self.env = {**os.environ, "RESTORE_VALIDATION_SIGNED_DIR": str(self.stage)}

    def run_stage(self, mode, enabled="true", *, expect_success=True):
        result = subprocess.run(["bash", str(SCRIPT), mode, str(self.artifacts), "demo", enabled],
                                env=self.env, capture_output=True, text=True)
        if expect_success:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def create_signed_fixtures(self):
        self.stage.mkdir()
        manifest = {"format_version": 1, "signing_profile": "restoresigner", "artifacts": {}}
        for name in ("coordinator", "worker"):
            archive = self.stage / f"{name}.zip"
            with ZipFile(archive, "w") as zipfile:
                zipfile.writestr(name + ".py", "# mock signed artifact; signature not tested here\n")
            manifest["artifacts"][name] = {"sha256": digest(archive), "signing_job_id": name + "-fake"}
        (self.stage / "signed-manifest.json").write_text(json.dumps(manifest))

    def test_script_syntax(self):
        subprocess.run(["bash", "-n", str(SCRIPT)], check=True)

    def test_missing_artifacts_are_disabled_noop(self):
        self.run_stage("plan", enabled="false")
        self.run_stage("apply", enabled="false")
        self.assertFalse((self.artifacts / "lambda/restore_validation").exists())

    def test_enabled_requires_signed_artifacts_in_both_jobs(self):
        self.run_stage("plan", expect_success=False)
        self.run_stage("apply", expect_success=False)

    def test_disabled_rejects_unexpected_artifacts(self):
        self.create_signed_fixtures()
        self.run_stage("plan", enabled="false", expect_success=False)
        shutil.rmtree(self.stage)
        (self.artifacts / "lambda/restore_validation").mkdir(parents=True)
        self.run_stage("apply", enabled="false", expect_success=False)

    def test_invalid_or_missing_explicit_flag_is_rejected(self):
        self.run_stage("plan", enabled="yes", expect_success=False)
        self.run_stage("plan", enabled="", expect_success=False)

    def test_stages_exact_hash_and_restores_in_apply(self):
        self.create_signed_fixtures()
        self.run_stage("plan")
        stored = self.artifacts / "lambda/restore_validation"
        for name in ("coordinator", "worker"):
            self.assertEqual(digest(stored / f"{name}.zip"), digest(self.stage / f"{name}.zip"))
        shutil.rmtree(self.stage)
        self.run_stage("apply")
        for name in ("coordinator", "worker"):
            self.assertEqual(digest(stored / f"{name}.zip"), digest(self.stage / f"{name}.zip"))

    def test_rejects_modified_signed_zip(self):
        self.create_signed_fixtures()
        (self.stage / "worker.zip").write_bytes(b"forged")
        self.run_stage("plan", expect_success=False)

    def test_rejects_modified_staged_zip_before_apply(self):
        self.create_signed_fixtures()
        self.run_stage("plan")
        (self.artifacts / "lambda/restore_validation/worker.zip").write_bytes(b"forged")
        self.run_stage("apply", expect_success=False)


if __name__ == "__main__":
    main(verbosity=2)
