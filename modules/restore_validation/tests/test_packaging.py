#!/usr/bin/env python3
"""Offline tests for the module's Lambda dependency preparation step."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("restore_validation_prepare", MODULE / "prepare.py")
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class PackagingTests(unittest.TestCase):
    def test_prepares_exact_sources_and_ca_without_creating_zips(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            ca = home / "rds-ca.pem"
            ca.write_bytes(b"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n")
            output = home / "build"
            with mock.patch.object(builder, "install_requirements") as install:
                builder.prepare(ca, output)
                self.assertEqual(install.call_count, 2)
                self.assertEqual(
                    [p.name for p in install.call_args_list[0].args[1]],
                    ["requirements-sdk.txt"],
                )
                self.assertEqual(
                    [p.name for p in install.call_args_list[1].args[1]],
                    ["requirements-sdk.txt", "requirements-worker.txt"],
                )
                self.assertEqual((output / "coordinator/coordinator.py").read_bytes(),
                                 (MODULE / "lambda/coordinator.py").read_bytes())
                self.assertEqual((output / "worker/worker.py").read_bytes(),
                                 (MODULE / "lambda/worker.py").read_bytes())
                self.assertEqual((output / "worker/canary_contract.json").read_bytes(),
                                 (MODULE / "lambda/canary_contract.json").read_bytes())
                self.assertEqual((output / "worker/rds-ca-bundle.pem").read_bytes(),
                                 ca.read_bytes())
                self.assertFalse(list(output.rglob("*.zip")))
                self.assertFalse((output / "coordinator/rds-ca-bundle.pem").exists())
                (output / "worker/stale.py").write_text("stale")
                builder.prepare(ca, output)
                self.assertFalse((output / "worker/stale.py").exists())

    def test_missing_or_invalid_ca_fails_before_preparation(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            output = home / "build"
            with self.assertRaisesRegex(RuntimeError, "RDS CA bundle"):
                builder.prepare(home / "missing.pem", output)
            ca = home / "invalid.pem"
            ca.write_text("not a certificate")
            with self.assertRaisesRegex(RuntimeError, "RDS CA bundle"):
                builder.prepare(ca, output)
            self.assertFalse(output.exists())

    def test_dependency_failure_cannot_leave_incomplete_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            ca = home / "rds-ca.pem"
            ca.write_bytes(b"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----\n")
            output = home / "build"
            with mock.patch.object(builder, "install_requirements", side_effect=RuntimeError("pip failed")):
                with self.assertRaisesRegex(RuntimeError, "pip failed"):
                    builder.prepare(ca, output)
            self.assertFalse((output / "coordinator").exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
