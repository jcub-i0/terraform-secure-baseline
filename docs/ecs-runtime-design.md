# ECS/Fargate Application Runtime Design

## Status and purpose

This document defines the approved architecture direction for adding generic,
secure ECS/Fargate application-runtime support in `terraform-secure-baseline`
v1.8.0. It is an architecture and interface contract, not an implementation
specification. The proposed interfaces remain subject to refinement during
implementation as long as the security, ownership, and deployment invariants in
this document are preserved.

The project is a generic secure AWS platform and workload baseline for
small-to-mid-size SaaS companies handling PII or other sensitive data. It is not
an application-specific deployment. ReconoSense is only a private reference
workload used to pressure-test this design. Reusable modules, inputs, outputs,
resource names, ports, domains, sidecars, and release logic must remain
application-neutral.

This document uses the following labels:

- **CURRENT REPOSITORY FACT** describes behavior already present in the
  repository. These statements cite exact repository paths and relevant
  Terraform or script symbols.
- **APPROVED V1.8.0 DESIGN** records an architectural decision for the initial
  ECS/Fargate implementation.
- **DEFERRED/FUTURE** identifies work intentionally outside the initial
  long-running service substrate. Deferred work is not a blocker unless a later
  implementation milestone explicitly depends on it.
- **EXISTING HARDENING ITEM** records non-ECS production-hardening work found
  during architecture review. ECS must not be redesigned around these items.

No ECS, ECR, ALB, IAM, networking, automation, validation, or workflow resources
are created by this document.

## Architectural position

**CURRENT REPOSITORY FACT:** The workload baseline is composed in
`baseline/main.tf`. Its sibling module calls currently include
`module.networking`, `module.security_policy`, `module.compute`,
`module.storage`, `module.iam`, `module.security`, `module.automation`,
`module.vpc_endpoints`, `module.firewall`, and `module.ecr`. Each environment
root delegates to that composition through `module.baseline`; for example,
`environments/dev/main.tf` declares `module "baseline"` with source
`../../baseline`.

**CURRENT REPOSITORY FACT:** `modules/compute` is an EC2 module. It creates
`aws_security_group.compute`, `aws_security_group.quarantine`, and
`aws_instance.ec2` in `modules/compute/main.tf`. It receives
`compute_private_subnet_ids_map` and an EC2 instance profile in
`modules/compute/variables.tf`.

**APPROVED V1.8.0 DESIGN:** EC2 remains a supported workload pattern.
`modules/compute` remains EC2-only and is not converted into an EC2/ECS
polymorphic module.

**APPROVED V1.8.0 DESIGN:** ECS/Fargate is the preferred application-runtime
pattern for modern SaaS workloads. It is added as a sibling capability beneath
the existing baseline composition. The conceptual cardinality is:

```text
environment
├── existing EC2 capability, when used
├── one ECS cluster
├── one shared Application Load Balancer, when ingress is enabled
├── N ECR repositories
└── N ECS services
```

The initial new module boundaries are exactly:

```text
modules/ecr
modules/ecs_cluster
modules/application_load_balancer
modules/ecs_service
```

The baseline will instantiate repositories and services from stable maps using
Terraform `for_each`. Stable caller-selected keys, rather than list positions or
derived image names, form the resource addressing contract.

## Target architecture

```text
                                      Internet clients
                                             |
                                      HTTPS listener
                                             |
public subnets                    one environment-level ALB
                                      |       |       |
                               target group  target group ...
                                      |       |
compute_private subnets       ECS service  ECS service ...       EC2 remains supported
                                  |   |          |
                                  |   +----------+---- Interface endpoints
                                  |                    in endpoint_private
                                  |
                                  +-------------------- RDS
                                                       in data_private

compute_private default egress
  -> Network Firewall endpoint in firewall_private -> NAT -> Internet
  -> NAT directly when egress_mode = nat_only
  -> no default route when egress_mode = vpc_endpoints_only

serverless_private
  -> workload-local security and containment Lambda functions
```

The new runtime consumes the existing network, security, IAM, storage,
monitoring, and automation ownership domains. It does not establish a parallel
central security architecture.

## Subnet model

**CURRENT REPOSITORY FACT:** `modules/networking/main.tf` creates six subnet
classes through `aws_subnet.public`, `aws_subnet.compute_private`,
`aws_subnet.data_private`, `aws_subnet.serverless_private`,
`aws_subnet.firewall_private`, and `aws_subnet.endpoint_private`.
`modules/networking/outputs.tf` exposes map and list outputs for all six classes.

**CURRENT REPOSITORY FACT:** RDS uses the data subnets through
`aws_db_subnet_group.data` in `modules/storage/main.tf`. VPC-attached isolation
and rollback Lambdas receive `serverless_private_subnet_ids` in
`modules/automation/main.tf`. Interface endpoints use
`endpoint_private_subnet_ids_map` in `modules/vpc_endpoints/main.tf`. Network
Firewall receives `firewall_private_subnet_ids_map` from `baseline/main.tf`.

**CURRENT REPOSITORY FACT:** Only compute-private route tables receive a
mode-dependent default workload egress route:
`aws_route.compute_default_to_firewall` for `network_firewall`,
`aws_route.compute_default_to_nat` for `nat_only`, and no default route for
`vpc_endpoints_only`, all in `modules/networking/main.tf`.

**APPROVED V1.8.0 DESIGN:** No new application subnet class is introduced in
v1.8.0. Subnet roles remain:

| Subnet class | Runtime role |
| --- | --- |
| `public` | Internet-facing environment ALB |
| `compute_private` | EC2 and ECS/Fargate application compute |
| `data_private` | RDS |
| `serverless_private` | VPC-attached security and automation Lambda functions |
| `endpoint_private` | Interface VPC Endpoints |
| `firewall_private` | AWS Network Firewall |

Fargate task ENIs use `compute_private` subnets and must set
`assign_public_ip = false`. Public-IP assignment is a platform invariant, not a
service-level option.

## New module responsibilities

### `modules/ecr`

**CURRENT REPOSITORY FACT — owns:**

- Private ECR repositories created by `aws_ecr_repository.repositories`.
- Repository encryption configuration.
- Tag immutability.
- The 30-day untagged-image lifecycle policy created by
  `aws_ecr_lifecycle_policy.untagged_cleanup`.
- Repository tags and resource-backed metadata outputs.

**CURRENT REPOSITORY FACT — explicitly does not own:**

