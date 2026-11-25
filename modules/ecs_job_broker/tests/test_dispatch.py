"""Dispatch wire contracts and scripted clients; not live DynamoDB/ECS qualification."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from dataclasses import replace
import json
from threading import Barrier, Lock
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from admission_executor import AdmissionOutcome, AdmissionReason, AdmissionResult
from dispatch import LaunchOutcome as Launch, WriteOutcome as Write, dispatch_admitted
import test_admission


class ServiceError(Exception):
    def __init__(self, code, *, status=400, retries=0, reasons=None, resource_ids=None):
        super().__init__("private service message")
        self.response = {
            "Error": {"Code": code, "Message": str(self)},
            "ResponseMetadata": {
                "HTTPStatusCode": status, "RequestId": "service-request-id", "RetryAttempts": retries,
            },
        }
        if reasons is not None:
            self.response["CancellationReasons"] = [
                {"Code": value, "Message": "private cancellation detail"} for value in reasons
            ]
        if resource_ids is not None:
            self.response["resourceIds"] = resource_ids


def acknowledged(retries=0):
    return {"ResponseMetadata": {
        "HTTPStatusCode": 200, "RequestId": "aws-request-id", "RetryAttempts": retries,
    }}


class DispatchTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_admission.AdmissionTests()
        self.fixture.setUp()
        self.prepared = self.fixture.prepare()
        self.item = self.fixture.request_item(self.prepared)
        self.run_task = json.loads(self.item["run_task_request_json"]["S"])
        self.intent = json.loads(self.item["intent_json"]["S"])
        self.admitted = AdmissionResult(
            AdmissionOutcome.CONFIRMED, AdmissionReason.ACKNOWLEDGED,
            self.prepared.request_pk, self.prepared.attempt_id,
        )
        self.ledger = Mock(spec=["transact_write_items"])
        self.ledger.transact_write_items.return_value = acknowledged()
        self.ecs = Mock(spec=["run_task", "meta"])
        self.ecs.meta = SimpleNamespace(config=SimpleNamespace(retries={
            "mode": "standard", "total_max_attempts": 1,
        }))
        self.task_arn = "arn:aws:ecs:us-east-1:123456789012:task/shared/" + "a" * 32
        self.success = acknowledged() | {"tasks": [{
            "taskArn": self.task_arn, "clusterArn": self.run_task["cluster"],
            "taskDefinitionArn": self.run_task["taskDefinition"],
        }], "failures": []}
        self.ecs.run_task.return_value = self.success
        self.factory = Mock(return_value=self.ecs)

    def dispatch(self, **changes):
        return dispatch_admitted(self.prepared, **({
            "admission_result": self.admitted, "owner_invocation_id": "invocation-1",
            "ledger_client": self.ledger, "launcher_client_factory": self.factory,
        } | changes))

    def transaction(self, index):
        return self.ledger.transact_write_items.call_args_list[index].kwargs

    def assert_request_binding(self, action, *, before):
        self.assertEqual(action["Key"], {"pk": {"S": self.prepared.request_pk}})
        names = action["ExpressionAttributeNames"]
        values = action["ExpressionAttributeValues"]
        condition = action["ConditionExpression"]
        for alias, field, value_alias, expected in (
            ("#version", "schema_version", ":version", {"N": "1"}),
            ("#kind", "record_type", ":kind", {"S": "REQUEST"}),
            ("#status", "status", ":before", {"S": before}),
            ("#owner", "owner_invocation_id", ":owner", self.item["owner_invocation_id"]),
            ("#attempt", "attempt_id", ":attempt", self.item["attempt_id"]),
            ("#intent", "intent_json", ":intent", self.item["intent_json"]),
            ("#launch", "run_task_request_json", ":launch", self.item["run_task_request_json"]),
        ):
            self.assertEqual(names[alias], field)
            self.assertEqual(values[value_alias], expected)
            self.assertIn(f"{alias} = {value_alias}", condition)

    def assert_slot_binding(self, action):
        expected = self.prepared.transaction_request()["TransactItems"][2]["Update"]
        self.assertEqual(action["Key"], expected["Key"])
        self.assertEqual(action["ExpressionAttributeValues"], {
            ":version": {"N": "1"}, ":kind": {"S": "SLOT"}, ":occupied": {"S": "OCCUPIED"},
            ":request": self.item["pk"], ":attempt": self.item["attempt_id"], ":job": self.item["job_key"],
        } | ({":free": {"S": "FREE"}} if "UpdateExpression" in action else {}))
        self.assertEqual(action["ConditionExpression"],
                         "#version = :version AND #kind = :kind AND #state = :occupied "
                         "AND #request = :request AND #attempt = :attempt AND #job = :job")

    def assert_accounting_guard(self, action):
        expected = self.prepared.transaction_request()["TransactItems"][3]["Update"]
        self.assertEqual(action["Key"], expected["Key"])
        self.assertEqual(action["ConditionExpression"],
                         "#version = :version AND #kind = :kind "
                         "AND #pending >= :one AND #occupied >= #pending")
        self.assertEqual(action["ExpressionAttributeValues"][":one"], {"N": "1"})
        self.assertEqual(action["ExpressionAttributeValues"][":kind"], {"S": "ACCOUNTING"})

    def test_claim_binds_owner_snapshot_slot_and_accounting_without_new_admission(self):
        result = self.dispatch()
        transaction = self.transaction(0)
        self.assertEqual(transaction["ClientRequestToken"], result.dispatch_id)
        self.assertNotEqual(result.dispatch_id, self.prepared.attempt_id)
        self.assertEqual([list(action) for action in transaction["TransactItems"]],
                         [["Update"], ["ConditionCheck"], ["ConditionCheck"]])
        request, slot, accounting = [next(iter(action.values())) for action in transaction["TransactItems"]]
        self.assert_request_binding(request, before="REGISTERED")
        self.assertIn("attribute_not_exists(#dispatch)", request["ConditionExpression"])
        self.assertEqual(request["ExpressionAttributeValues"][":after"], {"S": "DISPATCHING"})
        self.assertEqual(request["ExpressionAttributeValues"][":dispatch"], {"S": result.dispatch_id})
        self.assertEqual(request["UpdateExpression"], "SET #status = :after, #dispatch = :dispatch")
        self.assert_slot_binding(slot)
        self.assert_accounting_guard(accounting)
        for action in (request, slot, accounting):
            self.assertEqual(action["TableName"], self.fixture.context["ledger_table_arn"])
        # Admission can close after reservation. This claim has no OPEN-gate check.
        self.assertNotIn(self.fixture.context["gate_table_arn"], json.dumps(transaction))

    def test_launch_uses_exact_admitted_parameters_and_job_launcher(self):
        before = self.prepared.transaction_request()
        result = self.dispatch()
        self.factory.assert_called_once_with(self.intent["launcher_role_arn"])
        self.ecs.run_task.assert_called_once_with(**self.run_task)
        self.assertEqual(self.prepared.transaction_request(), before)
        self.assertEqual(result.launch.outcome, Launch.ACCEPTED)
        self.assertEqual(result.launch.task_arns, (self.task_arn,))
        self.assertEqual(result.claim.outcome, Write.CONFIRMED)
        self.assertEqual(result.recording.outcome, Write.CONFIRMED)

    def test_accepted_task_reduces_pending_but_retains_the_slot_until_terminal_monitoring(self):
        result = self.dispatch()
        transaction = self.transaction(1)
        self.assertEqual([list(action) for action in transaction["TransactItems"]],
                         [["Update"], ["ConditionCheck"], ["Update"]])
        request = transaction["TransactItems"][0]["Update"]
        self.assert_request_binding(request, before="DISPATCHING")
        self.assertIn("#dispatch = :dispatch", request["ConditionExpression"])
        self.assertEqual(request["ExpressionAttributeValues"][":dispatch"], {"S": result.dispatch_id})
        self.assertEqual(request["ExpressionAttributeValues"][":after"], {"S": "LAUNCH_ACCEPTED"})
        self.assertEqual(request["ExpressionAttributeValues"][":task"], {"S": self.task_arn})
        self.assert_slot_binding(transaction["TransactItems"][1]["ConditionCheck"])
        accounting = transaction["TransactItems"][2]["Update"]
        self.assert_accounting_guard(accounting)
        self.assertEqual(accounting["UpdateExpression"], "ADD #pending :minus_one")
        self.assertEqual(accounting["ExpressionAttributeValues"][":minus_one"], {"N": "-1"})
        self.assertNotIn(transaction["ClientRequestToken"],
                         (self.prepared.attempt_id, self.transaction(0)["ClientRequestToken"]))

    def test_explicit_no_task_failure_atomically_releases_only_the_matching_reservation(self):
        self.ecs.run_task.return_value = acknowledged() | {
            "tasks": [], "failures": [{"reason": "RESOURCE:MEMORY", "detail": "private detail"}],
        }
        result = self.dispatch()
        self.assertEqual(result.launch.outcome, Launch.REJECTED)
        request, slot, accounting = [action["Update"] for action in self.transaction(1)["TransactItems"]]
        self.assert_request_binding(request, before="DISPATCHING")
        self.assertEqual(request["ExpressionAttributeValues"][":after"], {"S": "LAUNCH_REJECTED"})
        self.assert_slot_binding(slot)
        self.assertEqual(slot["UpdateExpression"], "SET #state = :free REMOVE #request, #attempt")
        self.assert_accounting_guard(accounting)
        self.assertEqual(accounting["UpdateExpression"], "ADD #pending :minus_one, #occupied :minus_one")
        self.assertEqual(accounting["ExpressionAttributeValues"][":minus_one"], {"N": "-1"})
        self.assertNotIn("private detail", json.dumps(self.transaction(1)))

    def test_unknown_launch_records_evidence_without_releasing_slot_or_counters(self):
        self.ecs.run_task.side_effect = TimeoutError("private timeout detail")
        result = self.dispatch()
        self.assertEqual(result.launch.outcome, Launch.UNKNOWN)
        self.assertEqual(result.recording.outcome, Write.CONFIRMED)
        request, slot, accounting = self.transaction(1)["TransactItems"]
        self.assert_request_binding(request["Update"], before="DISPATCHING")
        self.assertEqual(request["Update"]["ExpressionAttributeValues"][":after"], {"S": "LAUNCH_UNKNOWN"})
        self.assert_slot_binding(slot["ConditionCheck"])
        self.assert_accounting_guard(accounting["ConditionCheck"])
        observation = json.loads(request["Update"]["ExpressionAttributeValues"][":observation"]["S"])
        self.assertEqual(observation["error_code"], "TimeoutError")
        self.assertNotIn("private timeout detail", repr(result) + json.dumps(self.transaction(1)))
        self.ecs.run_task.assert_called_once()

    def test_unconfirmed_admission_never_reaches_clients(self):
        for outcome in (AdmissionOutcome.DUPLICATE, AdmissionOutcome.CONFLICT,
                        AdmissionOutcome.REJECTED, AdmissionOutcome.UNKNOWN):
            with self.subTest(outcome=outcome):
                result = self.dispatch(admission_result=replace(self.admitted, outcome=outcome))
                self.assertEqual(result.claim.outcome, Write.NOT_ATTEMPTED)
                self.assertEqual(result.launch.outcome, Launch.NOT_ATTEMPTED)
                self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
                self.assertIsNone(result.dispatch_id)
        self.factory.assert_not_called()
        self.ledger.transact_write_items.assert_not_called()

    def test_wrong_owner_or_candidate_evidence_is_rejected_before_client_io(self):
        for changes in (
            {"owner_invocation_id": "another-invocation"},
            {"owner_invocation_id": ""},
            {"admission_result": replace(self.admitted, attempt_id="other-attempt")},
            {"admission_result": replace(self.admitted, request_pk="other-request")},
        ):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.dispatch(**changes)
        self.factory.assert_not_called()
        self.ledger.transact_write_items.assert_not_called()

    def test_launcher_setup_failure_leaves_the_registered_obligation_intact(self):
        self.factory.side_effect = ServiceError("AccessDeniedException")
        result = self.dispatch()
        self.assertEqual(result.launch.outcome, Launch.NOT_ATTEMPTED)
        self.assertEqual(result.launch.reason, "LAUNCHER_SETUP_FAILED")
        self.assertEqual(result.launch.error_code, "AccessDeniedException")
        self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
        self.ledger.transact_write_items.assert_not_called()
        self.ecs.run_task.assert_not_called()
        self.assertNotIn("private service message", repr(result))

    def test_launcher_must_explicitly_disable_sdk_retries_before_claiming(self):
        for retries in ({}, {"max_attempts": 0}, {"total_max_attempts": 2},
                        {"total_max_attempts": True}, {"total_max_attempts": "1"}, None):
            with self.subTest(retries=retries):
                self.ecs.meta.config.retries = retries
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.NOT_ATTEMPTED)
                self.assertEqual(result.launch.reason, "INVALID_LAUNCHER_RETRY_POLICY")
        self.ledger.transact_write_items.assert_not_called()
        self.ecs.run_task.assert_not_called()

    def test_request_slot_or_accounting_claim_denial_prevents_ecs_and_recording(self):
        for position in range(3):
            with self.subTest(position=position):
                self.ledger.reset_mock()
                codes = ["None"] * 3
                codes[position] = "ConditionalCheckFailed"
                self.ledger.transact_write_items.side_effect = ServiceError(
                    "TransactionCanceledException", reasons=codes,
                )
                result = self.dispatch()
                self.assertEqual(result.claim.outcome, Write.REJECTED)
                self.assertEqual(result.claim.cancellation_codes, tuple(codes))
                self.assertEqual(result.launch.outcome, Launch.NOT_ATTEMPTED)
                self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
                self.ledger.transact_write_items.assert_called_once()
        self.ecs.run_task.assert_not_called()

    def test_uncertain_claim_does_not_use_a_read_or_cached_owner_as_a_permit(self):
        for failure in (TimeoutError("lost claim response"),
                        ServiceError("TransactionCanceledException", retries=1),
                        ServiceError("TransactionCanceledException", retries=None)):
            with self.subTest(failure=type(failure).__name__):
                self.ledger.reset_mock()
                self.ledger.transact_write_items.side_effect = failure
                result = self.dispatch()
                self.assertEqual(result.claim.outcome, Write.UNKNOWN)
                self.assertEqual(result.launch.outcome, Launch.NOT_ATTEMPTED)
                self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
                self.ledger.transact_write_items.assert_called_once()
        self.ecs.run_task.assert_not_called()

    def test_sdk_replay_of_this_claim_can_continue_once_with_one_ecs_call(self):
        self.ledger.transact_write_items.side_effect = [acknowledged(2), acknowledged(1)]
        result = self.dispatch()
        self.assertEqual(result.claim.outcome, Write.CONFIRMED)
        self.assertEqual(result.claim.sdk_retry_attempts, 2)
        self.assertEqual(result.recording.outcome, Write.CONFIRMED)
        self.ecs.run_task.assert_called_once()
        self.assertEqual(self.ledger.transact_write_items.call_count, 2)

    def claim_oracle(self):
        # Model just the service's claim/cache responses, not DynamoDB expression
        # evaluation. Separate wire assertions verify the conditions we submit.
        lock, tokens = Lock(), set()

        def submit(**transaction):
            update = transaction["TransactItems"][0]["Update"]
            if update["ExpressionAttributeValues"][":after"] != {"S": "DISPATCHING"}:
                return acknowledged()
            token = transaction["ClientRequestToken"]
            with lock:
                if token in tokens:
                    return acknowledged(1)
                if tokens:
                    raise ServiceError("TransactionCanceledException", reasons=[
                        "ConditionalCheckFailed", "None", "None",
                    ])
                tokens.add(token)
                return acknowledged()
        return submit

    def test_reentry_uses_a_fresh_claim_token_instead_of_replaying_cached_success(self):
        self.ledger.transact_write_items.side_effect = self.claim_oracle()
        first, second = self.dispatch(), self.dispatch()
        self.assertEqual(first.launch.outcome, Launch.ACCEPTED)
        self.assertEqual(second.launch.outcome, Launch.NOT_ATTEMPTED)
        self.assertEqual(second.claim.outcome, Write.REJECTED)
        self.assertNotEqual(first.dispatch_id, second.dispatch_id)
        self.ecs.run_task.assert_called_once()

    def test_competing_dispatch_entries_only_launch_for_the_scripted_claim_winner(self):
        barrier = Barrier(2)

        def factory(role):
            barrier.wait(timeout=5)
            return self.ecs

        self.factory.side_effect = factory
        self.ledger.transact_write_items.side_effect = self.claim_oracle()
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.dispatch(), range(2)))
        self.assertCountEqual([result.launch.outcome for result in results],
                              [Launch.ACCEPTED, Launch.NOT_ATTEMPTED])
        self.assertNotEqual(results[0].dispatch_id, results[1].dispatch_id)
        self.ecs.run_task.assert_called_once()

    def test_recording_failure_does_not_turn_accepted_task_into_a_failed_or_retried_launch(self):
        for failure, expected in (
            (TimeoutError("lost write response"), Write.UNKNOWN),
            (ServiceError("AccessDeniedException"), Write.REJECTED),
            (ServiceError("TransactionCanceledException", retries=1), Write.UNKNOWN),
        ):
            with self.subTest(expected=expected):
                self.ecs.reset_mock()
                self.ledger.reset_mock()
                self.ledger.transact_write_items.side_effect = [acknowledged(), failure]
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.ACCEPTED)
                self.assertEqual(result.launch.task_arns, (self.task_arn,))
                self.assertEqual(result.recording.outcome, expected)
                self.assertEqual(self.ledger.transact_write_items.call_count, 2)
                self.ecs.run_task.assert_called_once()

    def test_a_repeated_result_write_cannot_bypass_the_expected_attempt_and_state(self):
        self.ledger.transact_write_items.side_effect = [acknowledged(), ServiceError(
            "TransactionCanceledException", reasons=["ConditionalCheckFailed", "None", "None"],
        )]
        result = self.dispatch()
        update = self.transaction(1)["TransactItems"][0]["Update"]
        self.assert_request_binding(update, before="DISPATCHING")
        self.assertIn("#dispatch = :dispatch", update["ConditionExpression"])
        self.assertEqual(result.recording.outcome, Write.REJECTED)
        self.assertEqual(result.launch.outcome, Launch.ACCEPTED)
        self.assertEqual(self.ledger.transact_write_items.call_count, 2)
        self.ecs.run_task.assert_called_once()

    def test_documented_ecs_refusals_can_release_only_without_prior_sdk_attempts(self):
        for code in ("AccessDeniedException", "BlockedException", "ClusterNotFoundException",
                     "InvalidParameterException", "PlatformTaskDefinitionIncompatibilityException",
                     "PlatformUnknownException", "UnsupportedFeatureException"):
            with self.subTest(code=code):
                self.ledger.reset_mock()
                self.ecs.run_task.side_effect = ServiceError(code)
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.REJECTED)
                self.assertEqual(result.launch.error_code, code)
                self.assertEqual(result.launch.aws_request_id, "service-request-id")
                self.assertIn("Update", self.transaction(1)["TransactItems"][1])
        self.ecs.run_task.side_effect = ServiceError("AccessDeniedException", retries=1)
        self.assertEqual(self.dispatch().launch.outcome, Launch.UNKNOWN)

    def test_ambiguous_ecs_errors_preserve_identifiers_and_reservations(self):
        for error in (TimeoutError("response lost"), ServiceError("ServerException", status=500),
                      ServiceError("ClientException"), ServiceError("FutureException"),
                      ServiceError("AccessDeniedException", resource_ids=[self.task_arn]),
                      ServiceError("ConflictException", resource_ids=self.task_arn),
                      ServiceError("ConflictException", resource_ids=[self.task_arn])):
            with self.subTest(error=type(error).__name__):
                self.ledger.reset_mock()
                self.ecs.reset_mock()
                self.ecs.run_task.side_effect = error
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.UNKNOWN)
                self.assertIn("ConditionCheck", self.transaction(1)["TransactItems"][1])
                self.assertIn("ConditionCheck", self.transaction(1)["TransactItems"][2])
                self.ecs.run_task.assert_called_once()
        self.assertEqual(result.launch.task_arns, (self.task_arn,))
        self.assertIn(self.task_arn, json.dumps(self.transaction(1)))

    def test_minimal_task_response_is_accepted_without_requiring_optional_task_fields(self):
        for arn in (self.task_arn, self.task_arn.replace("task/shared/", "task/")):
            with self.subTest(arn=arn):
                self.ecs.run_task.return_value = acknowledged() | {"tasks": [{"taskArn": arn}]}
                self.assertEqual(self.dispatch().launch.outcome, Launch.ACCEPTED)

    def test_response_ambiguity_preserves_every_observed_task(self):
        second = self.task_arn[:-1] + "b"
        cases = [
            ({"tasks": [], "failures": []}, ()),
            ({"tasks": [{}], "failures": []}, ()),
            ({"tasks": [{"taskArn": self.task_arn}, {"taskArn": second}], "failures": []},
             (self.task_arn, second)),
            ({"tasks": [{"taskArn": self.task_arn}], "failures": [{"reason": "FAILURE"}]},
             (self.task_arn,)),
            ({"tasks": [], "failures": [{"arn": self.task_arn, "reason": "FAILURE"}]},
             (self.task_arn,)),
            ({"tasks": [], "failures": [{}]}, ()),
            ({"tasks": None, "failures": []}, ()),
        ]
        for body, arns in cases:
            with self.subTest(body=body):
                self.ledger.reset_mock()
                self.ecs.run_task.return_value = acknowledged() | body
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.UNKNOWN)
                self.assertEqual(result.launch.task_arns, arns)
                self.assertIn("ConditionCheck", self.transaction(1)["TransactItems"][2])

    def test_unexpected_task_binding_is_unresolved_and_retained_for_reconciliation(self):
        for changed in (
            {"taskArn": self.task_arn.replace("123456789012", "999999999999")},
            {"taskArn": self.task_arn.replace("task/shared/", "task/other/")},
            {"clusterArn": self.run_task["cluster"] + "-other"},
            {"taskDefinitionArn": self.run_task["taskDefinition"] + "0"},
        ):
            with self.subTest(changed=changed):
                self.ecs.run_task.return_value = deepcopy(self.success)
                self.ecs.run_task.return_value["tasks"][0].update(changed)
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.UNKNOWN)
                self.assertEqual(len(result.launch.task_arns), 1)

    def test_missing_or_positive_ecs_retry_metadata_cannot_establish_a_conclusive_outcome(self):
        for retries in (None, 1):
            with self.subTest(retries=retries):
                self.ecs.run_task.return_value = deepcopy(self.success)
                metadata = self.ecs.run_task.return_value["ResponseMetadata"]
                if retries is None:
                    del metadata["RetryAttempts"]
                else:
                    metadata["RetryAttempts"] = retries
                result = self.dispatch()
                self.assertEqual(result.launch.outcome, Launch.UNKNOWN)
                self.assertEqual(result.launch.task_arns, (self.task_arn,))

    def test_unexpected_dynamodb_responses_do_not_create_false_certainty(self):
        self.ledger.transact_write_items.return_value = {}
        result = self.dispatch()
        self.assertEqual(result.claim.outcome, Write.UNKNOWN)
        self.ecs.run_task.assert_not_called()
        self.ledger.transact_write_items.side_effect = [acknowledged(), {}]
        result = self.dispatch()
        self.assertEqual(result.launch.outcome, Launch.ACCEPTED)
        self.assertEqual(result.recording.outcome, Write.UNKNOWN)

    def test_result_and_persisted_evidence_exclude_service_messages_and_task_payloads(self):
        self.success["tasks"][0]["overrides"] = {"private": "private task payload"}
        self.ledger.transact_write_items.side_effect = [acknowledged(), ServiceError(
            "TransactionCanceledException", reasons=["ConditionalCheckFailed", "None", "None"],
        )]
        result = self.dispatch()
        combined = repr(result) + json.dumps(self.transaction(1))
        for secret in ("private task payload", "private service message", "private cancellation detail"):
            self.assertNotIn(secret, combined)
        self.assertEqual(result.recording.cancellation_codes,
                         ("ConditionalCheckFailed", "None", "None"))


if __name__ == "__main__":
    unittest.main()
