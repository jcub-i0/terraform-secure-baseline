"""Claim one dispatch, call ECS once, and record its outcome through supplied clients.

This module has offline coverage only. It does not authenticate delivery, assume
roles, construct SDK clients, enforce an invocation deadline, or perform recovery.
"""

from dataclasses import dataclass
from enum import Enum
import json
from uuid import uuid4

from admission import PreparedAdmission
from admission_executor import AdmissionOutcome, AdmissionResult


class WriteOutcome(Enum):
    NOT_ATTEMPTED = "NOT_ATTEMPTED"
    CONFIRMED = "CONFIRMED"
    REJECTED = "REJECTED"
    UNKNOWN = "UNKNOWN"


class LaunchOutcome(Enum):
    NOT_ATTEMPTED = "NOT_ATTEMPTED"
    ACCEPTED = "ACCEPTED"
    REJECTED = "REJECTED"
    UNKNOWN = "UNKNOWN"


@dataclass(frozen=True)
class WriteEvidence:
    outcome: WriteOutcome
    aws_request_id: str | None = None
    sdk_retry_attempts: int | None = None
    error_code: str | None = None
    # Request, slot, accounting; service messages/items are never copied.
    cancellation_codes: tuple[str, ...] | None = None


@dataclass(frozen=True)
class LaunchObservation:
    outcome: LaunchOutcome
    reason: str
    aws_request_id: str | None = None
    sdk_retry_attempts: int | None = None
    error_code: str | None = None
    task_arns: tuple[str, ...] = ()
    failure_codes: tuple[str, ...] = ()
    failure_resource_arns: tuple[str, ...] = ()


@dataclass(frozen=True)
class DispatchResult:
    """Separate observed ECS behavior from certainty about durable recording.

    NOT_ATTEMPTED does not release an existing reservation. ACCEPTED does not
    establish task completion. UNKNOWN, even when recorded, remains unresolved.
    No result authorizes another dispatch or reservation cleanup.
    """

    request_pk: str
    attempt_id: str
    dispatch_id: str | None
    claim: WriteEvidence
    launch: LaunchObservation
    recording: WriteEvidence


_DDB_REJECTIONS = frozenset({
    "TransactionCanceledException", "AccessDeniedException", "ValidationException",
    "ResourceNotFoundException", "UnrecognizedClientException", "InvalidSignatureException",
    "ProvisionedThroughputExceededException", "RequestLimitExceeded",
    "ThrottlingException", "TransactionConflictException",
})
# Explicit refusals from the RunTask contract. ConflictException can identify
# existing tasks. Generic ClientException and unfamiliar errors stay uncertain.
_ECS_REJECTIONS = frozenset({
    "AccessDeniedException", "BlockedException", "ClusterNotFoundException",
    "InvalidParameterException", "PlatformTaskDefinitionIncompatibilityException",
    "PlatformUnknownException", "UnsupportedFeatureException",
})


def _mapping(value) -> dict:
    return value if isinstance(value, dict) else {}


def _text(value) -> str | None:
    return value if isinstance(value, str) and value else None


def _metadata(response) -> dict:
    return _mapping(_mapping(response).get("ResponseMetadata"))


def _request_id(response) -> str | None:
    return _text(_metadata(response).get("RequestId"))


def _retries(response) -> int | None:
    value = _metadata(response).get("RetryAttempts")
    return value if type(value) is int and value >= 0 else None


def _error_code(error) -> str:
    response = _mapping(getattr(error, "response", None))
    return _text(_mapping(response.get("Error")).get("Code")) or type(error).__name__


def _json(value) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def _submit(client, transaction) -> WriteEvidence:
    try:
        response = client.transact_write_items(**transaction)
    except Exception as error:
        response = _mapping(getattr(error, "response", None))
        code = _error_code(error)
        reasons = response.get("CancellationReasons")
        codes = None
        if isinstance(reasons, list) and len(reasons) == 3:
            values = tuple(_mapping(reason).get("Code") for reason in reasons)
            if all(isinstance(value, str) for value in values):
                codes = values
        rejected = (code in _DDB_REJECTIONS and _retries(response) == 0
                    and _metadata(response).get("HTTPStatusCode") in (400, 403))
        return WriteEvidence(
            WriteOutcome.REJECTED if rejected else WriteOutcome.UNKNOWN,
            _request_id(response), _retries(response), code, codes,
        )
    if _metadata(response).get("HTTPStatusCode") == 200:
        return WriteEvidence(WriteOutcome.CONFIRMED, _request_id(response), _retries(response))
    return WriteEvidence(WriteOutcome.UNKNOWN, _request_id(response), _retries(response),
                         "UnexpectedWriteResponse")