- Application source, Docker builds, tests, image publishing, or digest
  promotion.
- ECS clusters, task definitions, or services.
- Account-level Amazon Inspector enablement or ownership.
- Selection of the image digest deployed by an ECS service.
- KMS key creation, repository resource policies, or repository/registry
  scanning configuration.

`modules/ecr/variables.tf` defines `name_prefix`, `environment`, the required
customer-managed key ARN `kms_key_arn`, and `repositories` as
`map(object({}))` with default `{}`. Repository map keys are the repository-name
component and the stable Terraform `for_each` identity; there is no separate
`name_suffix` field. For example, key `application` renders
`${var.name_prefix}-application`.

`modules/ecr/outputs.tf` exports one `repositories` map keyed by the same
repository names. Each resource-backed entry contains `arn`, `name`,
`repository_url`, and `registry_id`. It does not resolve or output an image tag
or digest.

All repositories use `image_tag_mutability = "IMMUTABLE"` and KMS encryption
with the actual CMK ARN supplied by `module.security.ecr_cmk_arn`; the ECR alias
ARN is not used for repository encryption. `modules/security/main.tf` owns the
dedicated `aws_kms_key.ecr` and `aws_kms_alias.ecr` resources.

The current ephemeral development/test posture sets
`force_delete = true # CHANGE THIS IN PROD` and does not configure
`prevent_destroy`. This permits routine environment teardown even when a
repository contains development images. Persistent production use must
reconsider that destruction behavior.

The lifecycle policy expires only untagged images older than 30 days and never
matches tagged release images. Any digest that is active or remains deployable
by Terraform must retain at least one immutable release tag; release automation
must not remove the final such tag. Lifecycle cleanup is independent of
`force_delete` and is not a prerequisite for `terraform destroy`. More
sophisticated historical release retention remains deferred.

`baseline/main.tf` instantiates `module.ecr` and supplies the security-owned key
ARN, but it does not pass `repositories`. The `{}` default therefore creates no
repositories, and the environment roots do not yet expose repository
configuration or repository metadata outputs.

### `modules/ecs_cluster`

**APPROVED V1.8.0 DESIGN — owns:**

- The environment ECS cluster.
- Fargate capacity-provider association and environment-level capacity-provider
  defaults.
- Cluster-level monitoring settings, including the selected Container Insights
  posture.
- Cluster tags and identifiers.
- The cluster-level ECS Exec state, initially disabled.

**APPROVED V1.8.0 DESIGN — explicitly does not own:**

- ECR repositories.
- ALBs, listeners, target groups, or listener rules.
- ECS task definitions or services.
- Service execution roles or task roles.
- Cross-component security-group rules.
- Central GuardDuty organization settings.

Key inputs are expected to include `name_prefix`, `environment`, monitoring
settings, capacity-provider defaults, and an explicit ECS Exec setting whose
initial value is disabled.

Key outputs are expected to include cluster ARN, cluster name, cluster ID, and
effective capacity-provider information.

Dependencies are limited to platform naming/tagging and any cluster-level
logging configuration. The cluster must not depend on individual services.

Expected lifecycle/cardinality is exactly one cluster per environment. It is a
long-lived environment resource and must not be replaced as part of a routine
application image release.

### `modules/application_load_balancer`

**APPROVED V1.8.0 DESIGN — owns:**

- One environment-level Application Load Balancer when ingress is enabled.
- The ALB security-group object, but not cross-component rules.
- HTTPS listener configuration using a caller-supplied ACM certificate ARN.
- Target groups and deterministic listener rules for ingress-enabled ECS
  services.
- A fail-closed fixed-response default action on the shared HTTPS listener.
- Health-check configuration supplied through the generic service contract.
- ALB access, connection, and health-check logging configuration and
  service-level operational attributes.
- An optional association point for a caller-supplied WAF web ACL ARN.

**APPROVED V1.8.0 DESIGN — explicitly does not own:**

- ACM certificate creation or validation.
- Route53 zones, records, or domain ownership.
- First-class WAF policy/rule ownership.
- ECS services, task definitions, or task security groups.
- Application ports or routing rules that are not declared through the generic
  service interface.

Key inputs are expected to include VPC ID, public subnet IDs, certificate ARN,
TLS policy, vended-log destination/configuration, optional WAF ARN, and a stable
map of ingress declarations containing listener priority, conditions, explicit
allowed client CIDRs, target port, protocol, and health checks.

Key outputs are expected to include ALB ARN, ARN suffix, DNS name, hosted zone
ID, listener ARN, ALB security-group ID, and target-group ARNs by stable service
key.

Dependencies are networking public subnets, logging/storage integration, and
the ingress portions of the stable service map. The ECS service consumes its
target-group ARN; the ALB module must not depend on a running ECS service.

Expected lifecycle/cardinality is zero or one shared ALB per environment and
zero or one target group/listener rule per ingress-enabled service. Per-service
ALBs are deferred.

The preferred logging direction is Application Load Balancer vended log
delivery to CloudWatch Logs for access, connection, and health-check logs. This
aligns with the repository's existing CloudWatch/logging architecture. The
design must not assume that the existing centralized S3 log bucket is compatible
with legacy ALB access-log delivery. Exact Terraform resources and support in
the repository's pinned AWS provider/configuration must be verified during
implementation before code is written; the relevant constraints and selections
are in `environments/*/providers.tf` and `.terraform.lock.hcl`. If vended
CloudWatch delivery is not supported there, implementation must design a
dedicated compatible logging destination instead of weakening the
centralized-log bucket policy.

### `modules/ecs_service`

**APPROVED V1.8.0 DESIGN — owns:**

- One long-running ECS service.
- Its Fargate task definition and generic multi-container definition.
- Its task security-group object, but not cross-component rules.
- Service/container CloudWatch log groups.
- Service deployment controls and rollback/circuit-breaker settings.
- Service autoscaling resources when configured.
- Service and task-definition tags, including explicit automatic-containment
  authorization.
- Attachment of an ingress-enabled service to the target group supplied by the
  shared ALB module.
- A readiness checkpoint proving required security-policy rules exist before
  tasks are launched.

**APPROVED V1.8.0 DESIGN — explicitly does not own:**

- The ECS cluster.
- ECR repositories or image publication.
- The shared ALB, listeners, target groups, listener rules, or certificate.
- IAM role resources; their ARNs are supplied by `modules/iam`.
- The RDS instance, database users, schema migrations, or credential rotation.
- Cross-component security-group rules.
- Arbitrary internet egress approval.
- Scheduled or run-to-completion tasks.

