"""Offline producer-catalog validation; no AWS identity qualification."""

import unittest

from catalog_producers import InvalidProducerCatalog, load_producer_policies
from producer_authorization import UnauthorizedProducer, authorize_producer
from request_schema import JobRequest


class CatalogProducerTests(unittest.TestCase):
    def setUp(self):
        self.role_id = "AROAEXAMPLEORIGINAL001"
        self.replacement = "AROAEXAMPLEREPLACEMENT"
        self.entry = {
            "logical_producer_id": "nightly-producer",
            "role_ids": [self.role_id],
            "allowed_jobs": ["archive"],
        }
        self.jobs = frozenset({"archive", "report"})
        self.request = JobRequest("archive", "request-001", "generation-001")

    def load(self, entries):
        return load_producer_policies(entries, declared_job_keys=self.jobs)

    def test_loaded_policy_works_with_authorization(self):
        policies = self.load([self.entry])
        self.assertEqual(
            authorize_producer(
                self.request,
                producer_role_id=self.role_id,
                producers_by_role_id=policies,
            ),
            "nightly-producer",
        )

    def test_multiple_approved_roles_share_one_logical_identity(self):
        self.entry["role_ids"].append(self.replacement)
        policies = self.load([self.entry])
        for role_id in (self.role_id, self.replacement):
            with self.subTest(role_id=role_id):
                self.assertEqual(
                    policies[role_id].logical_producer_id, "nightly-producer"
                )
                self.assertEqual(
                    policies[role_id].allowed_jobs, frozenset({"archive"})
                )

    def test_undefined_job_is_rejected(self):
        for job in ("undefined", "*", "Archive"):
            with self.subTest(job=job):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load([self.entry | {"allowed_jobs": [job]}])

    def test_duplicate_bindings_are_rejected(self):
        for entries in (
            [self.entry | {"role_ids": [self.role_id, self.role_id]}],
            [self.entry, self.entry | {"logical_producer_id": "other-producer"}],
            [self.entry, self.entry | {"role_ids": [self.replacement]}],
        ):
            with self.subTest(entries=entries):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load(entries)

    def test_malformed_structure_is_rejected(self):
        incomplete = dict(self.entry)
        del incomplete["allowed_jobs"]
        for entries in (
            None, {}, "producers", [None],
            [incomplete], [self.entry | {"overrides": {}}],
        ):
            with self.subTest(entries=entries):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load(entries)

    def test_malformed_lists_are_rejected(self):
        for field in ("role_ids", "allowed_jobs"):
            for value in ("archive", {}, None, [123], [""], [" padded "]):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidProducerCatalog):
                        self.load([self.entry | {field: value}])
        for change in (
            {"role_ids": []},
            {"allowed_jobs": ["archive", "archive"]},
        ):
            with self.subTest(change=change):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load([self.entry | change])

    def test_non_role_identifiers_and_sessions_are_rejected(self):
        for role_id in (
            "nightly-producer",
            "arn:aws:iam::123456789012:role/nightly-producer",
            self.role_id + ":session-name",
            "AIDAEXAMPLEUSER0000001",
            "AROA*",
            "AROA" + "A" * 11,
            "AROA" + "A" * 125,
        ):
            with self.subTest(role_id=role_id):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load([self.entry | {"role_ids": [role_id]}])

    def test_supported_role_id_length_boundaries(self):
        for length in (16, 128):
            role_id = "AROA" + "A" * (length - 4)
            with self.subTest(length=length):
                policies = self.load([self.entry | {"role_ids": [role_id]}])
                self.assertIn(role_id, policies)

    def test_invalid_logical_ids_are_rejected(self):
        for logical_id in ("", " padded ", None, 123):
            with self.subTest(logical_id=logical_id):
                with self.assertRaises(InvalidProducerCatalog):
                    self.load([self.entry | {"logical_producer_id": logical_id}])

    def test_empty_configuration_grants_nothing(self):
        self.assertEqual(dict(self.load([])), {})
        policies = self.load([self.entry | {"allowed_jobs": []}])
        with self.assertRaises(UnauthorizedProducer):
            authorize_producer(
                self.request,
                producer_role_id=self.role_id,
                producers_by_role_id=policies,
            )

    def test_loaded_configuration_is_an_immutable_snapshot(self):
        policies = self.load([self.entry])
        self.entry["allowed_jobs"].append("report")
        self.entry["role_ids"].append(self.replacement)
        self.assertEqual(
            policies[self.role_id].allowed_jobs, frozenset({"archive"})
        )
        self.assertNotIn(self.replacement, policies)
        with self.assertRaises(TypeError):
            policies[self.replacement] = policies[self.role_id]

    def test_invalid_declared_job_keys_are_rejected(self):
        for jobs in ({"archive"}, "archive", frozenset({""}), frozenset({123})):
            with self.subTest(jobs=jobs):
                with self.assertRaises(InvalidProducerCatalog):
                    load_producer_policies([self.entry], declared_job_keys=jobs)


if __name__ == "__main__":
    unittest.main()
