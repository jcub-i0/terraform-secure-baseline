"""Validate a catalog's decoded producer section; no provenance checks."""

import re
from collections.abc import Mapping
from types import MappingProxyType

from producer_authorization import ProducerPolicy


class InvalidProducerCatalog(ValueError):
    """Producer configuration is malformed or ambiguous."""


_ROLE_ID = re.compile(r"AROA[A-Za-z0-9_]{12,124}")
_FIELDS = {"logical_producer_id", "role_ids", "allowed_jobs"}


def _is_identifier(value: object) -> bool:
    return isinstance(value, str) and bool(value) and value == value.strip()


def _identifier_list(value: object, field: str) -> frozenset[str]:
    if not isinstance(value, list) or not all(map(_is_identifier, value)):
        raise InvalidProducerCatalog(f"Invalid {field} list.")
    if len(value) != len(set(value)):
        raise InvalidProducerCatalog(f"Duplicate value in {field}.")
    return frozenset(value)


def load_producer_policies(
    producers: object,
    *,
    declared_job_keys: frozenset[str],
) -> Mapping[str, ProducerPolicy]:
    """Build an immutable role-ID mapping from a decoded producer list.

    The full catalog loader must supply keys from validated job entries.
    This function does not decode JSON or authenticate producer identities.
    """
    if not isinstance(declared_job_keys, frozenset) or not all(
        map(_is_identifier, declared_job_keys)
    ):
        raise InvalidProducerCatalog("Invalid declared job keys.")
    if not isinstance(producers, list):
        raise InvalidProducerCatalog("Producers must be a list.")

    policies = {}
    logical_ids = set()
    for entry in producers:
        if not isinstance(entry, dict) or set(entry) != _FIELDS:
            raise InvalidProducerCatalog("Invalid producer fields.")

        logical_id = entry["logical_producer_id"]
        if not _is_identifier(logical_id) or logical_id in logical_ids:
            raise InvalidProducerCatalog("Invalid or duplicate logical producer ID.")

        role_ids = _identifier_list(entry["role_ids"], "role_ids")
        allowed_jobs = _identifier_list(entry["allowed_jobs"], "allowed_jobs")
        if not role_ids or any(_ROLE_ID.fullmatch(role) is None for role in role_ids):
            raise InvalidProducerCatalog("Invalid producer role ID.")
        if not allowed_jobs <= declared_job_keys:
            raise InvalidProducerCatalog("Producer references an undefined job.")
        if role_ids & policies.keys():
            raise InvalidProducerCatalog("Role ID belongs to multiple producers.")

        policy = ProducerPolicy(logical_id, allowed_jobs)
        logical_ids.add(logical_id)
        for role_id in role_ids:
            policies[role_id] = policy

    return MappingProxyType(policies)
