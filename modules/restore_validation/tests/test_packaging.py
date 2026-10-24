#!/usr/bin/env python3
"""Offline deterministic artifact packaging tests without third-party wheels."""
import importlib.util
import json
from pathlib import Path
import tempfile
from unittest import TestCase, main
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("restore_builder", ROOT / "scripts/restore_validation/build.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class PackagingTests(TestCase):
    def test_reproducible_source_archives_and_contract(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            ca = tmp / "ca.pem"
            ca.write_text("-----BEGIN CERTIFICATE-----\nTEST ONLY\n-----END CERTIFICATE-----\n")
            a = builder.build(ca, tmp / "artifacts", tmp / "build", test_only=True)
            b = builder.build(ca, tmp / "artifacts", tmp / "build", test_only=True)
            self.assertEqual(a, b)
            self.assertFalse(a["deployable"])
            for name in ("worker", "coordinator"):
                dest = tmp / "artifacts" / (name + ".zip")
                self.assertEqual(builder.sha256(dest), a["artifacts"][name]["sha256"])
                with ZipFile(dest) as z:
                    self.assertIn(name + ".py", z.namelist())
                    self.assertIn("DO_NOT_DEPLOY.TEST_ONLY", z.namelist())
                    self.assertTrue(all(info.date_time[:3] == (1980, 1, 1) for info in z.infolist()))
                if name == "worker":
                    self.assertIn("canary_contract.json", ZipFile(dest).namelist())
                    self.assertIn("rds-ca-bundle.pem", ZipFile(dest).namelist())
            manifest = json.loads((tmp / "artifacts/unsigned-manifest.json").read_text())
            self.assertEqual(manifest, a)

    def test_requires_ca_bundle(self):
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            with self.assertRaisesRegex(RuntimeError, "RDS CA bundle"):
                builder.build(tmp / "missing.pem", tmp / "out", tmp / "build", test_only=True)


if __name__ == "__main__":
    main(verbosity=2)
