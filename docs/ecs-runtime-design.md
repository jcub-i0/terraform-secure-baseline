# ECS/Fargate Application Runtime Design

## Status and purpose

This document records the implemented, unreleased v1.8.0 secure container
workload architecture on `main`. The B1-B8 prerequisites and C1-C5 core
ECS/Fargate runtime are implemented, merged, and live-tested. `v1.7.0` remains
the latest released version.

The platform remains generic. It is not an application-specific Terraform
implementation. EC2 remains a supported host-based workload pattern through
`modules/compute`; ECS/Fargate is the preferred modern SaaS/application
runtime. The two are sibling capabilities, and `modules/compute` remains
EC2-only.

This document distinguishes:

- **CURRENT IMPLEMENTATION**: behavior present in Terraform or validation now.
- **DEFERRED/FUTURE**: work outside the merged core runtime.
- **EXISTING HARDENING ITEM**: production hardening that is independent of ECS
  architecture.

## Implemented module boundaries

The runtime is composed from four separate reusable modules:

```text
modules/ecr
modules/ecs_cluster
modules/application_load_balancer
modules/ecs_service
```

`baseline/main.tf` composes those modules with the existing IAM, security,
networking, storage, firewall, and endpoint modules. Workload roots in
`environments/dev`, `environments/staging`, and `environments/prod` pass the
same canonical inputs to `module.baseline`. All resources remain in the
existing workload-environment Terraform state; the runtime does not introduce
a foundation/runtime state split.

Conceptual cardinality is:

```text
workload environment
├── one ECS cluster
├── zero or one shared ALB
├── N ECR repositories
└── N ECS services
```

The cluster exists even when `ecs_services = {}`. The ALB exists only when at
least one service configures ingress.

## Network placement

The existing subnet classes retain their established roles:

| Subnet class | Current role |
| --- | --- |
| `public` | Internet-facing shared ALB |
| `compute_private` | EC2 and ECS/Fargate application compute |
| `data_private` | RDS |
| `serverless_private` | VPC-attached security and automation Lambda functions |
| `endpoint_private` | Interface VPC Endpoints |
| `firewall_private` | AWS Network Firewall |

`modules/ecs_service/main.tf` configures Fargate services with `awsvpc`, the
compute-private subnet set, exactly one service task security group, and
`assign_public_ip = false`. No application-specific subnet class or public task
IP is supported.

Workload egress continues to follow `effective_egress_mode`:

- `network_firewall`: compute routes through Network Firewall and NAT;
- `nat_only`: compute routes directly through NAT; and
- `vpc_endpoints_only`: compute has no default internet route.

The latter remains fail closed; declaring application domains does not create
connectivity in that mode.

## Canonical service interface

Operators maintain one `ecs_services` map. `baseline/locals.tf` derives the
narrower ECR, IAM, ALB, security-policy, and ECS runtime maps. Operators do not
maintain parallel `alb_services`, IAM-service, or security-policy-service maps.

The exact current interface in `baseline/variables.tf` is:

```hcl
variable "ecs_services" {
  type = map(object({
    repository_name = string
    image_digest    = string

    container_port = number
    cpu            = number
    memory         = number
    desired_count  = optional(number, 1)

    cpu_architecture = optional(string, "X86_64")
    database_access = optional(bool, false)

    environment_variables = optional(map(string), {})

    secrets_manager_secrets = optional(map(string), {})
    ssm_parameters          = optional(map(string), {})
    task_execution_kms_key_arns  = optional(set(string), [])

    ingress = optional(object({
      priority          = number
      host_headers      = optional(set(string), [])
      path_patterns     = optional(set(string), [])
      health_check_path = optional(string, "/health")
    }), null)
  }))

  default = {}
}
```

Service keys are stable environment-local identities. Repository names use
lowercase ECR syntax. Image digests must match `sha256:` followed by 64
lowercase hexadecimal characters. Plain environment-variable names cannot
overlap ECS-native secret names, and a secret name cannot be declared in both
Secrets Manager and SSM maps.

