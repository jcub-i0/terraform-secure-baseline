# ECS/Fargate Application Runtime Design

## Status and purpose

This document describes the implemented ECS/Fargate runtime architecture through `v1.10.0`, including GuardDuty Fargate Runtime Monitoring, ownership boundaries, service scaling, deployment health, operational alarms, runtime-security policy, application release lifecycle, and validation responsibilities.

ECS/Fargate is the preferred modern SaaS/application runtime. EC2 remains a supported host-based workload pattern.

## Implemented module boundaries

The reusable container platform is intentionally divided across four sibling modules rather than one monolithic ECS module:

```text
modules/ecr
modules/ecs_cluster
modules/application_load_balancer
modules/ecs_service
```

`baseline` composes these modules with `modules/iam`, `modules/networking/security_policy`, `modules/vpc_endpoints`, `modules/security`, and existing workload infrastructure. ECR repositories are N-per-environment, the ECS cluster is one-per-environment, the shared ALB is zero-or-one-per-environment, and ECS services are N-per-environment.

Do not move ECR into bootstrap, introduce a second service map, or split foundation/runtime Terraform state merely to reduce applies.

## Network placement

Fargate tasks use `awsvpc`, run in `compute_private` subnets, and receive no public IP. An optional shared internet-facing ALB uses public subnets. Interface VPC Endpoints, including `ecr.api`, `ecr.dkr`, and `guardduty-data`, use `endpoint_private` subnets. ECR image layers use the S3 Gateway Endpoint. GuardDuty Runtime Monitoring telemetry uses the Terraform-owned `guardduty-data` Interface Endpoint rather than a GuardDuty-created duplicate endpoint.

Application HTTPS egress follows the effective workload egress mode: `development` defaults to `nat_only`, `production` defaults to `network_firewall`, and `minimal` defaults to `vpc_endpoints_only`. The task-security-policy path is derived from the same effective mode rather than using a separate ECS egress model.

## Canonical service interface

Operators maintain exactly one `ecs_services` map. Baseline derives the narrower ECR, IAM, ALB, security-policy, and ECS-runtime maps from it.

The current interface is conceptually:

