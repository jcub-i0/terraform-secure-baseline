"""Execute one prepared admission; results never authorize ECS dispatch."""

from dataclasses import dataclass, field
from enum import Enum
import json

from admission import (
    ExistingRequestDisposition,
    InvalidLedgerRecord,
    PreparedAdmission,
    classify_existing_request,
)


class AdmissionOutcome(Enum):
    CONFIRMED = "CONFIRMED"
    DUPLICATE = "DUPLICATE"
    CONFLICT = "CONFLICT"
    REJECTED = "REJECTED"
    UNKNOWN = "UNKNOWN"


class AdmissionReason(Enum):
    ACKNOWLEDGED = "ACKNOWLEDGED"
    REQUEST_EXISTS = "REQUEST_EXISTS"
    INTENT_CONFLICT = "INTENT_CONFLICT"
    GATE_NOT_ELIGIBLE = "GATE_NOT_ELIGIBLE"
    SLOT_UNAVAILABLE = "SLOT_UNAVAILABLE"
    ACCOUNTING_CONDITION_FAILED = "ACCOUNTING_CONDITION_FAILED"
    PERMISSION_DENIED = "PERMISSION_DENIED"
    CONFIGURATION_ERROR = "CONFIGURATION_ERROR"
    TRANSIENT_SERVICE_FAILURE = "TRANSIENT_SERVICE_FAILURE"
    TRANSACTION_CANCELED = "TRANSACTION_CANCELED"
    TRANSACTION_IN_PROGRESS = "TRANSACTION_IN_PROGRESS"
    TOKEN_MISMATCH = "TOKEN_MISMATCH"
    UNCLASSIFIED_FAILURE = "UNCLASSIFIED_FAILURE"
    UNEXPECTED_RESPONSE = "UNEXPECTED_RESPONSE"
    LOOKUP_FAILED = "LOOKUP_FAILED"
    ORIGINAL_REQUEST_MISSING = "ORIGINAL_REQUEST_MISSING"
    INVALID_REQUEST_RECORD = "INVALID_REQUEST_RECORD"


@dataclass(frozen=True)
class AdmissionResult:
    """Evidence about the submitted candidate, never a dispatch/release permit.

    attempt_id identifies the candidate even for DUPLICATE/CONFLICT; the
    original record retains its own owner and attempt. Its snapshot is for
    trusted runtime use and must not be logged or exposed to producers.
    """

    outcome: AdmissionOutcome
    reason: AdmissionReason
    request_pk: str
    attempt_id: str
    aws_request_id: str | None = None
    sdk_retry_attempts: int | None = None
    error_code: str | None = None
    # Positions: gate, request, slot, accounting. No service messages or items.
    cancellation_codes: tuple[str, ...] | None = None
    lookup_request_id: str | None = None
    lookup_error_code: str | None = None
    original_request_json: str | None = field(default=None, repr=False)


def admission_client_config() -> dict:
    """Arguments for botocore.config.Config on the runtime DynamoDB client.

    Standard SDK retries are bounded to three total attempts per API call.
    These socket timeouts are not an end-to-end deadline. Runtime integration
    budgets admission and lookup within the invocation; live behavior still
    requires qualification.
    This helper creates no client and performs no AWS or credential lookup.
    """
    return {
        "connect_timeout": 1,
        "read_timeout": 2,
        "retries": {"mode": "standard", "total_max_attempts": 3},
    }


def _mapping(value) -> dict:
    return value if isinstance(value, dict) else {}


def _metadata(response) -> dict:
    return _mapping(_mapping(response).get("ResponseMetadata"))


def _request_id(response) -> str | None:
    value = _metadata(response).get("RequestId")
    return value if isinstance(value, str) else None


def _retries(response) -> int | None:
    value = _metadata(response).get("RetryAttempts")
    return value if type(value) is int and value >= 0 else None


def _error_code(error) -> str:
    code = _mapping(_mapping(getattr(error, "response", None)).get("Error")).get("Code")
    return code if isinstance(code, str) else type(error).__name__


def _cancellation_codes(response) -> tuple[str, ...] | None:
    reasons = _mapping(response).get("CancellationReasons")
    if not isinstance(reasons, list) or len(reasons) != 4:
        return None
    codes = tuple(_mapping(reason).get("Code") for reason in reasons)
    return codes if all(isinstance(code, str) for code in codes) else None