The current service abstraction creates exactly one essential container named
for the service. Multi-container/sidecar support is not part of the current
interface.

## Image and repository lifecycle

`modules/ecr` owns private repositories through
`aws_ecr_repository.repositories` and their lifecycle policies through
`aws_ecr_lifecycle_policy.untagged_cleanup`. Its `repositories` input is
`map(object({}))`, keyed directly by repository name. Actual names are
`${var.name_prefix}-${each.key}`.

All repositories use:

- `image_tag_mutability = "IMMUTABLE"`;
- KMS encryption with the dedicated ECR CMK from `modules/security`; and
- a lifecycle policy that expires only untagged images older than 30 days.

No repository policy, basic scanning configuration, or registry scanning
configuration is owned by `modules/ecr`. Inspector ownership stays in
`modules/security`; baseline adds `ECR` to
`effective_inspector_resource_types` whenever the effective repository set is
non-empty.

Baseline computes the effective repository set by merging explicitly declared
repositories with repository names required by `ecs_services`. This permits a
first deployment such as:

```hcl
repositories = {
  test = {}
}
ecs_services = {}
```

followed by:

```hcl
repositories = {}
ecs_services = {
  test = {
    repository_name = "test"
    # remaining service fields omitted
  }
}
```

The stable repository key remains `test`, so that transition does not
destroy/recreate the repository.

Any digest that is active or remains deployable by Terraform must retain at
least one immutable release tag. Tag immutability prevents reassignment but
does not prevent deleting the final tag. Application release automation must
not remove that tag while the digest remains active or deployable.

The current ephemeral development/test posture sets
`force_delete = true # CHANGE THIS IN PROD` on repositories. This lets normal
apply/test/destroy cycles remove repositories containing development images.
There is no `prevent_destroy` protection. Persistent production deployments
must reconsider this behavior.

Terraform never builds, publishes, or selects an image. Task image references
are constructed in `baseline/locals.tf` as:

```text
<resource-backed repository_url>@sha256:<digest>
```

The intended first-service lifecycle is:

1. Terraform ensures the environment foundation and ECR repository exist.
2. Application code is built, tested, and pushed outside Terraform.
3. The authoritative ECR SHA-256 digest is resolved.
4. Terraform plans and applies the ECS runtime with that immutable digest.

Staged live testing may use additional applies, but three applies are not an
architectural requirement.

## ECS cluster

`modules/ecs_cluster` owns one `aws_ecs_cluster.cluster` per environment. It
owns naming, standard tags, and the Container Insights setting. It does not own
services, task definitions, IAM roles, networking, ALB resources, ECR, or
service log groups.

`container_insights` accepts `enhanced`, `enabled`, or `disabled` and defaults
to `enhanced`. The resource-backed workload output is:

```hcl
ecs_cluster = {
  arn                = string
  name               = string
  container_insights = string
}
```

The runtime validator compares the live cluster setting exactly with that
output; it does not hard-code the default.

## ECS services and task definitions

One `modules/ecs_service` instance manages the full stable service map. For
each key it owns:

- `aws_security_group.task_security_groups`;
- `aws_cloudwatch_log_group.service_logs`;
- `aws_ecs_task_definition.task_definitions`; and
- `aws_ecs_service.services`.

Task definitions use Fargate, `awsvpc`, Linux, and either `X86_64` or `ARM64`.
The module validates supported Fargate CPU/memory combinations. The platform
version is explicit, defaults to `1.4.0`, and is exposed from the resource as
`ecs_services[service].platform_version` for exact validation.

Each task definition uses a per-service execution role and application task
role. It contains one essential container named for the stable service key,
one TCP port mapping whose host and container ports match, plaintext
environment entries, ECS-native secret references, and an `awslogs` driver.