```hcl
variable "ecs_services" {
  type = map(object({
    repository_name = string
    image_digest    = optional(string)

    container_port = number
    cpu            = number
    memory         = number
    desired_count  = optional(number, 1)

    scaling = optional(object({
      min_capacity               = number
      max_capacity               = number
      cpu_target_percent         = optional(number)
      memory_target_percent      = optional(number)
      alb_requests_per_target    = optional(number)
      scale_in_cooldown_seconds  = optional(number, 300)
      scale_out_cooldown_seconds = optional(number, 300)
    }), null)

    deployment = optional(object({
      minimum_healthy_percent           = optional(number, 100)
      maximum_percent                   = optional(number, 200)
      health_check_grace_period_seconds = optional(number, 0)
    }), {})

    cpu_architecture = optional(string, "X86_64")
    database_access = optional(bool, false)

    environment_variables = optional(map(string), {})

    secrets_manager_secrets      = optional(map(string), {})
    ssm_parameters               = optional(map(string), {})
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

A non-null digest must match `sha256:` plus 64 lowercase hexadecimal characters. Plain environment-variable names cannot overlap ECS-native secret names, and a secret name cannot be declared in both the Secrets Manager and SSM maps.

When `scaling` is configured, `min_capacity` must be at least 1, `max_capacity` must be greater than or equal to `min_capacity`, and the configured `desired_count` bootstrap value must fall within that range. At least one of `cpu_target_percent`, `memory_target_percent`, or `alb_requests_per_target` must be configured, target values must be greater than zero, and cooldowns must be non-negative. `alb_requests_per_target` additionally requires `ingress`.

Deployment-health inputs preserve ECS defaults when omitted: `minimum_healthy_percent = 100`, `maximum_percent = 200`, and `health_check_grace_period_seconds = 0`.

### Registered versus deployable services

`image_digest = null` is a valid lifecycle state. It means the service is registered but unreleased.

Baseline derives `deployable_ecs_services` by filtering the canonical map to entries whose `image_digest` is non-null. ECR repository requirements intentionally derive from **all registered services**, while per-service ECS runtime, runtime IAM, task security groups, application log groups, and ALB routing derive only from **deployable services**.

Therefore a registered-but-unreleased service preserves/creates its required ECR repository without creating a task definition or ECS service. Selecting a valid digest later materializes the runtime from the same service entry. Registered-but-unreleased services also create no Application Auto Scaling targets or policies and no ECS operational alarms.

### Fixed versus autoscaled desired-count ownership

`scaling = null` means the service is fixed-count. Terraform owns `desired_count` and the runtime validator requires the live ECS desired count to equal the configured value exactly.

A non-null `scaling` object means the service is autoscaled. The configured `desired_count` is bootstrap capacity used when the ECS service is created; after creation, Application Auto Scaling owns subsequent desired-count changes within `min_capacity` and `max_capacity`. Terraform must not reset a legitimate runtime scaling decision back to the bootstrap count.

`modules/ecs_service` therefore keeps fixed and autoscaled ECS services on separate Terraform resources. Fixed services use `aws_ecs_service.services`; autoscaled services use `aws_ecs_service.autoscaled_services` with `lifecycle.ignore_changes = [desired_count]`. This split is required because Terraform lifecycle behavior cannot be selected conditionally for individual `for_each` instances.

Existing fixed-count services retain the original `aws_ecs_service.services` address, preserving the v1.8 state identity for services that do not opt into scaling.

## Image and repository lifecycle

`modules/ecr` owns private repositories and their lifecycle policies. Repositories use immutable tags, KMS encryption with the dedicated ECR CMK, and a lifecycle rule that expires only untagged images older than 30 days.

The effective repository set merges explicitly configured `repositories` with repository names required by the canonical `ecs_services` map. Explicit repositories remain useful when a repository is needed without a service declaration, but the normal first-image path can register a service with `image_digest = null` and let that service derive the repository.

Any image digest that remains active or deployable must retain at least one tag so it is not eligible for the untagged-image lifecycle policy. Tag immutability prevents reassignment of a tag; it does not protect an intentionally untagged image from lifecycle cleanup.

Terraform never builds, pushes, tests, or chooses application images. A deployable task image is constructed from the resource-backed repository URL and the selected digest:

```text
<repository_url>@sha256:<digest>
```

## ECS cluster and Container Insights

`modules/ecs_cluster` owns one ECS cluster per workload environment, the cluster's Container Insights configuration, and the workload cluster's explicit GuardDuty Runtime Monitoring participation intent.

`container_insights` accepts `enhanced`, `enabled`, or `disabled` and defaults to `enhanced`.

When Container Insights is enabled, the module also owns the performance log group:

```text
/aws/ecs/containerinsights/<cluster-name>/performance
```

Terraform manages that log group's retention, workload logs-CMK encryption, tags, and resource-backed metadata. The workload `ecs_cluster` output includes cluster identity, the resource-backed Container Insights setting, and `container_insights_log_group` metadata; the log-group value is `null` when Container Insights is disabled.

GuardDuty Fargate Runtime Monitoring participation is derived by baseline from `deployment_profile`:

| `deployment_profile` | Runtime Monitoring | ECS cluster tag |
|---|---:|---|
| `production` | Enabled | `GuardDutyManaged=true` |
| `development` | Enabled | `GuardDutyManaged=true` |
| `minimal` | Disabled | `GuardDutyManaged=false` |

`modules/ecs_cluster` receives the already-resolved boolean as `guardduty_fargate_runtime_monitoring_enabled` and writes the AWS-defined `GuardDutyManaged` tag directly on the cluster. The module does not infer deployment profiles itself.

The cluster outputs expose both:

```text
guardduty_fargate_runtime_monitoring_enabled
guardduty_managed_tag_value
```

so validation can compare Terraform intent, live cluster tags, and deployment-profile expectations without reconstructing policy from naming conventions.
## ECS services and task definitions

`modules/ecs_service` receives only deployable services from baseline. For each low-level service entry it owns a task security group, a Terraform-managed service log group, a task definition, and an ECS service.

Task definitions use Fargate, `awsvpc`, Linux, and either `X86_64` or `ARM64`. The module validates supported Fargate CPU/memory combinations. The platform version is explicit, defaults to `1.4.0`, and is exposed from the resource as `ecs_services[service].platform_version` for exact validation.

Each task definition uses separate per-service task execution and application task roles. The current abstraction contains exactly one essential container named for the stable service key, one TCP port mapping, plaintext environment values, approved ECS-native secret references, and the `awslogs` driver.

The ECS service runs in compute-private subnets, uses only its task security group, disables public IP assignment, and enables deployment circuit breaking with automatic rollback. Load-balancer attachment exists only for deployable services with ingress configuration.

## Deployment health

Both fixed and autoscaled services apply the canonical `deployment` settings directly to the ECS service:

- `minimum_healthy_percent` controls the lower deployment bound as a percentage of desired tasks;
- `maximum_percent` controls the upper deployment bound; and
- `health_check_grace_period_seconds` tells ECS how long after task startup to ignore unhealthy load-balancer, VPC Lattice, and container health checks.

The existing deployment circuit breaker remains enabled with automatic rollback. The deployment settings are exposed through resource-backed service outputs so `validate-ecs-runtime.sh` can compare the exact live ECS values with Terraform.

## Application Auto Scaling

For every deployable service whose canonical `scaling` object is non-null, `modules/ecs_service` creates one `aws_appautoscaling_target` for `ecs:service:DesiredCount` using the configured minimum and maximum capacities. v1.9 uses target-tracking policies only.

Optional target-tracking policies are materialized from the same scaling object:

| Canonical field | AWS predefined metric |
|---|---|
| `cpu_target_percent` | `ECSServiceAverageCPUUtilization` |
| `memory_target_percent` | `ECSServiceAverageMemoryUtilization` |
| `alb_requests_per_target` | `ALBRequestCountPerTarget` |

All configured policies use `scale_in_cooldown_seconds` and `scale_out_cooldown_seconds`. CPU and memory policies do not require ingress. ALB request-count scaling requires an ingress-enabled deployable service.

The `ALBRequestCountPerTarget` resource label is derived from Terraform-owned ALB and target-group resource identities:

```text
<load-balancer-arn-suffix>/<target-group-arn-suffix>
```

Baseline consumes `load_balancer_arn_suffix` and per-target-group `arn_suffix` outputs from `modules/application_load_balancer`; validation does not reconstruct these identities from naming conventions in Bash.

AWS creates and manages the CloudWatch alarms that support target-tracking policies. Those alarms remain AWS-managed and are intentionally separate from Terraform-owned operational notification alarms.

## Logging

Each deployable service receives a Terraform-owned application log group:

```text
/aws/ecs/<name-prefix>/<service>
```

The log group uses the effective profile-driven CloudWatch retention period and the workload logs CMK. Task definitions reference the resource-backed log-group name directly and do not rely on `awslogs-create-group`.

The cluster-owned Container Insights performance log group uses `/aws/ecs/containerinsights/<cluster-name>/performance` and follows the same effective retention/logs-CMK policy. Service log groups and the cluster performance log group have different resource owners, but both are part of the workload logging contract.

## IAM ownership

`modules/iam` creates separate task execution and application task roles for deployable services only.

The task execution role is used by ECS/Fargate during startup. Its custom policy scopes application ECR pulls, CloudWatch Logs writes, declared Secrets Manager/SSM references, and optional KMS decrypt authority required to retrieve startup configuration. The application task role is the role used by application code after the container starts and intentionally begins without broad application permissions.

The canonical field `task_execution_kms_key_arns` means: the customer-managed KMS key ARNs that the **task execution role** may use with `kms:Decrypt` during startup. If the configured set is empty, the execution policy must not grant `kms:Decrypt`. If it is populated, the policy must grant `kms:Decrypt` to exactly those key ARNs. This authority is separate from application task-role permissions.

GuardDuty Runtime Monitoring adds one profile-aware execution-role requirement. When Runtime Monitoring is enabled (`production` or `development`), baseline resolves the regional AWS-hosted agent repository ARN:

```text
arn:<partition>:ecr:<region>:<guardduty-agent-account-id>:repository/aws-guardduty-agent-fargate
```

and supplies exactly that ARN through `guardduty_agent_ecr_repository_arns`. The execution policy grants only:

```text
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

