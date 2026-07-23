# Security Policy Module

## Overview

The `security_policy` module centrally manages security group rules for the
workload environment.

This module does **not** create security groups. It receives security group IDs
from the compute, data, automation, and VPC endpoint layers and attaches the
approved rules between them.

The module also exports the compute-related security group rule IDs that must
exist before EC2 instances launch.

---

## Purpose

The module centralizes network access policy for:

- Compute access to Interface VPC Endpoints
- Lambda automation access to Interface VPC Endpoints
- Compute access to the database
- Database ingress from compute
- Conditional compute HTTPS egress through the configured egress path
- Resource-level dependency readiness for compute EC2 instances

Keeping these rules in one module makes traffic policy easier to review and
avoids scattering security group rules across compute, storage, automation, and
VPC endpoint modules.

---

## Resources Created

This module creates `aws_security_group_rule` resources only.

### Interface VPC Endpoint Rules

Allows Interface VPC Endpoint access from:

- The compute security group over TCP/443
- The EC2 Isolation Lambda security group over TCP/443
- The EC2 Rollback Lambda security group over TCP/443

The Interface Endpoint security group also receives an outbound TCP/443 rule for
communication from endpoint ENIs to AWS services.

### Compute Rules

Allows compute instances to:

- Reach Interface VPC Endpoints over TCP/443
- Reach the database security group on `var.db_port`
- Reach `0.0.0.0/0` over TCP/443 when the effective egress mode is
  `nat_only` or `network_firewall`

The general HTTPS egress rule is not created when:

```text
egress_mode = "vpc_endpoints_only"
```

### Data Rules

Allows the database or data security group to receive traffic from the compute
security group on `var.db_port`.

### Lambda Automation Rules

Allows the EC2 Isolation and EC2 Rollback Lambda security groups to reach
Interface VPC Endpoints over TCP/443.

---

## Conditional Egress Behavior

The `compute_egress_to_internet_https` rule uses:

```hcl
count = var.egress_mode == "vpc_endpoints_only" ? 0 : 1
```

Behavior by mode:

| Egress mode | General compute TCP/443 egress |
|---|---|
| `network_firewall` | Created |
| `nat_only` | Created |
| `vpc_endpoints_only` | Not created |

The rule permits HTTPS traffic at the security group layer. The actual egress
path is controlled by the networking architecture:

- `network_firewall`: compute route to AWS Network Firewall, then NAT Gateway
- `nat_only`: compute route directly to a NAT Gateway
- `vpc_endpoints_only`: approved AWS service access through VPC endpoints only

---

## Inputs

| Name | Type | Description | Required |
|---|---|---|---:|
| `egress_mode` | `string` | Effective egress mode controlling conditional compute HTTPS egress | Yes |
| `compute_sg_id` | `string` | Security group ID for EC2 compute instances | Yes |
| `data_sg_id` | `string` | Security group ID for the database or data layer | Yes |
| `lambda_ec2_isolation_sg_id` | `string` | Security group ID for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_sg_id` | `string` | Security group ID for the EC2 Rollback Lambda | Yes |
| `interface_endpoints_sg_id` | `string` | Security group ID for Interface VPC Endpoints | Yes |
| `db_port` | `string` | Database port allowed between compute and data resources | Yes |

Expected `egress_mode` values:

```text
network_firewall
nat_only
vpc_endpoints_only
```

---

## Outputs

### `compute_sg_rule_ids`

Exports the security group rule IDs that must exist before compute EC2
instances launch.

```hcl
output "compute_sg_rule_ids" {
  description = "Security Group rule IDs that must exist before compute EC2 instances launch"

  value = {
    endpoints_ingress_from_compute = aws_security_group_rule.endpoints_ingress_from_compute.id
    compute_egress_to_endpoints    = aws_security_group_rule.compute_egress_to_endpoints.id
    compute_egress_to_db           = aws_security_group_rule.compute_egress_to_db.id

    compute_egress_to_internet_https = try(
      aws_security_group_rule.compute_egress_to_internet_https[0].id,
      null
    )
  }
}
```

Output shape:

```hcl
{
  endpoints_ingress_from_compute   = string
  compute_egress_to_endpoints      = string
  compute_egress_to_db             = string
  compute_egress_to_internet_https = string | null
}
```

`compute_egress_to_internet_https` is `null` when `egress_mode` is
`vpc_endpoints_only`, because the conditional rule has `count = 0`.

### Dependency-Readiness Purpose

The parent networking module passes this output through to the compute module:

```text
security_policy.compute_sg_rule_ids
        |
        v
