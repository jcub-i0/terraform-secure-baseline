#!/usr/bin/env python3
"""Idempotently integrate M1-B2 offline tests and protected signed-plan workflow.

Run from the repository root after copying M1-B2 files. Only edits these two
existing workflow files. Fails closed if the known anchors have changed.
"""
from __future__ import annotations

import argparse
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[2]


def replace_once(text: str, old: str, new: str, name: str) -> str:
    if new in text:
        return text
    if text.count(old) != 1:
        raise RuntimeError(f"{name}: expected exactly one old anchor, got {text.count(old)}")
    return text.replace(old, new, 1)


def tf_scans(text: str) -> str:
    anchor = """      - name: Terraform format check
        id: terraform_fmt"""
    insert = """      - name: Test RDS Restore Validation runtime, packaging, and artifact contract
        run: |
          set -euo pipefail
          python3 -m unittest discover -s scripts/tests -p 'test_restore_validation_*.py' -v
          bash -n scripts/restore_validation/sign.sh
          bash -n scripts/restore_validation/stage-artifacts.sh

"""
    return replace_once(text, anchor, insert + anchor, "tf-scans restore-validation tests")


def tf_apply(text: str) -> str:
    text = replace_once(text,
        """            reconcile_workload_account:
                description: "Reconcile the workload account after a successful baseline apply"
                required: true
                default: false
                type: boolean
""",
        """            reconcile_workload_account:
                description: "Reconcile the workload account after a successful baseline apply"
                required: true
                default: false
                type: boolean
            restore_validation_enabled:
                description: "Opt in to RDS Restore Validation (requires pre-provisioned AWS Signer and an RDS read-only secret)"
                required: true
                default: false
                type: boolean
""", "Terraform Apply input")

    text = replace_once(text,
        """            TF_VAR_production_retirement_mode: ${{ inputs.production_retirement_mode }}
            ALB_CERTIFICATE_ARN:""",
        """            TF_VAR_production_retirement_mode: ${{ inputs.production_retirement_mode }}
            TF_VAR_restore_validation_enabled: ${{ inputs.restore_validation_enabled }}
            TF_VAR_restore_validation_secret_arn: ${{ vars.RESTORE_VALIDATION_SECRET_ARN }}
            ALB_CERTIFICATE_ARN:""", "Terraform Plan restore-validation variables")

    anchor = """            - name: Create exact saved plan
              shell: bash"""
    insert = """            - name: Build and sign Restore Validation Lambdas
              if: inputs.restore_validation_enabled
              shell: bash
              env:
                  RESTORE_SIGNING_PROFILE_NAME: ${{ vars.RESTORE_SIGNING_PROFILE_NAME }}
                  RESTORE_SIGNING_BUCKET: ${{ vars.RESTORE_SIGNING_BUCKET }}
                  RDS_CA_SHA256: ${{ vars.RDS_CA_SHA256 }}
                  RESTORE_VALIDATION_RELEASE: "true"
              run: |
                  set -euo pipefail
                  : "${RDS_CA_SHA256:?Configure the reviewed RDS_CA_SHA256 in protected environment variables}"
                  [[ "${RDS_CA_SHA256}" =~ ^[a-f0-9]{64}$ ]] || exit 2
                  ca_file="${RUNNER_TEMP}/rds-ca-bundle.pem"
                  [[ "${AWS_REGION}" =~ ^[a-z0-9-]+$ ]] || exit 2
                  curl --fail --silent --show-error --location \\
                    "https://truststore.pki.rds.amazonaws.com/${AWS_REGION}/${AWS_REGION}-bundle.pem" \\
                    --output "${ca_file}"
                  echo "${RDS_CA_SHA256}  ${ca_file}" | sha256sum --check --status
                  python3 scripts/restore_validation/build.py --rds-ca-bundle "${ca_file}"
                  bash scripts/restore_validation/sign.sh

"""
    text = replace_once(text, anchor, insert + anchor, "Terraform Plan signed artifacts")

    before = """                    sha256sum --check "${PLAN_BASENAME}-plan.sha256"
                  )

            - name: Upload saved plan"""
    after = """                    sha256sum --check "${PLAN_BASENAME}-plan.sha256"
                  )
                  bash scripts/restore_validation/stage-artifacts.sh plan "${artifact_dir}" "${PLAN_BASENAME}" "${{ inputs.restore_validation_enabled }}"

            - name: Upload saved plan"""
    text = replace_once(text, before, after, "Terraform Plan artifact staging")

    before = """                    install -m 0600 -- "${verified_zip}" "${lambda_dir}/${lambda}.zip"
                  done

                  terraform -chdir="${WORKING_DIRECTORY}" apply"""
    after = """                    install -m 0600 -- "${verified_zip}" "${lambda_dir}/${lambda}.zip"
                  done
                  bash scripts/restore_validation/stage-artifacts.sh apply \\
                    "${GITHUB_WORKSPACE}/${PLAN_ARTIFACT_DIR}" "${PLAN_BASENAME}" "${{ inputs.restore_validation_enabled }}"

                  terraform -chdir="${WORKING_DIRECTORY}" apply"""
    text = replace_once(text, before, after, "Terraform Apply artifact restoration")
    return text


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Validate anchors and show edits, without writing")
    args = parser.parse_args()
    paths = {".github/workflows/tf-scans.yml": tf_scans,
             ".github/workflows/terraform-apply.yml": tf_apply}
    changes = {}
    for name, transform in paths.items():
        path = REPO / name
        if not path.is_file():
            raise SystemExit(f"Missing {name}; copy files to target repository first")
        original = path.read_text()
        updated = transform(original)
        changes[path] = updated
        print(f"{'Would update' if args.check else 'Updated'}: {name}" + (" (already integrated)" if updated == original else ""))
    if not args.check:
        for path, content in changes.items():
            path.write_text(content)


if __name__ == "__main__":
    main()
