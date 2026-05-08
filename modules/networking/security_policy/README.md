# Security Policy Module

## Overview

The `security_policy` module manages security group rules for the workload environment.

This module does **not** create security groups directly.

Instead, it receives security group IDs from other modules and creates the rules that allow approved traffic between them.

---

## Purpose

The purpose of this module is to centralize network access policy between baseline components.

It manages rules for:

- Compute access to Interface VPC Endpoints
- Lambda automation access to Interface VPC Endpoints
- Compute access to the database
- Database ingress from compute
- Compute HTTPS egress through the controlled egress path

Keeping these rules in a dedicated module makes the traffic policy easier to review and avoids scattering security group rules across compute, storage, automation, and VPC endpoint modules.

---

## Resources Created

This module creates `aws_security_group_rule` resources only.

### Interface VPC Endpoint Rules

Allows HTTPS access to Interface VPC Endpoints from:

- Compute security group
- EC2 Isolation Lambda security group
- EC2 Rollback Lambda security group

### Compute Rules

Allows compute instances to:

- Reach Interface VPC Endpoints over TCP/443
- Reach the database security group on `var.db_port`
- Use HTTPS egress through the Network Firewall and NAT path

### Data Rules

Allows the database/data security group to receive traffic from compute on `var.db_port`.

### Lambda Automation Rules

Allows the EC2 Isolation and EC2 Rollback Lambda security groups to reach Interface VPC Endpoints over TCP/443.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `compute_sg_id` | Security group ID for EC2 compute instances | Yes |
| `data_sg_id` | Security group ID for the database/data layer | Yes |
| `lambda_ec2_isolation_sg_id` | Security group ID for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_sg_id` | Security group ID for the EC2 Rollback Lambda | Yes |
| `interface_endpoints_sg_id` | Security group ID for Interface VPC Endpoints | Yes |
| `db_port` | Database port allowed between compute and data resources | Yes |

---

## Outputs

This module has no outputs.

---

## Usage Example

%%%hcl
module "security_policy" {
  source = "../../modules/networking/security_policy"

  compute_sg_id              = module.compute.compute_sg_id
  data_sg_id                 = module.storage.data_sg_id
  interface_endpoints_sg_id  = module.vpc_endpoints.interface_endpoints_sg_id
  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
  db_port                    = var.db_port
}
%%%

---

## Traffic Summary

| Source | Destination | Port | Purpose |
|---|---|---:|---|
| Compute SG | Interface Endpoints SG | 443 | Private AWS service access |
| EC2 Isolation Lambda SG | Interface Endpoints SG | 443 | Private AWS API access |
| EC2 Rollback Lambda SG | Interface Endpoints SG | 443 | Private AWS API access |
| Compute SG | Data SG | `db_port` | Database access |
| Data SG | Compute SG | `db_port` | Database ingress from compute |
| Compute SG | `0.0.0.0/0` | 443 | HTTPS egress through controlled firewall/NAT path |

---

## Security Notes

- This module should not be used to create broad inbound access.
- Interface Endpoint access is limited to approved internal security groups.
- Database access is limited to compute security group traffic on the configured database port.
- Compute HTTPS egress is intended to flow through the baseline’s controlled egress path, including Network Firewall and NAT.
- Lambda automation security groups are only granted HTTPS access to Interface VPC Endpoints.

---

## Notes

- Deploy this module after compute, storage, automation, and VPC endpoint security groups exist.
- This module intentionally has no outputs.
- Security group resources are created by other modules; this module only attaches rules to them.