networking.compute_sg_rule_ids
        |
        v
compute.compute_sg_rule_ids
        |
        v
terraform_data.compute_security_policy_ready
        |
        v
aws_instance.ec2
```

This resource-level dependency chain allows the compute security group to be
created before the security-policy rules while preventing the EC2 instances
from launching until those required rules exist.

It avoids both:

- A first-boot race where cloud-init runs before HTTPS egress is ready
- A cyclic module-level dependency between networking and compute

---

## Usage Example

```hcl
module "security_policy" {
  source = "../modules/networking/security_policy"

  egress_mode = var.egress_mode

  compute_sg_id              = module.compute.compute_sg_id
  data_sg_id                 = module.storage.data_sg_id
  lambda_ec2_isolation_sg_id = module.automation.lambda_ec2_isolation_sg_id
  lambda_ec2_rollback_sg_id  = module.automation.lambda_ec2_rollback_sg_id
  interface_endpoints_sg_id  = module.vpc_endpoints.interface_endpoints_sg_id
  db_port                    = var.db_port
}
```

The parent networking module should pass through the readiness output:

```hcl
output "compute_sg_rule_ids" {
  description = "Security group rule IDs that must exist before compute EC2 instances launch"
  value       = module.security_policy.compute_sg_rule_ids
}
```

---

## Traffic Summary

| Source | Destination | Port | Purpose | Condition |
|---|---|---:|---|---|
| Compute SG | Interface Endpoints SG | 443 | Private AWS service access | Always |
| EC2 Isolation Lambda SG | Interface Endpoints SG | 443 | Private AWS API access | Always |
| EC2 Rollback Lambda SG | Interface Endpoints SG | 443 | Private AWS API access | Always |
| Interface Endpoints SG | `0.0.0.0/0` | 443 | Endpoint ENI communication with AWS services | Always |
| Compute SG | Data SG | `db_port` | Database access | Always |
| Data SG | Compute SG | `db_port` | Database ingress from compute | Always |
| Compute SG | `0.0.0.0/0` | 443 | HTTPS through configured egress path | Not `vpc_endpoints_only` |

---

## Validation

### Terraform Validation

```bash
terraform fmt -recursive
terraform validate
terraform plan
```

### Confirm Compute HTTPS Egress

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --group-ids "${COMPUTE_SG_ID}" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json
```

For `nat_only` and `network_firewall`, expect a rule equivalent to:

```text
TCP 443 -> 0.0.0.0/0
```

For `vpc_endpoints_only`, the general `0.0.0.0/0` HTTPS rule should be absent.

### Confirm Terraform Readiness Output

From the parent environment root:

```bash
terraform output -json compute_sg_rule_ids
```

Or inspect the security-policy submodule resource directly:

```bash
terraform state show \
  'module.networking.module.security_policy.aws_security_group_rule.compute_egress_to_internet_https[0]'
```

The exact state address may include additional parent module prefixes.

---

## Security Notes

- This module should not create broad inbound access.
- Interface Endpoint ingress is limited to approved internal security groups.
- Database access is limited to compute security group traffic on the configured
  database port.
- General compute HTTPS egress is created only for egress modes that provide a
  controlled public egress path.
- The security group rule alone does not provide internet access; routes, NAT
  Gateways, Network Firewall policy, NACLs, and DNS must also be correctly
  configured.
- Lambda automation security groups are granted only TCP/443 access to Interface
  VPC Endpoints.
- The readiness output exposes resource IDs for dependency ordering; it does not
  grant additional network access.

---

## Notes

- Deploy this module after the referenced compute, data, automation, and
  Interface Endpoint security groups exist.
- Security groups are created by other modules; this module attaches rules to
  them.
- The `compute_sg_rule_ids` output is passed through the networking module to
  delay EC2 instance creation until required rules exist.
- Keep the output object attribute name
  `compute_egress_to_internet_https` consistent through the security-policy,
  networking, and compute modules.