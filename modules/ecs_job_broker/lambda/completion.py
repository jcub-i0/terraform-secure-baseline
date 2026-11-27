"""Record trusted ECS STOPPED evidence; offline clients do not authenticate delivery."""

from dataclasses import dataclass
from enum import Enum
import json
from uuid import uuid4

from admission import _json, _key
from dispatch import (
    WriteEvidence, WriteOutcome, _error_code, _mapping, _metadata, _request_id,
    _retries, _slot_operation, _submit, _text,
)


class CompletionOutcome(Enum):
    RECORDED = "RECORDED"
    ALREADY_RECORDED = "ALREADY_RECORDED"
    IGNORED = "IGNORED"
    DEFERRED = "DEFERRED"
    REJECTED = "REJECTED"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class CompletionResult:
    """Keep durable completion separate from write certainty and diagnostics.

    Only RECORDED or ALREADY_RECORDED establishes the terminal ledger state.
    DEFERRED must retain evidence for later processing or protected recovery.
    UNKNOWN may include a committed write. No outcome authorizes dispatch,
    separate cleanup, or treating an untracked task as conclusively absent.
    Queue acknowledgement, retry and failure routing are caller responsibilities.
    """

    outcome: CompletionOutcome
    reason: str
    task_arn: str | None
    request_pk: str | None
    attempt_id: str | None
    dispatch_id: str | None
    recording: WriteEvidence
    read_aws_request_id: str | None = None
    read_sdk_retry_attempts: int | None = None
    read_error_code: str | None = None


def _string(item, name):
    value = _mapping(item).get(name)
    return _text(value.get("S")) if isinstance(value, dict) and set(value) == {"S"} else None


def _record_is(item, kind, expected):
    return (
        isinstance(item, dict)
        and item.get("schema_version") == {"N": "1"}
        and item.get("record_type") == {"S": kind}
        and all(item.get(name) == {"S": value} for name, value in expected.items())
    )


def _read_item(client, table, pk):
    try:
        response = client.get_item(
            TableName=table, Key={"pk": {"S": pk}}, ConsistentRead=True,
        )
    except Exception as error:
        response = _mapping(getattr(error, "response", None))
        code = _error_code(error)
    else:
        if _metadata(response).get("HTTPStatusCode") == 200:
            if "Item" not in response:
                return None, None
            if isinstance(response["Item"], dict) and response["Item"]:
                return response["Item"], None
        code = "UnexpectedReadResponse"
    return None, {
        "read_aws_request_id": _request_id(response),
        "read_sdk_retry_attempts": _retries(response), "read_error_code": code,
    }


def _terminal_evidence(event, detail):
    # Optional diagnostics do not determine whether the task has stopped.
    # Ignore extra AWS fields; never copy overrides, logs or free-form reasons.
    containers = detail.get("containers")
    exits = []
    for row in containers if isinstance(containers, list) else []:
        row = _mapping(row)
        if name := _text(row.get("name")):
            code = row.get("exitCode")
            exits.append({"name": name, "exit_code": code if type(code) is int else None})
    version = detail.get("version")
    return {
        "task_arn": detail["taskArn"], "cluster_arn": detail["clusterArn"],
        "task_definition_arn": detail["taskDefinitionArn"], "last_status": "STOPPED",
        "event_id": _text(event.get("id")), "event_time": _text(event.get("time")),
        "task_version": version if type(version) is int else _text(version),
        "stopped_at": _text(detail.get("stoppedAt")),
        "stop_code": _text(detail.get("stopCode")), "containers": exits,
    }