Key inputs are expected to include cluster ARN/name, compute-private subnet IDs,
task execution-role ARN, task-role ARN, task and container definitions,
digest-pinned container image URIs, CPU/memory/runtime platform and Fargate
platform version, desired count,
optional target-group ARN, application/database/endpoint access declarations, deployment
controls, autoscaling configuration, containment authorization, and a typed map
of required security-policy rule IDs.

Key outputs are expected to include service ARN/name, task-definition ARN and
family, task security-group ID, log-group names/ARNs, effective runtime platform,
and autoscaling target identifiers. Role ARNs may be repeated as convenience
outputs but remain owned by `modules/iam`.

Dependencies are the cluster, ECR image availability, IAM roles,
compute-private subnets, optional target group, and security-policy readiness
object. The module must not launch a service until required rule IDs are known.

Expected lifecycle/cardinality is one module instance per stable `ecs_services`
map key. Task-definition revisions are expected as immutable image digests or
runtime settings change. Routine revisions must not replace the cluster or
shared ALB.

## Extensions to existing ownership domains

### `baseline/`

**CURRENT REPOSITORY FACT:** `baseline/main.tf` is the integration layer that
wires networking, policy, compute, storage, IAM, security, automation,
monitoring, endpoints, firewall, and ECR resources into sibling modules. It
already instantiates `module.ecr` with `module.security.ecr_cmk_arn`, propagates
the RDS consumer outputs, and passes the effective firewall domain set. It does
not yet pass repository definitions or ECS IAM service definitions.

**APPROVED V1.8.0 DESIGN:** The baseline will:

- Accept the remaining environment ECS runtime configuration, repository map,
  and stable `ecs_services` map.
- Instantiate one `modules/ecs_cluster`.
- Pass N repository definitions to the existing `module.ecr` call.
- Instantiate zero or one `modules/application_load_balancer` based on whether
  ingress is enabled.
- Instantiate `modules/ecs_service` with `for_each` over stable enabled service
  keys.
- Pass task and ALB SG IDs to `modules/networking/security_policy` and feed
  resulting rule IDs back to each ECS service readiness input.
- Export non-secret cluster, repository, ALB, and service metadata needed by
  operators and validation; the approved RDS consumer metadata is already
  propagated.

ECS infrastructure remains in the existing workload environment Terraform
state; no additional environment state or validation layer is introduced.

### `environments/*`

**CURRENT REPOSITORY FACT:** `environments/dev/main.tf`,
`environments/staging/main.tf`, and `environments/prod/main.tf` are thin roots
that pass environment variables to `module.baseline`. Their backends are
environment-specific; for example, `environments/dev/backend.tf` uses the
`baseline/dev.tfstate` S3 object key with native lockfiles.

**APPROVED V1.8.0 DESIGN:** Each environment root will expose and pass through
the same typed generic runtime inputs. Environment roots are where approved
service maps, selected digests, certificate ARN, and environment-level egress
domain allowlists become visible in the reviewed plan. They must not acquire
application-specific variable names.

### `modules/networking/security_policy`

**CURRENT REPOSITORY FACT:** Resource-owning modules create SG objects while
`modules/networking/security_policy/main.tf` owns cross-component
`aws_security_group_rule` resources. Existing examples include
`endpoints_ingress_from_compute`, `compute_egress_to_endpoints`,
`compute_egress_to_db`, and `db_ingress_from_compute`.

**CURRENT REPOSITORY FACT:** EC2 launch readiness is represented by
`aws_security_group_rule` IDs returned from
`modules/networking/security_policy/outputs.tf` as `compute_sg_rule_ids`.
`modules/compute/main.tf` places those IDs into
`terraform_data.compute_security_policy_ready`, and `aws_instance.ec2` depends
on that checkpoint.

**APPROVED V1.8.0 DESIGN:** The security-policy module remains authoritative for
these ECS-related relationships:

```text
approved client CIDR       -> ALB SG       : listener port
ALB SG                     -> task SG      : declared application port
task SG                    -> data SG      : declared database port
data SG                    <- task SG      : declared database port
task SG                    -> endpoint SG  : TCP/443
endpoint SG                <- task SG      : TCP/443
task SG                    -> S3 prefix list : TCP/443
task SG                    -> approved application destinations only
explicit service task SG   -> task SG      : explicitly declared service port
```

The ALB module creates the ALB SG object. Each ECS service module creates its
task SG object. The existing EC2 compute SG must never be attached to ECS tasks.

The policy module will return rule IDs grouped by stable service key. Each ECS
service will place its object into a readiness checkpoint and depend on it before
service creation, matching the current EC2 pattern.

The S3 rule targets the AWS-managed S3 prefix list and is required independently
of the task-to-Interface-Endpoint-SG relationship. The `ecr.api` and `ecr.dkr`
services use Interface Endpoints, while ECR image layers are retrieved through
the existing S3 Gateway Endpoint. Restrictive task SGs therefore require
TCP/443 egress to the S3 managed prefix list. The same path supports the future
GuardDuty Fargate managed-agent image path. It is not part of, and must not be
conflated with, the EC2 quarantine or evidence workflows.

### `modules/vpc_endpoints`

**CURRENT REPOSITORY FACT:** `local.interface_endpoints` in
`modules/vpc_endpoints/main.tf` currently includes private endpoints for AWS
services such as STS, CloudWatch Logs, SSM, Secrets Manager, KMS, SNS, SQS,
EventBridge, Security Hub, Lambda, `ecr.api`, `ecr.dkr`, and
`guardduty-data`. The module also creates `aws_vpc_endpoint.s3`, and
`baseline/main.tf` attaches that S3 gateway endpoint to endpoint, compute, and
serverless route tables. The ECR API and registry paths therefore use Interface
Endpoints, while image layers use the existing S3 Gateway Endpoint.

**APPROVED V1.8.0 DESIGN:** The endpoint SG will receive
TCP/443 ingress from authorized ECS task SGs through the security-policy module.
ECR image layers continue to use the S3 Gateway Endpoint, with task SG egress to
the AWS-managed S3 prefix list controlled by the security-policy module.
Supported AWS service traffic should use VPC endpoints instead of general
internet egress wherever practical.

Amazon ECS control-plane endpoints are not part of the initial mandatory
Fargate endpoint set. They may be added later if an identified private API path
requires them.

