"""Integrated offline broker flow; protected AWS delivery/bootstrap is not implemented."""

from dataclasses import asdict, dataclass, field
from enum import Enum
import json

from admission import prepare_admission
from admission_executor import AdmissionOutcome, execute_admission
from catalog import InvalidCatalog, load_catalog
from completion import CompletionOutcome, _string, record_task_completion
from dispatch import LaunchOutcome, WriteOutcome, dispatch_admitted
from producer_authorization import UnauthorizedProducer
from request_schema import RejectedRequest


class DeliveryKind(Enum):
    REQUEST = "REQUEST"
    COMPLETION = "COMPLETION"


class Disposition(Enum):
    ACK = "ACK"
    RETRY = "RETRY"


@dataclass(frozen=True)
class AuthenticatedDelivery:
    """Output of a trusted delivery adapter, never authentication by itself.

    Kind and producer identity must come from the protected delivery boundary,
    not from claims in the message body. Constructing this object does not prove
    AWS provenance. body is the original SQS body; no payload is logged here.
    """

    kind: DeliveryKind
    body: str = field(repr=False)
    producer_role_id: str | None = None


@dataclass(frozen=True)
class DeliveryResult:
    """ACK means message handling is complete, not application-job success.

    RETRY retains the delivery for bounded redelivery/DLQ handling. It never
    authorizes takeover, cleanup, or another ECS call for an existing attempt.
    Only codes and opaque ledger/task identifiers cross this result boundary.
    """

    disposition: Disposition
    reason: str
    request_pk: str | None = None
    attempt_id: str | None = None
    dispatch_id: str | None = None
    task_arn: str | None = None
    error_code: str | None = None


class RetryDelivery(RuntimeError):
    """Single-message handler failure; retain result codes without raw payloads."""

    def __init__(self, result: DeliveryResult):
        self.result = result
        super().__init__(result.reason)


def _duplicate_result(admitted, prepared):
    # The executor has already checked the original key/schema/intent and gate.
    # A matching intent alone is insufficient to acknowledge unresolved work.
    try:
        item = json.loads(admitted.original_request_json)
        status = _string(item, "status")
        attempt = _string(item, "attempt_id")
        dispatch = _string(item, "dispatch_id")
        task = _string(item, "task_arn")
        identifiers = {
            "request_pk": prepared.request_pk, "attempt_id": attempt,
            "dispatch_id": dispatch, "task_arn": task,
        }
        if status in ("REGISTERED", "DISPATCHING", "LAUNCH_UNKNOWN"):
            return DeliveryResult(Disposition.RETRY, "DUPLICATE_UNRESOLVED", **identifiers)
        if (status not in ("LAUNCH_ACCEPTED", "LAUNCH_REJECTED", "TASK_STOPPED")
                or not attempt or not dispatch or not _string(item, "owner_invocation_id")):
            raise ValueError("Incomplete resolved request.")
        launch = json.loads(_string(item, "run_task_request_json"))
        expected = json.loads(prepared.intent_json)["run_task"] | {"clientToken": attempt}
        observation = json.loads(_string(item, "launch_observation_json"))
        if launch != expected:
            raise ValueError("Inconsistent original launch.")
        if status == "LAUNCH_REJECTED":
            valid = (observation["outcome"] == "REJECTED"
                     and observation["task_arns"] == [] and "task_arn" not in item)
        else:
            valid = (bool(task) and observation["outcome"] == "ACCEPTED"
                     and observation["task_arns"] == [task])
            if status == "TASK_STOPPED":
                terminal = json.loads(_string(item, "completion_observation_json"))
                valid = valid and all(terminal.get(key) == value for key, value in {
                    "task_arn": task, "cluster_arn": launch["cluster"],
                    "task_definition_arn": launch["taskDefinition"], "last_status": "STOPPED",
                }.items())
        if not valid:
            raise ValueError("Inconsistent resolved result.")
    except (ValueError, TypeError, KeyError, AttributeError):
        return DeliveryResult(Disposition.RETRY, "DUPLICATE_INVALID_RECORD",
                              request_pk=prepared.request_pk)
    return DeliveryResult(Disposition.ACK, "DUPLICATE_RESOLVED", **identifiers)


