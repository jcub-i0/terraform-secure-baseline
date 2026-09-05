# ECS Service Module

## Overview

The `ecs_service` module creates ECS/Fargate workload services for a workload environment.

Each configured service receives its own:

- ECS task security group
- CloudWatch Logs log group
- ECS task definition
- ECS service

The module is designed for long-running Fargate services using private `compute_private` subnets, digest-pinned container images, per-service IAM roles, KMS-encrypted CloudWatch log groups, and optional Application Load Balancer target-group integration.

Services are keyed by stable service name through the `services` map.

## Resources Created

For every entry in `services`, the module creates:

- One `aws_security_group`
- One `aws_cloudwatch_log_group`
- One `aws_ecs_task_definition`
- One `aws_ecs_service`

The module also creates two `terraform_data` readiness resources used to ensure that required IAM execution policies and cross-component security-group rules exist before ECS services launch:

- `terraform_data.ecs_execution_policy_ready`
- `terraform_data.ecs_security_policy_ready`

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct ECS service resources. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `primary_region` | `string` | Yes | — | AWS Region used by ECS services and the `awslogs` log driver. |
| `vpc_id` | `string` | Yes | — | VPC ID used when creating ECS task security groups. |
| `cluster_arn` | `string` | Yes | — | ARN of the ECS cluster that hosts the services. |
| `compute_private_subnet_ids` | `set(string)` | Yes | — | Compute-private subnet IDs used by Fargate tasks. |
| `cloudwatch_retention_days` | `number` | Yes | — | Retention period for ECS CloudWatch log groups. |
| `platform_version` | `string` | No | `"1.4.0"` | AWS Fargate platform version used by ECS services. |
| `services` | `map(object(...))` | No | `{}` | ECS/Fargate services keyed by stable service name. |
| `logs_cmk_arn` | `string` | Yes | — | ARN of the customer-managed KMS key used to encrypt ECS CloudWatch log groups. |
| `execution_policy_ids` | `map(string)` | No | `{}` | ECS task execution IAM policy IDs keyed by service name and used as launch-readiness dependencies. |
| `security_policy_rule_ids` | `map(set(string))` | No | `{}` | Cross-component security-group rule IDs keyed by service name and used as launch-readiness dependencies. |

## Service Configuration

The `services` map is keyed by stable ECS service name.

Example:

```hcl
services = {
  api = {
    image          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/tf-secure-baseline-dev-api@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    container_port = 8080
    cpu            = 512
    memory         = 1024
    desired_count  = 1

    execution_role_arn = "arn:aws:iam::123456789012:role/example-api-ecs-execution"
    task_role_arn      = "arn:aws:iam::123456789012:role/example-api-ecs-task"

    target_group_arn = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/example/0123456789abcdef"

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
| `desired_count` | `number` | No | `1` | Desired number of running ECS tasks. |
| `execution_role_arn` | `string` | Yes | — | ECS task execution-role ARN. |
| `task_role_arn` | `string` | Yes | — | Application task-role ARN. |
| `target_group_arn` | `string` | No | `null` | Optional ALB target-group ARN. |
| `cpu_architecture` | `string` | No | `"X86_64"` | Task CPU architecture. Supported values are `X86_64` and `ARM64`. |
| `environment_variables` | `map(string)` | No | `{}` | Plaintext environment variables supplied to the container. |
| `secrets` | `map(string)` | No | `{}` | Container secret names mapped to Secrets Manager or SSM Parameter Store references. |

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

`aws_ecs_service.services` depends on both readiness resources.

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

## Optional Load Balancer Integration

A service may optionally provide:

```hcl
target_group_arn = "..."
```

When present, the ECS service attaches to that target group using:

- The service name as the container name
- The configured `container_port`

When `target_group_arn` is `null`, no ECS load-balancer block is created.

The Application Load Balancer, target groups, listeners, and listener rules remain owned by `modules/application_load_balancer`.

## Deployment Behavior

ECS services use the deployment circuit breaker with automatic rollback:

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
platform_version
```

### `task_definition_arns`

ECS task-definition ARNs keyed by service name.

### `services`

ECS service metadata keyed by service name.

Each entry contains:

```text
arn
name
```

## Ownership Boundary

This module owns:

- ECS task security groups
- ECS task definitions
- Container definitions
- CloudWatch log groups for ECS workloads
- ECS/Fargate services
- Fargate networking configuration
- Optional service-to-target-group attachment
- ECS deployment circuit-breaker configuration
- Runtime metadata outputs
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
- KMS key creation
- Secrets Manager secrets
- SSM parameters
- DNS
- Deployment image selection from mutable tags

Those responsibilities belong to other modules or baseline integration.

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
```

Cross-component security rules and IAM policies are created before service launch through the module's readiness dependency contract.

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

This allows ECS runtime capability to be wired into the baseline without requiring every workload environment to run ECS services.

## Baseline Integration

The current baseline supplies:

- ECS cluster ARN
- Compute-private subnet IDs
- Logging CMK ARN
- Per-service execution-role ARN
- Per-service task-role ARN
- Optional ALB target-group ARN
- Execution-policy readiness IDs
- Security-policy readiness rule IDs
- Service image digests and runtime configuration

Runtime validation is handled by `scripts/validation/validate-ecs-runtime.sh`
inside the existing workload baseline validation layer. The validator uses the
resource-backed `platform_version` output rather than hard-coding the module's
current `1.4.0` default.