against that repository. Registry authorization remains the existing `ecr:GetAuthorizationToken` permission on `*`.

When Runtime Monitoring is disabled (`minimal`), the GuardDuty-agent repository set is empty and no GuardDuty-specific ECR statement is emitted. Application ECR repository scope remains separate and unchanged.

Neither ECS role receives `iam:PassRole` as part of the per-service runtime contract, and the module does not attach the broad AWS-managed `AmazonECSTaskExecutionRolePolicy`.
## Security-group ownership and launch readiness

Security-group ownership remains split by resource owner:

| Object or rule | Owner |
|---|---|
| ALB SG object | `modules/application_load_balancer` |
| ECS task SG objects | `modules/ecs_service` |
| RDS/data SG object | `modules/storage` |
| Interface Endpoint SG object | `modules/vpc_endpoints` |
| Cross-component SG rules | `modules/networking/security_policy` |

Every deployable task receives the required Interface Endpoint and S3 relationships. Database access rules exist only when `database_access = true`. ALB/task rules exist only for deployable ingress services. Application HTTPS egress exists for `nat_only` and `network_firewall` and is absent for `vpc_endpoints_only`.

Launch readiness is resource-granular: IAM execution-policy IDs and security-policy rule IDs feed `terraform_data` readiness checkpoints, and ECS service launch waits on those checkpoints. The task-security-group objects remain independently creatable so cross-component rules can reference them without creating module dependency cycles.

