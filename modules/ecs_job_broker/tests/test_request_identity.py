"""Offline durable-key compatibility tests; no ledger writes or admission."""

from dataclasses import replace
import unittest

from producer_authorization import ProducerPolicy, authorize_producer
from request_identity import request_ledger_key
from request_schema import JobRequest


class RequestIdentityTests(unittest.TestCase):
    def setUp(self):
        self.request = JobRequest("archive", "request-001", "generation-001")
        self.scope = {
            "application_id": "example-app",
            "environment": "test",
            "logical_producer_id": "nightly-producer",
        }

    def test_storage_format_matches_fixed_vector(self):
        self.assertEqual(
            request_ledger_key(self.request, **self.scope),
            "request:v1:"
            "3d2dd2214fdbb685d3cc5512bb81ac451b936fea84a9573bd41050aff9817a82",
        )

    def test_each_identity_component_has_its_own_namespace(self):
        original = request_ledger_key(self.request, **self.scope)
        for field in self.scope:
            with self.subTest(field=field):
                changed = self.scope | {field: self.scope[field] + "-other"}
                self.assertNotEqual(
                    original, request_ledger_key(self.request, **changed)
                )
        self.assertNotEqual(
            original,
            request_ledger_key(
                replace(self.request, request_key="request-002"), **self.scope
            ),
        )

    def test_job_generation_and_schedule_do_not_reset_identity(self):
        original = request_ledger_key(self.request, **self.scope)
        for request in (
            replace(self.request, job_key="report"),
            replace(self.request, admission_generation="generation-002"),
            replace(
                self.request,
                schedule_key="archive-nightly",
                schedule_arn=(
                    "arn:aws:scheduler:us-east-1:123456789012:"
                    "schedule/test/archive-nightly"
                ),
                scheduled_time="2026-11-24T01:00:00Z",
            ),
        ):
            with self.subTest(request=request):
                self.assertEqual(
                    original, request_ledger_key(request, **self.scope)
                )

    def test_component_boundaries_are_unambiguous(self):
        first = self.scope | {
            "application_id": "example|test", "environment": "east"
        }
        second = self.scope | {
            "application_id": "example", "environment": "test|east"
        }
        self.assertNotEqual(
            request_ledger_key(self.request, **first),
            request_ledger_key(self.request, **second),
        )

    def test_request_keys_are_not_normalized(self):
        for first, second in (
            ("Request-001", "request-001"),
            ("caf\u00e9", "cafe\u0301"),
        ):
            with self.subTest(first=first, second=second):
                self.assertNotEqual(
                    request_ledger_key(
                        replace(self.request, request_key=first), **self.scope
                    ),
                    request_ledger_key(
                        replace(self.request, request_key=second), **self.scope
                    ),
                )

    def test_approved_role_replacement_preserves_request_identity(self):
        policy = ProducerPolicy("nightly-producer", frozenset({"archive"}))
        keys = []
        for role_id in ("AROAEXAMPLEORIGINAL001", "AROAEXAMPLEREPLACEMENT"):
            logical_id = authorize_producer(
                self.request,
                producer_role_id=role_id,
                producers_by_role_id={role_id: policy},
            )
            keys.append(request_ledger_key(
                self.request,
                **(self.scope | {"logical_producer_id": logical_id}),
            ))
        self.assertEqual(keys[0], keys[1])

    def test_invalid_scope_components_are_rejected(self):
        for field in self.scope:
            for value in ("", " padded ", None, 123, False):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(ValueError):
                        request_ledger_key(
                            self.request, **(self.scope | {field: value})
                        )

    def test_invalid_request_keys_are_rejected(self):
        for value in ("", " padded ", None, 123, False):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    request_ledger_key(
                        replace(self.request, request_key=value), **self.scope
                    )


if __name__ == "__main__":
    unittest.main()
