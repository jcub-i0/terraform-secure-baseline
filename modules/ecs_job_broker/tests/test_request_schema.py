"""Offline request-contract tests; no AWS identity or admission claims."""

import json
import unittest

from request_schema import RejectedRequest, parse_request


class RequestSchemaTests(unittest.TestCase):
    def setUp(self):
        self.request = {
            "schema_version": 2,
            "job_key": "archive",
            "request_key": "request-001",
            "admission_generation": "generation-001",
        }

    def test_on_demand_request(self):
        parsed = parse_request(json.dumps(self.request))
        self.assertEqual(parsed.job_key, "archive")
        self.assertEqual(parsed.request_key, "request-001")
        self.assertEqual(parsed.admission_generation, "generation-001")
        self.assertIsNone(parsed.schedule_arn)

    def test_scheduled_request_preserves_correlation_metadata(self):
        schedule = {
            "schedule_key": "archive-nightly",
            "schedule_arn": (
                "arn:aws:scheduler:us-east-1:123456789012:"
                "schedule/test/archive-nightly"
            ),
            "scheduled_time": "2026-11-24T01:00:00Z",
        }
        parsed = parse_request(json.dumps(self.request | schedule))
        self.assertEqual(parsed.schedule_key, schedule["schedule_key"])
        self.assertEqual(parsed.schedule_arn, schedule["schedule_arn"])
        self.assertEqual(parsed.scheduled_time, schedule["scheduled_time"])

    def test_generation_is_required(self):
        del self.request["admission_generation"]
        with self.assertRaises(RejectedRequest):
            parse_request(json.dumps(self.request))

    def test_schema_version_is_explicit_and_integer(self):
        for version in (1, 2.0, True, "2"):
            with self.subTest(version=version):
                with self.assertRaises(RejectedRequest):
                    parse_request(json.dumps(
                        self.request | {"schema_version": version}
                    ))

    def test_rejects_execution_overrides_and_body_identity(self):
        for field in (
            "overrides", "task_definition_arn", "logical_producer_id", "SenderId"
        ):
            with self.subTest(field=field):
                with self.assertRaises(RejectedRequest):
                    parse_request(json.dumps(
                        self.request | {field: "untrusted"}
                    ))

    def test_duplicate_job_field_is_rejected(self):
        body = json.dumps(self.request)[:-1] + ', "job_key": "report"}'
        with self.assertRaises(RejectedRequest):
            parse_request(body)

    def test_incomplete_schedule_metadata_is_rejected(self):
        with self.assertRaises(RejectedRequest):
            parse_request(json.dumps(
                self.request | {"schedule_key": "archive-nightly"}
            ))

    def test_invalid_json_or_non_object_is_rejected(self):
        for body in ("{", "[]", "null"):
            with self.subTest(body=body):
                with self.assertRaises(RejectedRequest):
                    parse_request(body)

    def test_request_key_is_rejected_instead_of_normalized(self):
        for key in ("", " request-001 ", 123):
            with self.subTest(key=key):
                with self.assertRaises(RejectedRequest):
                    parse_request(json.dumps(
                        self.request | {"request_key": key}
                    ))


if __name__ == "__main__":
    unittest.main()