The ECS service uses Fargate launch type, the explicit platform version,
compute-private subnets, exactly the task SG, no public IP, and an enabled
deployment circuit breaker with automatic rollback. A load-balancer attachment
is present only for ingress-enabled services.

The current ephemeral posture sets
`force_delete = true # CHANGE THIS IN PROD` on `aws_ecs_service.services`.
Persistent production use must reconsider the destruction posture.

## Logging

`modules/ecs_service` owns one deterministic log group per service:

```text
/aws/ecs/${var.name_prefix}/${service_name}
```

Retention uses `effective_cloudwatch_retention_days`. Encryption uses the
existing workload logs CMK from `modules/security`, whose exact ARN is exposed
as `logs_cmk_arn`. The task definition uses:

```text
logDriver              = awslogs
awslogs-group          = resource-backed log-group name
awslogs-region         = workload Region
awslogs-stream-prefix  = ecs
mode                   = non-blocking
```

Terraform creates the log group; `awslogs-create-group = true` is neither
needed nor configured. `modules/logging` continues to own platform/security
telemetry such as CloudTrail and VPC Flow Logs.

## IAM ownership

`modules/iam/ecs.tf` creates one execution-role/task-role pair per service.
Both trust `ecs-tasks.amazonaws.com` with current-account and ECS SourceArn
restrictions.

The custom per-service execution policy grants:

- `ecr:GetAuthorizationToken` on `*`;
- ECR layer/image pull actions on only the service repository ARN;
- CloudWatch Logs stream creation/write actions on only the service log group;
- optional Secrets Manager, SSM Parameter Store, and `kms:Decrypt` access only
  for explicitly declared ARNs.

The task role initially has no broad application policy. Application API
permissions do not belong on the execution role. Neither role receives
`iam:PassRole`, and ordinary ECR pulls do not require direct execution-role
access to the ECR encryption CMK.

The execution-policy resource IDs feed ECS launch readiness. They are not
credentials and are not public workload-root outputs.

## Security-group ownership and readiness

Security-group ownership is intentionally split:

| Object or rule | Owner |
| --- | --- |
| ALB SG object | `modules/application_load_balancer` |
| ECS task SG objects | `modules/ecs_service` |
| RDS/data SG object | `modules/storage` |
| Interface Endpoint SG object | `modules/vpc_endpoints` |
| Cross-component SG rules | `modules/networking/security_policy` |

Every configured service receives these cross-component relationships:

```text
task SG -> Interface Endpoint SG :443
Interface Endpoint SG <- task SG :443
task SG -> AWS-managed S3 prefix list :443
```

The Interface Endpoints `ecr.api` and `ecr.dkr` carry ECR API/registry traffic.
ECR layers use the existing S3 Gateway Endpoint, so the S3 prefix-list rule is
required independently. Baseline passes the resource-backed
`aws_vpc_endpoint.s3.prefix_list_id`; validators do not assume the AWS
endpoint description response is the authoritative prefix-list source.

When `database_access = true`, policy adds task-to-data and data-from-task rules
on the RDS port. Those relationships are absent when it is false. When ingress
is configured, policy adds ALB-to-task relationships on the container port.
Application HTTPS egress exists for `nat_only` and `network_firewall` and is
absent for `vpc_endpoints_only`.

ALB rule filtering uses the plan-time-known semantic value `alb_access`, which
baseline derives from `service.ingress != null`. It must not filter on
whether the resource-derived ALB SG ID is non-null, because that ID is unknown
during planning.

Launch readiness is resource granular:

```text
IAM execution policy IDs
  -> terraform_data.ecs_execution_policy_ready

security-policy rule IDs
  -> terraform_data.ecs_security_policy_ready

both checkpoints
  -> aws_ecs_service.services
```

The task SG remains independently creatable so it can be passed to
`security_policy`. Only task launch waits on downstream rule IDs. Broad
module-level dependencies would create a cycle and are not part of the design.

## Application Load Balancer

