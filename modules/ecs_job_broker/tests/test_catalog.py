"""Offline catalog-to-request integration; identities and approvals are fixtures."""

from copy import deepcopy
from dataclasses import FrozenInstanceError
import json
import unittest

from catalog import InvalidCatalog, load_catalog, resolve_request
from producer_authorization import UnauthorizedProducer
from request_schema import RejectedRequest


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.role_id = "AROAEXAMPLEORIGINAL001"
        self.report_role_id = "AROAEXAMPLEREPORT0001"
        cluster = "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
        self.document = {
            "schema_version": 1,
            "application_id": "example-app",
            "environment": "test",
            "admission_generation": "generation-001",
            "cluster_arn": cluster,
            "jobs": {},
            "producers": [
                {
                    "logical_producer_id": "nightly-producer",
                    "role_ids": [self.role_id],
                    "allowed_jobs": ["archive"],
                },
                {
                    "logical_producer_id": "report-producer",
                    "role_ids": [self.report_role_id],
                    "allowed_jobs": ["report"],
                },
            ],
        }
        groups = {}
        for index, key in enumerate(("archive", "report"), start=1):
            self.document["jobs"][key] = {
                "binding": {
                    "task_definition_arn": (
                        f"arn:aws:ecs:us-east-1:123456789012:task-definition/{key}:17"
                    ),
                    **{
                        f"{role}_role_arn": (
                            f"arn:aws:iam::123456789012:role/jobs/{key}-{role}"
                        )
                        for role in ("launcher", "execution", "task")
                    },
                },
                "network": {
                    "subnet_ids": [f"subnet-{index:017x}"],
                    "security_group_ids": [f"sg-{index:017x}"],
                    "assign_public_ip": "DISABLED",
                },
                "fargate": {
                    "launch_type": "FARGATE", "platform_version": "1.4.0", "count": 1,
                },
                "execution_policy": {
                    "max_active_executions": 1, "run_task_total_max_attempts": 1,
                },
            }
            groups[key] = frozenset({f"sg-{index:017x}"})
        self.approvals = {
            "approved_cluster_arn": cluster,
            "approved_private_subnet_ids": frozenset({
                "subnet-00000000000000001", "subnet-00000000000000002",
            }),
            "approved_security_groups_by_job": groups,
        }
        self.request = {
            "schema_version": 2,
            "job_key": "archive",
            "request_key": "request-001",
            "admission_generation": "generation-001",
        }

    def load(self, document=None, **approval_changes):
        return load_catalog(
            json.dumps(self.document if document is None else document),
            **(self.approvals | approval_changes),
        )

    def resolve(self, catalog, *, request=None, role_id=None):
        return resolve_request(
            json.dumps(self.request if request is None else request),
            catalog=catalog,
            producer_role_id=self.role_id if role_id is None else role_id,
        )

    def test_request_resolves_to_exact_job_and_durable_key(self):
        catalog = self.load()
        archive = self.resolve(catalog)
        report = self.resolve(
            catalog, request=self.request | {"job_key": "report"},
            role_id=self.report_role_id,
        )
        for key, resolved in (("archive", archive), ("report", report)):
            with self.subTest(job=key):
                expected = self.document["jobs"][key]
                self.assertEqual(
                    resolved.job.binding.task_definition_arn,
                    expected["binding"]["task_definition_arn"],
                )
                self.assertEqual(resolved.job.binding.cluster_arn, catalog.cluster_arn)
                self.assertEqual(
                    resolved.job.network.security_group_ids,
                    tuple(expected["network"]["security_group_ids"]),
                )
                self.assertEqual(resolved.job.fargate.platform_version, "1.4.0")
                self.assertEqual(resolved.job.max_active_executions, 1)
                self.assertEqual(resolved.job.run_task_total_max_attempts, 1)
        self.assertEqual(archive.logical_producer_id, "nightly-producer")
        self.assertEqual(report.logical_producer_id, "report-producer")
        self.assertEqual(
            archive.ledger_key,
            "request:v1:"
            "3d2dd2214fdbb685d3cc5512bb81ac451b936fea84a9573bd41050aff9817a82",
        )
        self.assertNotEqual(archive.ledger_key, report.ledger_key)

    def test_unknown_producer_and_unauthorized_jobs_are_rejected(self):
        catalog = self.load()
        for role_id, job in (
            ("AROAEXAMPLEUNKNOWN0001", "archive"),
            (self.role_id, "report"),
            (self.role_id, "unknown"),
        ):
            with self.subTest(role=role_id, job=job):
                with self.assertRaises(UnauthorizedProducer):
                    self.resolve(
                        catalog, request=self.request | {"job_key": job},
                        role_id=role_id,
                    )

    def test_request_cannot_supply_identity_or_execution_settings(self):
        catalog = self.load()
        for field, value in (("SenderId", self.role_id), ("overrides", {})):
            with self.subTest(field=field):
                with self.assertRaises(RejectedRequest):
                    self.resolve(catalog, request=self.request | {field: value})

    def test_generation_check_does_not_reset_durable_identity(self):
        original = self.resolve(self.load())
        self.document["admission_generation"] = "generation-002"
        catalog = self.load()
        with self.assertRaises(RejectedRequest):
            self.resolve(catalog)
        changed = self.resolve(
            catalog, request=self.request | {"admission_generation": "generation-002"}
        )
        self.assertEqual(original.ledger_key, changed.ledger_key)

    def test_producer_job_references_are_derived_from_validated_jobs(self):
        self.document["producers"][0]["allowed_jobs"].append("missing-job")
        with self.assertRaises(InvalidCatalog):
            self.load()

    def test_duplicate_json_fields_are_rejected_at_multiple_levels(self):
        raw = json.dumps(self.document)
        for body in (
            raw[:-1] + ', "schema_version": 1}',
            raw.replace('"jobs": {', '"jobs": {"archive": {}, ', 1),
            raw.replace(
                '"assign_public_ip": "DISABLED"',
                '"assign_public_ip": "ENABLED", "assign_public_ip": "DISABLED"', 1,
            ),
            raw.replace(
                '"logical_producer_id": "nightly-producer"',
                '"logical_producer_id": "other", '
                '"logical_producer_id": "nightly-producer"',
                1,
            ),
        ):
            with self.subTest(body=body):
                with self.assertRaises(InvalidCatalog):
                    load_catalog(body, **self.approvals)

    def test_invalid_json_and_non_objects_are_rejected(self):
        for body in (None, {}, b"{}", "{", "[]", "null", '{"schema_version": NaN}'):
            with self.subTest(body=body):
                with self.assertRaises(InvalidCatalog):
                    load_catalog(body, **self.approvals)

    def test_catalog_header_requires_exact_fields_and_version(self):
        for field in self.document:
            document = deepcopy(self.document)
            del document[field]
            with self.subTest(missing=field):
                with self.assertRaises(InvalidCatalog):
                    self.load(document)
        for change in (
            {"extra": True}, {"schema_version": 2}, {"schema_version": True},
            {"schema_version": 1.0}, {"schema_version": "1"},
        ):
            with self.subTest(change=change):
                with self.assertRaises(InvalidCatalog):
                    self.load(self.document | change)
        for field in ("application_id", "environment", "admission_generation"):
            for value in ("", " padded ", None):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidCatalog):
                        self.load(self.document | {field: value})

    def test_job_structure_is_closed_and_keys_are_not_normalized(self):
        for field in self.document["jobs"]["archive"]:
            document = deepcopy(self.document)
            del document["jobs"]["archive"][field]
            with self.subTest(missing=field):
                with self.assertRaises(InvalidCatalog):
                    self.load(document)
        document = deepcopy(self.document)
        document["jobs"]["archive"]["overrides"] = {}
        with self.assertRaises(InvalidCatalog):
            self.load(document)
        for jobs in (None, [], {"archive": None, "report": None}):
            with self.subTest(jobs=jobs):
                with self.assertRaises(InvalidCatalog):
                    self.load(self.document | {"jobs": jobs})
        document = deepcopy(self.document)
        document["jobs"][" archive"] = document["jobs"].pop("archive")
        groups = dict(self.approvals["approved_security_groups_by_job"])
        groups[" archive"] = groups.pop("archive")
        with self.assertRaises(InvalidCatalog):
            self.load(document, approved_security_groups_by_job=groups)

    def test_fixed_execution_limits_are_required_and_cannot_change(self):
        original = self.document["jobs"]["archive"]["execution_policy"]
        invalid = [None, {}, original | {"release_on_timeout": True}]
        for field in original:
            invalid.append({
                key: value for key, value in original.items() if key != field
            })
            invalid.extend(
                original | {field: value}
                for value in (True, False, 1.0, "1", None, 0, -1, 2)
            )
        for policy in invalid:
            document = deepcopy(self.document)
            document["jobs"]["archive"]["execution_policy"] = policy
            with self.subTest(policy=policy):
                with self.assertRaises(InvalidCatalog):
                    self.load(document)

    def test_invalid_unselected_job_rejects_the_whole_catalog(self):
        for section, field, value in (
            ("binding", "task_definition_arn", "report"),
            ("network", "assign_public_ip", "ENABLED"),
            ("fargate", "count", 2),
        ):
            document = deepcopy(self.document)
            document["jobs"]["report"][section][field] = value
            with self.subTest(section=section):
                with self.assertRaises(InvalidCatalog):
                    self.load(document)

    def test_catalog_selections_must_match_external_resource_approvals(self):
        with self.assertRaises(InvalidCatalog):
            self.load(self.document | {"cluster_arn": "unapproved-cluster"})
        with self.assertRaises(InvalidCatalog):
            self.load(approved_private_subnet_ids=frozenset({
                "subnet-00000000000000001",
            }))
        groups = self.approvals["approved_security_groups_by_job"]
        for approval in (
            None, {},
            {"archive": groups["report"], "report": groups["archive"]},
            groups | {"extra-job": groups["archive"]},
        ):
            with self.subTest(approval=approval):
                with self.assertRaises(InvalidCatalog):
                    self.load(approved_security_groups_by_job=approval)

    def test_loaded_catalog_and_resolution_are_immutable_snapshots(self):
        catalog = self.load()
        self.approvals["approved_security_groups_by_job"].clear()
        resolved = self.resolve(catalog)
        self.assertEqual(
            resolved.job.network.security_group_ids, ("sg-00000000000000001",)
        )
        with self.assertRaises(TypeError):
            catalog.jobs["archive"] = catalog.jobs["report"]
        with self.assertRaises(TypeError):
            catalog.producers_by_role_id[self.role_id] = None
        with self.assertRaises(FrozenInstanceError):
            catalog.environment = "changed"
        with self.assertRaises(FrozenInstanceError):
            resolved.job.max_active_executions = 2
        with self.assertRaises(FrozenInstanceError):
            resolved.ledger_key = "changed"

    def test_empty_catalog_denies_all_requests(self):
        catalog = self.load(
            self.document | {"jobs": {}, "producers": []},
            approved_security_groups_by_job={},
        )
        with self.assertRaises(UnauthorizedProducer):
            self.resolve(catalog)

    def test_catalog_role_replacement_preserves_request_identity(self):
        original = self.resolve(self.load())
        replacement = "AROAEXAMPLEREPLACEMENT"
        self.document["producers"][0]["role_ids"] = [replacement]
        catalog = self.load()
        with self.assertRaises(UnauthorizedProducer):
            self.resolve(catalog)
        self.assertEqual(
            original.ledger_key, self.resolve(catalog, role_id=replacement).ledger_key
        )

    def test_resolution_preserves_key_for_repeated_or_changed_job_intent(self):
        self.document["producers"][0]["allowed_jobs"].append("report")
        catalog = self.load()
        original = self.resolve(catalog)
        self.assertEqual(original, self.resolve(catalog))
        changed = self.resolve(catalog, request=self.request | {"job_key": "report"})
        self.assertEqual(original.ledger_key, changed.ledger_key)
        self.assertNotEqual(original.job, changed.job)
        # A future ledger transaction must reject this conflicting intent.


if __name__ == "__main__":
    unittest.main()
