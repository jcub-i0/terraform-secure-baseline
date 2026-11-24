"""Offline policy tests; these do not qualify AWS delivery authenticity."""

from dataclasses import replace
import unittest

from producer_authorization import (
    ProducerPolicy,
    UnauthorizedProducer,
    authorize_producer,
)
from request_schema import JobRequest


class ProducerAuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.role_id = "AROAEXAMPLEORIGINAL001"
        self.request = JobRequest("archive", "request-001", "generation-001")
        self.policy = ProducerPolicy("nightly-producer", frozenset({"archive"}))
        self.producers = {self.role_id: self.policy}

    def authorize(self, request=None, role_id=None):
        return authorize_producer(
            self.request if request is None else request,
            producer_role_id=self.role_id if role_id is None else role_id,
            producers_by_role_id=self.producers,
        )

    def test_authorized_job_returns_stable_identity(self):
        self.assertEqual(self.authorize(), "nightly-producer")

    def test_role_identity_requires_an_exact_mapping(self):
        for role_id in (
            "AROAEXAMPLEUNKNOWN0001",
            self.role_id + ":session-name",
            " " + self.role_id,
            "arn:aws:iam::123456789012:role/nightly-producer",
            "",
            123,
        ):
            with self.subTest(role_id=role_id):
                with self.assertRaises(UnauthorizedProducer):
                    self.authorize(role_id=role_id)

    def test_job_permission_requires_an_exact_match(self):
        for job_key in ("report", "arch", "Archive"):
            with self.subTest(job_key=job_key):
                with self.assertRaises(UnauthorizedProducer):
                    self.authorize(replace(self.request, job_key=job_key))

    def test_schedule_metadata_cannot_authorize_an_unknown_producer(self):
        request = replace(
            self.request,
            schedule_key="archive-nightly",
            schedule_arn=(
                "arn:aws:scheduler:us-east-1:123456789012:"
                "schedule/test/archive-nightly"
            ),
            scheduled_time="2026-11-24T01:00:00Z",
        )
        with self.assertRaises(UnauthorizedProducer):
            self.authorize(request, role_id="AROAEXAMPLEUNKNOWN0001")

    def test_role_replacement_requires_mapping_and_preserves_logical_identity(self):
        replacement = "AROAEXAMPLEREPLACEMENT"
        with self.assertRaises(UnauthorizedProducer):
            self.authorize(role_id=replacement)

        original_identity = self.authorize()
        self.producers = {replacement: self.policy}
        self.assertEqual(self.authorize(role_id=replacement), original_identity)
        with self.assertRaises(UnauthorizedProducer):
            self.authorize()

    def test_empty_job_permissions_deny_access(self):
        self.producers = {
            self.role_id: ProducerPolicy("nightly-producer", frozenset())
        }
        with self.assertRaises(UnauthorizedProducer):
            self.authorize()

    def test_wildcard_does_not_expand_permissions(self):
        self.producers = {
            self.role_id: ProducerPolicy("nightly-producer", frozenset({"*"}))
        }
        with self.assertRaises(UnauthorizedProducer):
            self.authorize()

    def test_invalid_policy_identity_is_rejected(self):
        for identity in ("", " nightly-producer ", None):
            with self.subTest(identity=identity):
                with self.assertRaises(ValueError):
                    ProducerPolicy(identity, frozenset({"archive"}))

    def test_malformed_job_permissions_are_rejected(self):
        for jobs in ("archive", {"archive"}, frozenset({""}), frozenset({123})):
            with self.subTest(jobs=jobs):
                with self.assertRaises(ValueError):
                    ProducerPolicy("nightly-producer", jobs)


if __name__ == "__main__":
    unittest.main()
