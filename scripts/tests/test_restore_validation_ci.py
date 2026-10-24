#!/usr/bin/env python3
"""Offline tests for safe, idempotent workflow integration."""
import importlib.util
from pathlib import Path
from unittest import TestCase, main

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("integration", ROOT / "scripts/restore_validation/integrate_ci.py")
integration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(integration)


class CIIntegrationTests(TestCase):
    def test_static_analysis_test_insertion_is_idempotent(self):
        initial = "      - name: Terraform format check\n        id: terraform_fmt\n"
        updated = integration.tf_scans(initial)
        self.assertIn("python3 -m unittest discover", updated)
        self.assertEqual(integration.tf_scans(updated), updated)

    def test_protected_plan_signing_and_saved_artifact_insertion(self):
        original = '''            reconcile_workload_account:
                description: "Reconcile the workload account after a successful baseline apply"
                required: true
                default: false
                type: boolean
            TF_VAR_production_retirement_mode: ${{ inputs.production_retirement_mode }}
            ALB_CERTIFICATE_ARN: other
            - name: Create exact saved plan
              shell: bash
                    sha256sum --check "${PLAN_BASENAME}-plan.sha256"
                  )

            - name: Upload saved plan
                    install -m 0600 -- "${verified_zip}" "${lambda_dir}/${lambda}.zip"
                  done

                  terraform -chdir="${WORKING_DIRECTORY}" apply
'''
        updated = integration.tf_apply(original)
        self.assertIn("restore_validation_enabled:", updated)
        self.assertIn("default: false", updated)
        self.assertIn("if: inputs.restore_validation_enabled", updated)
        self.assertIn("TF_VAR_restore_validation_secret_arn", updated)
        self.assertIn('stage-artifacts.sh plan "${artifact_dir}"', updated)
        self.assertIn("stage-artifacts.sh apply", updated)
        self.assertIn("sha256sum --check --status", updated)
        self.assertEqual(integration.tf_apply(updated), updated)

    def test_fails_closed_if_old_workflow_changed(self):
        with self.assertRaisesRegex(RuntimeError, "expected exactly one old anchor"):
            integration.tf_apply("unrelated: workflow")


if __name__ == "__main__":
    main(verbosity=2)