def _request_update(request, dispatch_id, *, observation=None) -> dict:
    item = request["Item"]
    names = {
        "#version": "schema_version", "#kind": "record_type", "#status": "status",
        "#owner": "owner_invocation_id", "#attempt": "attempt_id", "#intent": "intent_json",
        "#launch": "run_task_request_json", "#dispatch": "dispatch_id",
    }
    values = {
        ":version": {"N": "1"}, ":kind": {"S": "REQUEST"},
        ":owner": item["owner_invocation_id"], ":attempt": item["attempt_id"],
        ":intent": item["intent_json"], ":launch": item["run_task_request_json"],
        ":dispatch": {"S": dispatch_id},
        ":before": {"S": "REGISTERED" if observation is None else "DISPATCHING"},
    }
    condition = (
        "#version = :version AND #kind = :kind AND #status = :before "
        "AND #owner = :owner AND #attempt = :attempt "
        "AND #intent = :intent AND #launch = :launch"
    )
    if observation is None:
        condition += " AND attribute_not_exists(#dispatch)"
        values[":after"] = {"S": "DISPATCHING"}
        update = "SET #status = :after, #dispatch = :dispatch"
    else:
        condition += " AND #dispatch = :dispatch"
        values[":after"] = {"S": f"LAUNCH_{observation.outcome.value}"}
        names["#observation"] = "launch_observation_json"
        values[":observation"] = {"S": _json({
            "outcome": observation.outcome.value, "reason": observation.reason,
            "aws_request_id": observation.aws_request_id,
            "sdk_retry_attempts": observation.sdk_retry_attempts,
            "error_code": observation.error_code, "task_arns": observation.task_arns,
            "failure_codes": observation.failure_codes,
            "failure_resource_arns": observation.failure_resource_arns,
        })}
        update = "SET #status = :after, #observation = :observation"
        if observation.outcome is LaunchOutcome.ACCEPTED:
            names["#task"] = "task_arn"
            values[":task"] = {"S": observation.task_arns[0]}
            update += ", #task = :task"
    return {
        "TableName": request["TableName"], "Key": {"pk": item["pk"]},
        "ConditionExpression": condition, "UpdateExpression": update,
        "ExpressionAttributeNames": names, "ExpressionAttributeValues": values,
    }


def _slot_operation(slot, item, *, release=False) -> dict:
    action = {
        "TableName": slot["TableName"], "Key": slot["Key"],
        "ConditionExpression": (
            "#version = :version AND #kind = :kind AND #state = :occupied "
            "AND #request = :request AND #attempt = :attempt AND #job = :job"
        ),
        "ExpressionAttributeNames": {
            "#version": "schema_version", "#kind": "record_type", "#state": "state",
            "#request": "request_pk", "#attempt": "attempt_id", "#job": "job_key",
        },
        "ExpressionAttributeValues": {
            ":version": {"N": "1"}, ":kind": {"S": "SLOT"}, ":occupied": {"S": "OCCUPIED"},
            ":request": item["pk"], ":attempt": item["attempt_id"], ":job": item["job_key"],
        },
    }
    if release:
        action["ExpressionAttributeValues"][":free"] = {"S": "FREE"}
        action["UpdateExpression"] = "SET #state = :free REMOVE #request, #attempt"
    return {"Update" if release else "ConditionCheck": action}


