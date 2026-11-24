"""Build durable request keys; reservation and conflict checks happen elsewhere."""

import hashlib
import json

from request_schema import JobRequest


def request_ledger_key(
    request: JobRequest,
    *,
    application_id: str,
    environment: str,
    logical_producer_id: str,
) -> str:
    """Build a stable key using protected scope and an authorized producer ID.

    Field order, encoding, and prefix are persistent storage format v1.
    Changing them requires a protocol that preserves existing request history.
    """
    identity = (
        application_id,
        environment,
        logical_producer_id,
        request.request_key,
    )

    if any(
        not isinstance(value, str) or not value or value != value.strip()
        for value in identity
    ):
        raise ValueError("Invalid request identity component.")

    encoded = json.dumps(
        identity, ensure_ascii=True, separators=(",", ":")
    ).encode("ascii")

    return "request:v1:" + hashlib.sha256(encoded).hexdigest()