`modules/application_load_balancer` creates zero or one shared,
internet-facing Application Load Balancer. It uses public subnets and one
environment-level ingress CIDR set. It creates no HTTP listener.

The HTTPS listener uses the caller-supplied ACM certificate ARN and TLS policy.
The current default is:

```text
ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09
```

Its default action is a fixed JSON 404. Each ingress-enabled service gets an
HTTP target group with `target_type = "ip"` and one explicit forwarding rule.
Each rule must contain at least one host-header or path-pattern condition; when
both are present, both conditions must match.

The ALB module owns the ALB SG object and public HTTPS ingress rule. The shared
SG ingress is environment-wide; the current interface does not implement
per-service client CIDR conditions. Cross-component ALB/task rules stay in
`modules/networking/security_policy`.

Current ALB ownership does not include Route53, ACM certificate creation, WAF,
or ALB vended-log delivery. The current deletion-friendly development posture
sets `enable_deletion_protection = false # CHANGE THIS IN PROD`.

The resource-backed output is:

```hcl
application_load_balancer = null # when no ingress service exists

# otherwise
application_load_balancer = {
  arn               = string
  dns_name          = string
  security_group_id = string
  https_listener = {
    arn             = string
    certificate_arn = string
    ssl_policy      = string
  }
  target_groups = map(object({
    arn  = string
    name = string
  }))
}
```

## Storage outputs and secret handling

`modules/storage` and the workload roots expose only non-secret RDS connection
metadata: address, endpoint, port, database name, master username, master
secret ARN, and data SG ID. They do not expose secret values or render
credential-bearing DSNs.

ECS services can reference explicitly approved Secrets Manager or SSM ARNs for
ECS-native injection. The generic runtime does not automatically grant the RDS
master credential, create application database users, rotate application
credentials, or run schema migrations.

## Validation contract

ECS/Fargate extends the existing workload-baseline validation layer. There are
four validation/evidence layers in total and 16 validators in the workload
baseline layer; no fifth layer exists.

The main prerequisite/runtime owners are:

- `validate-vpc-endpoints.sh`: canonical endpoint inventory, private DNS,
  exact endpoint subnets/SG, and S3 Gateway Endpoint route-table coverage;
- `validate-networking.sh`: resource-backed effective Network Firewall domain
  set and existing route/egress invariants;
- `validate-ecr.sh`: repository identity, immutable tags, KMS encryption,
  exact `ecr_cmk_arn`, and the approved untagged-only lifecycle policy;
- `validate-security-workload.sh`: live Inspector types against
  `effective_inspector_resource_types`;
- `validate-kms.sh`: environment alias/key inventory, key state,
  customer-managed ownership, and rotation;
- `validate-iam.sh`: ECS trust and custom execution-policy scope; and
- `validate-ecs-runtime.sh`: cluster, service, task definition, logging,
  network, and conditional ALB relationships.

`validate-ecs-runtime.sh` validates the resource-backed contract, including:

- cluster identity, `ACTIVE` state, and exact Container Insights setting;
- exact service inventory and service/task-definition identity;
- Fargate launch type and resource-backed platform version;
- compute-private subnets, disabled public IP assignment, and exactly the task
  SG;
- circuit breaker/rollback plus steady state (`runningCount == desiredCount`,
  `pendingCount == 0`, and PRIMARY rollout `COMPLETED`);
- Fargate, `awsvpc`, Linux, supported CPU architecture, and role equality;
- exactly one essential service-named container, a digest-pinned ECR image,
  TCP port mapping, and `awslogs` configuration;
- exact log-group identity, retention, and exact `logs_cmk_arn`;
- database SG presence/absence from resource-backed `database_access` intent;
- Interface Endpoint, S3 prefix-list, and egress-mode-aware HTTPS rules; and
- conditional ALB identity, public subnets, SG, exact HTTPS listener ARN,
  certificate, TLS policy, fixed 404, IP target group, listener rule, ECS
  attachment, and ALB/task SG rules.