def _cancellation_reason(codes) -> AdmissionReason:
    if codes is None:
        return AdmissionReason.TRANSACTION_CANCELED
    # Keep operational faults visible even when other conditions also fail.
    if "ValidationError" in codes or "ItemCollectionSizeLimitExceeded" in codes:
        return AdmissionReason.CONFIGURATION_ERROR
    if codes[3] == "ConditionalCheckFailed":
        return AdmissionReason.ACCOUNTING_CONDITION_FAILED
    if codes[0] == "ConditionalCheckFailed":
        return AdmissionReason.GATE_NOT_ELIGIBLE
    if any(code not in {"None", "ConditionalCheckFailed", "TransactionConflict",
                        "ProvisionedThroughputExceeded", "ThrottlingError"}
           for code in codes):
        return AdmissionReason.TRANSACTION_CANCELED
    if any(code in {"TransactionConflict", "ProvisionedThroughputExceeded",
                    "ThrottlingError"} for code in codes):
        return AdmissionReason.TRANSIENT_SERVICE_FAILURE
    if codes[1] == "ConditionalCheckFailed":
        return AdmissionReason.REQUEST_EXISTS
    if codes[2] == "ConditionalCheckFailed":
        # This condition also rejects malformed slots; do not claim BUSY.
        return AdmissionReason.SLOT_UNAVAILABLE
    return AdmissionReason.TRANSACTION_CANCELED


def _failure_reason(code, codes) -> tuple[AdmissionReason, bool]:
    """Return a diagnostic and whether this service error rejects its write.

    The caller separately checks for earlier, unobserved SDK attempts.
    This is an intentionally limited set; unfamiliar errors remain uncertain.
    """
    if code == "TransactionCanceledException":
        return _cancellation_reason(codes), True
    if code == "AccessDeniedException":
        return AdmissionReason.PERMISSION_DENIED, True
    if code in {"ValidationException", "ResourceNotFoundException",
                "UnrecognizedClientException", "InvalidSignatureException"}:
        return AdmissionReason.CONFIGURATION_ERROR, True
    if code in {"ProvisionedThroughputExceededException", "RequestLimitExceeded",
                "ThrottlingException", "TransactionConflictException"}:
        return AdmissionReason.TRANSIENT_SERVICE_FAILURE, True
    if code in {"InternalServerError", "ServiceUnavailable"}:
        return AdmissionReason.TRANSIENT_SERVICE_FAILURE, False
    if code == "TransactionInProgressException":
        return AdmissionReason.TRANSACTION_IN_PROGRESS, False
    if code == "IdempotentParameterMismatchException":
        return AdmissionReason.TOKEN_MISMATCH, False
    return AdmissionReason.UNCLASSIFIED_FAILURE, False


