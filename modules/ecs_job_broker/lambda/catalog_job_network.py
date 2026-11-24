"""Validate decoded job networking against supplied protected approvals."""

import re
from dataclasses import dataclass


class InvalidJobNetwork(ValueError):
    """Network configuration is malformed or outside the supplied approvals."""


@dataclass(frozen=True)
class JobNetwork:
    subnet_ids: tuple[str, ...]
    security_group_ids: tuple[str, ...]
    assign_public_ip: str


_FIELDS = {"subnet_ids", "security_group_ids", "assign_public_ip"}
_SUBNET = re.compile(r"subnet-(?:[0-9a-f]{8}|[0-9a-f]{17})")
_GROUP = re.compile(r"sg-(?:[0-9a-f]{8}|[0-9a-f]{17})")


def _valid_id(value, pattern):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def _check_approval(value, pattern, field):
    if not isinstance(value, frozenset) or not value or not all(
        _valid_id(item, pattern) for item in value
    ):
        raise InvalidJobNetwork(f"Invalid {field} approval.")


def _load_ids(value, pattern, limit, field):
    if not isinstance(value, list) or not 1 <= len(value) <= limit:
        raise InvalidJobNetwork(f"Invalid {field} list size or type.")
    if not all(_valid_id(item, pattern) for item in value):
        raise InvalidJobNetwork(f"Invalid identifier in {field}.")
    if len(value) != len(set(value)):
        raise InvalidJobNetwork(f"Duplicate identifier in {field}.")
    return tuple(value)


def load_job_network(
    network: object,
    *,
    approved_private_subnet_ids: frozenset[str],
    approved_security_group_ids: frozenset[str],
) -> JobNetwork:
    """Check a subnet selection and an exact reviewed security-group combination.

    The caller must supply qualified, protected approval context. This does not
    establish resource existence, VPC/account/Region membership, subnet privacy,
    effective security-group rules, or continued approval after infrastructure changes.
    """
    _check_approval(approved_private_subnet_ids, _SUBNET, "private subnet")
    _check_approval(approved_security_group_ids, _GROUP, "security group")
    if len(approved_security_group_ids) > 5:
        raise InvalidJobNetwork("Too many approved security groups for one task.")
    if not isinstance(network, dict) or set(network) != _FIELDS:
        raise InvalidJobNetwork("Invalid job network fields.")
    if network["assign_public_ip"] != "DISABLED":
        raise InvalidJobNetwork("Public IP assignment must be DISABLED.")

    subnets = _load_ids(network["subnet_ids"], _SUBNET, 16, "subnet_ids")
    groups = _load_ids(network["security_group_ids"], _GROUP, 5, "security_group_ids")
    if not frozenset(subnets) <= approved_private_subnet_ids:
        raise InvalidJobNetwork("Subnet selection exceeds approved private subnets.")
    if frozenset(groups) != approved_security_group_ids:
        raise InvalidJobNetwork("Security groups must match the reviewed combination.")

    return JobNetwork(subnets, groups, "DISABLED")
