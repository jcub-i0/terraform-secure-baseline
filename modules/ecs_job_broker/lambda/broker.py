"""Broker orchestration and Lambda bootstrap; activation requires protected AWS delivery.

The platform-approved ZIP contains this module, requirements-sdk.txt's installed
dependencies, runtime.json and catalog.json. runtime.json supplies schema_version
1, application_id, environment, the unqualified function_arn, ledger_table_arn,
request_queue_arn, completion_queue_arn (null until provisioned), and a requests
object containing gate_table_arn and catalog_approvals. The latter has the same
cluster/subnet/per-job SG fields accepted by load_catalog, with JSON lists for
sets. Those approvals come from platform review, never from catalog selections.

Queue/role attribution is trustworthy ONLY when deployment, invocation, queue,
producer trust and mapping policies enforce the approved delivery paths. This
code cannot distinguish a forged SQS-shaped direct invocation by inspecting it.
The Terraform function and mapping stay disabled pending those controls and
qualification. The runtime never initializes or opens a gate, resets accounting,
changes IAM, or performs protected recovery.
"""

from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
import json
from pathlib import Path

from admission import prepare_admission
from admission_executor import AdmissionOutcome, admission_client_config, execute_admission
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


class BudgetExceeded(RuntimeError):
    """Do not start another operation; preserve any existing reservation."""