### `modules/iam`

**CURRENT REPOSITORY FACT:** `modules/iam` owns role trust policies, IAM roles,
policies, attachments, and profiles. For example, `modules/iam/ec2.tf` owns
`aws_iam_role.ec2_role` and `aws_iam_instance_profile.ec2_profile`, while
`modules/iam/lambda.tf` owns the automation Lambda roles. Consumer modules
receive profile names or role ARNs through `baseline/main.tf`.

**CURRENT REPOSITORY FACT:** `modules/iam/ecs.tf` defines separate role pairs
per key in `var.ecs_iam_services` through
`aws_iam_role.ecs_task_execution_roles` and
`aws_iam_role.ecs_task_roles`. Both use
`data.aws_iam_policy_document.ecs_tasks_assume_role`, which trusts
`ecs-tasks.amazonaws.com` with source-account and regional ECS source-ARN
conditions.

The custom inline execution policy currently permits ECR authorization,
repository-scoped ECR image-pull actions, and log-group-scoped CloudWatch Logs
stream creation and writes. It does not attach
`AmazonECSTaskExecutionRolePolicy`, grant `iam:PassRole`, or grant direct access
to the ECR encryption CMK. The application task role is created without an
application policy and therefore initially carries no broad runtime authority.

`modules/iam/variables.tf` defines `ecs_iam_services` with required
`ecr_repository_arns` and `log_group_arns` sets plus optional execution secret,
SSM parameter, and KMS ARN sets. The optional sets are not yet consumed by
`modules/iam/ecs.tf` and grant no permissions. The intended SSM field name is
`execution_ssm_parameter_arns`; the current variable declaration contains a
spelling defect that must be corrected before caller wiring. The map defaults
to `{}`, and `baseline/main.tf` does not currently pass it, so no ECS role pair
is created by the workload roots yet. `modules/iam/outputs.tf` exposes
`ecs_task_execution_roles` and `ecs_task_roles` maps containing each role's ARN
and name.

**APPROVED V1.8.0 DESIGN:** The task role must not inherit image-pull or
task-definition secret permissions merely because the execution role has them.
Only explicitly approved application capabilities may be added to it.

The primary generic interface must not accept unrestricted arbitrary IAM policy
JSON. Typed capabilities identify allowed actions and exact resource ARNs.
Narrowly controlled escape hatches, if ever necessary, require separate design
and validation.

`modules/iam` will also own the future ECS containment Lambda role. Its
permissions must be limited to describing eligible ECS resources, reading tags,
capturing evidence, stopping an eligible task, publishing to the existing SecOps
topic, writing logs, and using the existing failure destination.

### `modules/storage`

**CURRENT REPOSITORY FACT:** `modules/storage/main.tf` owns
`aws_db_instance.main`, `aws_db_subnet_group.data`, `aws_security_group.data`,
and `aws_secretsmanager_secret.rds_master`. The secret value is written using a
write-only secret version and is not exported. `modules/storage/outputs.tf`,
`baseline/outputs.tf`, and each environment `outputs.tf` now export the
approved non-secret consumer metadata:

- RDS address.
- RDS endpoint.
- Port.
- Database name.
- Master username.
- Master secret ARN.
- Data security-group ID.

These outputs expose no password, secret value, or rendered connection string
containing credentials.

The generic runtime may consume arbitrary, explicitly approved Secrets Manager
references. Merely declaring database network access does not grant the task
role access to the RDS master secret. If a caller deliberately references a
credential secret in a task definition, the exact ARN is reviewed in the plan
and only the execution role receives the retrieval permission required for
injection. Application database-user creation and credential rotation are not
owned by the initial ECS runtime.

### `modules/firewall`

**CURRENT REPOSITORY FACT:** Each environment exposes
`allowed_egress_domains` and passes it to the baseline. `baseline/locals.tf`
keeps the Ubuntu platform domains in
`local.platform_required_egress_domains` and computes
`local.effective_allowed_egress_domains` as their union with the approved
environment set only when the effective mode is `network_firewall`; otherwise
the effective set is empty. `baseline/main.tf` passes that final set to
`modules/firewall`, whose `aws_networkfirewall_rule_group.stateful_domains`
uses it directly. `baseline/outputs.tf` and the environment roots expose the
resource-backed `effective_allowed_egress_domains` set when the firewall exists
and an empty set otherwise. `vpc_endpoints_only` remains fail closed.

Services declare which environment-approved egress sets they require. The
domain values themselves are approved at the environment boundary so they are
visible together in the saved Terraform plan. Supported AWS API traffic should
prefer VPC endpoints.

`vpc_endpoints_only` remains fail closed. A service requiring arbitrary internet
access is incompatible with that mode unless the dependency is reachable through
approved private connectivity. Validation of the Terraform input must reject an
incompatible declaration rather than silently create a route or broad SG rule.

### `modules/security`

**CURRENT REPOSITORY FACT:** Amazon Inspector ownership is in
`modules/security`. `aws_inspector2_enabler.main` in
`modules/security/main.tf` receives `inspector_resource_types`, whose accepted
values in `baseline/variables.tf` include `ECR`; the current default is `EC2`.
The same module now owns `aws_kms_key.ecr` and `aws_kms_alias.ecr`, and exports
their ARNs through `ecr_cmk_arn` and `ecr_cmk_alias_arn`.

**APPROVED V1.8.0 DESIGN:** Inspector ownership remains in `modules/security`.
`modules/ecr` must not enable or separately own account-level Inspector. When
ECR is enabled, the effective intended ECR scan posture must be expressed through
the existing Inspector interface and proven by workload validation.

The AWS Config recorder and managed-rule catalog may be extended with relevant
ECS, ECR, and ELB resource types and controls during implementation, but that
work remains under the existing `modules/security/config_baseline` ownership
boundary.

### `modules/automation`

**CURRENT REPOSITORY FACT:** Workload-local response automation is owned by
`modules/automation`. It currently owns EC2 isolation and rollback Lambda
functions, EventBridge rules and targets, DLQs, log groups, alarms, and the
workload-local SecOps event bus in `modules/automation/main.tf`. The central
security-services boundary explicitly excludes workload-local remediation and
Lambda response logic in
`bootstrap/security_operations/security_services/README.md`.

**APPROVED V1.8.0 DESIGN:** ECS task containment remains workload-local in
`modules/automation`. It is implemented as a distinct ECS containment path, not
as polymorphic EC2/ECS behavior inside the existing EC2 Lambda.