def _accounting_operation(accounting, *, outcome=None) -> dict:
    action = {
        "TableName": accounting["TableName"], "Key": accounting["Key"],
        "ConditionExpression": (
            "#version = :version AND #kind = :kind "
            "AND #pending >= :one AND #occupied >= #pending"
        ),
        "ExpressionAttributeNames": {
            "#version": "schema_version", "#kind": "record_type",
            "#pending": "unresolved_launches", "#occupied": "occupied_slots",
        },
        "ExpressionAttributeValues": {
            ":version": {"N": "1"}, ":kind": {"S": "ACCOUNTING"}, ":one": {"N": "1"},
        },
    }
    resolved = outcome in (LaunchOutcome.ACCEPTED, LaunchOutcome.REJECTED)
    if resolved:
        action["ExpressionAttributeValues"][":minus_one"] = {"N": "-1"}
        action["UpdateExpression"] = "ADD #pending :minus_one"
        if outcome is LaunchOutcome.REJECTED:
            action["UpdateExpression"] += ", #occupied :minus_one"
    return {"Update" if resolved else "ConditionCheck": action}


def _transaction(request, slot, accounting, dispatch_id, *, observation=None) -> dict:
    outcome = observation.outcome if observation else None
    return {
        # The claim ID is generated within this dispatcher entry. Recording is
        # a separate operation with a separate token. Neither is the ECS token.
        "ClientRequestToken": dispatch_id if observation is None else uuid4().hex,
        "TransactItems": [
            {"Update": _request_update(request, dispatch_id, observation=observation)},
            _slot_operation(slot, request["Item"], release=outcome is LaunchOutcome.REJECTED),
            _accounting_operation(accounting, outcome=outcome),
        ],
    }


def _response_observation(response, run_task) -> LaunchObservation:
    body = _mapping(response)
    tasks, failures = body.get("tasks"), body.get("failures", [])
    task_arns = tuple(
        arn for task in (tasks if isinstance(tasks, list) else [])
        if (arn := _text(_mapping(task).get("taskArn")))
    )
    failure_rows = failures if isinstance(failures, list) else []
    failure_codes = tuple(
        code for failure in failure_rows if (code := _text(_mapping(failure).get("reason")))
    )
    resources = tuple(
        arn for failure in failure_rows if (arn := _text(_mapping(failure).get("arn")))
    )
    # A failure identifying a task may itself require tracking; never release
    # its reservation as though no task could exist.
    failure_tasks = tuple(arn for arn in resources if ":task/" in arn)
    evidence = {
        "aws_request_id": _request_id(response), "sdk_retry_attempts": _retries(response),
        "task_arns": task_arns + failure_tasks,
        "failure_codes": failure_codes, "failure_resource_arns": resources,
    }
    if (_metadata(response).get("HTTPStatusCode") != 200 or _retries(response) != 0
            or not isinstance(tasks, list) or not isinstance(failures, list)):
        return LaunchObservation(LaunchOutcome.UNKNOWN, "UNEXPECTED_RESPONSE", **evidence)

    if len(tasks) == 1 and len(task_arns) == 1 and not failures:
        task = _mapping(tasks[0])
        prefix = run_task["cluster"].rsplit(":", 1)[0] + ":task/"
        resource = task_arns[0][len(prefix):].split("/")
        # Accept legacy task IDs and cluster-qualified ARNs, but do not record
        # a task from an explicitly different cluster as the admitted task.
        matching_resource = bool(resource[-1]) and (
            len(resource) == 1 or
            (len(resource) == 2 and resource[0] == run_task["cluster"].rsplit("/", 1)[1])
        )
        if (task_arns[0].startswith(prefix) and matching_resource
                and task.get("clusterArn", run_task["cluster"]) == run_task["cluster"]
                and task.get("taskDefinitionArn", run_task["taskDefinition"]) == run_task["taskDefinition"]):
            return LaunchObservation(LaunchOutcome.ACCEPTED, "TASK_ACCEPTED", **evidence)
    if not tasks and failures and len(failure_codes) == len(failures) and not failure_tasks:
        return LaunchObservation(LaunchOutcome.REJECTED, "NO_TASK_FAILURES", **evidence)
    return LaunchObservation(LaunchOutcome.UNKNOWN, "AMBIGUOUS_RESPONSE", **evidence)


