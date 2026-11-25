"""Validate decoded Fargate launch settings; no AWS or provenance checks."""

import re
from dataclasses import dataclass


class InvalidJobFargate(ValueError):
    """Fargate settings are malformed or outside the initial launch contract."""


@dataclass(frozen=True)
class JobFargate:
    launch_type: str
    platform_version: str
    count: int


_FIELDS = {"launch_type", "platform_version", "count"}
_VERSION_PART = r"(?:0|[1-9][0-9]*)"
_PLATFORM_VERSION = re.compile(
    rf"{_VERSION_PART}\.{_VERSION_PART}\.{_VERSION_PART}"
)


def load_job_fargate(fargate: object) -> JobFargate:
    """Validate one decoded Fargate section from a protected catalog.

    Platform validation checks selector syntax only. It does not establish AWS
    support, task-definition compatibility, or artifact approval. LATEST is an
    explicit selector, never an implicit default. Count one is a per-call limit,
    not an execution-concurrency reservation.
    """
    if not isinstance(fargate, dict) or set(fargate) != _FIELDS:
        raise InvalidJobFargate("Invalid job Fargate fields.")
    if fargate["launch_type"] != "FARGATE":
        raise InvalidJobFargate("Launch type must be FARGATE.")
    if type(fargate["count"]) is not int or fargate["count"] != 1:
        raise InvalidJobFargate("Task count must be the integer one.")

    platform_version = fargate["platform_version"]
    if not isinstance(platform_version, str) or (
        platform_version != "LATEST"
        and _PLATFORM_VERSION.fullmatch(platform_version) is None
    ):
        raise InvalidJobFargate("Invalid explicit Fargate platform selector.")

    return JobFargate("FARGATE", platform_version, 1)