The initial automatic containment scope is task level only:

```text
GuardDuty/Security Hub finding
  -> workload EventBridge rule
  -> ECS containment Lambda
  -> strict eligibility and authorization checks
  -> capture evidence durably
  -> ecs:StopTask
  -> ECS service restores desired count
  -> notify SecOps
```

Automatic containment must:

- Fail closed on missing, malformed, ambiguous, unauthorized, or unsupported
  finding/resource data.
- Act automatically only for `CRITICAL` findings.
- Require explicit workload/service authorization before containment.
- Resolve the finding to exactly one running task in the expected account,
  Region, cluster, and service.
- Reject standalone tasks in the initial service-only runtime unless separately
  authorized by a future design.
- Treat duplicate or already-handled findings idempotently and avoid repeated
  containment actions.
- Capture required evidence successfully before calling `ecs:StopTask`.
- Re-read task state immediately before the stop operation.
- Publish success/failure information to the existing workload SecOps path and
  retain EventBridge/Lambda failure handling.

Minimum pre-stop evidence is:

- Complete finding payload.
- Finding ID, type, and severity.
- Cluster ARN.
- Service ARN and name.
- Task ARN.
- Task-definition ARN.
- Container names.
- Image URI and image digest.
- Task-role ARN.
- Execution-role ARN.
- ENI and private IP.
- Task and service tags.
- Service network configuration.
- Containment timestamp and intended action.

The complete finding and resolved task context should be written to a durable,
encrypted workload-local evidence location under a deterministic finding/task
key before the stop call. Idempotency must account for a failure between evidence
capture and task stop: on retry, the function must inspect both the durable
record and live task state rather than treating evidence existence alone as proof
that containment completed. The final evidence store and conditional-write
mechanism may be refined during implementation, but these ordering and retry
semantics are mandatory.

Initial automatic containment must not suspend autoscaling, replace the service
SG, force a quarantine deployment, scale the service to zero, or shut down the
entire service. ECS service desired count restores capacity in the ordinary ECS
control loop. Whole-service containment remains a manual, controlled SecOps
operation.

### `scripts/validation`

**CURRENT REPOSITORY FACT:** `scripts/validation/validate-baseline.sh` now
orchestrates 15 workload validators through its `VALIDATION_SCRIPTS` array.
`scripts/validation/export-baseline.sh` mirrors those scripts to produce
workload-baseline evidence. `validate-ecr.sh` uses `ecr_repositories` as its
authoritative inventory and passes cleanly for `{}`. For configured
repositories it validates identity, immutability, KMS encryption presence, and
the exact untagged-only lifecycle policy. `validate-vpc-endpoints.sh` validates
the canonical endpoint inventory, private DNS, exact endpoint-private subnet
and SG placement, and exact S3 route-table coverage.

`validate-security-workload.sh` reads `effective_inspector_resource_types` and
performs an exact comparison with live Inspector resource states. It does not
reconstruct the repository-to-ECR composition rule. The current baseline and
environment output expressions expose the raw Inspector input instead of
`local.effective_inspector_resource_types`; automatic ECR inclusion therefore
cannot be proven from the workload-root contract until that Terraform defect is
corrected.

**APPROVED V1.8.0 DESIGN:** ECS, ECR, and ALB validation extend the existing
workload baseline validation layer. No fifth validation layer is created. The
current validator count is not a permanent contract.

Future runtime validators include `validate-ecs.sh` and `validate-alb.sh`.
Their exact split may be refined, but together the workload layer must prove at
least:

- Expected repositories exist with intended encryption, immutability, policy,
  safe digest retention lifecycle, and Inspector ECR posture.
- The ECS cluster has intended Fargate, monitoring, tag, and ECS Exec settings.
- Task definitions use Fargate-compatible `awsvpc` networking, explicit runtime
  OS/architecture and platform version, digest-pinned images, separate role
  ARNs, declared resources, log configuration, and hardened container settings.
- Services use compute-private subnets with public IP assignment disabled.
- ALB, listener, listener rules, target groups, TLS certificate, health checks,
  and SG relationships match Terraform intent. Validation must prove that
  Fargate/`awsvpc` target groups use `target_type = "ip"`, the listener default
  is the intended fixed response, and every forwarding rule has a meaningful
  routing condition. It must also prove the selected ALB log-delivery
  configuration and destination.
- ECS Interface Endpoint, S3 Gateway Endpoint, database, and external egress
  paths match declarations, including both directions of the task-SG/endpoint-SG
  TCP/443 relationship and task-SG TCP/443 egress to the AWS-managed S3 prefix
  list.
- Deployment circuit-breaker and autoscaling bounds match intent.
- Automatic-containment authorization and supporting workload-local resources
  exist without implying service-wide automatic containment.

The validators must remain read-only and query live AWS state, following the
purpose documented in `scripts/validation/README.md` and the existing evidence
export pattern.

## Security-group and launch-readiness contract

**APPROVED V1.8.0 DESIGN:** Security-group object and rule ownership is split
deliberately:

| Concern | Owner |
| --- | --- |
| ALB SG object | `modules/application_load_balancer` |
| ECS task SG object | `modules/ecs_service` |
| RDS/data SG object | `modules/storage` |
| Interface endpoint SG object | `modules/vpc_endpoints` |
| Cross-component ingress/egress rules | `modules/networking/security_policy` |

This mirrors current repository ownership rather than placing rules in whichever
module happens to consume them.

The baseline passes SG IDs into `security_policy`. Policy returns an object keyed
by stable service key, conceptually:

```hcl
ecs_service_sg_rule_ids = {
  service_key = {
    alb_ingress_to_task          = optional(string)
    task_egress_to_database      = optional(string)
    database_ingress_from_task   = optional(string)
    task_egress_to_endpoints     = string
    endpoints_ingress_from_task  = string
    task_egress_to_s3            = string
    approved_external_egress     = optional(list(string), [])
    approved_service_connections = optional(list(string), [])
  }
}
```

The ECS service module converts its rule-ID object into a readiness resource and
makes service creation depend on it. This prevents initial task launch from
racing the policy resources. It is a dependency mechanism, not a network-health
probe; live validation remains responsible for verifying effective deployed
state.

The task-to-S3 rule is a separate mandatory readiness input from the
task-to-Interface-Endpoint-SG and endpoint-SG-to-task relationships. It permits
TCP/443 to the AWS-managed S3 prefix list so the route can use the existing S3
Gateway Endpoint for ECR image layers and, later, the GuardDuty Fargate
managed-agent image path. It is unrelated to EC2 quarantine/evidence traffic.

