"""Offline transaction contracts; no proof of DynamoDB execution or fencing."""

from copy import deepcopy
import hashlib
import json
import unittest

from admission import (
    ExistingRequestDisposition as Disposition,
    InvalidLedgerRecord,
    classify_existing_request,
    prepare_admission,
)
from catalog import load_catalog
from producer_authorization import UnauthorizedProducer
from request_schema import RejectedRequest


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        cluster = "arn:aws:ecs:us-east-1:123456789012:cluster/shared"
        self.role_id = "AROAEXAMPLEORIGINAL001"
        job = {
            "binding": {
                "task_definition_arn": (
                    "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:17"
                ),
                **{
                    f"{role}_role_arn": f"arn:aws:iam::123456789012:role/{role}"
                    for role in ("launcher", "execution", "task")
                },
            },
            "network": {
                "subnet_ids": ["subnet-1234abcd"],
                "security_group_ids": ["sg-1234abcd"],
                "assign_public_ip": "DISABLED",
            },
            "fargate": {
                "launch_type": "FARGATE", "platform_version": "1.4.0", "count": 1,
            },
            "execution_policy": {
                "max_active_executions": 1, "run_task_total_max_attempts": 1,
            },
        }
        self.document = {
            "schema_version": 1, "application_id": "example-app",
            "environment": "test", "admission_generation": "generation-001",
            "cluster_arn": cluster,
            "jobs": {"archive": job, "report": deepcopy(job)},
            "producers": [{
                "logical_producer_id": "nightly-producer",
                "role_ids": [self.role_id], "allowed_jobs": ["archive", "report"],
            }],
        }
        self.approvals = {
            "approved_cluster_arn": cluster,
            "approved_private_subnet_ids": frozenset({"subnet-1234abcd"}),
            "approved_security_groups_by_job": {
                key: frozenset({"sg-1234abcd"}) for key in ("archive", "report")
            },
        }
        self.body = {
            "schema_version": 2, "job_key": "archive",
            "request_key": "request-001", "admission_generation": "generation-001",
        }
        self.context = {
            "producer_role_id": self.role_id, "owner_invocation_id": "invocation-1",
            "gate_table_arn": "arn:aws:dynamodb:us-east-1:123456789012:table/gates",
            "ledger_table_arn": "arn:aws:dynamodb:us-east-1:123456789012:table/ledger",
        }

    def prepare(self, *, body=None, document=None, **context):
        catalog = load_catalog(
            json.dumps(self.document if document is None else document),
            **self.approvals,
        )
        return prepare_admission(
            json.dumps(self.body if body is None else body), catalog=catalog,
            **(self.context | context),
        )

    @staticmethod
    def request_item(prepared):
        return prepared.transaction_request()["TransactItems"][1]["Put"]["Item"]

    @staticmethod
    def keys(prepared):
        result = []
        for wrapped in prepared.transaction_request()["TransactItems"]:
            action = next(iter(wrapped.values()))
            result.append(action.get("Key", action.get("Item"))["pk"]["S"])
        return result

    def test_transaction_reserves_all_four_records_with_fail_closed_conditions(self):
        prepared = self.prepare()
        transaction = prepared.transaction_request()
        actions = transaction["TransactItems"]
        self.assertEqual([list(action) for action in actions], [
            ["ConditionCheck"], ["Put"], ["Update"], ["Update"],
        ])
        self.assertEqual(self.keys(prepared), [
            "gate:v1:c25d7c931854b79548ce28775a893df3ab15f601b01307cc4d65efc47d2f3c6d",
            "request:v1:3d2dd2214fdbb685d3cc5512bb81ac451b936fea84a9573bd41050aff9817a82",
            "slot:v1:6725f476c8e2fd97c8b0b8b3e0c015644c4d30b18ee708affcc742a8af579bd8",
            "accounting:v1:c25d7c931854b79548ce28775a893df3ab15f601b01307cc4d65efc47d2f3c6d",
        ])
        gate, request, slot, accounting = [next(iter(a.values())) for a in actions]
        self.assertEqual(gate["TableName"], self.context["gate_table_arn"])
        for action in (request, slot, accounting):
            self.assertEqual(action["TableName"], self.context["ledger_table_arn"])
        self.assertEqual(gate["ConditionExpression"],
                         "#version = :version AND #kind = :kind AND #state = :open "
                         "AND #generation = :generation AND #digest = :digest "
                         "AND #ledger = :ledger")
        self.assertEqual(gate["ExpressionAttributeValues"][":open"], {"S": "OPEN"})
        self.assertEqual(gate["ExpressionAttributeValues"][":ledger"],
                         {"S": self.context["ledger_table_arn"]})
        self.assertEqual(request["ConditionExpression"], "attribute_not_exists(#pk)")
        self.assertEqual(slot["ConditionExpression"],
                         "attribute_not_exists(#pk) OR "
                         "(#version = :version AND #kind = :kind AND #state = :free)")
        self.assertEqual(slot["ExpressionAttributeValues"][":free"], {"S": "FREE"})
        self.assertEqual(slot["ExpressionAttributeValues"][":occupied"],
                         {"S": "OCCUPIED"})
        self.assertEqual(slot["ExpressionAttributeValues"][":request"],
                         {"S": prepared.request_pk})
        self.assertEqual(slot["ExpressionAttributeValues"][":attempt"],
                         {"S": prepared.attempt_id})
        self.assertEqual(accounting["ConditionExpression"],
                         "attribute_exists(#pk) AND #version = :version "
                         "AND #kind = :kind AND #pending >= :zero "
                         "AND #occupied >= #pending")
        self.assertEqual(accounting["UpdateExpression"],
                         "ADD #pending :one, #occupied :one")
        self.assertEqual(accounting["ExpressionAttributeValues"][":one"], {"N": "1"})
        self.assertEqual(accounting["ExpressionAttributeValues"][":zero"], {"N": "0"})
        self.assertEqual(accounting["ExpressionAttributeNames"]["#pending"],
                         "unresolved_launches")
        self.assertEqual(accounting["ExpressionAttributeNames"]["#occupied"],
                         "occupied_slots")

    def test_request_persists_exact_launch_snapshot_and_exclusive_owner(self):
        prepared = self.prepare()
        item = self.request_item(prepared)
        job = self.document["jobs"]["archive"]
        intent = json.loads(item["intent_json"]["S"])
        run_task = json.loads(item["run_task_request_json"]["S"])
        self.assertEqual(run_task, {
            "cluster": self.document["cluster_arn"],
            "taskDefinition": job["binding"]["task_definition_arn"],
            "launchType": "FARGATE", "platformVersion": "1.4.0", "count": 1,
            "networkConfiguration": {"awsvpcConfiguration": {
                "subnets": ["subnet-1234abcd"], "securityGroups": ["sg-1234abcd"],
                "assignPublicIp": "DISABLED",
            }},
            "clientToken": prepared.attempt_id,
        })
        for role in ("launcher", "execution", "task"):
            self.assertEqual(intent[f"{role}_role_arn"],
                             job["binding"][f"{role}_role_arn"])
        self.assertEqual(intent["execution_policy"], job["execution_policy"])
        self.assertEqual(intent["run_task"],
                         {k: v for k, v in run_task.items() if k != "clientToken"})
        self.assertEqual(item["owner_invocation_id"], {"S": "invocation-1"})
        self.assertEqual(item["attempt_id"], {"S": prepared.attempt_id})
        self.assertEqual(item["status"], {"S": "REGISTERED"})
        self.assertEqual(prepared.transaction_request()["ClientRequestToken"],
                         prepared.attempt_id)
        self.assertEqual(prepared.request_pk,
                         "request:v1:3d2dd2214fdbb685d3cc5512bb81ac451b936fea84a9573bd41050aff9817a82")

    def test_catalog_digest_binds_the_exact_loaded_text(self):
        source = json.dumps(self.document)
        for text in (source, source + "\n"):
            with self.subTest(trailing_newline=text.endswith("\n")):
                catalog = load_catalog(text, **self.approvals)
                expected = hashlib.sha256(text.encode("utf-8")).hexdigest()
                self.assertEqual(catalog.source_sha256, expected)
                prepared = prepare_admission(json.dumps(self.body), catalog=catalog,
                                             **self.context)
                gate = prepared.transaction_request()["TransactItems"][0]["ConditionCheck"]
                self.assertEqual(gate["ExpressionAttributeValues"][":digest"], {"S": expected})
                self.assertEqual(self.request_item(prepared)["catalog_sha256"], {"S": expected})

    def test_retry_payload_is_stable_but_new_delivery_has_a_new_attempt(self):
        original = self.prepare()
        expected = original.transaction_request()
        modified = original.transaction_request()
        modified["TransactItems"].clear()
        self.assertEqual(original.transaction_request(), expected)
        redelivery = self.prepare(owner_invocation_id="invocation-2")
        self.assertNotEqual(original.attempt_id, redelivery.attempt_id)
        self.assertEqual(original.intent_json, redelivery.intent_json)
        self.assertEqual(original.request_pk, redelivery.request_pk)
        for candidate in (original, redelivery):
            self.assertEqual(classify_existing_request(candidate, self.request_item(original)),
                             Disposition.DUPLICATE)

    def test_generation_role_replacement_and_correlation_do_not_reset_history(self):
        original = self.prepare()
        record = self.request_item(original)
        untouched = deepcopy(record)
        document = deepcopy(self.document)
        document["admission_generation"] = "generation-002"
        replacement = "AROAEXAMPLEREPLACED001"
        document["producers"][0]["role_ids"] = [replacement]
        candidate = self.prepare(
            document=document, producer_role_id=replacement,
            body=self.body | {
                "admission_generation": "generation-002", "schedule_key": "nightly",
                "schedule_arn": "correlation-only", "scheduled_time": "2026-11-25T00:00:00Z",
            },
        )
        self.assertEqual(self.keys(candidate), self.keys(original))
        self.assertEqual(candidate.intent_json, original.intent_json)
        self.assertNotEqual(self.request_item(candidate)["catalog_sha256"], record["catalog_sha256"])
        self.assertEqual(classify_existing_request(candidate, record), Disposition.DUPLICATE)
        self.assertEqual(record, untouched)

    def test_changed_job_or_execution_intent_conflicts(self):
        original = self.prepare()
        candidates = [self.prepare(body=self.body | {"job_key": "report"})]
        for field, value in (
            ("task_definition_arn", "arn:aws:ecs:us-east-1:123456789012:task-definition/archive:18"),
            ("launcher_role_arn", "arn:aws:iam::123456789012:role/replacement-launcher"),
        ):
            document = deepcopy(self.document)
            document["jobs"]["archive"]["binding"][field] = value
            candidates.append(self.prepare(document=document))
        for candidate in candidates:
            with self.subTest(intent=candidate.intent_json):
                self.assertEqual(candidate.request_pk, original.request_pk)
                self.assertEqual(classify_existing_request(candidate, self.request_item(original)),
                                 Disposition.CONFLICT)

    def test_slot_and_accounting_scopes_are_independent_of_request_and_producer(self):
        original = self.prepare()
        changed_request = self.prepare(body=self.body | {"request_key": "request-002"})
        changed_job = self.prepare(body=self.body | {"job_key": "report"})
        document = deepcopy(self.document)
        document["producers"][0]["logical_producer_id"] = "another-producer"
        changed_producer = self.prepare(document=document)
        for candidate in (changed_request, changed_producer):
            self.assertNotEqual(self.keys(original)[1], self.keys(candidate)[1])
            self.assertEqual(self.keys(original)[2:], self.keys(candidate)[2:])
        self.assertNotEqual(self.keys(original)[2], self.keys(changed_job)[2])
        self.assertEqual(self.keys(original)[3], self.keys(changed_job)[3])
        for field in ("application_id", "environment"):
            document = deepcopy(self.document)
            document[field] = "other"
            self.assertTrue(set(self.keys(original)).isdisjoint(self.keys(self.prepare(document=document))))

    def test_resolution_denials_prevent_preparation(self):
        with self.assertRaises(UnauthorizedProducer):
            self.prepare(producer_role_id="AROAEXAMPLEUNKNOWN001")
        with self.assertRaises(RejectedRequest):
            self.prepare(body=self.body | {"admission_generation": "old-generation"})
        with self.assertRaises(RejectedRequest):
            self.prepare(body=self.body | {"overrides": {"command": ["other"]}})
        with self.assertRaises(ValueError):
            self.prepare(gate_table_arn=self.context["ledger_table_arn"])

    def test_absence_and_unexpected_records_never_become_admission(self):
        prepared = self.prepare()
        self.assertEqual(classify_existing_request(prepared, None), Disposition.ABSENT)
        for change in ({"pk": {"S": "wrong"}}, {"schema_version": {"N": "2"}},
                       {"record_type": {"S": "SLOT"}}, {"intent_json": None}):
            with self.subTest(change=change), self.assertRaises(InvalidLedgerRecord):
                classify_existing_request(prepared, self.request_item(prepared) | change)


if __name__ == "__main__":
    unittest.main()