## Application Load Balancer

`modules/application_load_balancer` creates zero or one shared internet-facing HTTPS ALB. Baseline includes a service in the ALB map only when the service is deployable **and** its `ingress` object is non-null.

The listener uses a caller-supplied ACM certificate and defaults to `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09`. Its default action is a fixed 404 response. Each ingress-enabled deployable service receives an `ip` target group and one explicit listener rule with at least one host-header or path-pattern condition.

The ALB module does not own Route53, ACM certificate creation, WAF, or application deployment orchestration. Its resource-backed ALB and target-group ARN suffix outputs are consumed by both ALB request-count scaling and ingress-health monitoring.

## Operational health monitoring

`modules/monitoring` owns ECS operational notification alarms separately from the AWS-managed target-tracking alarms.

A task-deficit alarm is created for every deployable service when Container Insights is enabled. It evaluates the `ECS/ContainerInsights` expression `DesiredTaskCount - RunningTaskCount` once per minute and alarms when the deficit is greater than zero for three consecutive datapoints. Both ALARM and OK transitions notify the workload SecOps SNS topic, and missing data is treated as not breaching.

An ingress unhealthy-target alarm is created for every deployable ingress service. It evaluates `AWS/ApplicationELB` `UnHealthyHostCount` with `Maximum`, using the resource-backed load-balancer and target-group ARN suffixes, and alarms when the count is greater than zero for three consecutive one-minute datapoints. Both ALARM and OK transitions notify SecOps.

Task-deficit alarms are absent when Container Insights is disabled. Ingress alarms are conditional on ingress and are validated independently of the general ALB validation stage.

