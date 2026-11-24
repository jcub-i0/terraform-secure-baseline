"""Evaluate producer-to-job policy; identity authentication happens upstream."""

from collections.abc import Mapping
from dataclasses import dataclass

from request_schema import JobRequest


class UnauthorizedProducer(ValueError):
    """The supplied producer identity is not authorized for this job."""


def _is_identifier(value: object) -> bool:
    return isinstance(value, str) and bool(value) and value == value.strip()


@dataclass(frozen=True)
class ProducerPolicy:
    logical_producer_id: str
    allowed_jobs: frozenset[str]

    def __post_init__(self):
        if not _is_identifier(self.logical_producer_id):
            raise ValueError("Invalid logical producer identity.")
        if not isinstance(self.allowed_jobs, frozenset) or not all(
            _is_identifier(job) for job in self.allowed_jobs
        ):
            raise ValueError("Allowed jobs must be a frozenset of identifiers.")


def authorize_producer(
    request: JobRequest,
    *,
    producer_role_id: str,
    producers_by_role_id: Mapping[str, ProducerPolicy],
) -> str:
    """Return the stable producer ID after an exact job-permission check.

    The caller must establish producer_role_id through authenticated delivery
    and supply protected policy configuration. This is not launch admission.
    """
    if not _is_identifier(producer_role_id):
        raise UnauthorizedProducer("Producer is not authorized for this job.")

    policy = producers_by_role_id.get(producer_role_id)
    if policy is None or request.job_key not in policy.allowed_jobs:
        raise UnauthorizedProducer("Producer is not authorized for this job.")

    return policy.logical_producer_id