"""Offline job-binding validation; no AWS resource or policy qualification."""

from dataclasses import FrozenInstanceError
import unittest

from catalog_job_bindings import InvalidJobBinding, load_job_binding


class CatalogJobBindingTests(unittest.TestCase):
    def setUp(self):
        self.cluster = "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
        self.binding = {
            "task_definition_arn": (
                "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:17"
            ),
            "launcher_role_arn": (
                "arn:aws:iam::123456789012:role/application/archive-launcher"
            ),
            "execution_role_arn": (
                "arn:aws:iam::123456789012:role/application/archive-execution"
            ),
            "task_role_arn": (
                "arn:aws:iam::123456789012:role/application/archive-task"
            ),
        }

    def load(self, binding):
        return load_job_binding(binding, approved_cluster_arn=self.cluster)

    def test_valid_binding_preserves_exact_values(self):
        loaded = self.load(self.binding)
        self.assertEqual(loaded.cluster_arn, self.cluster)
        for field, value in self.binding.items():
            self.assertEqual(getattr(loaded, field), value)

    def test_supported_partitions_and_role_paths(self):
        for partition, region in (
            ("aws", "us-east-1"),
            ("aws-us-gov", "us-gov-west-1"),
            ("aws-cn", "cn-north-1"),
        ):
            with self.subTest(partition=partition):
                def convert(value):
                    return value.replace("arn:aws:", f"arn:{partition}:").replace(
                        "us-east-1", region
                    )

                binding = {
                    field: convert(value)
                    for field, value in self.binding.items()
                }
                loaded = load_job_binding(
                    binding, approved_cluster_arn=convert(self.cluster)
                )
                self.assertEqual(loaded.task_role_arn, binding["task_role_arn"])

    def test_task_definition_requires_full_revision_arn(self):
        family = self.binding["task_definition_arn"].rsplit(":", 1)[0]
        for value in (
            "archive:17", family, family + ":LATEST", family + ":0",
            family + ":-1", family + ":01", family + ":*",
        ):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobBinding):
                    self.load(self.binding | {"task_definition_arn": value})

    def test_task_scope_must_match_cluster(self):
        original = self.binding["task_definition_arn"]
        for old, new in (
            ("arn:aws:", "arn:aws-cn:"),
            ("us-east-1", "us-west-2"),
            ("123456789012", "999999999999"),
        ):
            with self.subTest(change=new):
                with self.assertRaises(InvalidJobBinding):
                    self.load(self.binding | {
                        "task_definition_arn": original.replace(old, new)
                    })

    def test_every_role_must_match_cluster_scope(self):
        for field in ("launcher_role_arn", "execution_role_arn", "task_role_arn"):
            for old, new in (
                ("arn:aws:", "arn:aws-cn:"),
                ("123456789012", "999999999999"),
            ):
                with self.subTest(field=field, change=new):
                    with self.assertRaises(InvalidJobBinding):
                        self.load(self.binding | {
                            field: self.binding[field].replace(old, new)
                        })

    def test_role_names_sessions_and_wildcards_are_rejected(self):
        for field in ("launcher_role_arn", "execution_role_arn", "task_role_arn"):
            for value in (
                "archive-role",
                "arn:aws:sts::123456789012:assumed-role/archive/session",
                "arn:aws:iam::123456789012:root",
                "arn:aws:iam::123456789012:role/application/*",
                "arn:aws:iam::123456789012:role/app?/archive",
            ):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidJobBinding):
                        self.load(self.binding | {field: value})

    def test_missing_fields_and_execution_overrides_are_rejected(self):
        for field in self.binding:
            incomplete = dict(self.binding)
            del incomplete[field]
            with self.subTest(missing=field):
                with self.assertRaises(InvalidJobBinding):
                    self.load(incomplete)
        for field in ("overrides", "cluster_arn", "command"):
            with self.subTest(extra=field):
                with self.assertRaises(InvalidJobBinding):
                    self.load(self.binding | {field: "unapproved"})

    def test_non_objects_are_rejected(self):
        for value in (None, [], "binding", True):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobBinding):
                    self.load(value)

    def test_invalid_field_types_and_whitespace_are_rejected(self):
        for field, original in self.binding.items():
            for value in (None, 123, "", " " + original, original + "\n"):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidJobBinding):
                        self.load(self.binding | {field: value})

    def test_cluster_requires_an_exact_cluster_arn(self):
        for cluster in (
            None, "shared", self.cluster + "*", self.cluster + "\n",
            self.binding["task_definition_arn"],
        ):
            with self.subTest(cluster=cluster):
                with self.assertRaises(InvalidJobBinding):
                    load_job_binding(self.binding, approved_cluster_arn=cluster)

    def test_loaded_binding_is_an_immutable_snapshot(self):
        loaded = self.load(self.binding)
        original = loaded.task_definition_arn
        self.binding["task_definition_arn"] = original.replace(":17", ":18")
        self.assertEqual(loaded.task_definition_arn, original)
        with self.assertRaises(FrozenInstanceError):
            loaded.task_definition_arn = self.binding["task_definition_arn"]


if __name__ == "__main__":
    unittest.main()
