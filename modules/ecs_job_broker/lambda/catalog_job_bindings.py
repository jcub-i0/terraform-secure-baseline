"""Validate one job's execution identities; no AWS or provenance checks."""

import re
from dataclasses import dataclass


class InvalidJobBinding(ValueError):
    """A job's execution identities are malformed or inconsistent."""


@dataclass(frozen=True)
class JobBinding:
    cluster_arn: str
    task_definition_arn: str
    launcher_role_arn: str
    execution_role_arn: str
    task_role_arn: str


_ROLE_FIELDS = ("launcher_role_arn", "execution_role_arn", "task_role_arn")
_FIELDS = {"task_definition_arn", *_ROLE_FIELDS}
_ECS_PREFIX = r"arn:(aws|aws-us-gov|aws-cn):ecs:([a-z0-9-]+):([0-9]{12}):"
_CLUSTER = _ECS_PREFIX + r"cluster/[A-Za-z0-9_-]{1,255}"
_TASK = _ECS_PREFIX + r"task-definition/[A-Za-z0-9_-]{1,255}:[1-9][0-9]*"
_ROLE = (
    r"arn:(aws|aws-us-gov|aws-cn):iam::([0-9]{12}):role/"
    r"(?:[\x21-\x7e]{1,510}/)?[A-Za-z0-9_+=,.@-]{1,64}"
)


def _match_arn(value: object, pattern: str, field: str):
    if not isinstance(value, str) or "*" in value or "?" in value:
        raise InvalidJobBinding(f"Invalid {field}.")
    match = re.fullmatch(pattern, value)
    if match is None:
        raise InvalidJobBinding(f"Invalid {field}.")
    return match


def load_job_binding(binding: object, *, approved_cluster_arn: str) -> JobBinding:
    """Validate a decoded binding against the supplied protected cluster.

    This establishes syntax and scope consistency, not AWS resource existence,
    effective permissions, or task-definition role associations.
    """
    cluster = _match_arn(approved_cluster_arn, _CLUSTER, "approved_cluster_arn")
    if not isinstance(binding, dict) or set(binding) != _FIELDS:
        raise InvalidJobBinding("Invalid job binding fields.")

    task = _match_arn(binding["task_definition_arn"], _TASK, "task_definition_arn")
    if task.groups() != cluster.groups():
        raise InvalidJobBinding(
            "Task definition must match cluster partition, region, and account."
        )

    role_scope = (cluster.group(1), cluster.group(3))
    for field in _ROLE_FIELDS:
        role = _match_arn(binding[field], _ROLE, field)
        if role.groups() != role_scope:
            raise InvalidJobBinding(
                "Job roles must match cluster partition and account."
            )

    return JobBinding(cluster_arn=approved_cluster_arn, **binding)
