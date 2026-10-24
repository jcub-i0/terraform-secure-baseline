#!/usr/bin/env python3
"""Build isolated Lambda source directories and deterministic unsigned ZIPs.

AWS Signer must sign these archives before Terraform attaches ENFORCE code signing.
No AWS operations are performed by this script.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED

ROOT = Path(__file__).resolve().parents[2]
MODULE = ROOT / "modules/restore_validation"
SOURCE = MODULE / "lambda"
LOCK = ROOT / "scripts/restore_validation"
REQUIRED_SOURCES = {"coordinator": ["coordinator.py"],
                    "worker": ["worker.py", "canary_contract.json", "rds-ca-bundle.pem"]}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1048576), b""):
            h.update(chunk)
    return h.hexdigest()


def deterministic_zip(source: Path, destination: Path) -> str:
    destination.parent.mkdir(parents=True, exist_ok=True)
    files = [p for p in source.rglob("*") if p.is_file()]
    if not files:
        raise RuntimeError("No files to archive")
    fd, temp = tempfile.mkstemp(prefix="restore-validation-zip-", suffix=".zip", dir=destination.parent)
    os.close(fd)
    try:
        with ZipFile(temp, "w", compression=ZIP_DEFLATED, compresslevel=9) as zf:
            for path in sorted(files, key=lambda p: p.relative_to(source).as_posix()):
                relative = path.relative_to(source).as_posix()
                if "__pycache__" in path.parts or relative.endswith((".pyc", ".pyo")):
                    continue
                info = ZipInfo(relative, date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = (0o100644 << 16)
                zf.writestr(info, path.read_bytes(), compress_type=ZIP_DEFLATED, compresslevel=9)
        os.replace(temp, destination)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
    return sha256(destination)


def pip_install(target: Path, requirements: list[Path]) -> None:
    cmd = [sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
           "--no-cache-dir", "--no-compile", "--no-deps", "--only-binary=:all:", "--target", str(target)]
    for req in requirements:
        cmd.extend(["--requirement", str(req)])
    subprocess.run(cmd, check=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})


def prepare(name: str, ca_file: Path | None, build_root: Path, *, test_only: bool) -> Path:
    target = build_root / name
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    if not test_only:
        packages = [LOCK / "requirements-sdk.txt"]
        if name == "worker":
            packages.append(LOCK / "requirements-worker.txt")
        pip_install(target, packages)
    for entry in REQUIRED_SOURCES[name]:
        if entry == "rds-ca-bundle.pem":
            if ca_file is None or not ca_file.is_file():
                raise RuntimeError("RDS CA bundle required; supply --rds-ca-bundle")
            content = ca_file.read_bytes()
            if b"-----BEGIN CERTIFICATE-----" not in content or b"-----END CERTIFICATE-----" not in content:
                raise RuntimeError("Invalid RDS CA bundle format")
            if len(content) > 512 * 1024:
                raise RuntimeError("RDS CA bundle is unexpectedly large")
            (target / entry).write_bytes(content)
        else:
            shutil.copyfile(SOURCE / entry, target / entry)
    if test_only:
        (target / "DO_NOT_DEPLOY.TEST_ONLY").write_text("No third-party dependencies were installed.\n")
    return target


def build(ca_file: Path, dest: Path, build_root: Path, *, test_only: bool = False) -> dict:
    if dest.resolve() == build_root.resolve():
        raise RuntimeError("Build and archive directories cannot be the same")
    artifacts = {}
    for name in ("coordinator", "worker"):
        source_dir = prepare(name, ca_file, build_root, test_only=test_only)
        output = dest / f"{name}.zip"
        artifacts[name] = {"sha256": deterministic_zip(source_dir, output), "size": output.stat().st_size}
    manifest = {"format_version": 1, "deployable": not test_only,
                "source_ca_sha256": sha256(ca_file), "artifacts": artifacts}
    dest.mkdir(parents=True, exist_ok=True)
    (dest / "unsigned-manifest.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rds-ca-bundle", type=Path, required=True,
                        help="AWS RDS CA bundle from truststore.pki.rds.amazonaws.com")
    parser.add_argument("--out", type=Path, default=SOURCE / "dist")
    parser.add_argument("--build-root", type=Path, default=SOURCE / "build")
    parser.add_argument("--test-only", action="store_true", help="Skip pip; archives marked non-deployable")
    args = parser.parse_args()
    print(json.dumps(build(args.rds_ca_bundle, args.out, args.build_root, test_only=args.test_only), indent=2))


if __name__ == "__main__":
    main()
