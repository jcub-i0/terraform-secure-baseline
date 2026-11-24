"""Parse untrusted broker request bodies; this does not authorize execution."""

import json
from dataclasses import dataclass


class RejectedRequest(ValueError):
    """The request does not satisfy the broker message contract."""


@dataclass(frozen=True)
class JobRequest:
    job_key: str
    request_key: str
    admission_generation: str
    schedule_key: str | None = None
    schedule_arn: str | None = None
    scheduled_time: str | None = None


_REQUIRED_FIELDS = {
    "schema_version", "job_key", "request_key", "admission_generation"
}
_SCHEDULE_FIELDS = {"schedule_key", "schedule_arn", "scheduled_time"}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise RejectedRequest("Duplicate JSON field.")
        result[key] = value
    return result


def parse_request(body: str) -> JobRequest:
    if not isinstance(body, str):
        raise RejectedRequest("Request body must be a JSON string.")

    try:
        data = json.loads(body, object_pairs_hook=_unique_object)
    except (json.JSONDecodeError, RecursionError) as exc:
        raise RejectedRequest("Invalid request JSON.") from exc

    if not isinstance(data, dict):
        raise RejectedRequest("Request must be a JSON object.")

    fields = set(data)
    if not _REQUIRED_FIELDS <= fields:
        raise RejectedRequest("Missing required request fields.")
    if fields - (_REQUIRED_FIELDS | _SCHEDULE_FIELDS):
        raise RejectedRequest("Unsupported request fields.")
    if type(data["schema_version"]) is not int or data["schema_version"] != 2:
        raise RejectedRequest("Only request schema version 2 is supported.")

    schedule_fields = fields & _SCHEDULE_FIELDS
    if schedule_fields and schedule_fields != _SCHEDULE_FIELDS:
        raise RejectedRequest("Schedule metadata must be complete or absent.")

    for field in fields - {"schema_version"}:
        value = data[field]
        if not isinstance(value, str) or not value or value != value.strip():
            raise RejectedRequest(f"Invalid request field: {field}.")

    return JobRequest(**{
        key: value for key, value in data.items() if key != "schema_version"
    })