v1.10 also adds a Terraform-owned EventBridge coverage-health signal for GuardDuty ECS Runtime Monitoring. The rule lives on the default event bus and matches:

```text
source      = aws.guardduty
detail-type = GuardDuty Runtime Protection Unhealthy
              GuardDuty Runtime Protection Healthy
resource    = ECS
account     = the workload account
```

The rule has exactly one target: the existing workload SecOps SNS topic. Delivery uses the shared security-notification EventBridge DLQ with three retry attempts and a maximum event age of 3600 seconds.

The input transformer preserves the workload account, Region, ECS cluster name, current and previous coverage status, GuardDuty issue text, GuardDuty update time, and EventBridge event time. This is a coverage-health notification path only; it does not implement automatic ECS/Fargate containment.
## Storage outputs and secret handling

Workload storage outputs expose non-secret RDS consumer metadata such as address, endpoint, port, database name, master username, master secret ARN, and data security-group ID. Secret values and credential-bearing DSNs are not emitted.

ECS services may reference explicitly approved Secrets Manager and SSM ARNs. The generic runtime does not create application database users, rotate application credentials, run schema migrations, or grant broad application AWS permissions.

## Application publication and release lifecycle

Application artifact delivery is implemented outside Terraform through `scripts/deployment/` and `.github/workflows/deploy-application.yml`.

The implemented flow is:

```text
registered ecs_services entry
  -> Deploy Application
  -> resolve canonical repository/platform
  -> build image
  -> publish to ECR with branch-trusted Image Publisher OIDC role
  -> resolve + re-check authoritative ECR sha256 digest
  -> separate release/PR job
  -> update only ecs_services.<service>.image_digest
  -> release PR
  -> human review/merge
  -> separate Terraform Apply workflow
  -> internal saved-plan generation
  -> protected approval
  -> exact-plan verification/application
  -> ECS convergence
  -> separate validation/evidence
```

The publisher job has AWS OIDC/ECR authority and `contents: read` only. It intentionally has no GitHub Environment because the IAM trust policy is branch-based. The release/PR job has `contents: write` and `pull-requests: write` but no AWS credentials and no `id-token`.

`update-application-digest.sh` requires the service to exist in the tracked canonical workload file and proves that the target digest is the only semantic service change. Successful image publication is not equivalent to infrastructure deployment; merge, Apply, convergence, and evidence remain separately reviewable stages.

## Plan and Apply semantics

The standalone `.github/workflows/terraform-plan.yml` and the Plan job inside `.github/workflows/terraform-apply.yml` are distinct.

The standalone Plan workflow provides informational/review plans and does not produce the binary plan consumed by Apply. `terraform-apply.yml` is self-contained: its internal Plan job creates the saved binary plan, readable plan, metadata, and checksum; the protected Apply job downloads and verifies that exact artifact and applies it without replanning.

Workload Plan/Apply paths pass and validate `DEPLOYMENT_PROFILE`. Missing or invalid deployment-profile configuration fails closed.

## Validation contract

ECS/Fargate remains inside the existing workload-baseline validation layer. There are four validation/evidence layers total and 16 validators in the workload baseline suite; v1.10 does not add a fifth layer or a seventeenth workload validator.

`validate-ecr.sh` verifies repository identity, immutable tags, KMS encryption against the exact workload ECR CMK, and the approved untagged-only lifecycle rule.

`validate-ecs-runtime.sh` remains the single workload-baseline ECS validator entry point. Its helpers under `scripts/validation/lib/ecs-runtime/` split contract, cluster, service, GuardDuty, autoscaling, ingress, alarm, and summary checks without creating another validation layer.

The runtime validator verifies:

- deployment-profile-derived Runtime Monitoring intent;
- exact live `GuardDutyManaged` cluster tag;
- exact Container Insights setting and performance log-group retention/KMS identity;
- exact live ECS service inventory;
- service steady state and completed primary rollout;
- compatible Fargate platform version;
- canonical task definition remaining application-only;
- immutable application image, logging, task networking, and conditional database/ALB relationships;
- injected GuardDuty agent state on protected running tasks;
- GuardDuty ECS coverage state;
- Application Auto Scaling targets/policies; and
- Terraform-owned ECS operational alarms.

For protected running tasks, the validator accepts the GuardDuty-injected container as either the exact `aws-gd-agent` name or an AWS-generated name beginning with `aws-guardduty-agent-`. It still requires exactly one GuardDuty agent container, requires that agent to be `RUNNING`, requires the canonical application container to remain valid, and rejects unexpected additional live containers.

GuardDuty coverage validation uses the workload detector only to call the GuardDuty coverage API. For enabled `production`/`development` clusters it requires exactly one matching ECS coverage record with:

```text
ResourceDetails.ResourceType = ECS
FargateDetails.ManagementType = AUTO_MANAGED
CoverageStatus = HEALTHY
FargateDetails.Issues = []
top-level Issue = empty
```

For `minimal`, healthy coverage is not required. A missing coverage record is valid, or a returned record must identify the expected cluster with Fargate `ManagementType = DISABLED`.

`validate-iam.sh` independently verifies exact profile-aware GuardDuty-agent ECR authority, preserves exact application ECR scope, rejects broad or unexpected ECR permissions, verifies task/execution trust separation, and rejects `iam:PassRole`.

`validate-vpc-endpoints.sh` requires the complete Terraform-owned Interface Endpoint inventory, exact Terraform/live endpoint IDs, exactly one `guardduty-data` endpoint, and reuse of that endpoint rather than a duplicate unmanaged GuardDuty endpoint.

`validate-eventbridge.sh` verifies the GuardDuty Runtime coverage rule pattern, exact SecOps SNS target, shared DLQ, retry policy, and required input-transformer evidence fields.

`validate-security-operations.sh` owns the centralized organization contract. It compares the Terraform-managed GuardDuty feature subset exactly with AWS and also fails if AWS reports any additional organization feature or additional configuration as enabled outside the Terraform-managed contract.

### v1.10 live qualification

Development qualification confirmed the implemented enabled-state path with a real Fargate service:

- `deployment_profile = development`;
- `GuardDutyManaged=true` in Terraform and live ECS;
- Fargate platform `1.4.0`;
- one GuardDuty agent injected and `RUNNING`;
- application container still valid and service at steady state;
- GuardDuty management type `AUTO_MANAGED`;
- GuardDuty ECS coverage `HEALTHY`;
- zero unresolved coverage issues;
- the unique Terraform-owned `guardduty-data` endpoint reused;
- exact GuardDuty-agent ECR scope retained; and
- the full workload validation suite passing `16/16`.

The same qualification cycle also corrected the profile-aware AWS Backup contract discovered during live validation: lower-cost disabled profiles retain the encrypted backup vault while omitting the backup plan/selection and applying `Backup=false` to workload EC2/RDS resources.

Generated evidence packages remain the authoritative per-run record. These validation results support deployment and audit readiness; they do not represent SOC 2 or ISO 27001 certification.
## Central security boundary

Inspector ECR scanning remains workload-local under `modules/security`. Central GuardDuty organization ownership remains in `bootstrap/security_operations/security_services`.

The implemented v1.10 centralized GuardDuty organization contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

Workload Terraform does not create or manage GuardDuty detectors or organization features. It consumes the centralized policy by expressing cluster participation, supplying exact task-execution IAM, owning the required networking, and validating workload-local runtime state.

The security-operations validator treats Terraform's resource-backed feature output as the canonical managed feature set. AWS may return other supported GuardDuty organization features; those additional features are acceptable only when their `auto_enable` value and all additional configurations are `NONE`.
## GuardDuty Fargate Runtime Monitoring contract

