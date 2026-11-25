"""Offline network-contract tests; approvals are synthetic fixtures."""

from dataclasses import FrozenInstanceError
import unittest

from catalog_job_network import InvalidJobNetwork, load_job_network


class CatalogJobNetworkTests(unittest.TestCase):
    def setUp(self):
        self.subnets = ["subnet-0123456789abcdef0", "subnet-fedcba98765432100"]
        self.groups = ["sg-0123456789abcdef0", "sg-fedcba98765432100"]
        self.network = {
            "subnet_ids": list(self.subnets),
            "security_group_ids": list(self.groups),
            "assign_public_ip": "DISABLED",
        }
        self.approval = {
            "approved_private_subnet_ids": frozenset(self.subnets),
            "approved_security_group_ids": frozenset(self.groups),
        }

    def load(self, network):
        return load_job_network(network, **self.approval)

    def test_valid_network_preserves_values(self):
        loaded = self.load(self.network)
        self.assertEqual(loaded.subnet_ids, tuple(self.subnets))
        self.assertEqual(loaded.security_group_ids, tuple(self.groups))
        self.assertEqual(loaded.assign_public_ip, "DISABLED")

    def test_subset_of_approved_subnets_is_allowed(self):
        loaded = self.load(self.network | {"subnet_ids": [self.subnets[0]]})
        self.assertEqual(loaded.subnet_ids, (self.subnets[0],))

    def test_security_group_order_does_not_change_approval(self):
        groups = list(reversed(self.groups))
        loaded = self.load(self.network | {"security_group_ids": groups})
        self.assertEqual(loaded.security_group_ids, tuple(groups))

    def test_security_group_combination_must_match(self):
        for groups in (
            [self.groups[0]],
            self.groups + ["sg-00000000000000001"],
            [self.groups[0], "sg-00000000000000001"],
        ):
            with self.subTest(groups=groups):
                with self.assertRaises(InvalidJobNetwork):
                    self.load(self.network | {"security_group_ids": groups})

    def test_unapproved_subnet_is_rejected(self):
        with self.assertRaises(InvalidJobNetwork):
            self.load(self.network | {
                "subnet_ids": ["subnet-00000000000000001"]
            })

    def test_public_ip_assignment_must_be_explicitly_disabled(self):
        for value in ("ENABLED", "disabled", " DISABLED", None, False, 0):
            with self.subTest(value=value):
                with self.assertRaises(InvalidJobNetwork):
                    self.load(self.network | {"assign_public_ip": value})

    def test_missing_extra_fields_and_non_objects_are_rejected(self):
        for field in self.network:
            incomplete = dict(self.network)
            del incomplete[field]
            with self.subTest(missing=field):
                with self.assertRaises(InvalidJobNetwork):
                    self.load(incomplete)
        for network in (None, [], "network", self.network | {"overrides": {}}):
            with self.subTest(network=network):
                with self.assertRaises(InvalidJobNetwork):
                    self.load(network)

    def test_invalid_lists_and_duplicates_are_rejected(self):
        for field in ("subnet_ids", "security_group_ids"):
            original = self.network[field][0]
            for value in ([], None, original, {original}, [original, original]):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidJobNetwork):
                        self.load(self.network | {field: value})

    def test_invalid_resource_ids_are_rejected(self):
        for field in ("subnet_ids", "security_group_ids"):
            original = self.network[field][0]
            for value in (
                None, 123, "", original.upper(), original + "*",
                " " + original, original + "\n", original[:-1],
                "vpc-0123456789abcdef0",
            ):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidJobNetwork):
                        self.load(self.network | {field: [value]})

    def test_legacy_resource_id_lengths_remain_supported(self):
        network = self.network | {
            "subnet_ids": ["subnet-1234abcd"],
            "security_group_ids": ["sg-1234abcd"],
        }
        loaded = load_job_network(
            network,
            approved_private_subnet_ids=frozenset(network["subnet_ids"]),
            approved_security_group_ids=frozenset(network["security_group_ids"]),
        )
        self.assertEqual(loaded.subnet_ids, ("subnet-1234abcd",))
        self.assertEqual(loaded.security_group_ids, ("sg-1234abcd",))

    def test_ecs_list_size_bounds(self):
        for subnet_count, group_count, valid in (
            (16, 5, True),
            (17, 5, False),
            (16, 6, False),
        ):
            subnets = [f"subnet-{i:017x}" for i in range(subnet_count)]
            groups = [f"sg-{i:017x}" for i in range(group_count)]
            network = self.network | {
                "subnet_ids": subnets,
                "security_group_ids": groups,
            }
            approval = {
                "approved_private_subnet_ids": frozenset(subnets),
                "approved_security_group_ids": frozenset(groups),
            }
            with self.subTest(subnets=subnet_count, groups=group_count):
                if valid:
                    loaded = load_job_network(network, **approval)
                    self.assertEqual(len(loaded.subnet_ids), 16)
                    self.assertEqual(len(loaded.security_group_ids), 5)
                else:
                    with self.assertRaises(InvalidJobNetwork):
                        load_job_network(network, **approval)

    def test_invalid_approval_context_is_rejected(self):
        for field, original in self.approval.items():
            for value in (None, set(original), frozenset(), frozenset({"invalid"})):
                with self.subTest(field=field, value=value):
                    with self.assertRaises(InvalidJobNetwork):
                        load_job_network(
                            self.network, **(self.approval | {field: value})
                        )

    def test_loaded_network_is_an_immutable_snapshot(self):
        loaded = self.load(self.network)
        self.network["subnet_ids"].clear()
        self.network["security_group_ids"].clear()
        self.assertEqual(loaded.subnet_ids, tuple(self.subnets))
        self.assertEqual(loaded.security_group_ids, tuple(self.groups))
        with self.assertRaises(FrozenInstanceError):
            loaded.assign_public_ip = "ENABLED"


if __name__ == "__main__":
    unittest.main()