The SG -> `security_policy` -> readiness -> ECS service dependency is
resource-granular. Implementations must not introduce mutually dependent
module-level `depends_on` relationships. In particular, the ECS task SG must be
creatable without consuming its own downstream security-policy readiness
output. Only the ECS service/task-launch resources depend on the completed
readiness checkpoint.

## Ingress design

**APPROVED V1.8.0 DESIGN:** Initial ingress uses one environment-level,
internet-facing ALB in public subnets. It accepts one ACM certificate ARN. The
shared HTTPS listener routes to multiple ECS services through separate target
groups and deterministic listener rules. Fargate/`awsvpc` target groups must use
`target_type = "ip"`.

The HTTPS listener default action is a fail-closed fixed response, such as HTTP
404. A service is reachable only through an explicit forwarding listener rule;
no service may silently become a catch-all or default forwarding target. Every
forwarding rule must contain at least one meaningful routing condition, such as
host, path, or a source-IP restriction that actually narrows the match.

Each ingress-enabled service declares its target container, target port,
listener-rule priority, routing conditions, explicit `allowed_client_cidrs`, and
health check. Listener-rule priorities must be unique within the environment and
should be explicitly provided or deterministically derived from stable keys with
collision checks.

Because the ALB and its SG are shared at environment level, ALB SG ingress is the
union of client CIDRs required by all ingress-enabled services. The shared SG
alone does not provide per-service source isolation. When a service declares a
narrower `allowed_client_cidrs` set, its listener rule must additionally enforce
that set with an ALB `source-ip` condition. A public service may explicitly
declare `0.0.0.0/0`; public access must never arise from a hidden default. A
`0.0.0.0/0` source-IP condition alone is not a meaningful routing condition, so
such a rule must also constrain its host or path.

Route53/domain ownership is outside initial scope. The ALB exposes DNS and zone
outputs so a separately owned DNS layer can create records. An optional WAF ARN
association point is allowed, but advanced WAF ownership is not required.

Services without ingress do not receive a target group or ALB-to-task rule.
Direct public task access is prohibited.

## Image integrity and exact saved-plan deployment

**CURRENT REPOSITORY FACT:** `.github/workflows/terraform-apply.yml` implements
the authoritative deployment sequence. The plan job runs Terraform with
`-out="${PLAN_FILE}"`, records plan metadata, creates a SHA-256 checksum, and
uploads the artifact. The apply job downloads the artifact, validates checksum
and metadata in `Verify saved Terraform plan`, and passes that exact binary plan
to `terraform apply` in `Apply reviewed Terraform plan`.

**APPROVED V1.8.0 DESIGN:** Every Terraform-managed ECS container image
reference must be digest pinned:

```text
repository/image@sha256:<digest>
```

Mutable tags and apply-time resolution of `latest` or another moving tag are
prohibited. The selected digest must be present in the reviewed saved Terraform
plan. The task definition therefore changes only when a caller supplies a new
reviewed digest or another reviewed runtime setting changes.

Repository lifecycle policy must preserve any digest that an active
Terraform-managed task definition or service can still reference. Initial
cleanup targets untagged and non-release build artifacts; immutable
release-tagged deployment images remain retained while they can be referenced.

ECS infrastructure stays in the existing workload environment Terraform state
and follows the existing sequence:

```text
Terraform Plan
  -> saved binary plan
  -> metadata and checksum
  -> review/approval
  -> exact saved-plan Apply
```

The initial repository/bootstrap sequence may require two exact-plan operations:

1. Create ECR repository and shared runtime infrastructure while a service is
   disabled.
2. Build, test, and publish an image outside Terraform; choose its immutable
   digest; then review and apply a plan enabling or revising the service with
   that digest.

No apply-time provisioner, local script, or imperative post-plan task-definition
registration may substitute a different image.

## Proposed generic service interface

**APPROVED V1.8.0 DESIGN — PROPOSED, NON-FINAL SCHEMA:** The following
baseline-level schema demonstrates the intended contract. Field names and exact
Terraform types may be refined during implementation, but it must remain
application-neutral and preserve the invariants described above.

```hcl
variable "ecs_services" {
  description = "Generic long-running ECS/Fargate services keyed by stable environment-local identifiers."

  type = map(object({
    enabled = optional(bool, true)

    cpu    = number
    memory = number

    runtime_platform = object({
      operating_system_family = string
      cpu_architecture        = string
      platform_version        = optional(string, "1.4.0")
    })

    desired_count = number

    containers = list(object({
      name      = string
      essential = optional(bool, true)
      sidecar   = optional(bool, false)

      image_uri = string # Required repository/image@sha256:<digest>

      command    = optional(list(string))
      entrypoint = optional(list(string))
      user       = optional(string)

      readonly_root_filesystem = optional(bool, true)

      ports = optional(list(object({
        name           = string
        container_port = number
        protocol       = optional(string, "tcp")
        app_protocol   = optional(string)
      })), [])

      environment = optional(map(string), {})

      secrets = optional(map(object({
        value_from = string # Approved Secrets Manager secret ARN, optionally with JSON key/version selector
      })), {})

      health_check = optional(object({
        command      = list(string)
        interval     = optional(number, 30)
        timeout      = optional(number, 5)
        retries      = optional(number, 3)
        start_period = optional(number, 0)
      }))

      log_stream_prefix = optional(string)
    }))

    ingress = optional(object({
      enabled = optional(bool, true)

      container_name = string
      container_port = number

      listener_rule_priority = number
      host_headers           = optional(set(string), [])
      path_patterns          = optional(set(string), [])

      # Explicit even for public services, which may deliberately use 0.0.0.0/0.
      allowed_client_cidrs = set(string)

      health_check = object({
        path                = string
        protocol            = optional(string, "HTTP")
        matcher             = optional(string, "200-399")
        interval            = optional(number, 30)
        timeout             = optional(number, 5)
        healthy_threshold   = optional(number, 2)
        unhealthy_threshold = optional(number, 3)
      })
    }))

    database_access = optional(object({
      enabled = optional(bool, true)
      port    = number

      # Optional explicit application credential reference. No credential is
      # created and the RDS master secret is never selected automatically.
      credential_secret_arn = optional(string)
    }))

    aws_capabilities = optional(object({
      secretsmanager_read_arns = optional(set(string), [])
      ssm_parameter_read_arns  = optional(set(string), [])
      s3_read_bucket_arns      = optional(set(string), [])
      s3_write_object_arns     = optional(set(string), [])
      sns_publish_topic_arns   = optional(set(string), [])
      sqs_consume_queue_arns   = optional(set(string), [])
      kms_decrypt_key_arns     = optional(set(string), [])
    }), {})

    external_egress = optional(object({
      required                 = optional(bool, false)
      approved_domain_set_keys = optional(set(string), [])
      tcp_ports                = optional(set(number), [443])
    }), {})

    service_connections = optional(map(object({
      destination_service_key = string
      port                    = number
      protocol                = optional(string, "tcp")
    })), {})

    autoscaling = optional(object({
      enabled      = optional(bool, true)
      min_capacity = number
      max_capacity = number

      cpu_target_percent    = optional(number)
      memory_target_percent = optional(number)
    }))

    deployment = optional(object({
      minimum_healthy_percent = optional(number, 100)
      maximum_percent         = optional(number, 200)

      circuit_breaker_enabled  = optional(bool, true)
      circuit_breaker_rollback = optional(bool, true)

      health_check_grace_period_seconds = optional(number, 60)
      wait_for_steady_state             = optional(bool, true)
    }), {})

    containment = optional(object({
      automatic_task_containment_authorized = optional(bool, false)
      minimum_severity                      = optional(string, "CRITICAL")
    }), {})
  }))

  default = {}
}
```

