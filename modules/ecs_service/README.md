# ECS Service Module

## Overview

The `ecs_service` module creates the deployable ECS/Fargate service runtime for a workload environment.

Each configured service receives its own:

- ECS task security group
- CloudWatch Logs log group
- ECS task definition
- ECS service

The module is designed for long-running Fargate services using private `compute_private` subnets, digest-pinned container images, per-service IAM roles, KMS-encrypted CloudWatch log groups, optional Application Load Balancer target-group integration, configurable deployment-health settings, and optional ECS Service Auto Scaling.

Services are keyed by stable service name through the `services` map.

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

The module also creates two `terraform_data` readiness resources used to ensure that required IAM execution policies and cross-component security-group rules exist before ECS services launch:

- `terraform_data.ecs_execution_policy_ready`
- `terraform_data.ecs_security_policy_ready`

Application Auto Scaling creates and manages the CloudWatch alarms associated with target-tracking policies. Those AWS-managed alarms are not Terraform-owned operational alarms and are not repurposed by this module.

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct ECS service resources. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `primary_region` | `string` | Yes | — | AWS Region used by ECS services and the `awslogs` log driver. |
| `vpc_id` | `string` | Yes | — | VPC ID used when creating ECS task security groups. |
| `cluster_arn` | `string` | Yes | — | ARN of the ECS cluster that hosts the services. |
| `cluster_name` | `string` | Yes | — | ECS cluster name used to construct Application Auto Scaling resource IDs. |
| `compute_private_subnet_ids` | `set(string)` | Yes | — | Compute-private subnet IDs used by Fargate tasks. |
| `cloudwatch_retention_days` | `number` | Yes | — | Retention period for ECS CloudWatch log groups. |
| `platform_version` | `string` | No | `"1.4.0"` | AWS Fargate platform version used by ECS services. |
| `services` | `map(object(...))` | No | `{}` | Deployable ECS/Fargate services keyed by stable service name. |
| `logs_cmk_arn` | `string` | Yes | — | ARN of the customer-managed KMS key used to encrypt ECS CloudWatch log groups. |
| `execution_policy_ids` | `map(string)` | No | `{}` | ECS task execution IAM policy IDs keyed by service name and used as launch-readiness dependencies. |
| `security_policy_rule_ids` | `map(set(string))` | No | `{}` | Cross-component security-group rule IDs keyed by service name and used as launch-readiness dependencies. |

## Service Configuration

The `services` map is keyed by stable ECS service name.

Example autoscaled ingress service:

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
      DATABASE_PASSWORD = "arn:aws:secretsmanager:us-east-1:123456789012:secret:example"
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
| `execution_role_arn` | `string` | Yes | — | ECS task execution-role ARN. |
| `task_role_arn` | `string` | Yes | — | Application task-role ARN. |
| `target_group_arn` | `string` | No | `null` | Optional ALB target-group ARN. |
| `alb_request_resource_label` | `string` | No | `null` | Resource label used by `ALBRequestCountPerTarget`; required together with `target_group_arn` when ALB request scaling is configured. |
| `cpu_architecture` | `string` | No | `"X86_64"` | Task CPU architecture. Supported values are `X86_64` and `ARM64`. |
| `environment_variables` | `map(string)` | No | `{}` | Plaintext environment variables supplied to the container. |
| `secrets` | `map(string)` | No | `{}` | Container secret names mapped to Secrets Manager or SSM Parameter Store references. |

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

- `min_capacity >= 1`
- `max_capacity >= min_capacity`
- `desired_count` falls within the configured capacity range
- at least one target-tracking metric is configured
- configured target values are greater than zero
- cooldown values are zero or greater
- `alb_requests_per_target` is used only with configured ingress

The low-level module additionally requires both `target_group_arn` and `alb_request_resource_label` when ALB request-count scaling is configured.

### Deployment configuration

The optional `deployment` object supports:

| Field | Type | Required | Default | Description |
|---|---|---:|---|---|
| `minimum_healthy_percent` | `number` | No | `100` | Minimum healthy task percentage ECS maintains during deployment. |
| `maximum_percent` | `number` | No | `200` | Maximum task percentage ECS may run during deployment. |
| `health_check_grace_period_seconds` | `number` | No | `0` | Time after task startup during which ECS ignores unhealthy load-balancer, VPC Lattice, and container health checks. |

The canonical baseline validates the deployment percentages and grace-period range before passing deployable services to this module.

## Image Integrity

Every service image must be digest-pinned using:

```text
repository@sha256:<64 lowercase hexadecimal characters>
```

Tag-only references such as:

```text
repository:latest
repository:v1.2.3
```

are rejected by input validation.

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

The module validates supported Fargate CPU and memory combinations before deployment.

The default Fargate platform version is:

```text
1.4.0
```

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

This module does not place ECS tasks in public subnets and does not assign public IP addresses.

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

The module does not enable `awslogs-create-group`; Terraform owns creation of the log groups.

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
  DATABASE_PASSWORD = "arn:aws:secretsmanager:..."
}
```

The task definition passes those references through the ECS `secrets` container-definition field.

IAM permissions required for ECS to retrieve those values remain owned by `modules/iam`.

## IAM Ownership

This module does not create ECS IAM roles.

Each service consumes:

- `execution_role_arn`
- `task_role_arn`

The execution role is used by the ECS/Fargate runtime for platform-level actions such as image pulls, logging, and explicitly configured task-definition secret retrieval.

The task role represents application-runtime AWS permissions.

Both roles remain owned by `modules/iam`.

## Launch Readiness

ECS services must not launch before their execution IAM policies and cross-component security-group rules exist.

The module uses:

```hcl
terraform_data.ecs_execution_policy_ready
terraform_data.ecs_security_policy_ready
```

as explicit readiness dependencies.

Both `aws_ecs_service.services` and `aws_ecs_service.autoscaled_services` depend on both readiness resources.

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

Input validation requires readiness-map coverage for every configured ECS service.

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

v1.9 uses target tracking only. Step scaling is not implemented by this module.

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

This allows failed deployments to roll back automatically rather than remaining indefinitely in a failed rollout state.

## Development/Test Destruction Posture

The current workload environments are routinely applied and destroyed for development, testing, and cost control.

ECS services therefore use:

```hcl
force_delete = true # CHANGE THIS IN PROD
```

This supports routine teardown of the current ephemeral workload environments.

Persistent production usage must reconsider this setting before deployment.

The module does not introduce `prevent_destroy` protection.

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

The canonical baseline validates scaling bounds, target metrics, cooldowns, ALB-request/ingress coupling, and deployment-health ranges before deriving this module's deployable service map.

Runtime validation is handled by `scripts/validation/validate-ecs-runtime.sh` inside the existing workload baseline validation layer. The validator compares the Terraform output contract with live ECS, Application Auto Scaling, ALB, logging, networking, deployment configuration, and Terraform-owned operational alarm state.

The validator treats fixed-count desired count as exact. For autoscaled services, it validates the live desired count against configured scaling bounds rather than the bootstrap `desired_count`, because Application Auto Scaling owns subsequent count changes.
