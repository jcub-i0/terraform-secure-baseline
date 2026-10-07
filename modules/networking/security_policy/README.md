# Security Policy Module

## Overview

The `security_policy` module centrally manages security group rules for the
workload environment.

This module does **not** create security groups. It receives security group IDs
from the compute, ECS service, ALB, data, automation, and VPC endpoint layers
and attaches the declared rules between them. The caller is responsible for
supplying the correct groups; this module does not validate account, VPC,
subnet placement, application identity, or the complete effective rule inventory.

The module exports both the compute rule IDs that must exist before EC2
instances launch and per-service ECS rule IDs used by the ECS service launch
readiness checkpoint.

---

## Purpose

The module centralizes network access policy for:

- Compute access to Interface VPC Endpoints
- Lambda automation access to Interface VPC Endpoints
- Quarantined EC2 access to the shared Interface Endpoint security group
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

This module creates `aws_security_group_rule` resources only. Its [resource
definitions](main.tf) are authoritative for the following rule inventory.
It does not create routes, endpoints, Network Firewall rules, IAM policies,
database credentials, or TLS configuration.

### Interface VPC Endpoint Rules

Allows Interface VPC Endpoint access from:

- The compute security group over TCP/443
- The EC2 Isolation Lambda security group over TCP/443
- The EC2 Rollback Lambda security group over TCP/443
- The quarantine security group over TCP/443
- Each configured ECS task security group over TCP/443

The Interface Endpoint security group also receives an outbound TCP/443 rule
to `0.0.0.0/0`. This is the configured destination, not an AWS-service identity
allowlist or a routing guarantee. The ingress and egress rules do not grant
permission to call the APIs reachable through an endpoint.

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
security group on `var.db_port`, and from each ECS task group whose
`database_access` flag is true. These are TCP rules, not SQL-user provisioning
or a database-authentication test. In the integrated storage module, `db_port`
is not wired to the RDS resource's `port` argument; changing this rule input
alone does not change the database listener. See the [storage reference](../../storage/README.md).

### Lambda Automation Rules

Allows the EC2 Isolation and EC2 Rollback Lambda security groups to reach
Interface VPC Endpoints over TCP/443. The IP Enrichment function has no workload
VPC attachment, so these rules do not constrain its external API traffic.

### Quarantine Rules

`endpoints_ingress_from_quarantine` and `quarantine_egress_to_endpoints`
preserve TCP/443 between quarantined EC2 instances and the shared Interface
Endpoint SG. This module grants the quarantine SG no general IPv4 HTTPS rule,
database rule, or S3-prefix-list rule.

Quarantine is therefore **not complete network disconnection**. The retained
path covers endpoint ENIs using the shared SG, not only the SSM endpoints.
Application/API authorization and the complete attached-group inventory remain
separate checks. The quarantine SG itself is created by [compute](../../compute/main.tf).

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
A null canonical image digest causes baseline to omit that service from this
module's input map; an empty map creates no per-service ECS rules.
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

The rule permits TCP/443 at the security group layer; it does not validate the
application protocol, certificate, destination hostname, or encryption.
The module compares the mode string to `vpc_endpoints_only` and does not itself
validate an enum. Pass the baseline's resolved `local.effective_egress_mode`,
not the user-facing `auto` input. An unsupported direct-call value would also
select the general TCP/443 rule rather than fail closed at this module boundary.

The intended integrated HTTPS path is controlled by the networking architecture:

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
| `s3_prefix_list_id` | `string` | Resource-backed S3 prefix-list ID; defaults to `null`, which is rejected when the service map is nonempty | Conditional |

Expected `egress_mode` values:

```text
network_firewall
nat_only
vpc_endpoints_only
```

The service schema in [variables.tf](variables.tf) is:

```hcl
map(object({
  task_sg_id      = string
  container_port  = number
  alb_sg_id       = optional(string)
  alb_access      = optional(bool, false)
  database_access = optional(bool, false)
}))
```

