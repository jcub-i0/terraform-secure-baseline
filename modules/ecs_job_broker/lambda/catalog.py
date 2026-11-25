"""Load catalog sections and resolve requests offline; no launch admission."""

import json
from collections.abc import Mapping
from dataclasses import dataclass
from types import MappingProxyType

from catalog_job_bindings import JobBinding, load_job_binding
from catalog_job_fargate import JobFargate, load_job_fargate
from catalog_job_network import JobNetwork, load_job_network
from catalog_producers import load_producer_policies
from producer_authorization import ProducerPolicy, authorize_producer
from request_identity import request_ledger_key
from request_schema import JobRequest, RejectedRequest, parse_request


class InvalidCatalog(ValueError):
    """The complete catalog or its supplied approval context is invalid."""


@dataclass(frozen=True)
class CatalogJob:
    binding: JobBinding
    network: JobNetwork
    fargate: JobFargate
    max_active_executions: int
    run_task_total_max_attempts: int


@dataclass(frozen=True)
class JobCatalog:
    application_id: str
    environment: str
    admission_generation: str
    cluster_arn: str
    jobs: Mapping[str, CatalogJob]
    producers_by_role_id: Mapping[str, ProducerPolicy]


@dataclass(frozen=True)
class ResolvedRequest:
    request: JobRequest
    logical_producer_id: str
    job: CatalogJob
    ledger_key: str


_CATALOG_FIELDS = {
    "schema_version", "application_id", "environment", "admission_generation",
    "cluster_arn", "jobs", "producers",
}
_JOB_FIELDS = {"binding", "network", "fargate", "execution_policy"}
_LIMIT_FIELDS = {"max_active_executions", "run_task_total_max_attempts"}


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise InvalidCatalog("Duplicate catalog JSON field.")
        result[key] = value
    return result


def _reject_constant(_value):
    raise InvalidCatalog("Non-finite JSON constants are unsupported.")


def load_catalog(
    body: str,
    *,
    approved_cluster_arn: str,
    approved_private_subnet_ids: frozenset[str],
    approved_security_groups_by_job: Mapping[str, frozenset[str]],
) -> JobCatalog:
    """Load schema-v1 JSON completely before returning an immutable catalog.

    The caller must establish artifact approval, the intended application and
    environment, and qualified protected resource approvals. Do not derive the
    approval arguments from the selections being checked. This function does
    not verify provenance, query AWS, or bind the catalog to an authoritative
    gate. Resource approvals are checked for each configured job. Empty jobs
    and producers are supported and permit no requests.
    """
    if not isinstance(body, str):
        raise InvalidCatalog("Catalog must be a JSON string.")
    try:
        data = json.loads(
            body, object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (ValueError, RecursionError) as exc:
        raise InvalidCatalog("Invalid catalog JSON.") from exc

    if not isinstance(data, dict) or set(data) != _CATALOG_FIELDS:
        raise InvalidCatalog("Invalid catalog fields.")
    if type(data["schema_version"]) is not int or data["schema_version"] != 1:
        raise InvalidCatalog("Only catalog schema version 1 is supported.")
    for field in (
        "application_id", "environment", "admission_generation", "cluster_arn"
    ):
        value = data[field]
        if not isinstance(value, str) or not value or value != value.strip():
            raise InvalidCatalog(f"Invalid catalog field: {field}.")
    if data["cluster_arn"] != approved_cluster_arn:
        raise InvalidCatalog("Catalog cluster does not match its approval.")

    raw_jobs = data["jobs"]
    if not isinstance(raw_jobs, dict):
        raise InvalidCatalog("Catalog jobs must be an object.")
    if (
        not isinstance(approved_security_groups_by_job, Mapping)
        or set(approved_security_groups_by_job) != set(raw_jobs)
    ):
        raise InvalidCatalog("Security-group approvals must cover exactly the jobs.")

    jobs = {}
    for job_key, entry in raw_jobs.items():
        if not job_key or job_key != job_key.strip():
            raise InvalidCatalog("Invalid catalog job key.")
        if not isinstance(entry, dict) or set(entry) != _JOB_FIELDS:
            raise InvalidCatalog("Invalid catalog job sections.")
        limits = entry["execution_policy"]
        if not isinstance(limits, dict) or set(limits) != _LIMIT_FIELDS:
            raise InvalidCatalog("Invalid execution-policy fields.")
        if any(
            type(limits[field]) is not int or limits[field] != 1
            for field in _LIMIT_FIELDS
        ):
            raise InvalidCatalog("Initial execution limits must be integer one.")

        try:
            jobs[job_key] = CatalogJob(
                binding=load_job_binding(
                    entry["binding"], approved_cluster_arn=approved_cluster_arn
                ),
                network=load_job_network(
                    entry["network"],
                    approved_private_subnet_ids=approved_private_subnet_ids,
                    approved_security_group_ids=(
                        approved_security_groups_by_job[job_key]
                    ),
                ),
                fargate=load_job_fargate(entry["fargate"]),
                **limits,
            )
        except ValueError as exc:
            raise InvalidCatalog(f"Invalid configuration for job {job_key}.") from exc

    try:
        producers = load_producer_policies(
            data["producers"], declared_job_keys=frozenset(jobs)
        )
    except ValueError as exc:
        raise InvalidCatalog("Invalid producer configuration.") from exc

    return JobCatalog(
        application_id=data["application_id"],
        environment=data["environment"],
        admission_generation=data["admission_generation"],
        cluster_arn=data["cluster_arn"],
        jobs=MappingProxyType(jobs),
        producers_by_role_id=producers,
    )


def resolve_request(
    body: str, *, catalog: JobCatalog, producer_role_id: str
) -> ResolvedRequest:
    """Resolve against a loaded catalog and a caller-authenticated producer ID.

    The generation comparison is only against the loaded catalog, not a live
    gate. Repeated resolution performs no deduplication or conflict detection.
    It reserves no slot, configures no SDK client, and authorizes no dispatch.
    This is not a Lambda handler or an authenticated event-delivery adapter.
    """
    request = parse_request(body)
    if request.admission_generation != catalog.admission_generation:
        raise RejectedRequest("Request generation does not match the catalog.")
    logical_id = authorize_producer(
        request, producer_role_id=producer_role_id,
        producers_by_role_id=catalog.producers_by_role_id,
    )
    return ResolvedRequest(
        request=request,
        logical_producer_id=logical_id,
        job=catalog.jobs[request.job_key],
        ledger_key=request_ledger_key(
            request, application_id=catalog.application_id,
            environment=catalog.environment, logical_producer_id=logical_id,
        ),
    )
