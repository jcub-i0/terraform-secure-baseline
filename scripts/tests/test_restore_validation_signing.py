#!/usr/bin/env python3
"""Offline mocked AWS Signer smoke test for the signed-artifact staging contract.

The fake AWS CLI copies archives without signing them: it tests manifest layout,
checksum handling, and inter-script wiring, NOT cryptographic signature validity.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts/restore_validation"

FAKE_AWS = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import shutil
import sys

args = sys.argv[1:]
root = Path(os.environ["FAKE_SIGNER_HOME"])
def option(name):
    return args[args.index(name) + 1]

if args[:2] == ["s3api", "get-bucket-versioning"]:
    print("Enabled")
elif args[:2] == ["s3api", "put-object"]:
    source = Path(option("--body"))
    (root / "objects").mkdir(exist_ok=True)
    shutil.copyfile(source, root / "objects" / source.name)
    print("version-1")
elif args[:2] == ["signer", "start-signing-job"]:
    source = option("--source")
    name = "coordinator" if source.endswith("/coordinator.zip,version=version-1}") else "worker"
    (root / "current-job").write_text(name)
    print("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
elif args[:2] == ["signer", "describe-signing-job"]:
    if option("--query") == "status":
        print("Succeeded")
    else:
        name = (root / "current-job").read_text()
        print(json.dumps({
            "bucketName": "restore-signing-bucket",
            "key": "restore-validation/signed/" + name + ".zip"
        }))
elif args[:2] == ["s3api", "get-object"]:
    archive = Path(option("--key")).name
    shutil.copyfile(root / "objects" / archive, Path(args[-1]))
else:
    raise SystemExit("Unexpected mocked AWS CLI call: " + repr(args))
'''


@unittest.skipUnless(shutil.which("jq") and shutil.which("unzip") and
                     shutil.which("sha256sum"), "requires jq, unzip and sha256sum")
class SigningArtifactContractTests(unittest.TestCase):
    def test_mock_signer_manifest_is_consumed_by_plan_stager(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            repo = Path(temp_dir) / "project"
            scripts = repo / "scripts/restore_validation"
            dist = repo / "modules/restore_validation/lambda/dist"
            fake_bin = repo / "fake-bin"
            saved_plan = repo / "plan"
            scripts.mkdir(parents=True)
            dist.mkdir(parents=True)
            fake_bin.mkdir(parents=True)
            saved_plan.mkdir(parents=True)

            for name in ("sign.sh", "stage-artifacts.sh"):
                shutil.copyfile(SCRIPTS / name, scripts / name)

            artifacts = {}
            for name in ("coordinator", "worker"):
                archive = dist / (name + ".zip")
                with ZipFile(archive, "w") as bundle:
                    bundle.writestr(name + ".py", "# synthetic test only\n")
                artifacts[name] = {
                    "sha256": hashlib.sha256(archive.read_bytes()).hexdigest()
                }
            (dist / "unsigned-manifest.json").write_text(json.dumps({
                "format_version": 1, "deployable": True, "artifacts": artifacts
            }))

            fake_aws = fake_bin / "aws"
            fake_aws.write_text(FAKE_AWS)
            fake_aws.chmod(0o755)

            env = {
                **os.environ,
                "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
                "FAKE_SIGNER_HOME": str(repo),
                "RESTORE_VALIDATION_RELEASE": "true",
                "RESTORE_SIGNING_PROFILE_NAME": "restore_signer",
                "RESTORE_SIGNING_BUCKET": "restore-signing-bucket",
            }
            subprocess.run(["bash", str(scripts / "sign.sh")],
                           check=True, env=env, capture_output=True, text=True)

            signed_dir = dist / "signed"
            manifest_path = signed_dir / "signed-manifest.json"
            self.assertTrue(manifest_path.is_file())
            self.assertFalse((dist / "signed-manifest.json").exists())
            manifest = json.loads(manifest_path.read_text())
            self.assertEqual(set(manifest["artifacts"]), {"coordinator", "worker"})
            for name in ("coordinator", "worker"):
                archive = signed_dir / (name + ".zip")
                self.assertEqual(
                    hashlib.sha256(archive.read_bytes()).hexdigest(),
                    manifest["artifacts"][name]["sha256"]
                )

            (saved_plan / "demo-plan.sha256").write_text("")
            subprocess.run(
                ["bash", str(scripts / "stage-artifacts.sh"),
                 "plan", str(saved_plan), "demo", "true"],
                check=True, env=env, capture_output=True, text=True
            )
            self.assertTrue(
                (saved_plan / "lambda/restore_validation/signed-manifest.json").is_file()
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