`ecr_repositories = {}` and `ecs_services = {}` are valid. The ECR validator
skips repository API calls for an empty repository map. The runtime validator
still validates the environment cluster, then skips per-service and ALB checks
when no services are configured.

The public validator-facing outputs include:

```text
ecs_cluster
ecs_services
ecs_service_configuration
ecs_task_definition_arns
ecs_task_security_group_ids
ecs_log_groups
ecs_task_execution_roles
ecs_task_roles
ecr_repositories
ecr_cmk_arn
logs_cmk_arn
application_load_balancer
s3_prefix_list_id
effective_egress_mode
effective_cloudwatch_retention_days
```

Internal readiness IDs are deliberately not exposed merely for validation.
When a value represents what Terraform configured on an AWS resource, the
project prefers a resource-backed Terraform output over re-deriving it or
hard-coding the value in Bash.

## Deployment semantics and ownership

The existing workflow contract remains authoritative:

```text
Terraform Plan
  -> saved binary plan
  -> checksum and metadata
  -> review/approval
  -> Apply the exact reviewed plan
```

Terraform/platform ownership includes the VPC, endpoints, cluster, ECR
repositories, ALB, ECS services/task definitions, IAM roles, SGs/rules, log
groups, monitoring, and validation.

Application/release ownership includes source code, Dockerfile, build/test,
image push, selection/promotion of the authoritative digest, schema migrations,
and application-aware release sequencing. Terraform consumes a selected digest
but does not build or push the image.

## Central security boundary

Inspector ECR scanning remains workload-local under `modules/security`.
Central GuardDuty organization ownership remains in
`bootstrap/security_operations/security_services`. Its current intended
feature state remains:

```text
EC2_AGENT_MANAGEMENT         = ALL
ECS_FARGATE_AGENT_MANAGEMENT = NONE
EKS_ADDON_MANAGEMENT         = NONE
```

An operational ECS runtime does not imply that Fargate managed-agent deployment
is enabled. That later change remains centrally owned. Workload-local,
deterministic remediation remains the containment boundary; no broad central
remediation role is introduced.

## Deferred/future work

The next immediate v1.8.0 milestone is an application image
build/publish/deployment workflow that will use short-lived AWS/OIDC
credentials, publish to ECR, resolve the authoritative digest, feed it into the
saved Terraform plan, apply that exact plan, wait for ECS convergence, and run
ECR/IAM/ECS validation. It is not implemented by the current core runtime.

Subsequent expected work includes:

- ECS Service Auto Scaling;
- GuardDuty Fargate Runtime Monitoring;
- fail-closed, evidence-first ECS task containment;
- the ReconoSense reference deployment;
- release-readiness documentation, changelog, and tagging;
- scheduled/run-to-completion and migration-task abstractions;
- Route53 and first-class ACM ownership;
- advanced WAF ownership;
- audited ECS Exec;
- service-wide automatic containment;
- per-service ALBs;
- multi-container/sidecar services;
- application database-user lifecycle and rotation;
- Windows Fargate; and
- sophisticated historical ECR release retention.

No `modules/ecs_task` module is part of the current architecture.

## Existing hardening items outside ECS scope

These independent items must not drive changes to ECS ownership:

- **RDS:** `aws_db_instance.main` currently has deletion protection disabled
  and skips a final snapshot, with production-follow-up comments in
  `modules/storage/main.tf`.
- **Central log bucket:** `aws_s3_bucket.centralized_logs` currently permits
  destruction and has no effective `prevent_destroy` protection, with
  production-follow-up comments in `modules/storage/main.tf`.
- **CMKs:** several workload CMKs, including the ECR CMK, currently have
  development-friendly lifecycle protection settings marked for production
  follow-up in `modules/security/main.tf`.

These settings support the current ephemeral apply/test/destroy model. They
must be deliberately reconsidered before persistent production use.