All containers, including application containers and sidecars, are modeled as
elements of `containers`. `sidecar` expresses intent without introducing fields
for any particular telemetry, security, proxy, or malware-scanning product.
Each container independently declares essentiality, command/entrypoint, ports,
environment, secrets, health check, filesystem posture, and logging prefix.

Implementation-time validation must enforce at least:

- Stable non-empty service and container keys/names.
- At least one essential non-sidecar application container.
- A digest-pinned `image_uri` for every application and sidecar container,
  matching the approved ECR/private-image policy.
- A valid Fargate CPU/memory combination.
- Initial `operating_system_family` is exactly `LINUX`; initial
  `cpu_architecture` is `X86_64` or `ARM64`.
- Fargate `platform_version` is at least `1.4.0` and initially defaults to the
  explicitly pinned value `1.4.0`.
- Non-negative desired count and valid autoscaling bounds.
- Unique container and named-port values.
- Ingress container/port exists, listener priorities are unique,
  `allowed_client_cidrs` is explicit, and each forwarding listener rule has at
  least one meaningful host, path, or source-IP routing condition.
- Plain environment variables do not contain secret values by design; secrets
  use approved ARN references.
- Task-definition secret ARNs result in execution-role access only.
- Typed application capabilities result in task-role access only.
- Database network access and database credential access are distinct.
- The RDS master secret is never automatically granted.
- Egress domain-set keys resolve to environment-approved sets.
- Internet egress declarations are rejected under `vpc_endpoints_only` unless
  approved private connectivity satisfies them.
- `automatic_task_containment_authorized` is explicit and defaults false; it is
  effective only when a separate workload/environment-level automatic ECS
  containment authorization is also explicitly enabled.
- Initial `minimum_severity` can only be `CRITICAL`; broader choices require a
  future design change.
- Fargate uses `awsvpc`, compute-private subnets, and public IP assignment
  disabled; callers cannot override those invariants.

The Linux-only initial runtime, with Fargate platform version 1.4.0 or newer,
keeps the service substrate compatible with the intended GuardDuty Fargate
Runtime Monitoring posture. Windows Fargate is deferred until its runtime,
security, observability, containment, and validation contracts are designed.

Supporting environment-level inputs are expected to include a repository map,
cluster/runtime settings, shared-ALB settings including certificate ARN, a map
of approved egress domain sets, and a workload-level automatic ECS containment
authorization that defaults false. Both workload-level authorization and the
service-level authorization must be true before automatic task containment is
eligible. The domains are intentionally outside each service object so
environment reviewers can assess the complete outbound policy in one place.

Expected non-secret outputs include:

```hcl
ecs_cluster = {
  arn  = string
  name = string
}

ecr_repositories = map(object({
  arn  = string
  name = string
  url  = string
}))

application_load_balancer = object({
  arn               = string
  dns_name          = string
  hosted_zone_id    = string
  listener_arn      = string
  security_group_id = string
})

ecs_services = map(object({
  service_arn            = string
  service_name           = string
  task_definition_arn    = string
  task_security_group_id = string
  execution_role_arn     = string
  task_role_arn          = string
  log_group_names        = map(string)
  target_group_arn       = optional(string)
}))
```

No output may contain a secret value or credential-bearing connection string.

## Autoscaling and ECS Exec

**APPROVED V1.8.0 DESIGN:** Service autoscaling is part of the eventual v1.8.0
long-running service runtime. It is configured per service with explicit minimum
and maximum capacity and optional CPU/memory target tracking. The service module
owns those resources. Desired count, autoscaling, and containment behavior must
be tested together so task-level containment causes normal service replacement
without changing service-wide policy.

**APPROVED V1.8.0 DESIGN:** ECS Exec is initially disabled at cluster and service
level.

**DEFERRED/FUTURE:** ECS Exec requires explicit opt-in, separately scoped
operator IAM, encrypted and audited session logging, session-retention policy,
and workload validation. It must not become implicitly enabled merely because
an execution role or SSM endpoints already exist.

## Inspector and GuardDuty integration

### Inspector/ECR

**CURRENT REPOSITORY FACT:** `baseline/variables.tf` and
`modules/security/variables.tf` accept `ECR` in `inspector_resource_types`.
`scripts/validation/validate-security-workload.sh` already validates the actual
Inspector ECR status against `effective_inspector_resource_types`.

**APPROVED V1.8.0 DESIGN:** ECR scanning uses this existing account-level
Inspector capability. Enabling ECR repositories must be accompanied by an
explicit intended Inspector ECR posture, and workload validation must prove the
live result. No parallel Inspector ownership is added to `modules/ecr`.

### GuardDuty Runtime Monitoring

**CURRENT REPOSITORY FACT:** Central GuardDuty organization ownership lives in
`bootstrap/security_operations/security_services`. Its
`guardduty_organization_features` default in `variables.tf` currently sets
`EC2_AGENT_MANAGEMENT = ALL`, `ECS_FARGATE_AGENT_MANAGEMENT = NONE`, and
`EKS_ADDON_MANAGEMENT = NONE`; the same current state is documented in that
stack's `README.md`. `aws_guardduty_organization_configuration_feature.main` in
`main.tf` applies those centrally owned values.