def _completion_transaction(table, item, evidence):
    # Bind every value used to select another record or establish launch identity.
    bindings = {
        "#app": "application_id", "#env": "environment", "#job": "job_key",
        "#owner": "owner_invocation_id", "#attempt": "attempt_id",
        "#dispatch": "dispatch_id", "#task": "task_arn",
        "#intent": "intent_json", "#launch": "run_task_request_json",
    }
    names = bindings | {
        "#version": "schema_version", "#kind": "record_type", "#status": "status",
        "#terminal": "completion_observation_json",
    }
    values = {":" + alias[1:]: item[field] for alias, field in bindings.items()}
    values.update({
        ":version": {"N": "1"}, ":kind": {"S": "REQUEST"},
        ":before": {"S": "LAUNCH_ACCEPTED"}, ":after": {"S": "TASK_STOPPED"},
        ":terminal": {"S": _json(evidence)},
    })
    condition = (
        "#version = :version AND #kind = :kind AND #status = :before "
        "AND attribute_not_exists(#terminal) AND "
        + " AND ".join(f"{alias} = :{alias[1:]}" for alias in bindings)
    )
    scope = (item["application_id"]["S"], item["environment"]["S"])
    return {
        "ClientRequestToken": uuid4().hex,
        "TransactItems": [
            {"Update": {
                "TableName": table, "Key": {"pk": item["pk"]},
                "ConditionExpression": condition,
                "UpdateExpression": "SET #status = :after, #terminal = :terminal",
                "ExpressionAttributeNames": names, "ExpressionAttributeValues": values,
            }},
            _slot_operation({
                "TableName": table,
                "Key": {"pk": {"S": _key("slot", *scope, item["job_key"]["S"])}},
            }, item, release=True),
            {"Update": {
                "TableName": table, "Key": {"pk": {"S": _key("accounting", *scope)}},
                "ConditionExpression": (
                    "#version = :version AND #kind = :kind "
                    "AND #pending >= :zero AND #occupied > #pending"
                ),
                "UpdateExpression": "ADD #occupied :minus_one",
                "ExpressionAttributeNames": {
                    "#version": "schema_version", "#kind": "record_type",
                    "#pending": "unresolved_launches", "#occupied": "occupied_slots",
                },
                "ExpressionAttributeValues": {
                    ":version": {"N": "1"}, ":kind": {"S": "ACCOUNTING"},
                    ":zero": {"N": "0"}, ":minus_one": {"N": "-1"},
                },
            }},
        ],
    }