def _single_record(event):
    records = event.get("Records") if isinstance(event, dict) else None
    if not isinstance(records, list) or len(records) != 1 or not isinstance(records[0], dict):
        raise RetryDelivery(DeliveryResult(Disposition.RETRY, "INVALID_BATCH"))
    return records[0]


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
    launcher_client_factory=None, check_budget=None,
) -> DeliveryResult:
    """Connect existing helpers for one authenticated delivery, without loops.

    Scope, catalog bytes/approvals, table ARNs, invocation ID and clients must
    come from protected runtime context. Requests load the supplied catalog;
    completion does not depend on the current catalog, gate or launcher setup.
    Clients retain the helpers' approved retry/identity contracts. lambda_handler
    supplies SDK clients and a remaining-time guard; callers using this helper
    directly must supply their own protected context. Offline tests inject
    delivery and scripted clients; they do not establish AWS provenance.

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
            check_budget=check_budget,
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

    if check_budget is not None:
        check_budget(50000)
    admitted = execute_admission(prepared, client=ledger_client,
                                 owner_invocation_id=owner_invocation_id, check_budget=check_budget)
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
        check_budget=check_budget,
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
    record = _single_record(event)
    try:
        delivery = authenticate_delivery(record)
    except Exception as error:
        result = DeliveryResult(Disposition.RETRY, "DELIVERY_AUTHENTICATION_FAILED",
                                error_code=type(error).__name__)
    else:
        try:
            result = process_delivery(delivery, owner_invocation_id=context.aws_request_id, **runtime)
        except BudgetExceeded:
            result = DeliveryResult(Disposition.RETRY, "BUDGET_EXHAUSTED")
        except Exception as error:
            result = DeliveryResult(Disposition.RETRY, "PROCESSING_ERROR",
                                    error_code=type(error).__name__)
    if result.disposition is Disposition.RETRY:
        raise RetryDelivery(result) from None
    return asdict(result) | {"disposition": result.disposition.value}


_PACKAGE_ROOT = Path(__file__).resolve().parent


def _scoped_resource(value, function, service, prefix):
    # Check security scope, not every AWS resource-name constraint.
    parts = value.split(":", 5) if isinstance(value, str) else []
    if (len(parts) != 6 or parts[:5] != ["arn", function[1], service, function[3], function[4]]
            or not parts[5].startswith(prefix) or len(parts[5]) <= len(prefix)
            or "*" in value or "?" in value or value != value.strip()):
        raise ValueError("Runtime resource scope mismatch.")


def _bootstrap_config(context):
    config = json.loads((_PACKAGE_ROOT / "runtime.json").read_bytes().decode("utf-8"))
    if not isinstance(config, dict) or type(config.get("schema_version")) is not int or config["schema_version"] != 1:
        raise ValueError("Unsupported bootstrap configuration.")
    for key in ("application_id", "environment", "function_arn"):
        if not isinstance(config.get(key), str) or not config[key] or config[key] != config[key].strip():
            raise ValueError("Missing bootstrap scope.")
    function = config["function_arn"].split(":")
    if (len(function) != 7 or function[0] != "arn" or function[2] != "lambda"
            or function[5] != "function" or not all(function) or "*" in config["function_arn"]
            or "?" in config["function_arn"]
            or context.invoked_function_arn.split(":")[:7] != function):
        raise ValueError("Bootstrap does not belong to this function.")
    _scoped_resource(config["ledger_table_arn"], function, "dynamodb", "table/")
    _scoped_resource(config["request_queue_arn"], function, "sqs", "")
    completion = config["completion_queue_arn"]
    if completion is not None:
        _scoped_resource(completion, function, "sqs", "")
        if completion == config["request_queue_arn"]:
            raise ValueError("Request and completion queues must be distinct.")
    return config, function


def _protected_delivery(record, config, region):
    """Attribute a record only under independently enforced delivery protections.

    Metadata consistency is not proof of invocation provenance. Deny ordinary
    direct invocation and protect queue submission/mutation and mappings before
    activation. Never use body claims or custom message attributes as identity.
    """
    if (record.get("eventSource") != "aws:sqs" or record.get("awsRegion") != region
            or not isinstance(record.get("body"), str)):
        raise ValueError("Unexpected delivery transport.")
    source = record.get("eventSourceARN")
    if source == config["request_queue_arn"]:
        sender = record.get("attributes", {}).get("SenderId")
        if not isinstance(sender, str):
            raise ValueError("Missing producer attribution.")
        role_id, separator, session = sender.partition(":")
        if not separator or not session or not role_id.startswith("AROA"):
            raise ValueError("Only assumed producer roles are supported.")
        return AuthenticatedDelivery(DeliveryKind.REQUEST, record["body"], role_id)
    if config["completion_queue_arn"] is not None and source == config["completion_queue_arn"]:
        return AuthenticatedDelivery(DeliveryKind.COMPLETION, record["body"])
    raise ValueError("Unapproved delivery queue.")


def _sdk_session(region):
    # Lazy import keeps the pure contracts usable without SDK initialization.
    from boto3.session import Session
    return Session(region_name=region)


def _bootstrap_runtime(config, function, delivery, context, check_budget):
    from botocore.config import Config

    runtime = {key: config[key] for key in ("application_id", "environment", "ledger_table_arn")}
    runtime["check_budget"] = check_budget
    if delivery.kind is DeliveryKind.REQUEST:
        request = config["requests"]
        gate = request["gate_table_arn"]
        _scoped_resource(gate, function, "dynamodb", "table/")
        if gate == config["ledger_table_arn"]:
            raise ValueError("The gate must be independent of the execution ledger.")
        approvals = request["catalog_approvals"]
        _scoped_resource(approvals["approved_cluster_arn"], function, "ecs", "cluster/")
        runtime.update(
            gate_table_arn=gate,
            # Decode bytes directly: universal-newline translation changes the digest.
            catalog_json=(_PACKAGE_ROOT / "catalog.json").read_bytes().decode("utf-8"),
            catalog_approvals={
                "approved_cluster_arn": approvals["approved_cluster_arn"],
                "approved_private_subnet_ids": frozenset(approvals["approved_private_subnet_ids"]),
                "approved_security_groups_by_job": {
                    job: frozenset(groups)
                    for job, groups in approvals["approved_security_groups_by_job"].items()
                },
            },
        )
    region = function[3]
    session = _sdk_session(region)
    runtime["ledger_client"] = session.client(
        "dynamodb", region_name=region,
        config=Config(**admission_client_config(), ignore_configured_endpoint_urls=True),
    )

    def launcher(role_arn):
        # Only dispatch of a confirmed admission calls this factory, using its
        # stored approved role. No cached credentials or broker-credential fallback.
        check_budget(35000)
        sts = session.client("sts", region_name=region, config=Config(
            connect_timeout=1, read_timeout=2,
            retries={"mode": "standard", "total_max_attempts": 1},
            ignore_configured_endpoint_urls=True,
        ))
        credentials = sts.assume_role(
            RoleArn=role_arn, RoleSessionName=f"broker-{context.aws_request_id}", DurationSeconds=900,
        )["Credentials"]
        if (any(not isinstance(credentials.get(key), str) or not credentials[key]
                for key in ("AccessKeyId", "SecretAccessKey", "SessionToken"))
                or not isinstance(credentials.get("Expiration"), datetime)
                or credentials["Expiration"] <= datetime.now(timezone.utc) + timedelta(seconds=65)):
            raise ValueError("Missing or expiring launcher credentials.")
        return session.client(
            "ecs", region_name=region, aws_access_key_id=credentials["AccessKeyId"],
            aws_secret_access_key=credentials["SecretAccessKey"],
            aws_session_token=credentials["SessionToken"],
            config=Config(connect_timeout=1, read_timeout=3,
                          retries={"mode": "standard", "total_max_attempts": 1},
                          ignore_configured_endpoint_urls=True),
        )

    if delivery.kind is DeliveryKind.REQUEST:
        runtime["launcher_client_factory"] = launcher
    return runtime


def lambda_handler(event, context):
    """Configured entry point, kept disabled by Terraform pending qualification.

    Fixed package files are supplied by the protected deployment authority.
    Only Lambda context supplies invocation identity/time. Budget checks prevent
    starting new operations with too little time: 15 seconds per DynamoDB call,
    20 before ECS (single 1s connect/3s read attempt plus result-write reserve).
    Earlier stage checks reserve the remaining sequence within the 60s function.
    They cannot cancel an in-flight call or prove an uncertain attempt resolved.
    """
    def check_budget(minimum_ms):
        remaining = context.get_remaining_time_in_millis()
        if type(remaining) is not int or remaining < minimum_ms:
            raise BudgetExceeded("Insufficient invocation time.")

    try:
        record = _single_record(event)
        check_budget(15000)
        config, function = _bootstrap_config(context)
        delivery = _protected_delivery(record, config, function[3])
        runtime = _bootstrap_runtime(config, function, delivery, context, check_budget)
    except RetryDelivery:
        raise
    except BudgetExceeded:
        raise RetryDelivery(DeliveryResult(Disposition.RETRY, "BUDGET_EXHAUSTED")) from None
    except Exception as error:
        raise RetryDelivery(DeliveryResult(Disposition.RETRY, "BOOTSTRAP_FAILED",
                                          error_code=type(error).__name__)) from None
    return handle_sqs_event(event, context, authenticate_delivery=lambda _: delivery, **runtime)
