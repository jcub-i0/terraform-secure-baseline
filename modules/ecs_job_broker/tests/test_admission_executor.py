"""Scripted-client contracts, not a DynamoDB simulator or live qualification."""

from copy import deepcopy
import json
import unittest
from unittest.mock import Mock, call

from admission_executor import (
    AdmissionOutcome as Outcome,
    AdmissionReason as Reason,
    admission_client_config,
    execute_admission,
)
import test_admission


class ServiceError(Exception):
    def __init__(self, code, *, reasons=None, retries=0, status=400,
                 request_id="write-request-id"):
        super().__init__("Sensitive service message must not enter results")
        self.response = {
            "Error": {"Code": code, "Message": str(self)},
            "ResponseMetadata": {
                "HTTPStatusCode": status, "RequestId": request_id,
                "RetryAttempts": retries,
            },
        }
        if reasons is not None:
            self.response["CancellationReasons"] = [{"Code": value} for value in reasons]


class AdmissionExecutorTests(unittest.TestCase):
    def setUp(self):
        # Reuse the complete fixture without importing its TestCase into this
        # module's discovery namespace (which would run its tests twice).
        self.fixture = test_admission.AdmissionTests()
        self.fixture.setUp()
        self.prepared = self.fixture.prepare()
        self.client = Mock(spec=["transact_write_items", "transact_get_items"])
        self.success = {"ResponseMetadata": {
            "HTTPStatusCode": 200, "RequestId": "write-request-id", "RetryAttempts": 0,
        }}
        self.client.transact_write_items.return_value = self.success

    def execute(self, **changes):
        return execute_admission(
            self.prepared, client=self.client,
            **({"owner_invocation_id": "invocation-1"} | changes),
        )

    def cancel(self, reasons, *, retries=0):
        error = ServiceError("TransactionCanceledException", reasons=reasons, retries=retries)
        self.client.transact_write_items.side_effect = error
        return error

    def collision(self, *, slot_unavailable=True):
        self.cancel([
            "None", "ConditionalCheckFailed",
            "ConditionalCheckFailed" if slot_unavailable else "None", "None",
        ])
        gate_action = self.prepared.transaction_request()["TransactItems"][0]["ConditionCheck"]
        values = gate_action["ExpressionAttributeValues"]
        gate = deepcopy(gate_action["Key"]) | {
            "schema_version": values[":version"], "record_type": values[":kind"],
            "state": values[":open"], "admission_generation": values[":generation"],
            "catalog_sha256": values[":digest"], "execution_ledger_arn": values[":ledger"],
        }
        original = self.fixture.request_item(
            self.fixture.prepare(owner_invocation_id="previous-invocation")
        )
        self.client.transact_get_items.return_value = {
            "ResponseMetadata": {"HTTPStatusCode": 200, "RequestId": "read-request-id"},
            "Responses": [{"Item": gate}, {"Item": original}],
        }
        return gate, original

    def test_client_policy_bounds_sdk_retries_without_disabling_them(self):
        config = admission_client_config()
        self.assertEqual(config["retries"], {"mode": "standard", "total_max_attempts": 3})
        self.assertEqual((config["connect_timeout"], config["read_timeout"]), (1, 2))
        config["retries"]["total_max_attempts"] = 99
        self.assertEqual(admission_client_config()["retries"]["total_max_attempts"], 3)

    def test_success_including_sdk_replay_acknowledges_the_exact_operation(self):
        expected = self.prepared.transaction_request()
        for retries in (0, 2):
            with self.subTest(retries=retries):
                self.client.reset_mock()
                self.success["ResponseMetadata"]["RetryAttempts"] = retries
                result = self.execute()
                self.assertEqual((result.outcome, result.reason),
                                 (Outcome.CONFIRMED, Reason.ACKNOWLEDGED))
                self.assertEqual(result.request_pk, self.prepared.request_pk)
                self.assertEqual(result.attempt_id, self.prepared.attempt_id)
                self.assertEqual(result.sdk_retry_attempts, retries)
                self.assertEqual(result.aws_request_id, "write-request-id")
                self.assertIsNone(result.original_request_json)
                self.assertEqual(self.client.mock_calls, [call.transact_write_items(**expected)])
                self.assertEqual(self.prepared.transaction_request(), expected)

    def test_another_invocation_cannot_submit_a_saved_preparation(self):
        for owner in ("another-invocation", ""):
            with self.subTest(owner=owner), self.assertRaises(ValueError):
                self.execute(owner_invocation_id=owner)
        self.assertEqual(self.client.mock_calls, [])

    def test_collision_returns_original_without_transferring_ownership(self):
        for unavailable in (False, True):
            with self.subTest(slot_unavailable=unavailable):
                self.client.reset_mock()
                gate, original = self.collision(slot_unavailable=unavailable)
                before = deepcopy(original)
                result = self.execute()
                self.assertEqual((result.outcome, result.reason),
                                 (Outcome.DUPLICATE, Reason.REQUEST_EXISTS))
                self.assertEqual(json.loads(result.original_request_json), before)
                self.assertEqual(original, before)
                self.assertNotEqual(original["attempt_id"]["S"], result.attempt_id)
                self.assertEqual(result.aws_request_id, "write-request-id")
                self.assertEqual(result.lookup_request_id, "read-request-id")
                transaction = self.prepared.transaction_request()
                self.assertEqual(self.client.mock_calls, [
                    call.transact_write_items(**transaction),
                    call.transact_get_items(TransactItems=[
                        {"Get": {
                            "TableName": self.fixture.context["gate_table_arn"],
                            "Key": {"pk": gate["pk"]},
                        }},
                        {"Get": {
                            "TableName": self.fixture.context["ledger_table_arn"],
                            "Key": {"pk": {"S": self.prepared.request_pk}},
                        }},
                    ]),
                ])
                original["status"] = {"S": "LATER_STATE"}
                self.assertEqual(json.loads(result.original_request_json), before)

    def test_collision_with_changed_intent_is_a_conflict(self):
        self.collision()
        original = self.fixture.request_item(self.fixture.prepare(
            body=self.fixture.body | {"job_key": "report"}
        ))
        self.client.transact_get_items.return_value["Responses"][1] = {"Item": original}
        result = self.execute()
        self.assertEqual((result.outcome, result.reason),
                         (Outcome.CONFLICT, Reason.INTENT_CONFLICT))
        self.assertEqual(json.loads(result.original_request_json), original)

    def test_collision_lookup_checks_current_gate_binding_and_schema(self):
        for field, value in (
            ("state", {"S": "CLOSED"}),
            ("admission_generation", {"S": "different-generation"}),
            ("catalog_sha256", {"S": "different-catalog"}),
            ("execution_ledger_arn", {"S": "different-ledger"}),
            ("schema_version", {"N": "2"}),
            ("record_type", {"S": "REQUEST"}),
        ):
            with self.subTest(field=field):
                gate, _ = self.collision()
                gate[field] = value
                result = self.execute()
                self.assertEqual((result.outcome, result.reason),
                                 (Outcome.REJECTED, Reason.GATE_NOT_ELIGIBLE))
                self.assertIsNone(result.original_request_json)
        self.collision()
        self.client.transact_get_items.return_value["Responses"][0] = {}
        self.assertEqual(self.execute().reason, Reason.GATE_NOT_ELIGIBLE)

    def test_cancellation_distinguishes_gate_slot_accounting_and_service_conditions(self):
        cases = [
            (["ConditionalCheckFailed", "None", "None", "None"], Reason.GATE_NOT_ELIGIBLE),
            (["None", "None", "ConditionalCheckFailed", "None"], Reason.SLOT_UNAVAILABLE),
            (["None", "None", "None", "ConditionalCheckFailed"], Reason.ACCOUNTING_CONDITION_FAILED),
            (["None", "TransactionConflict", "None", "None"], Reason.TRANSIENT_SERVICE_FAILURE),
            (["ThrottlingError", "None", "None", "None"], Reason.TRANSIENT_SERVICE_FAILURE),
            (["None", "None", "None", "ValidationError"], Reason.CONFIGURATION_ERROR),
        ]
        for codes, reason in cases:
            with self.subTest(codes=codes):
                self.client.reset_mock()
                self.cancel(codes)
                result = self.execute()
                self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, reason))
                self.assertEqual(result.cancellation_codes, tuple(codes))
                self.client.transact_write_items.assert_called_once()
                self.client.transact_get_items.assert_not_called()

    def test_multiple_failures_do_not_hide_accounting_faults_or_return_duplicates(self):
        cases = [
            (["ConditionalCheckFailed"] * 4, Reason.ACCOUNTING_CONDITION_FAILED),
            (["ConditionalCheckFailed", "ConditionalCheckFailed", "None", "None"],
             Reason.GATE_NOT_ELIGIBLE),
            (["None", "ConditionalCheckFailed", "None", "ValidationError"],
             Reason.CONFIGURATION_ERROR),
            (["None", "ConditionalCheckFailed", "None", "TransactionConflict"],
             Reason.TRANSIENT_SERVICE_FAILURE),
            (["None", "ConditionalCheckFailed", "None", "FutureReason"],
             Reason.TRANSACTION_CANCELED),
        ]
        for codes, reason in cases:
            with self.subTest(codes=codes):
                self.cancel(codes)
                result = self.execute()
                self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, reason))
                self.assertIsNone(result.original_request_json)
        self.client.transact_get_items.assert_not_called()

    def test_incomplete_cancellation_details_do_not_invent_a_cause(self):
        for codes in (None, [], ["None", "ConditionalCheckFailed"],
                      ["None", "ConditionalCheckFailed", None, "None"],
                      ["None"] * 4):
            with self.subTest(codes=codes):
                self.cancel(codes)
                result = self.execute()
                self.assertEqual((result.outcome, result.reason),
                                 (Outcome.REJECTED, Reason.TRANSACTION_CANCELED))
        self.client.transact_get_items.assert_not_called()

    def test_known_service_rejections_distinguish_configuration_and_transient_faults(self):
        for code, reason in (
            ("AccessDeniedException", Reason.PERMISSION_DENIED),
            ("ValidationException", Reason.CONFIGURATION_ERROR),
            ("ResourceNotFoundException", Reason.CONFIGURATION_ERROR),
            ("ProvisionedThroughputExceededException", Reason.TRANSIENT_SERVICE_FAILURE),
            ("ThrottlingException", Reason.TRANSIENT_SERVICE_FAILURE),
        ):
            with self.subTest(code=code):
                self.client.transact_write_items.side_effect = ServiceError(code)
                result = self.execute()
                self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, reason))
                self.assertEqual(result.error_code, code)
                self.assertNotIn("Sensitive service message", repr(result))
        self.client.transact_get_items.assert_not_called()

    def test_final_rejection_cannot_erase_uncertainty_from_sdk_retries(self):
        for code, codes, reason in (
            ("AccessDeniedException", None, Reason.PERMISSION_DENIED),
            ("TransactionCanceledException", ["None", "ConditionalCheckFailed", "None", "None"],
             Reason.REQUEST_EXISTS),
            ("TransactionCanceledException", ["None", "None", "None", "ConditionalCheckFailed"],
             Reason.ACCOUNTING_CONDITION_FAILED),
            ("ThrottlingException", None, Reason.TRANSIENT_SERVICE_FAILURE),
        ):
            for retries in (1, 2, None):
                with self.subTest(code=code, retries=retries):
                    error = ServiceError(code, reasons=codes, retries=retries)
                    if retries is None:
                        del error.response["ResponseMetadata"]["RetryAttempts"]
                    self.client.transact_write_items.side_effect = error
                    result = self.execute()
                    self.assertEqual((result.outcome, result.reason), (Outcome.UNKNOWN, reason))
                    self.assertEqual(result.sdk_retry_attempts, retries)
        self.client.transact_get_items.assert_not_called()

    def test_ambiguous_write_failures_do_not_trigger_outer_retries_or_reads(self):
        for error, reason in (
            (TimeoutError("sensitive timeout detail"), Reason.UNCLASSIFIED_FAILURE),
            (ServiceError("InternalServerError", status=500), Reason.TRANSIENT_SERVICE_FAILURE),
            (ServiceError("TransactionInProgressException"), Reason.TRANSACTION_IN_PROGRESS),
            (ServiceError("IdempotentParameterMismatchException"), Reason.TOKEN_MISMATCH),
            (ServiceError("FutureException"), Reason.UNCLASSIFIED_FAILURE),
        ):
            with self.subTest(error=type(error).__name__, reason=reason):
                self.client.reset_mock()
                self.client.transact_write_items.side_effect = error
                result = self.execute()
                self.assertEqual((result.outcome, result.reason), (Outcome.UNKNOWN, reason))
                self.assertIsNotNone(result.error_code)
                self.assertNotIn("sensitive timeout detail", repr(result))
                self.client.transact_write_items.assert_called_once()
                self.client.transact_get_items.assert_not_called()

    def test_failed_lookup_preserves_write_certainty_and_both_request_ids(self):
        self.collision()
        self.client.transact_get_items.side_effect = ServiceError(
            "AccessDeniedException", request_id="failed-read-id"
        )
        result = self.execute()
        self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, Reason.LOOKUP_FAILED))
        self.assertEqual(result.aws_request_id, "write-request-id")
        self.assertEqual(result.lookup_request_id, "failed-read-id")
        self.assertEqual(result.error_code, "TransactionCanceledException")
        self.assertEqual(result.lookup_error_code, "AccessDeniedException")
        self.client.transact_write_items.assert_called_once()

    def test_missing_or_malformed_original_is_an_operational_fault(self):
        for item, reason in (
            (None, Reason.ORIGINAL_REQUEST_MISSING),
            ({"pk": {"S": self.prepared.request_pk}}, Reason.INVALID_REQUEST_RECORD),
        ):
            with self.subTest(reason=reason):
                self.collision()
                self.client.transact_get_items.return_value["Responses"][1] = (
                    {} if item is None else {"Item": item}
                )
                result = self.execute()
                self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, reason))
                self.assertIsNone(result.original_request_json)

    def test_unexpected_responses_preserve_write_certainty(self):
        self.client.transact_write_items.return_value = {}
        result = self.execute()
        self.assertEqual((result.outcome, result.reason), (Outcome.UNKNOWN, Reason.UNEXPECTED_RESPONSE))
        self.client.transact_get_items.assert_not_called()
        self.collision()
        self.client.transact_get_items.return_value = {}
        result = self.execute()
        self.assertEqual((result.outcome, result.reason), (Outcome.REJECTED, Reason.UNEXPECTED_RESPONSE))

    def test_record_contents_and_cancellation_messages_are_excluded_from_result_repr(self):
        _, original = self.collision()
        original["unexpected_sensitive_field"] = {"S": "private-value"}
        error = self.client.transact_write_items.side_effect
        error.response["CancellationReasons"][1]["Message"] = "private-value"
        error.response["CancellationReasons"][1]["Item"] = original
        result = self.execute()
        self.assertEqual(result.outcome, Outcome.DUPLICATE)
        self.assertNotIn("private-value", repr(result))
        # The internal snapshot is intentionally available to trusted runtime,
        # not a logging payload. repr suppression does not redact explicit dumps.
        self.assertIn("private-value", result.original_request_json)


if __name__ == "__main__":
    unittest.main()
