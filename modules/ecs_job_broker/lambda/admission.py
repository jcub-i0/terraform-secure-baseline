"""Prepare offline admission transactions; preparation grants no launch authority."""

from dataclasses import dataclass
from enum import Enum
import hashlib
import json
from uuid import uuid4

from catalog import JobCatalog, resolve_request


class InvalidLedgerRecord(ValueError):
    """A supplied request record cannot safely be classified."""


class ExistingRequestDisposition(Enum):
    ABSENT = "ABSENT"
    DUPLICATE = "DUPLICATE"
    CONFLICT = "CONFLICT"


@dataclass(frozen=True)
class PreparedAdmission:
    request_pk: str
    attempt_id: str
    intent_json: str
    transaction_json: str

    def transaction_request(self) -> dict:
        """Return a fresh low-level DynamoDB request, without submitting it."""
        return json.loads(self.transaction_json)


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def _key(kind: str, *scope: str) -> str:
    # Prefix, field order and encoding are persistent storage format v1.
    digest = hashlib.sha256(_json(scope).encode("ascii")).hexdigest()
    return f"{kind}:v1:{digest}"


def prepare_admission(
    body: str,
    *,
    catalog: JobCatalog,
    producer_role_id: str,
    owner_invocation_id: str,
    gate_table_arn: str,
    ledger_table_arn: str,
) -> PreparedAdmission:
    """Resolve a request and freeze one four-record admission operation.

    Identity, artifact approval, and table references must come from protected
    caller context. The catalog digest comes from load_catalog's input text.
    This function does not read a live gate, submit a transaction, classify SDK
    errors, or authorize dispatch. The caller must retain this preparation for
    retries of the same operation; a new delivery gets a new attempt/token.
    """
    if any(not isinstance(value, str) or not value or value != value.strip()
           for value in (owner_invocation_id, gate_table_arn, ledger_table_arn)):
        raise ValueError("Missing or invalid protected admission context.")
    if gate_table_arn == ledger_table_arn:
        raise ValueError("The protected gate and execution ledger must be separate.")

    resolved = resolve_request(
        body, catalog=catalog, producer_role_id=producer_role_id
    )
    request, job = resolved.request, resolved.job
    scope = (catalog.application_id, catalog.environment)
    attempt_id = uuid4().hex
    run_task = {
        "cluster": job.binding.cluster_arn,
        "taskDefinition": job.binding.task_definition_arn,
        "launchType": job.fargate.launch_type,
        "platformVersion": job.fargate.platform_version,
        "count": job.fargate.count,
        "networkConfiguration": {
            "awsvpcConfiguration": {
                "subnets": list(job.network.subnet_ids),
                "securityGroups": list(job.network.security_group_ids),
                "assignPublicIp": job.network.assign_public_ip,
            },
        },
    }
    intent_json = _json({
        "schema_version": 1,
        "job_key": request.job_key,
        "launcher_role_arn": job.binding.launcher_role_arn,
        "execution_role_arn": job.binding.execution_role_arn,
        "task_role_arn": job.binding.task_role_arn,
        "run_task": run_task,
        "execution_policy": {
            "max_active_executions": job.max_active_executions,
            "run_task_total_max_attempts": job.run_task_total_max_attempts,
        },
    })
    # Generated tokens and provenance do not change duplicate execution intent.
    run_task = run_task | {"clientToken": attempt_id}
    request_strings = {
        "pk": resolved.ledger_key,
        "record_type": "REQUEST",
        "application_id": catalog.application_id,
        "environment": catalog.environment,
        "logical_producer_id": resolved.logical_producer_id,
        "request_key": request.request_key,
        "job_key": request.job_key,
        "admission_generation": catalog.admission_generation,
        "catalog_sha256": catalog.source_sha256,
        "attempt_id": attempt_id,
        "owner_invocation_id": owner_invocation_id,
        "status": "REGISTERED",
        "intent_json": intent_json,
        "run_task_request_json": _json(run_task),
    }
    if request.schedule_key is not None:
        # Correlation only: never producer identity or execution intent.
        request_strings["schedule_metadata_json"] = _json({
            "schedule_key": request.schedule_key,
            "schedule_arn": request.schedule_arn,
            "scheduled_time": request.scheduled_time,
        })
    request_item = {key: {"S": value} for key, value in request_strings.items()}
    request_item["schema_version"] = {"N": "1"}

    transaction = {
        "ClientRequestToken": attempt_id,
        "TransactItems": [
            {"ConditionCheck": {
                "TableName": gate_table_arn,
                "Key": {"pk": {"S": _key("gate", *scope)}},
                "ConditionExpression": (
                    "#version = :version AND #kind = :kind AND #state = :open "
                    "AND #generation = :generation AND #digest = :digest "
                    "AND #ledger = :ledger"
                ),
                "ExpressionAttributeNames": {
                    "#version": "schema_version", "#kind": "record_type",
                    "#state": "state", "#generation": "admission_generation",
                    "#digest": "catalog_sha256", "#ledger": "execution_ledger_arn",
                },
                "ExpressionAttributeValues": {
                    ":version": {"N": "1"}, ":kind": {"S": "GATE"},
                    ":open": {"S": "OPEN"},
                    ":generation": {"S": catalog.admission_generation},
                    ":digest": {"S": catalog.source_sha256},
                    ":ledger": {"S": ledger_table_arn},
                },
            }},
            {"Put": {
                "TableName": ledger_table_arn,
                "Item": request_item,
                "ConditionExpression": "attribute_not_exists(#pk)",
                "ExpressionAttributeNames": {"#pk": "pk"},
            }},
            {"Update": {
                "TableName": ledger_table_arn,
                "Key": {"pk": {"S": _key("slot", *scope, request.job_key)}},
                "ConditionExpression": (
                    "attribute_not_exists(#pk) OR "
                    "(#version = :version AND #kind = :kind AND #state = :free)"
                ),
                "UpdateExpression": (
                    "SET #version = :version, #kind = :kind, #state = :occupied, "
                    "#request = :request, #attempt = :attempt, #job = :job"
                ),
                "ExpressionAttributeNames": {
                    "#pk": "pk", "#version": "schema_version",
                    "#kind": "record_type", "#state": "state",
                    "#request": "request_pk", "#attempt": "attempt_id",
                    "#job": "job_key",
                },
                "ExpressionAttributeValues": {
                    ":version": {"N": "1"}, ":kind": {"S": "SLOT"},
                    ":free": {"S": "FREE"}, ":occupied": {"S": "OCCUPIED"},
                    ":request": {"S": resolved.ledger_key},
                    ":attempt": {"S": attempt_id}, ":job": {"S": request.job_key},
                },
            }},
            {"Update": {
                "TableName": ledger_table_arn,
                "Key": {"pk": {"S": _key("accounting", *scope)}},
                "ConditionExpression": (
                    "attribute_exists(#pk) AND #version = :version "
                    "AND #kind = :kind AND #pending >= :zero "
                    "AND #occupied >= #pending"
                ),
                "UpdateExpression": "ADD #pending :one, #occupied :one",
                "ExpressionAttributeNames": {
                    "#pk": "pk", "#version": "schema_version",
                    "#kind": "record_type", "#pending": "unresolved_launches",
                    "#occupied": "occupied_slots",
                },
                "ExpressionAttributeValues": {
                    ":version": {"N": "1"}, ":kind": {"S": "ACCOUNTING"},
                    ":zero": {"N": "0"}, ":one": {"N": "1"},
                },
            }},
        ],
    }
    return PreparedAdmission(
        resolved.ledger_key, attempt_id, intent_json, _json(transaction)
    )


def classify_existing_request(
    prepared: PreparedAdmission, item: dict | None
) -> ExistingRequestDisposition:
    """Compare a low-level DynamoDB Item; no disposition authorizes a launch.

    Current authentication, authorization and live generation checks remain
    caller responsibilities. Absence is not a reservation. A duplicate returns
    no ownership, even when the stored owner is this invocation. Stale reads
    and races must still be handled by the eventual transaction executor.
    """
    if item is None:
        return ExistingRequestDisposition.ABSENT
    if (
        not isinstance(item, dict)
        or item.get("pk") != {"S": prepared.request_pk}
        or item.get("schema_version") != {"N": "1"}
        or item.get("record_type") != {"S": "REQUEST"}
        or not isinstance(item.get("intent_json"), dict)
        or set(item["intent_json"]) != {"S"}
        or not isinstance(item["intent_json"]["S"], str)
    ):
        raise InvalidLedgerRecord("Unexpected request record identity or schema.")
    if item["intent_json"]["S"] == prepared.intent_json:
        return ExistingRequestDisposition.DUPLICATE
    return ExistingRequestDisposition.CONFLICT
