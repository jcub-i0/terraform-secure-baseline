#!/usr/bin/env python3
"""Prepare dependency-inclusive Lambda directories for Terraform archive_file.

The caller supplies the RDS CA bundle; the protected Plan job verifies its SHA-256.
This script does not create ZIPs, contact AWS, or sign artifacts.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

MODULE = Path(__file__).resolve().parent
LAMBDA = MODULE / "lambda"
BUILD_ROOT = LAMBDA / "build"
SOURCES = {
    "coordinator": ("coordinator.py",),
    "worker": ("worker.py", "canary_contract.json"),
}
REQUIREMENTS = {
    "coordinator": ("requirements-sdk.txt",),
    "worker": ("requirements-sdk.txt", "requirements-worker.txt"),
}


def read_ca_bundle(path: Path) -> bytes:
    if not path.is_file() or path.is_symlink():
        raise RuntimeError("Missing or invalid RDS CA bundle")
    contents = path.read_bytes()
    if (not contents or len(contents) > 512 * 1024
            or b"-----BEGIN CERTIFICATE-----" not in contents
            or b"-----END CERTIFICATE-----" not in contents):
        raise RuntimeError("Invalid RDS CA bundle contents")
    return contents


def install_requirements(target: Path, files: tuple[Path, ...]) -> None:
    command = [
        sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
        "--no-cache-dir", "--no-compile", "--no-deps", "--only-binary=:all:",
        "--target", str(target),
    ]
    for file in files:
        if not file.is_file():
            raise RuntimeError(f"Missing Lambda requirements: {file.name}")
        command.extend(["--requirement", str(file)])
    subprocess.run(command, check=True, env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"})


def prepare(ca_bundle: Path, build_root: Path = BUILD_ROOT) -> None:
    ca_bytes = read_ca_bundle(ca_bundle)
    if build_root.is_symlink():
        raise RuntimeError("Lambda build root must not be a symbolic link")
    for name, sources in SOURCES.items():
        target = build_root / name
        if target.is_symlink():
            raise RuntimeError(f"Lambda build directory must not be a symbolic link: {name}")
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True)
        try:
            install_requirements(target, tuple(LAMBDA / file for file in REQUIREMENTS[name]))
            for filename in sources:
                source = LAMBDA / filename
                if not source.is_file() or source.is_symlink():
                    raise RuntimeError(f"Missing Lambda source: {filename}")
                shutil.copyfile(source, target / filename)
            if name == "worker":
                (target / "rds-ca-bundle.pem").write_bytes(ca_bytes)
        except Exception:
            shutil.rmtree(target, ignore_errors=True)
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rds-ca-bundle", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.rds_ca_bundle)


if __name__ == "__main__":
    main()
