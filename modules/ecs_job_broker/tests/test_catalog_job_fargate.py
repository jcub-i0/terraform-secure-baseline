"""Offline Fargate-contract tests; no live platform qualification."""

from dataclasses import FrozenInstanceError
import unittest

from catalog_job_fargate import InvalidJobFargate, load_job_fargate


class CatalogJobFargateTests(unittest.TestCase):
    def setUp(self):
        self.fargate = {
            "launch_type": "FARGATE",
            "platform_version": "1.4.0",
            "count": 1,
        }

    def test_explicit_numeric_platform_preserves_values(self):
        loaded = load_job_fargate(self.fargate)
        self.assertEqual(loaded.launch_type, "FARGATE")
        self.assertEqual(loaded.platform_version, "1.4.0")
        self.assertEqual(loaded.count, 1)
        self.assertIs(type(loaded.count), int)

    def test_latest_is_an_explicit_supported_selector(self):
        loaded = load_job_fargate(self.fargate | {"platform_version": "LATEST"})
        self.assertEqual(loaded.platform_version, "LATEST")

    def test_numeric_syntax_does_not_claim_aws_version_support(self):
        loaded = load_job_fargate(self.fargate | {"platform_version": "9.12.34"})
        self.assertEqual(loaded.platform_version, "9.12.34")

    def test_launch_type_must_be_fargate(self):
        for value in ("EC2", "EXTERNAL", "FARGATE_SPOT", "fargate", "", None, True, []):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(self.fargate | {"launch_type": value})

    def test_count_must_be_exactly_integer_one(self):
        for value in (0, 2, -1, True, False, 1.0, "1", None, []):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(self.fargate | {"count": value})

    def test_malformed_platform_selectors_are_rejected(self):
        for value in (
            None, True, 1, 1.4, [], "", "latest", " LATEST", "LATEST\n",
            "1", "1.4", "1.4.0.0", "01.4.0", "1.04.0", "1.4.00",
            "-1.4.0", "1.4.*", "1.4.0-beta", "1.4.0+build",
            " 1.4.0", "1.4.0\n", "\u0661.4.0",
        ):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(self.fargate | {"platform_version": value})

    def test_all_fields_are_required_without_defaults(self):
        for field in self.fargate:
            incomplete = dict(self.fargate)
            del incomplete[field]
            with self.subTest(missing=field):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(incomplete)

    def test_extra_fields_and_execution_overrides_are_rejected(self):
        for field, value in (
            ("overrides", {}),
            ("capacity_provider_strategy", []),
            ("enable_execute_command", True),
        ):
            with self.subTest(extra=field):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(self.fargate | {field: value})

    def test_non_objects_are_rejected(self):
        for value in (None, [], "fargate", True, 1):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobFargate):
                    load_job_fargate(value)

    def test_loaded_settings_are_an_immutable_snapshot(self):
        loaded = load_job_fargate(self.fargate)
        self.fargate.update(launch_type="EC2", platform_version="LATEST", count=2)
        self.assertEqual(loaded.launch_type, "FARGATE")
        self.assertEqual(loaded.platform_version, "1.4.0")
        self.assertEqual(loaded.count, 1)
        with self.assertRaises(FrozenInstanceError):
            loaded.count = 2


if __name__ == "__main__":
    unittest.main()
