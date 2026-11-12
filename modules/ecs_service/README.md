# ECS Service Module

## Overview

The `ecs_service` module creates the deployable ECS/Fargate service runtime for a workload environment.

Each configured service receives its own:

- ECS task security group
- CloudWatch Logs log group
- ECS task definition
- ECS service

The module is designed for long-running Fargate services with one primary application container and optional generic sidecars, using private `compute_private` subnets, digest-pinned container images, per-service IAM roles, KMS-encrypted CloudWatch log groups, optional Application Load Balancer target-group integration, configurable deployment-health settings, optional ECS-native container health checks, and optional ECS Service Auto Scaling.

Services are keyed by stable service name through the `services` map.

The low-level `services` map consumes already-resolved runtime values; operators normally configure the canonical `ecs_services` map in `environments/<env>/container-workloads.auto.tfvars.json`. Do not confuse module inputs with baseline profile defaults.

A service is either:

- **fixed-count** when `scaling = null`; Terraform owns `desired_count`; or
- **autoscaled** when `scaling` is non-null; `desired_count` is bootstrap capacity and Application Auto Scaling owns subsequent desired-count changes.

The module keeps those service classes on separate `aws_ecs_service` resources because Terraform lifecycle `ignore_changes` cannot be selected conditionally per `for_each` instance.

## Resources Created

For every entry in `services`, the module creates:

- One `aws_security_group.task_security_groups` instance
- One `aws_cloudwatch_log_group.service_logs` instance
- One `aws_ecs_task_definition.task_definitions` instance
- Exactly one ECS service:
  - `aws_ecs_service.services` for fixed-count services; or
  - `aws_ecs_service.autoscaled_services` for autoscaled services

For each autoscaled service, the module also creates:

- One `aws_appautoscaling_target.ecs_services` instance
- Zero or one CPU target-tracking policy
- Zero or one memory target-tracking policy
- Zero or one ALB request-count target-tracking policy

At least one target-tracking metric is required by the canonical baseline contract whenever scaling is configured.

The module creates shared `terraform_data` readiness resources for execution policies and security-group rules, plus per-service readiness instances for configured application task-role policy attachments:

- `terraform_data.ecs_execution_policy_ready`
- `terraform_data.ecs_security_policy_ready`
- `terraform_data.ecs_task_role_policy_ready[service]` only for keys in `task_role_policy_attachment_ids`

Application Auto Scaling creates and manages the CloudWatch alarms associated with target-tracking policies. Those AWS-managed alarms are not Terraform-owned operational alarms and are not repurposed by this module.

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct ECS service resources. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `primary_region` | `string` | Yes | — | Region used by the `awslogs` configuration. Baseline supplies the active provider region; this input does not configure an AWS provider or state backend. |
| `vpc_id` | `string` | Yes | — | VPC ID used when creating ECS task security groups. |
| `cluster_arn` | `string` | Yes | — | ARN of the ECS cluster that hosts the services. |
| `cluster_name` | `string` | Yes | — | ECS cluster name used to construct Application Auto Scaling resource IDs. |
| `compute_private_subnet_ids` | `set(string)` | Yes | — | Compute-private subnet IDs used by Fargate tasks. |
| `cloudwatch_retention_days` | `number` | Yes | — | Retention period for ECS CloudWatch log groups. |
| `platform_version` | `string` | No | `"LATEST"` | AWS Fargate platform version used by ECS services. |
| `services` | `map(object(...))` | No | `{}` | Deployable ECS/Fargate services keyed by stable service name. |
| `logs_cmk_arn` | `string` | Yes | — | ARN of the customer-managed KMS key used to encrypt ECS CloudWatch log groups. |
| `execution_policy_ids` | `map(string)` | No | `{}` | ECS task execution IAM policy IDs keyed by service name and used as launch-readiness dependencies. |
| `task_role_policy_attachment_ids` | `map(set(string))` | No | `{}` | Optional task-role managed-policy attachment IDs keyed by opted-in service; launch-readiness dependency only. |
| `security_policy_rule_ids` | `map(set(string))` | No | `{}` | Cross-component security-group rule IDs keyed by service name and used as launch-readiness dependencies. |
| `availability_zone_rebalancing` | `string` | No | `null` | Explicit ECS service AZ rebalancing: `ENABLED`, `DISABLED`, or `null`. Baseline supplies `ENABLED` for production and `null` otherwise. |
| `force_delete` | `bool` | Yes | — | Whether ECS service deletion may bypass first scaling the service to zero. Baseline supplies `false` for production, including retirement, and `true` otherwise. |

