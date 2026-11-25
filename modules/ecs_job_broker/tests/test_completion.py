"""Completion wire contracts with scripted clients, not AWS authentication/atomicity."""

from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
from threading import Barrier, Lock
import unittest
from unittest.mock import Mock

from completion import CompletionOutcome as Outcome, record_task_completion
from dispatch import WriteOutcome as Write
from test_dispatch import ServiceError, acknowledged
import test_dispatch


class CompletionTests(unittest.TestCase):
    def setUp(self):
        # Exercise the actual admission -> dispatch -> lookup wire contract.
        # Import the module, not its TestCase, to avoid duplicate discovery.
        self.fixture = test_dispatch.DispatchTests()
        self.fixture.setUp()
        dispatched = self.fixture.dispatch()
        self.item = deepcopy(self.fixture.item)
        self.item.update({
            "status": {"S": "LAUNCH_ACCEPTED"}, "task_arn": {"S": self.fixture.task_arn},
            "dispatch_id": {"S": dispatched.dispatch_id},
        })
        self.lookup = deepcopy(self.fixture.transaction(1)["TransactItems"][3]["Put"]["Item"])
        self.context = {
            "application_id": "example-app", "environment": "test",
            "ledger_table_arn": self.fixture.fixture.context["ledger_table_arn"],
        }
        self.event = {
            "source": "aws.ecs", "detail-type": "ECS Task State Change",
            "account": "123456789012", "region": "us-east-1",
            "id": "event-1", "time": "2026-11-25T23:00:00Z",
            "detail": {
                "taskArn": self.fixture.task_arn, "clusterArn": self.fixture.run_task["cluster"],
                "taskDefinitionArn": self.fixture.run_task["taskDefinition"],
                "lastStatus": "STOPPED", "desiredStatus": "STOPPED", "version": 7,
                "stoppedAt": "2026-11-25T22:59:59Z", "stopCode": "EssentialContainerExited",
                "containers": [{"name": "archive", "exitCode": 0}],
            },
        }
        self.ledger = Mock(spec=["get_item", "transact_write_items"])
        self.ledger.get_item.side_effect = self.read
        self.ledger.transact_write_items.return_value = acknowledged()

    def read(self, **request):
        key = request["Key"]["pk"]["S"]
        for item in (self.lookup, self.item):
            if item is not None and item["pk"]["S"] == key:
                return acknowledged() | {"Item": deepcopy(item)}
        return acknowledged()

    def complete(self, **changes):
        return record_task_completion(self.event, ledger_client=self.ledger,
                                      **(self.context | changes))

    def transaction(self):
        return self.ledger.transact_write_items.call_args.kwargs

    def remember_terminal_write(self, transaction):
        # Script the persisted response state; this is not an expression engine.
        values = transaction["TransactItems"][0]["Update"]["ExpressionAttributeValues"]
        self.item["status"] = deepcopy(values[":after"])
        self.item["completion_observation_json"] = deepcopy(values[":terminal"])

    def test_stopped_event_reads_lookup_and_request_consistently_then_records(self):
        before = deepcopy((self.event, self.lookup, self.item))
        result = self.complete()
        self.assertEqual(result.outcome, Outcome.RECORDED)
        self.assertEqual(result.recording.outcome, Write.CONFIRMED)
        self.assertEqual(result.request_pk, self.item["pk"]["S"])
        self.assertEqual(result.attempt_id, self.item["attempt_id"]["S"])
        self.assertEqual(result.dispatch_id, self.item["dispatch_id"]["S"])
        self.assertEqual([call.kwargs for call in self.ledger.get_item.call_args_list], [
            {"TableName": self.context["ledger_table_arn"], "Key": {"pk": item["pk"]},
             "ConsistentRead": True} for item in (self.lookup, self.item)
        ])
        self.ledger.transact_write_items.assert_called_once()
        self.assertEqual((self.event, self.lookup, self.item), before)

    def test_terminal_transaction_binds_request_attempt_snapshot_and_task(self):
        self.complete()
        transaction = self.transaction()
        self.assertEqual([list(action) for action in transaction["TransactItems"]],
                         [["Update"], ["Update"], ["Update"]])
        update = transaction["TransactItems"][0]["Update"]
        self.assertEqual(update["Key"], {"pk": self.item["pk"]})
        names, values = update["ExpressionAttributeNames"], update["ExpressionAttributeValues"]
        for alias, field in (
            ("#app", "application_id"), ("#env", "environment"), ("#job", "job_key"),
            ("#owner", "owner_invocation_id"), ("#attempt", "attempt_id"),
            ("#dispatch", "dispatch_id"), ("#task", "task_arn"),
            ("#intent", "intent_json"), ("#launch", "run_task_request_json"),
        ):
            self.assertEqual(names[alias], field)
            self.assertEqual(values[":" + alias[1:]], self.item[field])
            self.assertIn(f"{alias} = :{alias[1:]}", update["ConditionExpression"])
        self.assertEqual(values[":version"], {"N": "1"})
        self.assertEqual(values[":kind"], {"S": "REQUEST"})
        self.assertIn("#version = :version AND #kind = :kind AND #status = :before",
                      update["ConditionExpression"])
        self.assertIn("attribute_not_exists(#terminal)", update["ConditionExpression"])
        self.assertEqual(values[":before"], {"S": "LAUNCH_ACCEPTED"})
        self.assertEqual(values[":after"], {"S": "TASK_STOPPED"})
        self.assertEqual(update["UpdateExpression"], "SET #status = :after, #terminal = :terminal")
        self.assertNotIn(transaction["ClientRequestToken"],
                         (self.item["attempt_id"]["S"], self.item["dispatch_id"]["S"]))

    def test_slot_release_and_counter_decrement_are_atomic_and_preserve_pending(self):
        self.complete()
        _, slot, accounting = [action["Update"] for action in self.transaction()["TransactItems"]]
        original = self.fixture.prepared.transaction_request()["TransactItems"]
        self.assertEqual(slot["Key"], original[2]["Update"]["Key"])
        self.assertEqual(slot["ConditionExpression"],
                         "#version = :version AND #kind = :kind AND #state = :occupied "
                         "AND #request = :request AND #attempt = :attempt AND #job = :job")
        for alias, field in ((":request", "pk"), (":attempt", "attempt_id"), (":job", "job_key")):
            self.assertEqual(slot["ExpressionAttributeValues"][alias], self.item[field])
        self.assertEqual(slot["UpdateExpression"], "SET #state = :free REMOVE #request, #attempt")
        self.assertEqual(accounting["Key"], original[3]["Update"]["Key"])
        self.assertEqual(accounting["ConditionExpression"],
                         "#version = :version AND #kind = :kind "
                         "AND #pending >= :zero AND #occupied > #pending")
        self.assertEqual(accounting["ExpressionAttributeValues"][":zero"], {"N": "0"})
        self.assertEqual(accounting["ExpressionAttributeValues"][":minus_one"], {"N": "-1"})
        self.assertEqual(accounting["UpdateExpression"], "ADD #occupied :minus_one")
        self.assertEqual(accounting["ExpressionAttributeNames"]["#pending"], "unresolved_launches")
        for action in self.transaction()["TransactItems"]:
            self.assertEqual(action["Update"]["TableName"], self.context["ledger_table_arn"])

    def test_completion_uses_original_release_without_reopening_admission(self):
        self.item["admission_generation"] = {"S": "retired-generation"}
        self.item["catalog_sha256"] = {"S": "retired-catalog"}
        self.assertEqual(self.complete().outcome, Outcome.RECORDED)
        self.assertNotIn(self.fixture.fixture.context["gate_table_arn"], json.dumps(self.transaction()))
        self.assertNotIn("admission_generation", json.dumps(self.transaction()))

    def test_nonzero_exit_and_startup_failure_release_capacity_without_claiming_success(self):
        for changes in ({"containers": [{"name": "archive", "exitCode": 2}]},
                        {"stopCode": "TaskFailedToStart", "containers": []}):
            with self.subTest(changes=changes):
                self.event["detail"].update(changes)
                self.assertEqual(self.complete().outcome, Outcome.RECORDED)
                evidence = json.loads(self.transaction()["TransactItems"][0]["Update"]
                                      ["ExpressionAttributeValues"][":terminal"]["S"])
                self.assertEqual(evidence["last_status"], "STOPPED")
                self.assertNotIn("success", evidence)

    def test_desired_stop_or_container_exit_is_not_terminal_task_evidence(self):
        for status in ("RUNNING", "STOPPING", "DEPROVISIONING"):
            with self.subTest(status=status):
                self.event["detail"]["lastStatus"] = status
                self.event["detail"]["containers"][0]["lastStatus"] = "STOPPED"
                self.assertEqual(self.complete().outcome, Outcome.IGNORED)
        self.assertEqual(self.ledger.mock_calls, [])

    def test_event_envelope_and_account_region_mismatches_stop_before_reads(self):
        original = deepcopy(self.event)
        for changes in ({"source": "application"}, {"detail-type": "other"},
                        {"account": "999999999999"}, {"region": "us-west-2"}, {"detail": []}):
            with self.subTest(changes=changes):
                self.event = original | changes
                self.assertEqual(self.complete().outcome, Outcome.REJECTED)
        self.event = deepcopy(original)
        self.event["detail"]["taskArn"] = self.fixture.task_arn.replace("123456789012", "999999999999")
        self.assertEqual(self.complete().reason, "EVENT_SCOPE_MISMATCH")
        self.assertEqual(self.ledger.mock_calls, [])

    def test_missing_terminal_identity_is_rejected_without_io(self):
        original = deepcopy(self.event)
        for key in ("taskArn", "clusterArn", "taskDefinitionArn", "lastStatus"):
            with self.subTest(key=key):
                self.event = deepcopy(original)
                del self.event["detail"][key]
                self.assertEqual(self.complete().outcome, Outcome.REJECTED)
        self.assertEqual(self.ledger.mock_calls, [])

    def test_protected_context_is_required(self):
        for changes in ({"application_id": ""}, {"environment": " "},
                        {"ledger_table_arn": "ledger"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.complete(**changes)
        self.assertEqual(self.ledger.mock_calls, [])

    def test_early_event_is_deferred_then_can_complete_after_launch_recording(self):
        lookup = self.lookup
        self.lookup = None
        early = self.complete()
        self.assertEqual(early.outcome, Outcome.DEFERRED)
        self.assertEqual(early.reason, "LOOKUP_NOT_FOUND")
        self.assertEqual(early.recording.outcome, Write.NOT_ATTEMPTED)
        self.ledger.transact_write_items.assert_not_called()
        self.lookup = lookup
        self.assertEqual(self.complete().outcome, Outcome.RECORDED)

    def test_missing_request_and_unresolved_launch_states_never_release(self):
        item = self.item
        self.item = None
        self.assertEqual(self.complete().reason, "REQUEST_NOT_FOUND")
        self.item = item
        for status in ("REGISTERED", "DISPATCHING", "LAUNCH_UNKNOWN"):
            with self.subTest(status=status):
                self.item["status"] = {"S": status}
                self.assertEqual(self.complete().reason, "LAUNCH_NOT_RECORDED")
        self.ledger.transact_write_items.assert_not_called()

    def test_lookup_cannot_cross_scope_schema_or_task_identity(self):
        original = deepcopy(self.lookup)
        for field, value in (
            ("schema_version", {"N": "2"}), ("record_type", {"S": "REQUEST"}),
            ("application_id", {"S": "other-app"}), ("environment", {"S": "production"}),
            ("task_arn", {"S": "other-task"}), ("attempt_id", {"S": ""}),
            ("dispatch_id", {"N": "1"}), ("request_pk", {"S": "", "N": "1"}),
        ):
            with self.subTest(field=field):
                self.lookup = original | {field: value}
                self.ledger.reset_mock()
                self.assertEqual(self.complete().reason, "INVALID_LOOKUP")
                self.ledger.get_item.assert_called_once()
                self.ledger.transact_write_items.assert_not_called()

    def test_request_must_match_lookup_attempt_dispatch_task_and_scope(self):
        original = deepcopy(self.item)
        for field, value in (
            ("schema_version", {"N": "2"}), ("record_type", {"S": "SLOT"}),
            ("application_id", {"S": "other-app"}), ("environment", {"S": "other-env"}),
            ("attempt_id", {"S": "other-attempt"}), ("dispatch_id", {"S": "other-dispatch"}),
            ("task_arn", {"S": "other-task"}), ("status", {"S": "LAUNCH_REJECTED"}),
            ("owner_invocation_id", {"S": ""}),
        ):
            with self.subTest(field=field):
                self.item = original | {field: value}
                self.assertEqual(self.complete().reason, "INVALID_REQUEST")
        self.ledger.transact_write_items.assert_not_called()

    def test_cluster_and_exact_task_definition_are_bound_to_original_launch(self):
        original = deepcopy(self.event)
        for key in ("clusterArn", "taskDefinitionArn"):
            with self.subTest(key=key):
                self.event = deepcopy(original)
                self.event["detail"][key] += "0"
                self.assertEqual(self.complete().reason, "LAUNCH_IDENTITY_MISMATCH")
        self.ledger.transact_write_items.assert_not_called()

    def test_inconsistent_or_unreadable_launch_snapshot_is_rejected(self):
        original = deepcopy(self.item)
        launch = deepcopy(self.fixture.run_task)
        for field, value in (
            ("run_task_request_json", "not json"), ("intent_json", "[]"),
            ("run_task_request_json", json.dumps(launch | {"clientToken": "other-attempt"})),
            ("run_task_request_json", json.dumps(launch | {"count": 2})),
            ("job_key", "report"),
        ):
            with self.subTest(field=field, value=value):
                self.item = original | {field: {"S": value}}
                self.assertEqual(self.complete().reason, "LAUNCH_IDENTITY_MISMATCH")
        self.ledger.transact_write_items.assert_not_called()

    def test_duplicate_event_does_not_touch_a_slot_that_may_have_been_reused(self):
        self.complete()
        self.remember_terminal_write(self.transaction())
        self.ledger.reset_mock()
        self.event["id"] = "another-delivery-id"
        self.event["detail"]["version"] = 8
        result = self.complete()
        self.assertEqual(result.outcome, Outcome.ALREADY_RECORDED)
        self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
        self.ledger.transact_write_items.assert_not_called()
        self.assertEqual(self.ledger.get_item.call_count, 2)  # No slot read or write.

    def test_missing_or_contradictory_terminal_record_is_not_reported_as_complete(self):
        self.item["status"] = {"S": "TASK_STOPPED"}
        for value in (None, "not json", json.dumps({"task_arn": "another-task"})):
            with self.subTest(value=value):
                if value is None:
                    self.item.pop("completion_observation_json", None)
                else:
                    self.item["completion_observation_json"] = {"S": value}
                self.assertEqual(self.complete().reason, "INVALID_TERMINAL_RECORD")
        self.ledger.transact_write_items.assert_not_called()

    def test_terminal_evidence_on_nonterminal_request_is_not_overwritten(self):
        self.item["completion_observation_json"] = {"S": "existing evidence"}
        self.assertEqual(self.complete().reason, "INVALID_TERMINAL_RECORD")
        self.ledger.transact_write_items.assert_not_called()

    def test_each_transaction_guard_can_reject_without_partial_cleanup(self):
        for position in range(3):
            with self.subTest(position=position):
                self.ledger.reset_mock()
                codes = ["None"] * 3
                codes[position] = "ConditionalCheckFailed"
                self.ledger.transact_write_items.side_effect = ServiceError(
                    "TransactionCanceledException", reasons=codes,
                )
                result = self.complete()
                self.assertEqual(result.outcome, Outcome.REJECTED)
                self.assertEqual(result.recording.cancellation_codes, tuple(codes))
                self.ledger.transact_write_items.assert_called_once()
                self.assertEqual(self.ledger.get_item.call_count, 2)

    def test_lost_completion_ack_is_unknown_until_redelivery_observes_terminal_record(self):
        def persist_then_timeout(**transaction):
            self.remember_terminal_write(transaction)
            raise TimeoutError("private response failure")

        self.ledger.transact_write_items.side_effect = persist_then_timeout
        first = self.complete()
        self.assertEqual(first.outcome, Outcome.UNKNOWN)
        self.assertEqual(first.recording.outcome, Write.UNKNOWN)
        self.assertEqual(self.complete().outcome, Outcome.ALREADY_RECORDED)
        self.ledger.transact_write_items.assert_called_once()

    def test_competing_completions_submit_conditions_and_only_scripted_winner_records(self):
        barrier, lock = Barrier(2), Lock()
        submissions = []

        def submit(**transaction):
            # Both read the accepted request before the scripted commit race.
            # This models service responses, not DynamoDB condition evaluation.
            barrier.wait(timeout=5)
            with lock:
                submissions.append(transaction)
                if len(submissions) == 1:
                    return acknowledged()
                raise ServiceError("TransactionCanceledException", reasons=[
                    "ConditionalCheckFailed", "ConditionalCheckFailed", "None",
                ])

        self.ledger.transact_write_items.side_effect = submit
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.complete(), range(2)))
        self.assertCountEqual([r.outcome for r in results], [Outcome.RECORDED, Outcome.REJECTED])
        self.assertNotEqual(submissions[0]["ClientRequestToken"], submissions[1]["ClientRequestToken"])
        self.assertEqual(submissions[0]["TransactItems"], submissions[1]["TransactItems"])

    def test_sdk_replayed_write_ack_is_confirmed_but_retried_errors_remain_uncertain(self):
        self.ledger.transact_write_items.return_value = acknowledged(2)
        self.assertEqual(self.complete().recording.sdk_retry_attempts, 2)
        for failure in (ServiceError("TransactionCanceledException", retries=1),
                        ServiceError("AccessDeniedException", retries=None), TimeoutError("private")):
            with self.subTest(failure=type(failure).__name__):
                self.ledger.transact_write_items.side_effect = failure
                self.assertEqual(self.complete().outcome, Outcome.UNKNOWN)

    def test_read_failures_are_not_mistaken_for_missing_or_completed_records(self):
        for position in (0, 1):
            for failure in (ServiceError("AccessDeniedException"), TimeoutError("private")):
                with self.subTest(position=position, failure=type(failure).__name__):
                    responses = [acknowledged() | {"Item": deepcopy(self.lookup)},
                                 acknowledged() | {"Item": deepcopy(self.item)}]
                    responses[position] = failure
                    self.ledger.get_item.side_effect = responses
                    result = self.complete()
                    self.assertEqual(result.outcome, Outcome.UNKNOWN)
                    self.assertEqual(result.recording.outcome, Write.NOT_ATTEMPTED)
                    self.assertIn(result.read_error_code, ("AccessDeniedException", "TimeoutError"))
        self.ledger.transact_write_items.assert_not_called()

    def test_malformed_service_responses_do_not_establish_completion(self):
        for response in ({}, acknowledged() | {"Item": None}, acknowledged() | {"Item": []}):
            with self.subTest(response=response):
                self.ledger.get_item.side_effect = None
                self.ledger.get_item.return_value = response
                self.assertEqual(self.complete().outcome, Outcome.UNKNOWN)
        self.ledger.get_item.side_effect = self.read
        self.ledger.transact_write_items.return_value = {}
        self.assertEqual(self.complete().recording.outcome, Write.UNKNOWN)

    def test_evidence_retains_only_structured_terminal_metadata(self):
        self.event["futureAwsField"] = {"private": "private future field"}
        self.event["detail"].update({
            "overrides": {"environment": "private environment"}, "stoppedReason": "private reason",
            "containers": [{"name": "archive", "exitCode": 23, "reason": "private container reason"}],
        })
        self.ledger.transact_write_items.side_effect = ServiceError(
            "TransactionCanceledException", reasons=["None", "ConditionalCheckFailed", "None"],
        )
        result = self.complete()
        evidence = json.loads(self.transaction()["TransactItems"][0]["Update"]
                              ["ExpressionAttributeValues"][":terminal"]["S"])
        self.assertEqual(evidence, {
            "task_arn": self.fixture.task_arn, "cluster_arn": self.fixture.run_task["cluster"],
            "task_definition_arn": self.fixture.run_task["taskDefinition"], "last_status": "STOPPED",
            "event_id": "event-1", "event_time": "2026-11-25T23:00:00Z", "task_version": 7,
            "stopped_at": "2026-11-25T22:59:59Z", "stop_code": "EssentialContainerExited",
            "containers": [{"name": "archive", "exit_code": 23}],
        })
        serialized = json.dumps(self.transaction()) + repr(result)
        self.assertNotIn("private", serialized)

    def test_optional_diagnostics_do_not_control_terminal_release(self):
        self.event.pop("id")
        self.event.pop("time")
        for key in ("version", "stoppedAt", "stopCode", "containers"):
            self.event["detail"].pop(key)
        self.assertEqual(self.complete().outcome, Outcome.RECORDED)


if __name__ == "__main__":
    unittest.main()