def execute_admission(
    prepared: PreparedAdmission, *, client, owner_invocation_id: str,
    check_budget=None,
) -> AdmissionResult:
    """Submit once through a trusted, configured low-level DynamoDB client.

    Runtime must use Config(**admission_client_config()), freshly authenticate
    delivery, and prepare once for this invocation. Only the SDK retries this
    submission, using the unchanged payload/token. There is no outer retry loop
    or cross-invocation recovery API here. UNKNOWN ends this invocation; later
    authenticated delivery follows fresh conditional admission, never takeover.
    Runtime supplies check_budget before each SDK operation. It cannot cancel
    an in-flight request or resolve uncertainty.

    REJECTED establishes no commit for this submission, not for the request's
    lifetime. UNKNOWN preserves possible commits from unobserved SDK attempts.
    Reason describes the final evidence; it never overrides outcome certainty.
    A successful SDK retry may acknowledge an earlier commit. CONFIRMED is not
    new launch authority: dispatch still needs its separate ownership protocol.

    Tests use scripted clients only. Gate authority, permissions, initialization
    and lifecycle integration must be approved before actual AWS execution.
    """
    transaction = prepared.transaction_request()
    gate = transaction["TransactItems"][0]["ConditionCheck"]
    request = transaction["TransactItems"][1]["Put"]
    if not owner_invocation_id or request["Item"]["owner_invocation_id"] != {
        "S": owner_invocation_id
    }:
        raise ValueError("Prepared admission belongs to another invocation.")

    def result(outcome, reason, response=None, **details):
        return AdmissionResult(
            outcome=outcome, reason=reason,
            request_pk=prepared.request_pk, attempt_id=prepared.attempt_id,
            aws_request_id=_request_id(response), sdk_retry_attempts=_retries(response),
            **details,
        )

    if check_budget is not None:
        check_budget(15000)
    try:
        response = client.transact_write_items(**transaction)
    except Exception as error:
        # Restrict the catch to I/O. Unknown client failures may follow a write.
        failure = _mapping(getattr(error, "response", None))
        code = _error_code(error)
        codes = (
            _cancellation_codes(failure)
            if code == "TransactionCanceledException" else None
        )
        reason, rejects_write = _failure_reason(code, codes)
        evidence = {"error_code": code, "cancellation_codes": codes}
        if not (rejects_write and _retries(failure) == 0
                and _metadata(failure).get("HTTPStatusCode") in (400, 403)):
            # RetryAttempts is a count, not proof that earlier writes failed.
            return result(AdmissionOutcome.UNKNOWN, reason, failure, **evidence)
        if reason is not AdmissionReason.REQUEST_EXISTS:
            return result(AdmissionOutcome.REJECTED, reason, failure, **evidence)
    else:
        if _metadata(response).get("HTTPStatusCode") != 200:
            return result(AdmissionOutcome.UNKNOWN, AdmissionReason.UNEXPECTED_RESPONSE, response)
        return result(AdmissionOutcome.CONFIRMED, AdmissionReason.ACKNOWLEDGED, response)

    # Only an established collision reaches this read. Check current eligibility
    # and the original record in one snapshot; never acquire or transfer ownership.
    if check_budget is not None:
        check_budget(15000)
    try:
        lookup = client.transact_get_items(TransactItems=[
            {"Get": {"TableName": gate["TableName"], "Key": gate["Key"]}},
            {"Get": {
                "TableName": request["TableName"], "Key": {"pk": request["Item"]["pk"]},
            }},
        ])
    except Exception as error:
        return result(
            AdmissionOutcome.REJECTED, AdmissionReason.LOOKUP_FAILED, failure,
            **evidence, lookup_request_id=_request_id(getattr(error, "response", None)),
            lookup_error_code=_error_code(error),
        )

    evidence["lookup_request_id"] = _request_id(lookup)
    responses = _mapping(lookup).get("Responses")
    if (_metadata(lookup).get("HTTPStatusCode") != 200
            or not isinstance(responses, list) or len(responses) != 2):
        return result(AdmissionOutcome.REJECTED, AdmissionReason.UNEXPECTED_RESPONSE,
                      failure, **evidence)

    current_gate = _mapping(_mapping(responses[0]).get("Item"))
    expected = gate["ExpressionAttributeValues"]
    gate_fields = {
        "schema_version": ":version", "record_type": ":kind", "state": ":open",
        "admission_generation": ":generation", "catalog_sha256": ":digest",
        "execution_ledger_arn": ":ledger",
    }
    if any(current_gate.get(key) != expected[value] for key, value in gate_fields.items()):
        return result(AdmissionOutcome.REJECTED, AdmissionReason.GATE_NOT_ELIGIBLE,
                      failure, **evidence)

    original = _mapping(responses[1]).get("Item")
    try:
        disposition = classify_existing_request(prepared, original)
        if disposition is ExistingRequestDisposition.ABSENT:
            return result(AdmissionOutcome.REJECTED, AdmissionReason.ORIGINAL_REQUEST_MISSING,
                          failure, **evidence)
        original_json = json.dumps(original, ensure_ascii=True, sort_keys=True)
    except (InvalidLedgerRecord, TypeError, ValueError):
        return result(AdmissionOutcome.REJECTED, AdmissionReason.INVALID_REQUEST_RECORD,
                      failure, **evidence)

    duplicate = disposition is ExistingRequestDisposition.DUPLICATE
    return result(
        AdmissionOutcome.DUPLICATE if duplicate else AdmissionOutcome.CONFLICT,
        AdmissionReason.REQUEST_EXISTS if duplicate else AdmissionReason.INTENT_CONFLICT,
        failure, **evidence, original_request_json=original_json,
    )