def record_task_completion(
    event: dict, *, application_id: str, environment: str,
    ledger_table_arn: str, ledger_client,
    check_budget=None,
) -> CompletionResult:
    """Consume one caller-authenticated ECS task event through an injected client.

    The event must originate from the approved, protected ECS delivery path.
    Matching source/account/Region fields only checks consistency; it does not
    authenticate an event or prevent forged direct invocation. Protected runtime
    context selects the application, environment and ledger. This helper neither
    authenticates delivery nor implements the queue, client factory, evidence
    retention, backfill or protected recovery. Runtime supplies check_budget
    before reads and terminal recording; it cannot cancel in-flight requests.

    Immutable lookup and request records are read consistently. Only a bound
    LAUNCH_ACCEPTED task can transition. Reads never grant launch authority.
    One conditional transaction records STOPPED and releases its reservation;
    SDK retries retain that payload/token. Re-entry is safe through prior-state
    and ownership conditions, even after transaction-token expiry.
    """
    if any(not isinstance(value, str) or not value or value != value.strip()
           for value in (application_id, environment, ledger_table_arn)):
        raise ValueError("Missing or invalid protected completion context.")
    table_parts = ledger_table_arn.split(":", 5)
    if (len(table_parts) != 6 or table_parts[0] != "arn" or table_parts[2] != "dynamodb"
            or not all(table_parts[1:]) or not table_parts[5].startswith("table/")):
        raise ValueError("Completion requires the protected ledger table ARN.")
    partition, region, account = table_parts[1], table_parts[3], table_parts[4]
    event = _mapping(event)
    detail = _mapping(event.get("detail"))
    task_arn = _text(detail.get("taskArn"))
    request_pk = attempt_id = dispatch_id = None

    def result(outcome, reason, recording=None, read=None):
        return CompletionResult(
            outcome, reason, task_arn, request_pk, attempt_id, dispatch_id,
            recording if recording is not None else WriteEvidence(WriteOutcome.NOT_ATTEMPTED),
            **(read or {}),
        )

    if (event.get("source") != "aws.ecs" or event.get("detail-type") != "ECS Task State Change"
            or event.get("account") != account or event.get("region") != region
            or not all(_text(detail.get(key)) for key in
                       ("taskArn", "clusterArn", "taskDefinitionArn", "lastStatus"))):
        return result(CompletionOutcome.REJECTED, "INVALID_EVENT")
    prefix = f"arn:{partition}:ecs:{region}:{account}:"
    if any(not detail[key].startswith(prefix + resource) for key, resource in (
        ("taskArn", "task/"), ("clusterArn", "cluster/"),
        ("taskDefinitionArn", "task-definition/"),
    )):
        return result(CompletionOutcome.REJECTED, "EVENT_SCOPE_MISMATCH")
    if detail["lastStatus"] != "STOPPED":
        return result(CompletionOutcome.IGNORED, "NOT_TERMINAL")

    scope = {"application_id": application_id, "environment": environment}
    lookup_pk = _key("task", application_id, environment, task_arn)
    if check_budget is not None:
        check_budget(45000)
    lookup, failure = _read_item(ledger_client, ledger_table_arn, lookup_pk)
    if failure:
        return result(CompletionOutcome.UNKNOWN, "LOOKUP_READ_FAILED", read=failure)
    if lookup is None:
        # Could be an early event, an untracked task, or a failed result write.
        # Absence alone cannot distinguish these cases or authorize cleanup.
        return result(CompletionOutcome.DEFERRED, "LOOKUP_NOT_FOUND")
    if (not _record_is(lookup, "TASK_LOOKUP", scope | {"pk": lookup_pk, "task_arn": task_arn})
            or not all(_string(lookup, field) for field in
                       ("request_pk", "attempt_id", "dispatch_id"))):
        return result(CompletionOutcome.REJECTED, "INVALID_LOOKUP")
    request_pk, attempt_id, dispatch_id = (
        _string(lookup, field) for field in ("request_pk", "attempt_id", "dispatch_id")
    )
    if check_budget is not None:
        check_budget(30000)
    item, failure = _read_item(ledger_client, ledger_table_arn, request_pk)
    if failure:
        return result(CompletionOutcome.UNKNOWN, "REQUEST_READ_FAILED", read=failure)
    if item is None:
        return result(CompletionOutcome.DEFERRED, "REQUEST_NOT_FOUND")
    if not _record_is(item, "REQUEST", scope | {"pk": request_pk, "attempt_id": attempt_id}):
        return result(CompletionOutcome.REJECTED, "INVALID_REQUEST")
    status = _string(item, "status")
    if status in ("REGISTERED", "DISPATCHING", "LAUNCH_UNKNOWN"):
        return result(CompletionOutcome.DEFERRED, "LAUNCH_NOT_RECORDED")
    if (status not in ("LAUNCH_ACCEPTED", "TASK_STOPPED")
            or _string(item, "dispatch_id") != dispatch_id
            or _string(item, "task_arn") != task_arn
            or not all(_string(item, field) for field in
                       ("job_key", "owner_invocation_id", "intent_json", "run_task_request_json"))):
        return result(CompletionOutcome.REJECTED, "INVALID_REQUEST")
    try:
        intent = json.loads(item["intent_json"]["S"])
        launch = json.loads(item["run_task_request_json"]["S"])
        consistent = (
            launch["cluster"] == detail["clusterArn"]
            and launch["taskDefinition"] == detail["taskDefinitionArn"]
            and launch["clientToken"] == attempt_id
            and intent["job_key"] == item["job_key"]["S"]
            and intent["run_task"] == {key: value for key, value in launch.items()
                                       if key != "clientToken"}
        )
    except (ValueError, TypeError, KeyError):
        consistent = False
    if not consistent:
        return result(CompletionOutcome.REJECTED, "LAUNCH_IDENTITY_MISMATCH")

    evidence = _terminal_evidence(event, detail)
    if status == "TASK_STOPPED":
        try:
            previous = json.loads(_string(item, "completion_observation_json"))
            recorded = all(previous[key] == evidence[key] for key in
                           ("task_arn", "cluster_arn", "task_definition_arn", "last_status"))
        except (ValueError, TypeError, KeyError):
            recorded = False
        return result(CompletionOutcome.ALREADY_RECORDED if recorded else CompletionOutcome.REJECTED,
                      "TERMINAL_ALREADY_RECORDED" if recorded else "INVALID_TERMINAL_RECORD")
    if "completion_observation_json" in item:
        return result(CompletionOutcome.REJECTED, "INVALID_TERMINAL_RECORD")
    if check_budget is not None:
        check_budget(15000)
    recording = _submit(ledger_client, _completion_transaction(ledger_table_arn, item, evidence))
    outcome, reason = {
        WriteOutcome.CONFIRMED: (CompletionOutcome.RECORDED, "ACKNOWLEDGED"),
        WriteOutcome.REJECTED: (CompletionOutcome.REJECTED, "WRITE_REJECTED"),
        WriteOutcome.UNKNOWN: (CompletionOutcome.UNKNOWN, "WRITE_UNKNOWN"),
    }[recording.outcome]
    return result(outcome, reason, recording)