GuardDuty Runtime Monitoring for Fargate is a cluster/runtime security
capability, not a per-service application setting. It does not add fields to the
canonical `ecs_services` map.

### Terraform and GuardDuty ownership

Terraform owns the policy and prerequisites that determine whether Runtime
Monitoring operates:

- centralized GuardDuty organization Runtime Monitoring configuration;
- centralized Fargate automated-agent management configuration;
- deployment-profile defaults;
- ECS cluster `GuardDutyManaged` intent;
- task execution IAM;
- ECR/S3/`guardduty-data` networking;
- validation expectations.

GuardDuty service-manages the runtime artifacts produced by that
Terraform-owned policy:

- `aws-gd-agent` injection;
- GuardDuty agent updates;
- runtime telemetry collection.

Those service-managed artifacts intentionally do not have separate Terraform
resource addresses. The model is comparable to Application Auto Scaling:
Terraform owns the scaling policy while AWS directly lifecycle-manages the
target-tracking CloudWatch alarms created from that policy.

### Organization-wide secure default

The v1.10 centralized GuardDuty contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

Enabling Fargate automated agent management centrally makes runtime protection
the organization default for existing and future member accounts.

### Deployment-profile policy

Fargate Runtime Monitoring is a cost-sensitive security control and therefore
follows the existing `deployment_profile` model instead of adding a new
standalone top-level enable/disable variable.

The implemented defaults are:

| `deployment_profile` | Fargate Runtime Monitoring | ECS cluster intent |
|---|---:|---|
| `production` | Enabled | `GuardDutyManaged=true` |
| `development` | Enabled | `GuardDutyManaged=true` |
| `minimal` | Disabled | `GuardDutyManaged=false` |

Conceptually:

```hcl
profile_default_guardduty_fargate_runtime_monitoring_enabled = (
  !local.is_minimal_profile
)
```

`development` remains protected because it is the lower-cost qualification
environment for the production security architecture, not an intentionally
insecure sandbox. `minimal` carries the explicit exclusion because that profile
already trades selected security/availability services for the lowest-cost
private AWS-only footprint.

The first v1.10 implementation does not introduce an independent public
`guardduty_fargate_runtime_monitoring_enabled` variable. If adopters later
demonstrate a legitimate requirement for an override, it can use the existing
nullable-override pattern without changing the profile defaults.

### Cluster enrollment intent

The Terraform-managed workload ECS cluster expresses the effective
deployment-profile policy explicitly with the AWS-defined `GuardDutyManaged`
tag:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

Even though centralized Fargate automated-agent management is `ALL`, explicitly
setting `GuardDutyManaged=true` on protected baseline clusters preserves a
resource-level desired state and avoids relying solely on implicit account-wide
behavior. `GuardDutyManaged=false` is the deliberate minimal-profile exclusion.

The setting applies to the single Terraform-managed ECS cluster and does not
change the canonical `ecs_services` schema, application image ownership,
Application Auto Scaling ownership, or deployment-health semantics.

### Terraform-owned GuardDuty networking

Terraform continues to own workload networking. The existing `guardduty-data`
Interface VPC Endpoint is the authoritative Runtime Monitoring telemetry
endpoint. GuardDuty must reuse that endpoint and must not create a second VPC
endpoint or endpoint security group.

The existing private runtime paths remain:

```text
ECS task SG
  -> ecr.api / ecr.dkr Interface Endpoints
  -> S3 Gateway Endpoint
  -> guardduty-data Interface Endpoint
```

Fargate tasks continue to use `awsvpc`, compute-private subnets, and
`assign_public_ip = false`.

### Task execution IAM

The ECS task execution role remains least privilege. Existing application image
pulls remain scoped to the application's Terraform-owned ECR repositories.

When the effective profile enables Runtime Monitoring (`production` or
`development`), Terraform adds only the additional pull scope required for the
AWS-hosted `aws-guardduty-agent-fargate` repository while preserving the
existing action set:

```text
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

The additional repository-scoped GuardDuty-agent permissions must be absent for
the `minimal` profile.

Baseline implements a Region-to-GuardDuty-agent-account mapping and derives one exact regional repository ARN of the form:

```text
arn:<partition>:ecr:<region>:<guardduty-agent-account-id>:repository/aws-guardduty-agent-fargate
```

Broad ECR administrative authority and repository wildcards are not part of the contract.

### Agent injection and rollout

GuardDuty owns injection and lifecycle of the `aws-gd-agent` sidecar. Terraform
does not add that container to the canonical ECS task definition.

New protected tasks must expose exactly one injected GuardDuty agent container and report it as `RUNNING`. Live ECS responses may use the exact `aws-gd-agent` name or an AWS-generated `aws-guardduty-agent-<suffix>` name; validation accepts both forms while preserving the one-agent requirement. Existing running Fargate tasks are not silently retrofitted, so brownfield adoption requires one deliberate new service deployment after central configuration, IAM, networking, and cluster intent converge.

Terraform must not permanently set forced-deployment behavior merely to obtain
GuardDuty agent injection.

For a fresh baseline deployment with central Fargate agent management already
enabled, the first ECS service deployment should receive GuardDuty
instrumentation from initial task launch.

### Cost-conscious design

GuardDuty Runtime Monitoring adds monitored-vCPU cost and consumes task
resources for the injected security sidecar. The baseline treats that as a
deployment-profile tradeoff rather than a per-service application decision:

- `production`: Runtime Monitoring enabled;
- `development`: Runtime Monitoring enabled so qualification matches the
  production runtime-security architecture;
- `minimal`: Runtime Monitoring disabled to preserve the lowest-cost profile.

The baseline does not automatically inflate application task CPU/memory
settings to compensate for the sidecar. Live qualification uses Container
Insights to observe agent overhead and documents practical sizing implications.

### Validation ownership

Security-operations validation owns the centralized GuardDuty contract:

```text
RUNTIME_MONITORING = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT = ALL
EKS_ADDON_MANAGEMENT = NONE
```

Workload ECS runtime validation owns the effective profile and cluster/runtime
contract.

For `production` and `development`, validation proves:

- effective Runtime Monitoring enabled;
- exact `GuardDutyManaged=true`;
- compatible Fargate platform version;
- exact GuardDuty-agent ECR pull scope;
- existing application ECR scope preserved;
- required ECR, S3, and `guardduty-data` connectivity;
- exactly one Terraform-owned `guardduty-data` endpoint;
- `aws-gd-agent` present on newly deployed tasks;
- `aws-gd-agent` `RUNNING`;
- healthy GuardDuty ECS/Fargate coverage.

For `minimal`, validation proves:

- effective Runtime Monitoring disabled;
- exact `GuardDutyManaged=false`;
- no GuardDuty-agent ECR repository scope;
- absence of injected GuardDuty sidecars is valid;
- healthy GuardDuty ECS/Fargate coverage is not required.

`validate-ecs-runtime.sh` remains the single workload-baseline ECS validator
entry point. v1.10 does not create a seventeenth validator or a fifth
validation/evidence layer.

### Containment remains separate

Automatic ECS/Fargate task containment is outside the v1.10 Runtime Monitoring
contract and requires a separate response design. Runtime detection and coverage
must not be coupled to an unproven containment mechanism.

## Deferred beyond v1.10.0

The following capabilities remain outside the v1.10 Runtime Monitoring release boundary:

- fail-closed ECS task containment/remediation
- ReconoSense reference deployment

Other potential extensions include scheduled/run-to-completion task abstractions, first-class Route53/ACM ownership, WAF, audited ECS Exec, multi-container services, application database-user lifecycle, Windows Fargate, and more sophisticated historical ECR retention.

No `modules/ecs_task` module is part of the current architecture.