The eight non-service string inputs have no defaults. The module does not
independently check `alb_access` against a non-null ALB SG or validate port
ranges and group/region ownership. Its S3 validation is a non-null check, not
an AWS lookup of the supplied prefix list. The integrated caller supplies those
relationships; standalone callers must review them separately.

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

Output shape (descriptive notation, not executable HCL):

```text
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
internet, database, and ALB rule IDs (descriptive notation):

```text
{
  endpoints_ingress     = string
  endpoints_egress      = string
  s3_egress             = string
  internet_https_egress = string | null
  db_egress             = string | null
  db_ingress            = string | null
  alb_ingress          = string | null
  alb_egress           = string | null
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
  -> fixed-count / autoscaled ECS service resources
```

The task SG can be created without consuming its own downstream readiness
output. Only ECS task launch depends on completed rule IDs. Broad module-level
`depends_on` relationships between `ecs_service` and `security_policy` would
create a cycle and must not replace this graph.

The compute readiness object references only the four attributes shown above.
It does not include the separate data-side `db_ingress_from_compute` rule, the
quarantine rules, or the Lambda rules. ECS readiness includes the applicable
per-service IDs, including both sides of optional database/ALB relationships.
These dependencies order selected Terraform resource operations; they do not
probe effective network access or guarantee IAM/network propagation.

The rule IDs do not prove route, NAT Gateway, Network Firewall, DNS,
package-repository, database, or application availability. Compute also has a
separate endpoint-ID readiness dependency. See [compute/main.tf](../../compute/main.tf).

---

## Usage Example

```hcl
module "security_policy" {
  source = "../modules/networking/security_policy"

  egress_mode = local.effective_egress_mode

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

## Security-group rule summary

The table describes where Terraform attaches each rule. An ingress rule on a
destination SG is not a reverse traffic flow; security groups are stateful.

| Rule attached to | Type | Peer or destination | Port | Condition |
|---|---|---|---:|---|
| Interface Endpoints SG | Ingress | Compute SG | 443 | Always |
| Interface Endpoints SG | Ingress | EC2 Isolation Lambda SG | 443 | Always |
| Interface Endpoints SG | Ingress | EC2 Rollback Lambda SG | 443 | Always |
| Interface Endpoints SG | Ingress | Quarantine SG | 443 | Always |
| Quarantine SG | Egress | Interface Endpoints SG | 443 | Always |
| EC2 Isolation Lambda SG | Egress | Interface Endpoints SG | 443 | Always |
| EC2 Rollback Lambda SG | Egress | Interface Endpoints SG | 443 | Always |
| Interface Endpoints SG | Egress | `0.0.0.0/0` | 443 | Always |
| Compute SG | Egress | Interface Endpoints SG | 443 | Always |
| Compute SG | Egress | Data SG | `db_port` | Always |
| Data SG | Ingress | Compute SG | `db_port` | Always |
| Compute SG | Egress | `0.0.0.0/0` | 443 | Not `vpc_endpoints_only` |
| ECS task SG | Egress | Interface Endpoints SG | 443 | Per configured ECS service |
| Interface Endpoints SG | Ingress | ECS task SG | 443 | Per configured ECS service |
| ECS task SG | Egress | S3 managed prefix list | 443 | Per configured ECS service |
| ECS task SG | Egress | `0.0.0.0/0` | 443 | Per service; not `vpc_endpoints_only` |
| ECS task SG | Egress | Data SG | `db_port` | `database_access = true` |
| Data SG | Ingress | ECS task SG | `db_port` | `database_access = true` |
| ECS task SG | Ingress | ALB SG | Service port | `alb_access = true` |
| ALB SG | Egress | ECS task SG | Service port | `alb_access = true` |

---

## Validation

### Terraform Validation

Use an initialized workload root from the repository root directory, with the
same effective inputs used for deployment. This child module is not a
standalone deployment root. The local examples assume an explicitly selected
workload profile, service Region, and expected account as described in the
[validation checklist](../../../docs/validation-checklist.md). Under GitHub
OIDC, use the supplied credential chain rather than inventing a named profile.

```bash
(
  set -euo pipefail
  : "${ENVIRONMENT:?Select dev, staging, or prod}"
  case "$ENVIRONMENT" in dev|staging|prod) ;; *) exit 1 ;; esac
  export AWS_PROFILE="${AWS_PROFILE:?Set the workload profile}"
  export AWS_REGION="${AWS_REGION:?Set the service Region}"
  export EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the workload account ID}"
  ENV_DIR="environments/${ENVIRONMENT}"
  terraform fmt -check -recursive
  terraform -chdir="$ENV_DIR" validate
  ./scripts/validation/validate-compute.sh "$ENVIRONMENT"
  ./scripts/validation/validate-ecs-runtime.sh "$ENVIRONMENT"
)
```

`${VAR:?message}` stops the command when a required local value is unset or
empty; it does not certify that the value is correct. These validators inspect
selected live compute and ECS network relationships. Run networking and endpoint
validation separately for topology and private connectivity; no single rule ID
or SG listing proves the whole path. A Terraform plan, when needed, is a
separate operation with the deployed input set and is not executed above.

### Confirm Compute HTTPS Egress

```bash
aws ec2 describe-security-groups \
  --region "${AWS_REGION:?Set the service Region}" \
  --profile "${AWS_PROFILE:?Set the workload profile}" \
  --group-ids "${COMPUTE_SG_ID:?Select the Terraform-owned compute SG}" \
  --query 'SecurityGroups[0].IpPermissionsEgress' \
  --output json
```

For `nat_only` and `network_firewall`, expect a rule equivalent to:

```text
TCP 443 -> 0.0.0.0/0
```

For `vpc_endpoints_only`, the general `0.0.0.0/0` HTTPS rule should be absent.

### Confirm Terraform Readiness Output

`compute_sg_rule_ids` and `ecs_sg_rule_ids` are child-module outputs in
[outputs.tf](outputs.tf), not public outputs of the shipped workload roots.
Do not expect `terraform output compute_sg_rule_ids` to work from an environment.

Inspect the stored compute readiness object and an unconditional rule instead:

```bash
terraform -chdir="environments/${ENVIRONMENT:?Select dev, staging, or prod}" state show \
  'module.baseline.module.compute.terraform_data.compute_security_policy_ready'

terraform -chdir="environments/${ENVIRONMENT:?Select dev, staging, or prod}" state show \
  'module.baseline.module.security_policy.aws_security_group_rule.compute_egress_to_endpoints'
```

The sibling `security_policy` module is called by `baseline`; it is not nested
inside `module.networking`. The conditional internet rule has address
`module.baseline.module.security_policy.aws_security_group_rule.compute_egress_to_internet_https[0]`
only when created. State inspection reports stored Terraform values, not a fresh
AWS packet-path test. Adapt parent prefixes only for a deliberately different
caller composition.

---

## Security Notes

- This module should not create broad inbound access.
- Interface Endpoint ingress is granted from the supplied compute, Lambda,
  quarantine, and ECS groups. This is SG-based access, not an API allowlist.
- Data ingress is granted from compute and explicitly opted-in ECS task groups
  on `db_port`; the module does not grant database credentials or establish TLS.
- In the integrated baseline, resolved egress mode controls general compute
  TCP/443 egress. This child module does not itself reject unsupported mode strings.
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

- Compose this module with the referenced SG-owning modules through resource
  references; do not separately apply child modules or add cyclic whole-module
  dependencies to simulate the resource-level readiness graph.
- Security groups are created by other modules; this module attaches rules to
  them.
- The baseline passes `compute_sg_rule_ids` directly from this module into
  `compute` to delay EC2 instance creation until required rules exist.
- The baseline passes normalized `ecs_sg_rule_ids` to `ecs_service` to delay
  task launch until the applicable rules exist.
- Keep the output and compute input attribute name `compute_egress_to_internet_https` consistent.

See [main.tf](main.tf), [variables.tf](variables.tf), [outputs.tf](outputs.tf),
and the [baseline composition](../../../baseline/main.tf) for the maintained
implementation contract.
