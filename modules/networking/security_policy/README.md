# Security Policy Module

## Overview

The `security_policy` module centrally manages security group rules for the
workload environment.

This module does **not** create security groups. It receives security group IDs
from the compute, ECS service, ALB, data, automation, and VPC endpoint layers
and attaches the approved rules between them.

The module exports both the compute rule IDs that must exist before EC2
instances launch and per-service ECS rule IDs used by the ECS service launch
readiness checkpoint.

---

## Purpose

The module centralizes network access policy for:

- Compute access to Interface VPC Endpoints
- Lambda automation access to Interface VPC Endpoints
- Compute access to the database
- Database ingress from compute
- Conditional compute HTTPS egress through the configured egress path
- Resource-level dependency readiness for compute EC2 instances
- ECS task access to Interface Endpoints and the S3 Gateway Endpoint path
- Conditional ECS task access to RDS and the shared ALB
- Egress-mode-aware ECS application HTTPS egress
- Resource-level dependency readiness for ECS services

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

### ECS Task Rules

For every entry in `ecs_security_policy_services`, the module creates:

- task SG egress to the Interface Endpoint SG over TCP/443;
- Interface Endpoint SG ingress from the task SG over TCP/443; and
- task SG egress to the S3 managed prefix list over TCP/443.

The S3 rule is independent of the Interface Endpoint relationship. ECR API and
registry traffic uses the `ecr.api` and `ecr.dkr` Interface Endpoints, while ECR
image layers use the existing S3 Gateway Endpoint.

General task HTTPS egress to `0.0.0.0/0` exists only when the effective egress
mode is `nat_only` or `network_firewall`. Database rules exist only when
`database_access = true`. ALB-to-task rules exist only when `alb_access = true`.
Baseline derives `alb_access` from the plan-time-known fact that service ingress
is configured; filtering must not depend on the resource-derived `alb_sg_id`,
which is unknown during planning.

---

## Conditional Egress Behavior

The `compute_egress_to_internet_https` rule uses:

```hcl
count = var.egress_mode == "vpc_endpoints_only" ? 0 : 1
```

The per-service `ecs_tasks_egress_to_internet_https` collection applies the
same condition. Behavior by mode is:

| Egress mode | General compute TCP/443 | General ECS task TCP/443 |
|---|---|---|
| `network_firewall` | Created | Created per service |
| `nat_only` | Created | Created per service |
| `vpc_endpoints_only` | Not created | Not created |

The rule permits HTTPS traffic at the security group layer. The actual egress
path is controlled by the networking architecture:

- `network_firewall`: compute route to AWS Network Firewall, then NAT Gateway
- `nat_only`: compute route directly to a NAT Gateway
- `vpc_endpoints_only`: approved AWS service access through VPC endpoints only

---

## Inputs

| Name | Type | Description | Required |
|---|---|---|---:|
| `egress_mode` | `string` | Effective egress mode controlling conditional compute and ECS HTTPS egress | Yes |
| `compute_sg_id` | `string` | Security group ID for EC2 compute instances | Yes |
| `data_sg_id` | `string` | Security group ID for the database or data layer | Yes |
| `lambda_ec2_isolation_sg_id` | `string` | Security group ID for the EC2 Isolation Lambda | Yes |
| `lambda_ec2_rollback_sg_id` | `string` | Security group ID for the EC2 Rollback Lambda | Yes |
| `interface_endpoints_sg_id` | `string` | Security group ID for Interface VPC Endpoints | Yes |
| `db_port` | `string` | Database port allowed between compute and data resources | Yes |
| `quarantine_sg_id` | `string` | EC2 quarantine security group ID | Yes |
| `ecs_security_policy_services` | `map(object(...))` | Per-service task SG, port, optional ALB SG, and database/ALB intent | No; default `{}` |
| `s3_prefix_list_id` | `string` | Resource-backed prefix-list ID from `aws_vpc_endpoint.s3.prefix_list_id`; required when ECS services are present | Conditional |

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

### `ecs_sg_rule_ids`

Exports a map keyed by the same canonical ECS service names. Each entry
contains the Interface Endpoint ingress/egress IDs, S3 egress ID, and nullable
internet, database, and ALB rule IDs:

```hcl
{
  endpoints_ingress     = string
  endpoints_egress      = string
  s3_egress             = string
  internet_https_egress = string | null
  db_egress             = string | null
  db_ingress            = string | null
  alb_ingress            = string | null
  alb_egress             = string | null
}
```

Baseline compacts the applicable IDs into one set per service and passes that
map to `modules/ecs_service`. These IDs remain an internal resource-granular
readiness interface; they are not required workload-root outputs.

### Dependency-Readiness Purpose

The baseline passes this output directly into the compute module:

```text
security_policy.compute_sg_rule_ids
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
created before the security-policy rules while preventing EC2 instances from
launching until those rules exist.

ECS uses the same resource-granular pattern:

```text
ECS task SG
  -> security_policy ECS rules
  -> terraform_data.ecs_security_policy_ready
  -> aws_ecs_service.services
```

The task SG can be created without consuming its own downstream readiness
output. Only ECS task launch depends on completed rule IDs. Broad module-level
`depends_on` relationships between `ecs_service` and `security_policy` would
create a cycle and must not replace this graph.

The object proves security-group rule readiness only. It does not prove route,
NAT Gateway, Network Firewall, DNS, or package-repository availability.

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
  quarantine_sg_id           = module.compute.quarantine_sg_id

  ecs_security_policy_services = local.ecs_security_policy_services
  s3_prefix_list_id            = module.vpc_endpoints.s3_prefix_list_id
}
```

Pass the readiness output directly to `compute` in the calling baseline:

```hcl
module "compute" {
  source = "../modules/compute"

  # Other compute inputs omitted.
  compute_sg_rule_ids = module.security_policy.compute_sg_rule_ids
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
| ECS task SG | Interface Endpoints SG | 443 | Private AWS service access | Per configured ECS service |
| Interface Endpoints SG | ECS task SG | 443 | Return path for private AWS service access | Per configured ECS service |
| ECS task SG | S3 managed prefix list | 443 | ECR image layers and private S3 access | Per configured ECS service |
| ECS task SG | `0.0.0.0/0` | 443 | HTTPS through configured egress path | Not `vpc_endpoints_only` |
| ECS task SG | Data SG | `db_port` | Database access | `database_access = true` |
| Data SG | ECS task SG | `db_port` | Database ingress | `database_access = true` |
| ALB SG | ECS task SG | Service port | Ingress forwarding | `alb_access = true` |
| ECS task SG | ALB SG | Service port | Target traffic relationship | `alb_access = true` |

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
- ECS service intent is derived from the canonical `ecs_services` map; operators
  do not maintain a separate security-policy service map.
- The readiness output exposes resource IDs for dependency ordering; it does not
  grant additional network access.

---

## Notes

- Deploy this module after the referenced compute, ECS task, ALB, data,
  automation, and Interface Endpoint security groups exist.
- Security groups are created by other modules; this module attaches rules to
  them.
- The baseline passes `compute_sg_rule_ids` directly from this module into
  `compute` to delay EC2 instance creation until required rules exist.
- The baseline passes normalized `ecs_sg_rule_ids` to `ecs_service` to delay
  task launch until the applicable rules exist.
- Keep the output and compute input attribute name `compute_egress_to_internet_https` consistent.
