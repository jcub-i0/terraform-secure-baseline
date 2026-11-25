"""Connected helper flows with scripted AWS I/O; no delivery authentication or DB simulator."""

from copy import deepcopy
import json
import traceback
from types import SimpleNamespace
import unittest
from unittest.mock import Mock

from broker import AuthenticatedDelivery, DeliveryKind, Disposition, RetryDelivery, handle_sqs_event
from test_admission_executor import ServiceError
from test_dispatch import acknowledged
import test_admission


class BrokerTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_admission.AdmissionTests()
        self.fixture.setUp()
        self.context = SimpleNamespace(aws_request_id="invocation-1")
        self.kind = DeliveryKind.REQUEST
        self.producer = self.fixture.role_id
        self.body = deepcopy(self.fixture.body)
        self.task = "arn:aws:ecs:us-east-1:123456789012:task/shared/" + "a" * 32
        self.item = self.lookup = self.gate = None
        self.ledger = Mock(spec=["transact_write_items", "transact_get_items", "get_item"])
        self.ledger.transact_write_items.side_effect = self.commit
        self.ledger.transact_get_items.side_effect = lambda **_: acknowledged() | {
            "Responses": [{"Item": deepcopy(self.gate)}, {"Item": deepcopy(self.item)}],
        }
        self.ledger.get_item.side_effect = self.read
        self.ecs = Mock(spec=["run_task", "meta"])
        self.ecs.meta = SimpleNamespace(config=SimpleNamespace(retries={"total_max_attempts": 1}))
        self.ecs.run_task.return_value = acknowledged() | {"tasks": [{
            "taskArn": self.task, "clusterArn": self.fixture.document["cluster_arn"],
            "taskDefinitionArn": self.fixture.document["jobs"]["archive"]["binding"]["task_definition_arn"],
        }], "failures": []}
        self.factory = Mock(return_value=self.ecs)
        # Explicitly simulated trust boundary: route and producer come from test
        # context, never from claims in the body or apparent SQS event metadata.
        self.authenticate = Mock(side_effect=lambda record: AuthenticatedDelivery(
            self.kind, record["body"], self.producer,
        ))
        self.runtime = {
            "application_id": "example-app", "environment": "test",
            "catalog_json": json.dumps(self.fixture.document),
            "catalog_approvals": self.fixture.approvals,
            "gate_table_arn": self.fixture.context["gate_table_arn"],
            "ledger_table_arn": self.fixture.context["ledger_table_arn"],
            "ledger_client": self.ledger, "launcher_client_factory": self.factory,
        }

    def event(self):
        return {"Records": [{
            "body": json.dumps(self.body), "messageId": "message-1", "eventSource": "aws:sqs",
            "eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:requests",
            "attributes": {"SenderId": self.fixture.role_id},
        }]}

    def handle(self, **changes):
        return handle_sqs_event(self.event(), self.context, authenticate_delivery=self.authenticate,
                                **(self.runtime | changes))

    def retry(self, **changes):
        with self.assertRaises(RetryDelivery) as raised:
            self.handle(**changes)
        self.assertEqual(raised.exception.result.disposition, Disposition.RETRY)
        return raised.exception.result

    def set_gate(self, action):
        values = action["ExpressionAttributeValues"]
        self.gate = deepcopy(action["Key"]) | {
            name: deepcopy(values[alias]) for name, alias in (
                ("schema_version", ":version"), ("record_type", ":kind"), ("state", ":open"),
                ("admission_generation", ":generation"), ("catalog_sha256", ":digest"),
                ("execution_ledger_arn", ":ledger"),
            )
        }

    def commit(self, **transaction):
        # Record the submitted snapshots for the next scripted read. We do not
        # evaluate DynamoDB expressions, contention, accounting or SDK retries.
        actions = transaction["TransactItems"]
        if "ConditionCheck" in actions[0]:
            self.set_gate(actions[0]["ConditionCheck"])
            self.item = deepcopy(actions[1]["Put"]["Item"])
        else:
            values = actions[0]["Update"]["ExpressionAttributeValues"]
            for alias, name in (
                (":after", "status"), (":dispatch", "dispatch_id"), (":task", "task_arn"),
                (":observation", "launch_observation_json"), (":terminal", "completion_observation_json"),
            ):
                if alias in values:
                    self.item[name] = deepcopy(values[alias])
            if len(actions) == 4:
                self.lookup = deepcopy(actions[3]["Put"]["Item"])
        return acknowledged()

    def collide(self, **transaction):
        self.set_gate(transaction["TransactItems"][0]["ConditionCheck"])
        raise ServiceError("TransactionCanceledException", reasons=[
            "None", "ConditionalCheckFailed", "None", "None",
        ])

    def read(self, **request):
        for item in (self.item, self.lookup):
            if item is not None and request["Key"]["pk"] == item["pk"]:
                return acknowledged() | {"Item": deepcopy(item)}
        return acknowledged()

    def completion(self, status="STOPPED"):
        self.kind = DeliveryKind.COMPLETION
        self.body = {
            "source": "aws.ecs", "detail-type": "ECS Task State Change",
            "account": "123456789012", "region": "us-east-1",
            "detail": {
                "taskArn": self.task, "clusterArn": self.fixture.document["cluster_arn"],
                "taskDefinitionArn": self.fixture.document["jobs"]["archive"]["binding"]["task_definition_arn"],
                "lastStatus": status, "containers": [{"name": "archive", "exitCode": 2}],
            },
        }

    def test_connected_request_duplicate_completion_and_duplicate_completion(self):
        first = self.handle()
        self.assertEqual(first["disposition"], "ACK")
        self.assertEqual(first["reason"], "LAUNCH_ACCEPTED_RECORDING_CONFIRMED")
        self.assertEqual(self.item["status"], {"S": "LAUNCH_ACCEPTED"})
        admission, claim, recording = [c.kwargs for c in self.ledger.transact_write_items.call_args_list]
        self.assertEqual([len(t["TransactItems"]) for t in (admission, claim, recording)], [4, 3, 4])
        self.factory.assert_called_once_with(self.fixture.document["jobs"]["archive"]["binding"]["launcher_role_arn"])
        self.ecs.run_task.assert_called_once_with(**json.loads(self.item["run_task_request_json"]["S"]))
        self.assertEqual(self.lookup["request_pk"], self.item["pk"])

        self.ledger.transact_write_items.side_effect = self.collide
        self.context.aws_request_id = "redelivery"
        duplicate = self.handle()
        candidate = self.ledger.transact_write_items.call_args.kwargs["TransactItems"][1]["Put"]["Item"]
        self.assertEqual(duplicate["reason"], "DUPLICATE_RESOLVED")
        self.assertEqual(duplicate["attempt_id"], first["attempt_id"])
        self.assertNotEqual(candidate["attempt_id"]["S"], first["attempt_id"])
        self.ecs.run_task.assert_called_once()

        self.completion()
        self.ledger.transact_write_items.side_effect = self.commit
        completed = self.handle()
        self.assertEqual(completed["disposition"], "ACK")
        self.assertEqual(self.item["status"], {"S": "TASK_STOPPED"})
        terminal = self.ledger.transact_write_items.call_args.kwargs["TransactItems"]
        self.assertEqual(terminal[1]["Update"]["Key"], admission["TransactItems"][2]["Update"]["Key"])
        self.assertEqual(terminal[2]["Update"]["UpdateExpression"], "ADD #occupied :minus_one")
        self.assertEqual(json.loads(self.item["completion_observation_json"]["S"])["containers"][0]["exit_code"], 2)
        self.ledger.reset_mock()
        self.assertIn("ALREADY_RECORDED", self.handle()["reason"])
        self.ledger.transact_write_items.assert_not_called()

        self.kind, self.body = DeliveryKind.REQUEST, deepcopy(self.fixture.body)
        self.ledger.transact_write_items.side_effect = self.collide
        self.assertEqual(self.handle()["reason"], "DUPLICATE_RESOLVED")
        self.ecs.run_task.assert_called_once()

    def test_recorded_no_task_refusal_and_its_duplicate_are_acknowledged(self):
        self.ecs.run_task.return_value = acknowledged() | {"tasks": [], "failures": [{"reason": "RESOURCE:MEMORY"}]}
        self.assertEqual(self.handle()["reason"], "LAUNCH_REJECTED_RECORDING_CONFIRMED")
        self.assertEqual(self.item["status"], {"S": "LAUNCH_REJECTED"})
        self.assertIsNone(self.lookup)
        self.ledger.transact_write_items.side_effect = self.collide
        self.assertEqual(self.handle()["reason"], "DUPLICATE_RESOLVED")
        self.ecs.run_task.assert_called_once()

    def test_request_denials_fail_delivery_without_aws_calls(self):
        original = deepcopy(self.body)
        for body, producer, reason in (
            ("invalid request object", self.producer, "REQUEST_REJECTED"),
            (original, "unknown-role", "PRODUCER_NOT_AUTHORIZED"),
            (original | {"admission_generation": "old"}, self.producer, "REQUEST_REJECTED"),
            (original | {"kind": "COMPLETION"}, self.producer, "REQUEST_REJECTED"),
            (original | {"overrides": {}}, self.producer, "REQUEST_REJECTED"),
        ):
            with self.subTest(reason=reason):
                self.body, self.producer = body, producer
                self.assertEqual(self.retry().reason, reason)
        self.assertEqual(self.ledger.mock_calls, [])
        self.factory.assert_not_called()

    def test_catalog_and_scope_faults_fail_delivery_before_admission(self):
        self.assertEqual(self.retry(catalog_json="invalid json").reason, "INVALID_CATALOG")
        self.assertEqual(self.retry(application_id="other-app").reason, "CATALOG_SCOPE_MISMATCH")
        self.assertEqual(self.retry(environment="other-env").reason, "CATALOG_SCOPE_MISMATCH")
        self.assertEqual(self.retry(catalog_approvals=None).reason, "PROCESSING_ERROR")
        self.assertEqual(self.ledger.mock_calls, [])
        self.factory.assert_not_called()

    def test_sqs_shaped_event_cannot_bypass_rejected_delivery_authentication(self):
        self.authenticate.side_effect = PermissionError("private authentication details")
        result = self.retry()
        self.assertEqual(result.reason, "DELIVERY_AUTHENTICATION_FAILED")
        self.assertEqual(result.error_code, "PermissionError")
        self.assertNotIn("private", repr(result))
        self.assertEqual(self.ledger.mock_calls, [])
        self.factory.assert_not_called()

    def test_invalid_batches_and_untrusted_routes_never_process_or_acknowledge(self):
        for records in ([], self.event()["Records"] * 2, [None]):
            with self.subTest(records=records), self.assertRaises(RetryDelivery) as raised:
                handle_sqs_event({"Records": records}, self.context,
                                 authenticate_delivery=self.authenticate, **self.runtime)
            self.assertEqual(raised.exception.result.reason, "INVALID_BATCH")
        self.authenticate.assert_not_called()
        self.authenticate.side_effect = None
        for delivery in ({"kind": "COMPLETION"}, AuthenticatedDelivery("COMPLETION", "{}")):
            with self.subTest(delivery=delivery):
                self.authenticate.return_value = delivery
                self.assertEqual(self.retry().reason, "INVALID_DELIVERY_CONTEXT")
        self.assertEqual(self.ledger.mock_calls, [])
        self.factory.assert_not_called()

    def test_completion_does_not_load_current_catalog_or_setup_launcher(self):
        self.handle()
        self.completion("RUNNING")
        self.ledger.reset_mock()
        self.factory.reset_mock()
        broken_config = {"catalog_json": "invalid", "catalog_approvals": None,
                         "gate_table_arn": None, "launcher_client_factory": None}
        self.assertIn("IGNORED", self.handle(**broken_config)["reason"])
        self.assertEqual(self.ledger.mock_calls, [])
        self.body["detail"]["lastStatus"] = "STOPPED"
        self.assertEqual(self.handle(**broken_config)["disposition"], "ACK")
        self.factory.assert_not_called()

    def test_admission_faults_retry_without_dispatch_or_outer_submission_retry(self):
        for failure in (
            ServiceError("TransactionCanceledException", reasons=["ConditionalCheckFailed", "None", "None", "None"]),
            ServiceError("TransactionCanceledException", reasons=["None", "None", "ConditionalCheckFailed", "None"]),
            ServiceError("TransactionCanceledException", reasons=["None", "None", "None", "ConditionalCheckFailed"]),
            ServiceError("AccessDeniedException"), ServiceError("ValidationException"),
            ServiceError("ThrottlingException"), TimeoutError("private timeout"),
        ):
            with self.subTest(failure=type(failure).__name__):
                self.ledger.reset_mock()
                self.ledger.transact_write_items.side_effect = failure
                self.assertTrue(self.retry().reason.startswith("ADMISSION_"))
                self.ledger.transact_write_items.assert_called_once()
                self.ledger.transact_get_items.assert_not_called()
        self.factory.assert_not_called()
        self.ecs.run_task.assert_not_called()

    def test_conflicting_request_intent_is_preserved_for_failure_handling(self):
        self.handle()
        before = deepcopy(self.item)
        self.ledger.transact_write_items.side_effect = self.collide
        self.body["job_key"] = "report"
        self.assertIn("ADMISSION_CONFLICT", self.retry().reason)
        self.assertEqual(self.item, before)
        self.ecs.run_task.assert_called_once()

    def test_unresolved_duplicates_do_not_transfer_ownership_or_dispatch(self):
        self.handle()
        self.ledger.transact_write_items.side_effect = self.collide
        self.context.aws_request_id = "new-invocation"
        for status in ("REGISTERED", "DISPATCHING", "LAUNCH_UNKNOWN"):
            with self.subTest(status=status):
                self.item["status"] = {"S": status}
                before = deepcopy(self.item)
                result = self.retry()
                self.assertEqual(result.reason, "DUPLICATE_UNRESOLVED")
                self.assertEqual(result.attempt_id, before["attempt_id"]["S"])
                self.assertEqual(self.item, before)
        self.ecs.run_task.assert_called_once()
        self.factory.assert_called_once()

    def test_resolved_duplicate_requires_consistent_durable_result_evidence(self):
        self.handle()
        original = deepcopy(self.item)
        self.ledger.transact_write_items.side_effect = self.collide
        for changes in (
            {"task_arn": {"S": "wrong-task"}}, {"attempt_id": {"S": "wrong-attempt"}},
            {"launch_observation_json": {"S": "{}"}}, {"status": {"S": "TASK_STOPPED"}},
            {"status": {"S": "unexpected"}},
        ):
            with self.subTest(changes=changes):
                self.item = original | changes
                self.assertEqual(self.retry().reason, "DUPLICATE_INVALID_RECORD")
        self.ecs.run_task.assert_called_once()

    def test_unknown_admission_then_redelivery_cannot_adopt_committed_reservation(self):
        def commit_then_timeout(**transaction):
            self.commit(**transaction)
            raise TimeoutError("lost admission acknowledgement")

        self.ledger.transact_write_items.side_effect = commit_then_timeout
        first = self.retry()
        self.assertIn("ADMISSION_UNKNOWN", first.reason)
        original = deepcopy(self.item)
        self.ledger.transact_write_items.assert_called_once()
        self.ledger.transact_write_items.side_effect = self.collide
        self.context.aws_request_id = "redelivery"
        self.assertEqual(self.retry().reason, "DUPLICATE_UNRESOLVED")
        candidate = self.ledger.transact_write_items.call_args.kwargs["TransactItems"][1]["Put"]["Item"]
        self.assertEqual(candidate["pk"], original["pk"])
        self.assertNotEqual(candidate["attempt_id"], original["attempt_id"])
        self.assertEqual(self.item, original)
        self.ecs.run_task.assert_not_called()
        self.factory.assert_not_called()

    def test_redelivery_can_acquire_new_reservation_when_prior_uncertain_write_did_not_commit(self):
        self.ledger.transact_write_items.side_effect = TimeoutError("unobserved write")
        first = self.retry()
        self.ledger.transact_write_items.assert_called_once()
        self.assertIsNone(self.item)
        self.ledger.transact_write_items.side_effect = self.commit
        self.context.aws_request_id = "redelivery"
        second = self.handle()
        self.assertEqual(first.request_pk, second["request_pk"])
        self.assertNotEqual(first.attempt_id, second["attempt_id"])
        self.assertEqual(second["disposition"], "ACK")
        self.ecs.run_task.assert_called_once()

    def test_launcher_setup_failure_leaves_admission_for_recovery(self):
        self.factory.side_effect = PermissionError("private setup details")
        result = self.retry()
        self.assertIn("LAUNCHER_SETUP_FAILED", result.reason)
        self.assertEqual(self.item["status"], {"S": "REGISTERED"})
        self.ledger.transact_write_items.assert_called_once()
        self.ecs.run_task.assert_not_called()

    def test_claim_rejection_or_uncertainty_never_reaches_ecs(self):
        for failure in (ServiceError("TransactionCanceledException", reasons=["ConditionalCheckFailed", "None", "None"]),
                        TimeoutError("lost claim acknowledgement")):
            with self.subTest(failure=type(failure).__name__):
                self.ledger.reset_mock()
                def submit(**transaction):
                    if "ConditionCheck" in transaction["TransactItems"][0]:
                        return self.commit(**transaction)
                    raise failure
                self.ledger.transact_write_items.side_effect = submit
                self.assertIn("CLAIM_NOT_CONFIRMED", self.retry().reason)
                self.assertEqual(self.ledger.transact_write_items.call_count, 2)
        self.ecs.run_task.assert_not_called()

    def test_recorded_unknown_launch_and_redelivery_remain_retry_without_relaunch(self):
        self.ecs.run_task.side_effect = TimeoutError("private ECS details")
        self.assertEqual(self.retry().reason, "LAUNCH_UNKNOWN_RECORDING_CONFIRMED")
        self.assertEqual(self.item["status"], {"S": "LAUNCH_UNKNOWN"})
        self.ledger.transact_write_items.side_effect = self.collide
        self.assertEqual(self.retry().reason, "DUPLICATE_UNRESOLVED")
        self.ecs.run_task.assert_called_once()

    def test_accepted_launch_with_failed_recording_retries_and_redelivery_observes_actual_state(self):
        for committed in (False, True):
            with self.subTest(committed=committed):
                self.setUp()
                def submit(**transaction):
                    first = transaction["TransactItems"][0]
                    accepted = ("Update" in first and first["Update"]["ExpressionAttributeValues"][":after"]
                                == {"S": "LAUNCH_ACCEPTED"})
                    if accepted:
                        if committed:
                            self.commit(**transaction)
                            raise TimeoutError("lost result acknowledgement")
                        raise ServiceError("AccessDeniedException")
                    return self.commit(**transaction)
                self.ledger.transact_write_items.side_effect = submit
                self.assertTrue(self.retry().reason.startswith("LAUNCH_ACCEPTED_RECORDING_"))
                self.ledger.transact_write_items.side_effect = self.collide
                if committed:
                    self.assertEqual(self.handle()["reason"], "DUPLICATE_RESOLVED")
                else:
                    self.assertEqual(self.retry().reason, "DUPLICATE_UNRESOLVED")
                self.ecs.run_task.assert_called_once()

    def test_early_completion_retries_then_records_after_launch_lookup_exists(self):
        request = deepcopy(self.body)
        self.completion()
        terminal = deepcopy(self.body)
        self.assertIn("DEFERRED:LOOKUP_NOT_FOUND", self.retry().reason)
        self.ledger.transact_write_items.assert_not_called()
        self.kind, self.body = DeliveryKind.REQUEST, request
        self.handle()
        self.kind, self.body = DeliveryKind.COMPLETION, terminal
        self.assertIn("COMPLETION_RECORDED", self.handle()["reason"])

    def test_completion_invalid_evidence_and_read_or_write_failures_retry(self):
        self.handle()
        self.completion()
        self.body["account"] = "999999999999"
        self.body["detail"]["taskArn"] = "private event contents"
        rejected = self.retry()
        self.assertIn("COMPLETION_REJECTED", rejected.reason)
        self.assertIsNone(rejected.task_arn)
        self.assertNotIn("private", repr(rejected))
        self.body["account"] = "123456789012"
        self.body["detail"]["taskArn"] = self.task
        self.ledger.get_item.side_effect = TimeoutError("private read error")
        self.assertIn("COMPLETION_UNKNOWN", self.retry().reason)
        self.ledger.get_item.side_effect = self.read
        self.ledger.transact_write_items.side_effect = ServiceError("TransactionCanceledException",
                                                                   reasons=["None", "ConditionalCheckFailed", "None"])
        self.assertIn("COMPLETION_REJECTED:WRITE_REJECTED", self.retry().reason)
        self.assertEqual(self.item["status"], {"S": "LAUNCH_ACCEPTED"})
        self.ecs.run_task.assert_called_once()

    def test_lost_completion_ack_retries_then_acknowledges_without_second_write(self):
        self.handle()
        self.completion()
        self.ledger.reset_mock()
        def submit(**transaction):
            self.commit(**transaction)
            raise TimeoutError("lost completion acknowledgement")
        self.ledger.transact_write_items.side_effect = submit
        self.assertIn("COMPLETION_UNKNOWN:WRITE_UNKNOWN", self.retry().reason)
        self.assertIn("ALREADY_RECORDED", self.handle()["reason"])
        self.ledger.transact_write_items.assert_called_once()

    def test_unexpected_error_after_admission_fails_without_cleanup_or_sensitive_traceback(self):
        class BrokenClient:
            @property
            def meta(self):
                raise RuntimeError("private runtime data")
        self.factory.return_value = BrokenClient()
        with self.assertRaises(RetryDelivery) as raised:
            self.handle()
        result = raised.exception.result
        self.assertEqual((result.reason, result.error_code), ("PROCESSING_ERROR", "RuntimeError"))
        self.assertNotIn("private runtime data", ''.join(traceback.format_exception(raised.exception)))
        self.assertEqual(self.item["status"], {"S": "REGISTERED"})
        self.ledger.transact_write_items.assert_called_once()
        self.ecs.run_task.assert_not_called()

    def test_results_and_duplicate_handling_do_not_expose_message_or_ledger_snapshots(self):
        self.body["request_key"] = "private-request-key"
        first = self.handle()
        self.ledger.transact_write_items.side_effect = self.collide
        duplicate = self.handle()
        for result in (first, duplicate):
            self.assertNotIn("private-request-key", json.dumps(result))
            self.assertNotIn("original_request_json", result)
            self.assertNotIn("run_task_request_json", result)
            self.assertEqual(set(result), {"disposition", "reason", "request_pk", "attempt_id",
                                           "dispatch_id", "task_arn", "error_code"})
        self.assertNotIn("private-request-key", repr(AuthenticatedDelivery(DeliveryKind.REQUEST, json.dumps(self.body))))


if __name__ == "__main__":
    unittest.main()
