"""Connected helper flows with scripted AWS I/O; no delivery authentication or DB simulator."""

from copy import deepcopy
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import traceback
from types import SimpleNamespace
import unittest
from unittest.mock import ANY, Mock, patch

import broker
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


class RuntimeBootstrapTests(unittest.TestCase):
    """Real handler with package fixtures; no network, queue provenance or IAM proof."""

    def setUp(self):
        self.flow = BrokerTests()
        self.flow.setUp()
        temporary = TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.package = Path(temporary.name)
        self.function = "arn:aws:lambda:us-east-1:123456789012:function:broker-test"
        self.config = {
            "schema_version": 1, "application_id": "example-app", "environment": "test",
            "function_arn": self.function,
            "ledger_table_arn": self.flow.fixture.context["ledger_table_arn"],
            "request_queue_arn": "arn:aws:sqs:us-east-1:123456789012:requests",
            "completion_queue_arn": "arn:aws:sqs:us-east-1:123456789012:completions",
            "requests": {
                "gate_table_arn": self.flow.fixture.context["gate_table_arn"],
                "catalog_approvals": {
                    "approved_cluster_arn": self.flow.fixture.approvals["approved_cluster_arn"],
                    "approved_private_subnet_ids": sorted(self.flow.fixture.approvals["approved_private_subnet_ids"]),
                    "approved_security_groups_by_job": {
                        job: sorted(groups) for job, groups in
                        self.flow.fixture.approvals["approved_security_groups_by_job"].items()
                    },
                },
            },
        }
        self.write_config()
        (self.package / "catalog.json").write_text(json.dumps(self.flow.fixture.document))
        self.remaining = 60000
        self.context = SimpleNamespace(
            aws_request_id="invocation-1", invoked_function_arn=self.function + ":qualified",
            get_remaining_time_in_millis=lambda: self.remaining,
        )
        self.credentials = {
            "AccessKeyId": "ASIA" + "A" * 16, "SecretAccessKey": "private-secret",
            "SessionToken": "private-session-token",
            "Expiration": datetime.now(timezone.utc) + timedelta(minutes=15),
        }
        self.sts = Mock()
        self.sts.assume_role.return_value = {"Credentials": self.credentials}
        self.session = Mock()
        self.session.client.side_effect = self.client
        self.sdk = self.enterContext(patch.object(broker, "_sdk_session", return_value=self.session))
        self.enterContext(patch.object(broker, "_PACKAGE_ROOT", self.package))

    def write_config(self):
        (self.package / "runtime.json").write_text(json.dumps(self.config))

    def client(self, service, **kwargs):
        return {"dynamodb": self.flow.ledger, "sts": self.sts, "ecs": self.flow.ecs}[service]

    def event(self):
        event = self.flow.event()
        record = event["Records"][0]
        record["awsRegion"] = "us-east-1"
        record["attributes"]["SenderId"] = self.flow.fixture.role_id + ":arbitrary-session-name"
        if self.flow.kind is DeliveryKind.COMPLETION:
            record["eventSourceARN"] = self.config["completion_queue_arn"]
            record["attributes"] = {"SenderId": "service-sender-not-a-producer-role"}
        return event

    def invoke(self, event=None):
        return broker.lambda_handler(self.event() if event is None else event, self.context)

    def retry(self, event=None):
        with self.assertRaises(RetryDelivery) as raised:
            self.invoke(event)
        self.assertEqual(raised.exception.result.disposition, Disposition.RETRY)
        return raised.exception

    def test_packaged_handler_launches_using_exact_role_region_and_temporary_credentials(self):
        result = self.invoke()
        self.assertEqual(result["disposition"], "ACK")
        self.sdk.assert_called_once_with("us-east-1")
        self.sts.assume_role.assert_called_once_with(
            RoleArn=self.flow.fixture.document["jobs"]["archive"]["binding"]["launcher_role_arn"],
            RoleSessionName="broker-invocation-1", DurationSeconds=900,
        )
        calls = {call.args[0]: call.kwargs for call in self.session.client.call_args_list}
        self.assertEqual(set(calls), {"dynamodb", "sts", "ecs"})
        for service, (attempts, read) in {"dynamodb": (3, 2), "sts": (1, 2), "ecs": (1, 3)}.items():
            kwargs = calls[service]
            self.assertEqual(kwargs["region_name"], "us-east-1")
            self.assertEqual(kwargs["config"].retries, {"mode": "standard", "total_max_attempts": attempts})
            self.assertEqual((kwargs["config"].connect_timeout, kwargs["config"].read_timeout), (1, read))
            self.assertTrue(kwargs["config"].ignore_configured_endpoint_urls)
        for field, key in (("aws_access_key_id", "AccessKeyId"), ("aws_secret_access_key", "SecretAccessKey"),
                           ("aws_session_token", "SessionToken")):
            self.assertEqual(calls["ecs"][field], self.credentials[key])
            self.assertNotIn(field, calls["dynamodb"])
        self.flow.ecs.run_task.assert_called_once()
        self.assertNotIn("private", json.dumps(result))

    def test_request_identity_uses_role_id_not_session_or_body_claims(self):
        first = self.invoke()
        self.flow.ledger.transact_write_items.side_effect = self.flow.collide
        event = self.event()
        event["Records"][0]["attributes"]["SenderId"] = self.flow.fixture.role_id + ":different-session"
        duplicate = self.invoke(event)
        self.assertEqual(duplicate["request_pk"], first["request_pk"])
        self.assertEqual(duplicate["reason"], "DUPLICATE_RESOLVED")
        self.flow.body["producer_role_id"] = self.flow.fixture.role_id
        self.assertEqual(self.retry().result.reason, "REQUEST_REJECTED")
        self.flow.ecs.run_task.assert_called_once()

    def test_invalid_delivery_route_and_non_role_sender_fail_before_client_construction(self):
        for change in (
            {"eventSource": "other"}, {"awsRegion": "us-west-2"},
            {"eventSourceARN": "arn:aws:sqs:us-east-1:123456789012:unapproved"},
            {"eventSourceARN": "arn:aws:sqs:us-east-1:999999999999:requests"},
            {"attributes": {}}, {"attributes": {"SenderId": "AIDAUSER"}},
            {"attributes": {"SenderId": self.flow.fixture.role_id}},
        ):
            with self.subTest(change=change):
                event = self.event()
                event["Records"][0].update(change)
                self.assertEqual(self.retry(event).result.reason, "BOOTSTRAP_FAILED")
        self.sdk.assert_not_called()
        self.flow.ledger.transact_write_items.assert_not_called()

    def test_sender_authorization_cannot_be_supplied_by_custom_attributes(self):
        event = self.event()
        event["Records"][0]["attributes"]["SenderId"] = "AROA" + "Z" * 17 + ":session"
        event["Records"][0]["messageAttributes"] = {"SenderId": {"stringValue": self.flow.fixture.role_id}}
        self.assertEqual(self.retry(event).result.reason, "PRODUCER_NOT_AUTHORIZED")
        self.sts.assume_role.assert_not_called()
        self.flow.ledger.transact_write_items.assert_not_called()

    def test_completion_route_does_not_load_request_catalog_gate_or_credentials(self):
        self.invoke()
        self.flow.completion()
        self.session.client.reset_mock()
        self.sts.assume_role.reset_mock()
        del self.config["requests"]
        self.write_config()
        (self.package / "catalog.json").unlink()
        result = self.invoke()
        self.assertEqual(result["disposition"], "ACK")
        self.assertEqual(self.flow.item["status"], {"S": "TASK_STOPPED"})
        self.assertEqual([c.args[0] for c in self.session.client.call_args_list], ["dynamodb"])
        self.sts.assume_role.assert_not_called()
        self.flow.ecs.run_task.assert_called_once()

    def test_request_queue_cannot_select_completion_via_body(self):
        self.flow.completion()
        event = self.event()
        event["Records"][0]["eventSourceARN"] = self.config["request_queue_arn"]
        event["Records"][0]["attributes"]["SenderId"] = self.flow.fixture.role_id + ":session"
        self.assertEqual(self.retry(event).result.reason, "REQUEST_REJECTED")
        self.flow.ledger.get_item.assert_not_called()
        self.flow.ledger.transact_write_items.assert_not_called()

    def test_unprovisioned_completion_route_is_closed(self):
        self.flow.completion()
        event = self.event()
        self.config["completion_queue_arn"] = None
        self.write_config()
        self.assertEqual(self.retry(event).result.reason, "BOOTSTRAP_FAILED")
        self.sdk.assert_not_called()

    def test_package_scope_bindings_fail_closed_before_aws(self):
        original = deepcopy(self.config)
        for change in (
            {"schema_version": True}, {"function_arn": self.function + "-other"},
            {"ledger_table_arn": "arn:aws:dynamodb:us-west-2:123456789012:table/ledger"},
            {"request_queue_arn": "arn:aws:sqs:us-east-1:999999999999:requests"},
            {"completion_queue_arn": self.config["request_queue_arn"]},
            {"requests": original["requests"] | {"gate_table_arn": original["ledger_table_arn"]}},
        ):
            with self.subTest(change=change):
                self.config = original | change
                self.write_config()
                self.assertEqual(self.retry().result.reason, "BOOTSTRAP_FAILED")
        self.sdk.assert_not_called()

    def test_packaged_catalog_keeps_exact_bytes_and_independent_approvals(self):
        raw = json.dumps(self.flow.fixture.document, indent=2).replace("\n", "\r\n").encode("utf-8")
        (self.package / "catalog.json").write_bytes(raw)
        self.invoke()
        values = self.flow.ledger.transact_write_items.call_args_list[0].kwargs["TransactItems"][0]["ConditionCheck"]["ExpressionAttributeValues"]
        self.assertEqual(values[":digest"], {"S": hashlib.sha256(raw).hexdigest()})
        self.config["requests"]["catalog_approvals"]["approved_private_subnet_ids"] = ["subnet-99999999"]
        self.write_config()
        self.assertEqual(self.retry().result.reason, "INVALID_CATALOG")
        self.flow.ecs.run_task.assert_called_once()

    def test_bootstrap_failures_and_missing_files_exclude_sensitive_exception_text(self):
        (self.package / "runtime.json").write_text("private invalid JSON")
        error = self.retry()
        self.assertEqual(error.result.reason, "BOOTSTRAP_FAILED")
        self.assertNotIn("private", ''.join(traceback.format_exception(error)))
        (self.package / "runtime.json").unlink()
        self.assertEqual(self.retry().result.error_code, "FileNotFoundError")
        self.sdk.assert_not_called()

    def test_failed_or_incomplete_assume_role_never_falls_back_to_broker_credentials(self):
        for response in (PermissionError("private STS failure"), {"Credentials": self.credentials | {"SessionToken": ""}},
                         {"Credentials": self.credentials | {"Expiration": datetime.now(timezone.utc)}}):
            with self.subTest(response_type=type(response).__name__):
                self.flow.setUp()
                self.session.client.reset_mock()
                self.sts.assume_role.side_effect = response if isinstance(response, Exception) else None
                self.sts.assume_role.return_value = response
                result = self.retry().result
                self.assertIn("LAUNCHER_SETUP_FAILED", result.reason)
                self.assertNotIn("private", repr(result))
                self.assertEqual(self.flow.item["status"], {"S": "REGISTERED"})
                self.assertEqual(self.flow.ledger.transact_write_items.call_count, 1)
                self.assertNotIn("ecs", [c.args[0] for c in self.session.client.call_args_list])

    def test_budget_guard_rejects_before_admission_and_invalid_clock(self):
        for remaining in (49000, 14000, None, True):
            with self.subTest(remaining=remaining):
                self.remaining = remaining
                self.assertEqual(self.retry().result.reason, "BUDGET_EXHAUSTED")
        self.flow.ledger.transact_write_items.assert_not_called()
        self.sts.assume_role.assert_not_called()

    def test_budget_loss_between_launch_stages_preserves_state_without_extra_calls(self):
        for stage, expected_state, writes, launches in (
            ("admission", "REGISTERED", 1, 0), ("credentials", "REGISTERED", 1, 0),
            ("claim", "DISPATCHING", 2, 0), ("launch", "DISPATCHING", 2, 1),
        ):
            with self.subTest(stage=stage):
                self.flow.setUp()
                self.remaining = 60000
                def write(**transaction):
                    result = self.flow.commit(**transaction)
                    action = transaction["TransactItems"][0]
                    if stage == "admission" and "ConditionCheck" in action:
                        self.remaining = 34000
                    if stage == "claim" and "Update" in action:
                        self.remaining = 19000
                    return result
                def assume(**kwargs):
                    if stage == "credentials":
                        self.remaining = 31000
                    return {"Credentials": self.credentials}
                def launch(**kwargs):
                    if stage == "launch":
                        self.remaining = 14000
                    return self.flow.ecs.run_task.return_value
                self.flow.ledger.transact_write_items.side_effect = write
                self.sts.assume_role.side_effect = assume
                self.flow.ecs.run_task.side_effect = launch
                self.assertEqual(self.retry().result.reason, "BUDGET_EXHAUSTED")
                self.assertEqual(self.flow.item["status"], {"S": expected_state})
                self.assertEqual(self.flow.ledger.transact_write_items.call_count, writes)
                self.assertEqual(self.flow.ecs.run_task.call_count, launches)

    def test_budget_loss_after_collision_prevents_lookup_and_repeat_dispatch(self):
        self.invoke()
        def collide(**transaction):
            self.remaining = 14000
            return self.flow.collide(**transaction)
        self.flow.ledger.transact_write_items.side_effect = collide
        self.assertEqual(self.retry().result.reason, "BUDGET_EXHAUSTED")
        self.flow.ledger.transact_get_items.assert_not_called()
        self.flow.ecs.run_task.assert_called_once()

    def test_completion_budget_loss_does_not_release_reservation(self):
        self.invoke()
        self.flow.completion()
        for stop_after in (1, 2):
            with self.subTest(stop_after=stop_after):
                self.remaining = 60000
                self.flow.ledger.get_item.reset_mock()
                self.flow.ledger.transact_write_items.reset_mock()
                def read(**request):
                    response = self.flow.read(**request)
                    if self.flow.ledger.get_item.call_count == stop_after:
                        self.remaining = 29000 if stop_after == 1 else 14000
                    return response
                self.flow.ledger.get_item.side_effect = read
                self.assertEqual(self.retry().result.reason, "BUDGET_EXHAUSTED")
                self.assertEqual(self.flow.ledger.get_item.call_count, stop_after)
                self.flow.ledger.transact_write_items.assert_not_called()
                self.assertEqual(self.flow.item["status"], {"S": "LAUNCH_ACCEPTED"})

    def test_pinned_sdk_accepts_handler_requests_without_network_or_ambient_ecs_credentials(self):
        from boto3.session import Session
        from botocore.stub import Stubber

        self.enterContext(patch.dict("os.environ", {
            "AWS_CONFIG_FILE": "/dev/null", "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
            "AWS_EC2_METADATA_DISABLED": "true",
        }, clear=True))
        real = Session(aws_access_key_id="AKIA" + "B" * 16, aws_secret_access_key="broker-secret",
                       aws_session_token="broker-token", region_name="us-east-1")
        clients = {}
        def client(service, **kwargs):
            sdk_client = real.client(service, **kwargs)
            clients[service] = sdk_client
            stub = Stubber(sdk_client)
            if service == "dynamodb":
                for _ in range(3):
                    stub.add_response("transact_write_items", acknowledged(),
                                      {"TransactItems": ANY, "ClientRequestToken": ANY})
            elif service == "sts":
                stub.add_response("assume_role", {"Credentials": self.credentials}, {
                    "RoleArn": self.flow.fixture.document["jobs"]["archive"]["binding"]["launcher_role_arn"],
                    "RoleSessionName": "broker-invocation-1", "DurationSeconds": 900,
                })
            else:
                stub.add_response("run_task", self.flow.ecs.run_task.return_value)
            self.enterContext(stub)
            self.addCleanup(stub.assert_no_pending_responses)
            return sdk_client
        self.session.client.side_effect = client
        with patch.dict("os.environ", {"AWS_ENDPOINT_URL": "http://127.0.0.1:1"}), \
                patch("botocore.httpsession.URLLib3Session.send", side_effect=AssertionError("No AWS calls")):
            self.assertEqual(self.invoke()["disposition"], "ACK")
        self.assertEqual(clients["ecs"]._request_signer._credentials.access_key, self.credentials["AccessKeyId"])
        self.assertEqual(clients["ecs"].meta.config.retries["total_max_attempts"], 1)
        for sdk_client in clients.values():
            self.assertNotIn("127.0.0.1", sdk_client.meta.endpoint_url)


if __name__ == "__main__":
    unittest.main()