**APPROVED V1.8.0 DESIGN:** During initial ECS implementation,
`ECS_FARGATE_AGENT_MANAGEMENT` remains `NONE`. After the runtime exists and its
networking, IAM, image access, task sizing, findings, and validation behavior
have been proven, the intended central state is:

```text
EC2_AGENT_MANAGEMENT         = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

That change remains owned by
`bootstrap/security_operations/security_services`; it is not an ECS service or
workload-module toggle. Central GuardDuty ownership and the existing
security-operations validation layer remain unchanged.

## Platform ownership versus application/release ownership

### Terraform/platform ownership

The platform Terraform owns:

- VPC, subnet, routing, Network Firewall, and cross-component network policy.
- Interface and gateway VPC endpoints.
- ECS cluster infrastructure.
- ECR repository infrastructure and repository policy/lifecycle.
- Shared ALB infrastructure, listener, target groups, and listener rules.
- ECS service and task-definition infrastructure.
- Task execution roles and application task roles generated from typed access
  declarations.
- Security-group objects and cross-component rules under their documented
  ownership split.
- CloudWatch log groups and infrastructure-level service observability.
- ECS service autoscaling.
- Inspector, GuardDuty integration points, workload security monitoring, and
  validation.
- Workload-local task-containment infrastructure and evidence path.

### Application/release ownership

The application/release process owns:

- Application source code.
- Dockerfile and container build.
- Unit, integration, security, and image tests.
- Image publication into an approved repository.
- Choosing and promoting an immutable image digest.
- Application schema migrations and their correctness.
- Application-aware release sequencing, readiness, and rollback decisions.

Terraform consumes the chosen immutable digest and declares infrastructure. It
does not build images or infer which digest should be promoted.

**DEFERRED/FUTURE:** The exact final boundary for high-frequency application
deployments remains a future design item. Any later application-release pipeline
must preserve reviewed immutable artifacts and must not weaken the existing
exact saved-plan semantics for Terraform-owned changes.

## Deferred items

The following are deliberately deferred and are not blockers for the initial
long-running ECS service substrate:

- Scheduled or run-to-completion ECS tasks.
- An application migration-task abstraction.
- Route53/domain ownership.
- First-class ACM certificate ownership.
- Advanced WAF ownership and rule construction.
- Audited ECS Exec.
- Service-wide automatic containment.
- Per-service ALBs.
- A sophisticated high-frequency application deployment pipeline.
- Application database-user lifecycle and credential rotation.
- Windows Fargate support.
- Sophisticated historical ECR release-retention policy beyond safely retaining
  images that may still be referenced.
- ReconoSense-specific deployment wiring.

No `modules/ecs_task` module is part of this architecture milestone. Scheduled
and one-off task design begins only after the normal long-running ECS service
substrate has been implemented and validated.

## Existing hardening items outside ECS scope

These findings are separate production-hardening work. They do not change the
ECS module boundaries and are not implemented as part of this design task.

### RDS deletion and final-snapshot policy

**EXISTING HARDENING ITEM:** `aws_db_instance.main` in
`modules/storage/main.tf` currently sets `deletion_protection = false` and
`skip_final_snapshot = true`, with comments identifying production follow-up.
Production behavior should become profile/environment appropriate in separate
hardening work.

### Centralized-log storage destruction and lifecycle protection

**EXISTING HARDENING ITEM:** `aws_s3_bucket.centralized_logs` in
`modules/storage/main.tf` currently sets `force_destroy = true` and has a
`lifecycle` block with `prevent_destroy = false`, again with production follow-up
comments. Retention, immutability, and destruction protection require separate
production-hardening treatment.

### CMK deletion protection

**EXISTING HARDENING ITEM:** Customer-managed keys in
`modules/security/main.tf`, including `aws_kms_key.logs`, `aws_kms_key.ebs`,
`aws_kms_key.secrets_manager`, and `aws_kms_key.backup_vault`, currently retain
`prevent_destroy = false` production follow-up settings where lifecycle blocks
are present. Production CMK deletion protection is separate from ECS runtime
design.

## Initial implementation invariants

The initial implementation is conformant only if all of the following remain
true:

1. EC2 continues to work and `modules/compute` remains EC2-only.
2. ECS/Fargate is a sibling capability using the four approved new modules.
3. Task ENIs use `compute_private` and never receive public IPs.
4. No new application subnet class is introduced.
5. Initial Fargate runtime is Linux, supports `X86_64` and `ARM64`, and pins a
   platform version of at least `1.4.0`, initially/defaulting to `1.4.0`.
6. One environment-level ALB serves ingress-enabled services through separate
   `target_type = "ip"` target groups and explicit conditioned listener rules;
   its HTTPS listener default is a fail-closed fixed response.
7. Shared ALB SG ingress is the union of explicitly declared service client
   CIDRs, while narrower per-service CIDRs are also enforced by listener-rule
   `source-ip` conditions.
8. ACM and Route53 ownership are not silently absorbed into the runtime.
9. Resource modules own SG objects; `security_policy` owns cross-component
   rules.
10. Security-policy readiness is established before service launch through
    resource-granular dependencies without module-level dependency cycles.
11. ECS execution and application roles are separate and least privilege.
12. Images are digest pinned in the reviewed saved plan, and ECR lifecycle
    policy cannot delete a digest that may still be referenced.
13. ECR uses the existing Inspector ownership model.
14. ECR API/Docker traffic uses Interface Endpoints; ECR layers use the existing
    S3 Gateway Endpoint, with task SG TCP/443 egress to the AWS-managed S3 prefix
    list as an independent readiness requirement.
15. Application domains are approved at environment level and are not reusable
    module defaults.
16. `vpc_endpoints_only` remains fail closed.
17. Storage exports only non-secret connection metadata and does not grant the
    RDS master credential automatically.
18. ECS Exec remains disabled.
19. Automatic containment is explicitly authorized, CRITICAL-only, task-level,
    evidence-first, idempotent, and fail closed.
20. Central GuardDuty Fargate agent management remains `NONE` during initial
    implementation and can change only in the central security-services stack.
21. ECS/ECR/ALB validation extends the existing workload baseline layer.
22. Scheduled tasks and application-specific release wiring remain deferred.