`execution_policy_ids` and `security_policy_rule_ids` default to empty maps but must each contain every configured service key. A non-empty `services` map therefore needs matching readiness inputs. `task_role_policy_attachment_ids` may contain only opted-in services; every supplied key must exist in `services`. Baseline supplies it from IAM attachment outputs, and an empty map creates no task-policy readiness instances.

## Service Configuration

The `services` map is keyed by stable ECS service name.

Example **non-production** autoscaled ingress service, showing only the `services` input. Replace the illustrative image and resource identifiers and supply the other required module inputs and readiness maps; this is not a complete module call:

```hcl
services = {
  api = {
    image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/tf-secure-baseline-dev-api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    container_port = 8080
    cpu            = 512
    memory         = 1024
    desired_count  = 1

    scaling = {
      min_capacity               = 1
      max_capacity               = 4
      cpu_target_percent         = 50
      memory_target_percent      = 60
      alb_requests_per_target    = 1000
      scale_in_cooldown_seconds  = 60
      scale_out_cooldown_seconds = 60
    }

    deployment = {
      minimum_healthy_percent           = 100
      maximum_percent                   = 200
      health_check_grace_period_seconds = 120
    }

    execution_role_arn = "arn:aws:iam::123456789012:role/example-api-ecs-execution"
    task_role_arn      = "arn:aws:iam::123456789012:role/example-api-ecs-task"

    target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/example/0123456789abcdef"

    alb_request_resource_label = "app/example-alb/0123456789abcdef/targetgroup/example/0123456789abcdef"

    cpu_architecture = "X86_64"

    environment_variables = {
      APP_ENV = "dev"
    }

    secrets = {
      DATABASE_PASSWORD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-AbCdEf"
    }
  }
}
```

Each service entry supports:

| Field | Type | Required | Default | Description |
|---|---|---:|---|---|
| `image` | `string` | Yes | — | Container image reference. Must be pinned to a SHA-256 digest. |
| `container_port` | `number` | Yes | — | Container and host port exposed by the task. |
| `cpu` | `number` | Yes | — | Fargate task CPU allocation. |
| `memory` | `number` | Yes | — | Fargate task memory allocation in MiB. |
| `desired_count` | `number` | No | `1` | Fixed desired count, or bootstrap count when `scaling` is configured. |
| `scaling` | `object(...)` | No | `null` | Optional Application Auto Scaling configuration. `null` means no scaling target or policy is created. |
| `deployment` | `object(...)` | No | `{}` | ECS deployment-health configuration. |
| `health_check` | `object(...)` | No | `null` | Optional ECS-native container health command and timing; omitted from task definitions when null. |
| `execution_role_arn` | `string` | Yes | — | ECS task execution-role ARN. |
| `task_role_arn` | `string` | Yes | — | Application task-role ARN. |
| `target_group_arn` | `string` | No | `null` | Optional ALB target-group ARN. |
| `alb_request_resource_label` | `string` | No | `null` | Resource label used by `ALBRequestCountPerTarget`; required together with `target_group_arn` when ALB request scaling is configured. |
| `cpu_architecture` | `string` | No | `"X86_64"` | Task CPU architecture. Supported values are `X86_64` and `ARM64`. |
| `environment_variables` | `map(string)` | No | `{}` | Plaintext environment variables supplied to the container. |
| `secrets` | `map(string)` | No | `{}` | Container secret names mapped to Secrets Manager or SSM Parameter Store references. |
| `sidecars` | `map(object(...))` | No | `{}` | Up to nine additional containers keyed by container name; see multi-container configuration below. |
| `depends_on` | `list(object(...))` | No | `[]` | Primary-container prerequisites, each with `container_name` and `condition`. |
| `task_volumes` | `set(string)` | No | `[]` | Named task-local volumes available to primary and sidecar mount points. |
| `mount_points` | `list(object(...))` | No | `[]` | Primary mounts with `source_volume`, `container_path`, and optional `read_only` (default `false`). |
| `ephemeral_storage_gib` | `number` | No | `null` | Optional task storage override: whole GiB, 21–200; null emits no override. |
| `start_timeout_seconds` / `stop_timeout_seconds` | `number` | No | `null` | Optional primary-container start/stop timeouts: whole seconds, 2–120. |

### Multi-container configuration

M1 preserves the primary container's service-key name, `essential = true`, and single TCP `container_port`. An omitted/empty `sidecars` map preserves the single-container definition. Sidecar names must differ from the primary and contain 1–255 letters, numbers, underscores, or hyphens. The maximum is nine Terraform-configured sidecars, or ten declared containers including the primary. GuardDuty-managed injection is separate from this declared inventory.

Each `sidecars.<name>` object supports:

| Field | Default | Usage and limits |
|---|---|---|
| `image` | Required | Complete digest-pinned image reference; the same integrity rules apply to the primary and sidecars. |
| `essential` | `true` | Set `false` for a prerequisite used with `COMPLETE` or `SUCCESS`. |
| `cpu_units` | `null` | Optional whole CPU units, at least 1 and less than task `cpu`. |
| `memory_limit_mib` | `null` | Optional whole MiB hard limit, at least 6 and no greater than task `memory`. |
| `memory_reservation_mib` | `null` | Optional whole MiB soft reservation, at least 6 and less than task `memory`; a configured hard limit must exceed it. |
| `environment_variables` / `secrets` | `{}` / `{}` | Per-container plaintext values and external secret references; a sidecar cannot use the same name in both maps. |
| `command` / `entry_point` | `null` / `null` | Ordered overrides; each configured list must contain at least one element and no null/blank elements. Null leaves the image default in effect. |
| `port_mappings` | `[]` | Objects with whole `container_port` (1–65535) and `protocol` (`tcp` by default, or `udp`); host port equals container port. |
| `read_only_root_filesystem` | `null` | Optional boolean rendered as `readonlyRootFilesystem`; null omits the field. |
| `health_check` | `null` | Same command/timing object and validation as the primary health check described below. |
| `start_timeout_seconds` / `stop_timeout_seconds` | `null` / `null` | Optional whole-second timeouts, 2–120. |
| `dependency_rank` | `0` | Nonnegative whole number used to validate dependency direction; it is not an ECS container field. |
| `depends_on` | `[]` | Prerequisites with `container_name` and `condition`, restricted as described below. |
| `mount_points` | `[]` | Objects with `source_volume`, `container_path`, and optional `read_only` (default `false`). |

The service's `cpu` and `memory` fields size the **whole task**. This module exposes per-container CPU/memory settings, command/entry-point overrides, and root-filesystem mode only for sidecars. Configured sidecar CPU units must sum to less than task CPU. The sum of each sidecar's memory reservation, falling back to its hard limit when no reservation is supplied, must remain below task memory. Omitted values are not automatic per-container budgets; size the task for the complete workload and any injected runtime agent.

Dependencies use `START`, `HEALTHY`, `COMPLETE`, or `SUCCESS`. Primary-container `depends_on` may reference existing sidecars. A sidecar may depend only on another sidecar with a **strictly lower** `dependency_rank`; it cannot depend on itself or the primary. Duplicate prerequisite names are rejected. `HEALTHY` requires a configured health check on the prerequisite; `COMPLETE` and `SUCCESS` require that prerequisite to be nonessential. Ranks constrain the graph to prevent cycles; rank alone does not create a dependency.

All declared port numbers must be unique across the task, even across different protocols. Optional ALB attachment still targets only the primary container; sidecar port mappings do not create ALB routes or security-group rules. All containers share task networking and task-level IAM roles.

`task_volumes` declares name-only, task-local volumes; volume names follow the same character/length rule as sidecar names. Mounts must reference a declared volume and use unique canonical absolute non-root destinations within each container: no `.`/`..` or empty path components, repeated/trailing separators, or surrounding whitespace. This interface does not configure EFS, host paths, or persistent storage.

The platform validation admits dependencies, start/stop timeouts, and secret injection with `LATEST`, `1.3.0`, or `1.4.0`. Explicit ephemeral storage, ARM64, tasks with at least 8 vCPUs, and Secrets Manager selectors require `LATEST` or `1.4.0`.