def process_delivery(
    delivery: AuthenticatedDelivery, *, application_id: str, environment: str,
    owner_invocation_id: str, ledger_table_arn: str, ledger_client,
    catalog_json=None, catalog_approvals=None, gate_table_arn=None,
    launcher_client_factory=None,
) -> DeliveryResult:
    """Connect existing helpers for one authenticated delivery, without loops.

    Scope, catalog bytes/approvals, table ARNs, invocation ID and clients must
    come from protected runtime context. Requests load the supplied catalog;
    completion does not depend on the current catalog, gate or launcher setup.
    Clients retain the helpers' approved retry/identity contracts. SDK creation,
    invocation budgets, authentication and deployed queue behavior are not
    implemented here. Tests inject trusted delivery and scripted clients.

    Later request delivery prepares a fresh candidate under the same durable
    request key; an existing record never becomes a dispatch permit. UNKNOWN
    ends this invocation without resubmission. No original record is rewritten
    or adopted to continue an earlier attempt.
    """
    if not isinstance(delivery, AuthenticatedDelivery) or not isinstance(delivery.kind, DeliveryKind):
        return DeliveryResult(Disposition.RETRY, "INVALID_DELIVERY_CONTEXT")
    if any(not isinstance(value, str) or not value or value != value.strip()
           for value in (application_id, environment, owner_invocation_id, ledger_table_arn)):
        return DeliveryResult(Disposition.RETRY, "INVALID_RUNTIME_CONTEXT")

    if delivery.kind is DeliveryKind.COMPLETION:
        try:
            event = json.loads(delivery.body)
        except (ValueError, TypeError, RecursionError):
            return DeliveryResult(Disposition.RETRY, "COMPLETION_INVALID_JSON")
        completed = record_task_completion(
            event, application_id=application_id, environment=environment,
            ledger_table_arn=ledger_table_arn, ledger_client=ledger_client,
        )
        acknowledge = completed.outcome in (
            CompletionOutcome.RECORDED, CompletionOutcome.ALREADY_RECORDED, CompletionOutcome.IGNORED,
        )
        return DeliveryResult(
            Disposition.ACK if acknowledge else Disposition.RETRY,
            f"COMPLETION_{completed.outcome.value}:{completed.reason}",
            completed.request_pk, completed.attempt_id, completed.dispatch_id,
            # Do not echo unbound event contents into log-safe diagnostics.
            completed.task_arn if completed.request_pk is not None else None,
            completed.recording.error_code or completed.read_error_code,
        )

    try:
        catalog = load_catalog(catalog_json, **(catalog_approvals or {}))
        if (catalog.application_id, catalog.environment) != (application_id, environment):
            return DeliveryResult(Disposition.RETRY, "CATALOG_SCOPE_MISMATCH")
        prepared = prepare_admission(
            delivery.body, catalog=catalog, producer_role_id=delivery.producer_role_id,
            owner_invocation_id=owner_invocation_id, gate_table_arn=gate_table_arn,
            ledger_table_arn=ledger_table_arn,
        )
    except InvalidCatalog:
        return DeliveryResult(Disposition.RETRY, "INVALID_CATALOG")
    except RejectedRequest:
        return DeliveryResult(Disposition.RETRY, "REQUEST_REJECTED")
    except UnauthorizedProducer:
        return DeliveryResult(Disposition.RETRY, "PRODUCER_NOT_AUTHORIZED")

    admitted = execute_admission(prepared, client=ledger_client, owner_invocation_id=owner_invocation_id)
    if admitted.outcome is AdmissionOutcome.DUPLICATE:
        return _duplicate_result(admitted, prepared)
    if admitted.outcome is not AdmissionOutcome.CONFIRMED:
        return DeliveryResult(
            Disposition.RETRY, f"ADMISSION_{admitted.outcome.value}:{admitted.reason.value}",
            prepared.request_pk, prepared.attempt_id, error_code=admitted.error_code,
        )

    dispatched = dispatch_admitted(
        prepared, admission_result=admitted, owner_invocation_id=owner_invocation_id,
        ledger_client=ledger_client, launcher_client_factory=launcher_client_factory,
    )
    acknowledge = (
        dispatched.recording.outcome is WriteOutcome.CONFIRMED
        and dispatched.launch.outcome in (LaunchOutcome.ACCEPTED, LaunchOutcome.REJECTED)
    )
    reason = f"LAUNCH_{dispatched.launch.outcome.value}_RECORDING_{dispatched.recording.outcome.value}"
    if dispatched.launch.outcome is LaunchOutcome.NOT_ATTEMPTED:
        reason = f"DISPATCH_{dispatched.launch.reason}:{dispatched.claim.outcome.value}"
    return DeliveryResult(
        Disposition.ACK if acknowledge else Disposition.RETRY, reason,
        prepared.request_pk, prepared.attempt_id, dispatched.dispatch_id,
        dispatched.launch.task_arns[0] if len(dispatched.launch.task_arns) == 1 else None,
        dispatched.recording.error_code or dispatched.launch.error_code or dispatched.claim.error_code,
    )


def handle_sqs_event(event, context, *, authenticate_delivery, **runtime) -> dict:
    """Injectable single-message adapter; not the configured lambda_handler.

    authenticate_delivery(record) must establish protected delivery provenance
    and return AuthenticatedDelivery with trusted kind/producer attribution.
    Checking queue ARN, SenderId or event shape alone is not authentication.
    The adapter is deliberately supplied, not implemented or selected by the
    event. Runtime bootstrap must enforce invocation and queue protections.

    Return normally only for ACK; raise RetryDelivery for all other outcomes.
    The Lambda event-source mapping, not this module, deletes or redelivers
    messages and performs configured DLQ redrive. It currently uses batch size
    one without partial-batch responses. No SQS API call or failure-forwarding
    write occurs here. Unknown exceptions fail the invocation without exposing
    their message, event payload, catalog, or internal ledger snapshots.
    """
    records = event.get("Records") if isinstance(event, dict) else None
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        raise RetryDelivery(DeliveryResult(Disposition.RETRY, "INVALID_BATCH"))
    try:
        delivery = authenticate_delivery(records[0])
    except Exception as error:
        result = DeliveryResult(Disposition.RETRY, "DELIVERY_AUTHENTICATION_FAILED",
                                error_code=type(error).__name__)
    else:
        try:
            result = process_delivery(delivery, owner_invocation_id=context.aws_request_id, **runtime)
        except Exception as error:
            result = DeliveryResult(Disposition.RETRY, "PROCESSING_ERROR",
                                    error_code=type(error).__name__)
    if result.disposition is Disposition.RETRY:
        raise RetryDelivery(result) from None
    return asdict(result) | {"disposition": result.disposition.value}