def _launch(client, run_task) -> LaunchObservation:
    try:
        response = client.run_task(**run_task)
    except Exception as error:
        response = _mapping(getattr(error, "response", None))
        resource_ids = response.get("resourceIds")
        task_arns = tuple(value for value in resource_ids if _text(value)) if (
            isinstance(resource_ids, list)
        ) else ()
        if _text(resource_ids):
            task_arns = (resource_ids,)
        code = _error_code(error)
        rejected = (code in _ECS_REJECTIONS and (resource_ids is None or resource_ids == [])
                    and _retries(response) == 0
                    and _metadata(response).get("HTTPStatusCode") in (400, 403))
        return LaunchObservation(
            LaunchOutcome.REJECTED if rejected else LaunchOutcome.UNKNOWN,
            "REQUEST_REJECTED" if rejected else "CLIENT_FAILURE",
            _request_id(response), _retries(response), code, task_arns,
        )
    return _response_observation(response, run_task)


def dispatch_admitted(
    prepared: PreparedAdmission, *, admission_result: AdmissionResult,
    owner_invocation_id: str, ledger_client, launcher_client_factory,
) -> DispatchResult:
    """Execute the approved dispatch protocol with trusted injected clients.

    launcher_client_factory(role_arn) must return an ECS client using that job's
    launcher role and Region, total_max_attempts=1, and explicit timeouts within
    the invocation budget. Client construction must not launch tasks. Effective
    identity, IAM, deadlines and SDK behavior require runtime integration and
    AWS qualification. The ledger client uses admission_client_config().

    A fresh claim ID is generated per entry, never supplied by the caller. An
    SDK replay of the current claim is safe within this one sequential call;
    re-entry uses a new token and cannot replay a cached dispatch permit.
    Claim failure or uncertainty stops before ECS. A recording failure never
    retries ECS or performs cleanup. No read grants ownership or recovery.
    """
    actions = prepared.transaction_request()["TransactItems"]
    request, slot, accounting = actions[1]["Put"], actions[2]["Update"], actions[3]["Update"]
    item = request["Item"]
    if (not owner_invocation_id or item["owner_invocation_id"] != {"S": owner_invocation_id}
            or item["pk"] != {"S": prepared.request_pk}
            or item["attempt_id"] != {"S": prepared.attempt_id}
            or (admission_result.request_pk, admission_result.attempt_id)
            != (prepared.request_pk, prepared.attempt_id)):
        raise ValueError("Admission evidence and prepared ownership must match this invocation.")
    not_written = WriteEvidence(WriteOutcome.NOT_ATTEMPTED)

    def skipped(reason, error_code=None):
        return DispatchResult(
            prepared.request_pk, prepared.attempt_id, None, not_written,
            LaunchObservation(LaunchOutcome.NOT_ATTEMPTED, reason, error_code=error_code),
            not_written,
        )

    if admission_result.outcome is not AdmissionOutcome.CONFIRMED:
        return skipped("ADMISSION_NOT_CONFIRMED")
    intent = json.loads(item["intent_json"]["S"])
    run_task = json.loads(item["run_task_request_json"]["S"])
    # Check the execution contract, not AWS naming/size/feature constraints.
    if (run_task["clientToken"] != prepared.attempt_id
            or intent["execution_policy"]["run_task_total_max_attempts"] != 1):
        raise ValueError("Dispatch must retain the admitted token and one-attempt launch policy.")
    try:
        client = launcher_client_factory(intent["launcher_role_arn"])
    except Exception as error:
        return skipped("LAUNCHER_SETUP_FAILED", _error_code(error))
    config = getattr(getattr(client, "meta", None), "config", None)
    attempts = _mapping(getattr(config, "retries", None)).get("total_max_attempts")
    if type(attempts) is not int or attempts != 1:
        return skipped("INVALID_LAUNCHER_RETRY_POLICY")

    dispatch_id = uuid4().hex
    claim = _submit(ledger_client, _transaction(request, slot, accounting, dispatch_id))
    if claim.outcome is not WriteOutcome.CONFIRMED:
        return DispatchResult(
            prepared.request_pk, prepared.attempt_id, dispatch_id, claim,
            LaunchObservation(LaunchOutcome.NOT_ATTEMPTED, "CLAIM_NOT_CONFIRMED"), not_written,
        )
    launch = _launch(client, run_task)
    recording = _submit(ledger_client, _transaction(
        request, slot, accounting, dispatch_id, observation=launch,
    ))
    return DispatchResult(prepared.request_pk, prepared.attempt_id, dispatch_id,
                          claim, launch, recording)