These are low-level `services` inputs. The canonical baseline `ecs_services` interface uses `repository_name` and `image_digest` for each container and separate `secrets_manager_secrets` / `ssm_parameters` maps; baseline resolves these to `image` and `secrets`. See the [runtime design](../../docs/ecs-runtime-design.md#ecs-services-and-task-definitions) for composition and the [native multi-container fixture](tests/multi_container.tftest.hcl) for a complete low-level configuration example.

### Scaling configuration

When `scaling` is non-null, the object supports:

| Field | Type | Required | Default | Description |
|---|---|---:|---|---|
| `min_capacity` | `number` | Yes | — | Minimum ECS task count registered with Application Auto Scaling. |
| `max_capacity` | `number` | Yes | — | Maximum ECS task count registered with Application Auto Scaling. |
| `cpu_target_percent` | `number` | No | `null` | Target value for `ECSServiceAverageCPUUtilization`. |
| `memory_target_percent` | `number` | No | `null` | Target value for `ECSServiceAverageMemoryUtilization`. |
| `alb_requests_per_target` | `number` | No | `null` | Target value for `ALBRequestCountPerTarget`. |
| `scale_in_cooldown_seconds` | `number` | No | `300` | Target-tracking scale-in cooldown. |
| `scale_out_cooldown_seconds` | `number` | No | `300` | Target-tracking scale-out cooldown. |

The canonical `baseline` interface enforces that:

- `min_capacity >= 1` during normal operation (`0` is accepted when retirement mode is enabled)
- `max_capacity >= min_capacity`
- `desired_count` falls within the configured capacity range
- at least one target-tracking metric is configured
- configured target values are greater than zero
- cooldown values are zero or greater
- `alb_requests_per_target` is used only with configured ingress

The low-level module requires both `target_group_arn` and `alb_request_resource_label` when ALB request-count scaling is configured. It does not independently reproduce all canonical baseline scaling or production-profile checks. For deployable services in normal production, baseline additionally requires fixed `desired_count >= 2` or autoscaled `min_capacity >= 2`; registered entries with a null digest are excluded from that production minimum check.

### Deployment configuration

The optional `deployment` object supports:

| Field | Type | Required | Default | Description |
|---|---|---:|---|---|
| `minimum_healthy_percent` | `number` | No | `100` | Minimum healthy task percentage ECS maintains during deployment. |
| `maximum_percent` | `number` | No | `200` | Maximum task percentage ECS may run during deployment. |
| `health_check_grace_period_seconds` | `number` | No | `0` | Time after task startup during which ECS ignores unhealthy load-balancer, VPC Lattice, and container health checks. |

The canonical baseline validates the deployment percentages and grace-period range before passing deployable services to this module.

### Native container health configuration

The primary and each sidecar support the same optional `health_check` object at
the canonical `ecs_services` interface and this module's `services` interface:

```hcl
health_check = {
  command      = ["CMD", "/app/healthcheck"]
  interval     = 30
  timeout      = 5
  retries      = 3
  start_period = 10
}
```

This belongs inside an existing service or sidecar entry. Supply an actual image executable
that returns 0 for the intended healthy condition; the module supplies no probe
binary. `CMD` requires an executable and optional arguments. `CMD-SHELL` requires
exactly two elements: the marker and one shell command; the image must support it.
All command elements must be non-null and nonempty after trimming whitespace.

| Field | Default | Accepted values |
|---|---:|---|
| `command` | Required when enabled | `CMD` with at least one executable element, or `CMD-SHELL` with exactly one command element |
| `interval` | 30 | Whole seconds, 5–300 |
| `timeout` | 5 | Whole seconds, 2–60 |
| `retries` | 3 | Whole number, 1–10 |
| `start_period` | 0 | Whole seconds, 0–300 |

The task definition conditionally merges `healthCheck` and maps `start_period`
to ECS `startPeriod`. Null/omitted configuration emits no `healthCheck`; changing
an enabled check revises the task definition. This is separate from service
`deployment.health_check_grace_period_seconds`, ALB target health and GuardDuty.
Baseline's `ecs_service_configuration` output includes the normalized object only
when enabled. The baseline still filters `image_digest = null` registrations out
of this low-level deployable map.

Runtime validation compares exact health configuration, normalizing an omitted
live `startPeriod` to zero. It polls primary-container health before strict
service rollout convergence: 13 observations five seconds apart by default.
`ECS_NATIVE_HEALTH_MAX_ATTEMPTS` accepts 1–60 and
`ECS_NATIVE_HEALTH_POLL_INTERVAL_SECONDS` accepts 0–60. Observed `UNHEALTHY` fails;
unresolved/missing health fails at the polling bound. Zero desired/running/pending
capacity is skipped; disabled checks add no native-health task queries.
Sidecar health-check definitions are compared as part of the complete task-definition inventory; the validator does not add independent sidecar health/lifecycle polling. ALB and GuardDuty validation still apply independently. See the
[validation reference](../../scripts/validation/README.md) for evidence boundaries.

## Image Integrity

Every primary and sidecar image must be digest-pinned using:

```text
repository@sha256:<64 lowercase hexadecimal characters>
```

Tag-only references such as:

```text
repository:latest
repository:v1.2.3
```

are rejected by input validation. The repository portion must be nonempty, with no whitespace or extra `@`; the digest must be exactly 64 lowercase hexadecimal characters with no suffix. Registry ports, nested repository paths, and a tag before the digest are allowed by the low-level interface. Baseline composition uses its managed ECR repository URLs.

This ensures that Terraform-managed deployments reference an immutable container image digest rather than a mutable tag.

## Fargate Runtime

Task definitions use:

```hcl
requires_compatibilities = ["FARGATE"]
network_mode             = "awsvpc"
```

The runtime platform is fixed to Linux:

```hcl
operating_system_family = "LINUX"
```

Each service may select:

```text
X86_64
ARM64
```

through `cpu_architecture`.

The module validates Linux Fargate task sizes from 0.25 through 32 vCPUs. For
`cpu = 32768` (32 vCPUs), `memory` must be exactly `61440`, `122880`, or `249856`
MiB (60, 120, or 244 GiB). Existing smaller task-size combinations remain
supported. As with all tasks of at least 8 vCPUs, 32-vCPU tasks require platform
`1.4.0` or `LATEST`. See [AWS Fargate task sizes](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task_definition_parameters.html#task_size).

The Fargate platform version defaults to `LATEST`, but it can be explicitly set to a specific version.

## Task Networking

Every ECS service receives its own task security group.

The security-group object is owned by this module, but this module intentionally creates no ingress or egress rules on it.

Cross-component security rules are owned by `modules/networking/security_policy`, including relationships such as:

```text
ALB SG -> ECS task SG
ECS task SG -> Interface Endpoint SG
ECS task SG -> S3 managed prefix list
ECS task SG -> database SG
```

Fargate services run in the supplied compute-private subnets with:

```hcl
assign_public_ip = false
```

Baseline supplies only its compute-private subnets. The module sets `assign_public_ip = false`, but a direct caller remains responsible for supplying the intended subnet set; the input itself is not an AZ/subnet-role discovery mechanism.

## CloudWatch Logging

Each service receives a deterministic CloudWatch Logs log group:

```text
/aws/ecs/${var.name_prefix}/${service_name}
```

The log group:

- Uses the configured `cloudwatch_retention_days`
- Is encrypted with the customer-managed KMS key supplied through `logs_cmk_arn`
- Is referenced directly by the service's ECS task definition

Container logging uses the `awslogs` driver:

```hcl
logDriver = "awslogs"
```

with:

```text
awslogs-group
awslogs-region
awslogs-stream-prefix
```

configured explicitly.

The log-driver mode is explicitly set to:

```text
non-blocking
```

The primary and every configured sidecar receive this logging configuration, sharing the service log group and `ecs` stream prefix with container-specific streams. There is no per-sidecar log-driver or log-group override. The module does not enable `awslogs-create-group`; Terraform owns creation of the log groups.

## Container Environment and Secrets

Plaintext runtime configuration may be supplied through:

```hcl
environment_variables = {
  APP_ENV = "dev"
}
```

Secret values are not stored directly in the service definition.

Instead, `secrets` maps container environment-variable names to external secret or parameter references:

```hcl
secrets = {
  DATABASE_PASSWORD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example-AbCdEf"
}
```

The primary and each sidecar use their own maps. The task definition passes references through the ECS `secrets` container-definition field. Secrets Manager requires a full secret ARN (including its six-character suffix); optional JSON-key/version selector syntax is preserved, and version stage and version ID cannot both be selected. SSM accepts exact parameter ARNs or same-region names/paths at this low-level interface. Wildcard references are rejected. The canonical baseline interface requires SSM ARNs for IAM derivation.

IAM permissions required for ECS to retrieve those values remain owned by `modules/iam`.

## IAM Ownership

This module does not create ECS IAM roles.

Each service consumes:

- `execution_role_arn`
- `task_role_arn`

The execution role is used by the ECS/Fargate runtime for platform-level actions such as image pulls, logging, and explicitly configured task-definition secret retrieval.

The task role represents application-runtime AWS permissions. The primary and all sidecars share the same task role and execution role; there is no per-container IAM isolation. Baseline derives execution-role ECR and secret/parameter scope from all configured containers, while startup-secret KMS keys remain explicitly supplied at service level. Secrets Manager selectors stay in the task definition but are stripped to the base secret ARN for IAM resource scope.

Both roles remain owned by `modules/iam` in baseline composition. The canonical `task_role_managed_policy_arns` set is attached there, only to the application role; this module consumes the role ARN and optional attachment readiness IDs. It does not author IAM policies or attach execution-role managed policies. Application permissions remain empty by default; policy content/effective authorization is an application-owner responsibility.

## Launch Readiness

ECS services must not launch before their execution IAM policies, configured application task-role managed-policy attachments, and cross-component security-group rules exist.

The module uses:

```text
terraform_data.ecs_execution_policy_ready
terraform_data.ecs_task_role_policy_ready
terraform_data.ecs_security_policy_ready
```

as explicit readiness dependencies.

Both `aws_ecs_service.services` and `aws_ecs_service.autoscaled_services` depend on all three readiness collections. Empty task-policy maps create no per-service readiness instances.

The corresponding variables are keyed by the same stable service names as `services`:

```hcl
execution_policy_ids = {
  api = "..."
}

security_policy_rule_ids = {
  api = [
    "...",
    "...",
  ]
}
```

Input validation requires execution-policy and security-policy readiness-map coverage for every configured ECS service. Optional task-policy attachment keys need only identify configured services. Dependency ordering does not by itself verify IAM policy content or live network connectivity; those are separate validation concerns.

This pattern preserves resource-granular dependency ordering:

```text
Task SG
   |
   v
Cross-component SG rules
   |
   v
Security-policy readiness
   |
   +------------------+
                      |
IAM execution policy |
   |                  |
   v                  v
IAM readiness ---> ECS service launch
```

It avoids making the entire ECS service module depend on the security-policy module, which would otherwise create a Terraform dependency cycle because security policy itself consumes ECS task security-group IDs.

## Desired-Count and Auto Scaling Ownership

Fixed-count and autoscaled services intentionally use separate Terraform resources.

### Fixed-count services

When:

```hcl
scaling = null
```

the service is created through `aws_ecs_service.services`, and Terraform owns:

```hcl
desired_count = each.value.desired_count
```

A later Terraform plan therefore reconciles the live desired count back to the configured value if it has changed.

### Autoscaled services

When `scaling` is non-null, the service is created through `aws_ecs_service.autoscaled_services`.

`desired_count` is used only as bootstrap capacity. The resource has:

```hcl
lifecycle {
  ignore_changes = [
    desired_count,
  ]
}
```

After creation, Application Auto Scaling owns legitimate desired-count changes. Terraform must not reassert the bootstrap value after a scale-out or scale-in event.

Each autoscaled service receives an `aws_appautoscaling_target` for:

```text
service/<cluster_name>/<ecs-service-name>
```

with:

```text
service_namespace  = ecs
scalable_dimension = ecs:service:DesiredCount
```

Target-tracking policies are created only for the metrics configured on the service:

- `ECSServiceAverageCPUUtilization`
- `ECSServiceAverageMemoryUtilization`
- `ALBRequestCountPerTarget`

The module uses the target-tracking model. Step scaling and scheduled scaling actions are not implemented by this module.

Changing a service between fixed-count and autoscaled modes changes its Terraform resource address. This module contains no automatic state-migration instruction for that transition; review the actual plan rather than assuming an in-place mode change.

AWS creates CloudWatch alarms for target-tracking policies. Those alarms remain AWS-managed and are separate from the Terraform-owned operational alarms created by `modules/monitoring`.

## Optional Load Balancer Integration

A service may optionally provide:

```hcl
target_group_arn = "..."
```

When present, the ECS service attaches to that target group using:

- The service name as the container name
- The configured `container_port`

When `target_group_arn` is `null`, no ECS load-balancer block is created.

ALB request-count scaling also requires:

```hcl
alb_request_resource_label = "..."
```

The canonical baseline derives this label from Terraform-owned ALB and target-group ARN suffix outputs:

```text
<load-balancer-arn-suffix>/<target-group-arn-suffix>
```

The label is therefore resource-backed rather than reconstructed from names in shell tooling.

The Application Load Balancer, target groups, listeners, listener rules, and ARN-suffix outputs remain owned by `modules/application_load_balancer`.

## Deployment Behavior

Both fixed-count and autoscaled ECS services apply the configured deployment-health settings directly to the ECS service:

```hcl
deployment_minimum_healthy_percent = each.value.deployment.minimum_healthy_percent
deployment_maximum_percent         = each.value.deployment.maximum_percent
health_check_grace_period_seconds  = each.value.deployment.health_check_grace_period_seconds
```

Defaults from the service contract are:

```text
minimum_healthy_percent           = 100
maximum_percent                   = 200
health_check_grace_period_seconds = 0
```

`health_check_grace_period_seconds` is the period after task startup during which ECS ignores unhealthy load-balancer, VPC Lattice, and container health checks.

ECS services also use the deployment circuit breaker with automatic rollback:

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

These flags enable the ECS deployment circuit breaker and request rollback. They are not proof that a particular rollback has executed successfully; retain runtime evidence for that claim.

## Production Availability

The baseline selects three standard AZs by default and supplies all effective compute-private subnets. Both ECS service resources receive `availability_zone_rebalancing = "ENABLED"` under the production profile. A direct module caller can supply `ENABLED`, `DISABLED`, or `null`; `null` is not a claim that AWS reports `DISABLED`.

The production minimum is **two**, not three: canonical input validation requires at least two fixed tasks or an autoscaling minimum of two for digest-selected services outside retirement. The shipped production sample chooses three tasks. Neither the number of configured subnets nor rebalancing intent proves one live task per AZ; use live task placement evidence when that distribution is required.

The normal production runtime validator additionally requires `minimum_healthy_percent = 100`, `maximum_percent >= 200`, and AZ rebalancing `ENABLED`, alongside the capacity minimum. The canonical Terraform input validation checks the general percentage ranges; do not describe all of the validator's stricter production checks as low-level module input constraints.

## Development/Test Destruction Posture

There is no longer a hard-coded `force_delete = true` for every service. Both ECS service resources consume the required `force_delete` input:

| Baseline posture | `force_delete` |
|---|---:|
| Normal production | `false` |
| Production retirement | `false` |
| Development/minimal | `true` |

The module has no `prevent_destroy` guard. `force_delete=false` is not a blanket prohibition on deleting a service; the approved production path first proves the service is quiesced.

### Production retirement

Baseline keeps the canonical service entry and selected digest, but derives runtime `desired_count=0`; for autoscaled services it also derives `min_capacity=0` and `max_capacity=0`. Do not delete the canonical service or set its digest to `null` as a substitute for Stage-1 retirement: that removes resources rather than preparing an in-place retirement plan.

The autoscaled resource retains `ignore_changes=[desired_count]` during retirement. Setting the derived bootstrap value to zero is not independent proof that live desired count was changed. The retirement-readiness script checks the actual ECS `desiredCount`, `runningCount`, and `pendingCount` are all zero, along with zero live scaling bounds and the absence of scheduled scaling actions for the relevant targets.

Use the [production retirement runbook](../../docs/production-retirement.md), not normal-operation runtime validation, to qualify the zero-capacity retirement posture. The complete durable-cleanup workflow is limited to the `prod` environment even though baseline production policy is profile-driven.

## Tags

Where supported, resources receive the standard workload tags:

```text
Name
Environment
Terraform
```

## Outputs

The module exposes the following outputs.

### `task_security_group_ids`

Task security-group IDs keyed by service name.

Example:

```hcl
task_security_group_ids = {
  api    = "sg-0123456789abcdef0"
  worker = "sg-0fedcba9876543210"
}
```

These IDs are intended for consumption by `modules/networking/security_policy`.

### `log_groups`

CloudWatch log-group metadata keyed by service name.

Each entry contains:

```text
arn
name
```

### `task_definition_arns`

ECS task-definition ARNs keyed by service name.

### `services`

ECS service metadata keyed by service name. The output merges fixed-count and autoscaled service resources into one stable map.

Each entry contains:

```text
arn
name
platform_version
deployment_minimum_healthy_percent
deployment_maximum_percent
health_check_grace_period_seconds
availability_zone_rebalancing
```

### `autoscaling_targets`

Application Auto Scaling target metadata keyed by autoscaled ECS service name.

Each entry contains:

```text
arn
resource_id
min_capacity
max_capacity
scalable_dimension
service_namespace
```

### `autoscaling_cpu_policies`

CPU target-tracking policy metadata keyed by service name.

Each entry includes policy identity, target value, cooldowns, resource identity, and predefined metric type.

### `autoscaling_memory_policies`

Memory target-tracking policy metadata keyed by service name.

Each entry includes policy identity, target value, cooldowns, resource identity, and predefined metric type.

### `autoscaling_alb_request_policies`

ALB request-count target-tracking policy metadata keyed by service name.

In addition to the common policy metadata, each entry exposes the exact resource-backed `resource_label`.

## Ownership Boundary

This module owns:

- ECS task security groups
- ECS task definitions
- Container definitions
- CloudWatch log groups for ECS workloads
- Fixed-count ECS/Fargate services
- Autoscaled ECS/Fargate services
- Application Auto Scaling targets for autoscaled services
- CPU, memory, and ALB request-count target-tracking policies when configured
- Fargate networking configuration
- Optional service-to-target-group attachment
- ECS deployment health settings and deployment circuit-breaker configuration
- Runtime and autoscaling metadata outputs
- Launch-readiness dependency resources

This module does **not** own:

- ECS clusters
- ECR repositories
- Container image builds or publishing
- ECS execution roles
- ECS task roles
- Cross-component security-group rules
- Application Load Balancers
- Target groups
- HTTPS listeners or listener rules
- Terraform-owned ECS operational CloudWatch alarms
- AWS-managed target-tracking CloudWatch alarms
- KMS key creation
- Secrets Manager secrets
- SSM parameters
- DNS
- Deployment image selection from mutable tags

Terraform-owned task-deficit and ingress-health alarms belong to `modules/monitoring`. Application Auto Scaling creates and manages its own target-tracking alarms.

Those responsibilities belong to other modules, AWS-managed target-tracking behavior, or baseline integration.

## Runtime Architecture

Conceptually:

```text
ECR digest-pinned image
        |
        v
ECS Task Definition
        |
        +--> execution role
        +--> task role
        +--> CloudWatch log group
        |
        v
ECS Service
        |
        +--> compute_private subnets
        +--> task security group
        +--> no public IP
        |
        +--> optional ALB target group
        |
        +--> fixed-count service
        |      -> Terraform owns desired_count
        |
        +--> autoscaled service
               -> bootstrap desired_count
               -> Application Auto Scaling target
               -> optional CPU target tracking
               -> optional memory target tracking
               -> optional ALB request target tracking
```

Cross-component security rules and IAM policies are created before service launch through the module's readiness dependency contract.

Autoscaling changes only desired-count ownership. Task definitions, deployment settings, networking, logging, IAM attachment, and optional ALB attachment remain Terraform-managed.

## Conditional Behavior

The module uses:

```hcl
services = {}
```

as its disabled/empty configuration.

When `services` is empty:

- No task security groups are created
- No log groups are created
- No task definitions are created
- No ECS services are created
- No Application Auto Scaling targets are created
- No target-tracking scaling policies are created

The two `terraform_data` readiness resources remain even with an empty service map. The shared cluster is owned elsewhere and also remains in baseline composition. Empty per-service validation is not evidence that a running application or its GuardDuty instrumentation was tested.

This allows ECS runtime capability to be wired into the baseline without requiring every workload environment to run ECS services.

Baseline passes only deployable canonical services to this module. A canonical `ecs_services` entry with `image_digest = null` is registered but unreleased: its derived ECR repository remains, while this module receives no entry for it and therefore creates no per-service runtime or scaling resources. Selecting a valid exact digest materializes the service from the same canonical entry.

For a deployable service, `scaling = null` creates a fixed-count service with no Application Auto Scaling resources. A non-null `scaling` object creates an autoscaled service and only the target-tracking policies whose metric targets are configured.

## Baseline Integration

The current baseline supplies:

- ECS cluster ARN and cluster name
- Compute-private subnet IDs
- Logging CMK ARN
- Per-service execution-role ARN
- Per-service task-role ARN
- Optional ALB target-group ARN
- Exact ALB request-scaling resource label derived from ALB and target-group ARN suffixes
- Execution-policy readiness IDs
- Security-policy readiness rule IDs
- Digest-pinned service image references
- Fixed-count versus autoscaled ownership through `scaling`
- Deployment-health configuration through `deployment`
- Runtime environment and secret configuration
- Profile-derived service AZ rebalancing and force-deletion policy
- Retirement-derived zero capacity without modifying canonical application settings

The canonical baseline validates scaling bounds, target metrics, cooldowns, ALB-request/ingress coupling, and deployment-health ranges before deriving this module's deployable service map.

Runtime validation is handled by `scripts/validation/validate-ecs-runtime.sh` inside the existing workload baseline validation layer. The validator compares the Terraform output contract with live ECS, Application Auto Scaling, ALB, logging, networking, deployment configuration, and Terraform-owned operational alarm state.

The validator treats fixed-count desired count as exact. For autoscaled services, it validates the live desired count against configured scaling bounds rather than the bootstrap `desired_count`, because Application Auto Scaling owns subsequent count changes.

## Container and Validation Limits

The module supports one essential primary application container and up to nine optional generic sidecars, with digest-pinned images, optional native health checks, constrained dependencies, shared task volumes, and the settings documented above. Omitting M1 inputs preserves the legacy single-container definition and existing service resource addresses. GuardDuty-managed agent injection remains an AWS-managed runtime mechanism outside the Terraform-configured sidecar map.

The module does not implement standalone bounded/one-off jobs, scheduled Fargate tasks, migration-aware releases, or application-level recovery tests. A nonessential prerequisite within a service task is not a generic job orchestration interface. The ALB health-check path belongs to the optional target group; it must not be confused with a task-definition container health check.

The existing workload suite remains 16 validators. `validate-ecs-runtime.sh` compares the complete configured container inventory and sidecar health-check definitions, while live native-health polling remains primary-only; `validate-iam.sh` checks the relevant role/policy contract. Neither an input check nor a normal steady-state pass replaces live failure-injection evidence or the retirement gates. M1 implementation is complete with acceptance pending; review of the N5D corrections, live AWS sidecar-readiness qualification, and owner acceptance remain outstanding. See the [M1 implementation status](../../v1-15-0/v1_15_0_M1_IMPLEMENTATION_STATUS.md) and [runtime validation design](../../docs/ecs-runtime-design.md#m1-container-inventory-compatibility).

## Implementation Sources

- [Resource definitions](main.tf), [input declarations](variables.tf), and [outputs](outputs.tf)
- [Canonical baseline inputs](../../baseline/variables.tf) and [runtime derivation](../../baseline/locals.tf)
- [Baseline module calls](../../baseline/main.tf)
- [Runtime service validation](../../scripts/validation/lib/ecs-runtime/services.sh)
- [Retirement readiness](../../scripts/deployment/validate-retirement-readiness.sh)
