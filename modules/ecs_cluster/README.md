# ECS Cluster Module

## Overview

The `ecs_cluster` module creates one Amazon ECS cluster for a workload environment.

It provides the shared cluster-level substrate for the workload's ECS/Fargate services while keeping service-specific concerns in separate modules.

## Resources Created

The module creates:

- One `aws_ecs_cluster`
- CloudWatch Container Insights configuration for the cluster
- One Terraform-managed Container Insights performance log group when `container_insights` is not `disabled`

The ECS cluster name is constructed as:

```text
${name_prefix}-ecs
```

For example:

```text
tf-secure-baseline-dev-ecs
```

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct the ECS cluster name. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `container_insights` | `string` | No | `"enhanced"` | CloudWatch Container Insights mode for the ECS cluster. Supported values are `enhanced`, `enabled`, and `disabled`. |
| `cloudwatch_retention_days` | `number` | Yes | — | Retention for the Container Insights performance log group. |
| `logs_cmk_arn` | `string` | Yes | — | Workload logs CMK ARN used to encrypt the performance log group. |

## Container Insights

The module enables CloudWatch Container Insights using:

```hcl
setting {
  name  = "containerInsights"
  value = var.container_insights
}
```

The default is:

```hcl
container_insights = "enhanced"
```

This provides the strongest default observability posture for ECS workloads while still allowing callers to explicitly select `enabled` or `disabled` when appropriate.

When Container Insights is enabled, Terraform also creates:

```text
/aws/ecs/containerinsights/${name_prefix}-ecs/performance
```

The log group uses the supplied retention period and logs CMK. It is absent when `container_insights = "disabled"`. The cluster depends on this resource so the Terraform-owned group exists before the cluster activates Container Insights.

v1.9 task-deficit monitoring uses the Container Insights `DesiredTaskCount` and `RunningTaskCount` metrics. Baseline therefore supplies task-deficit alarm inputs only when `container_insights` is not `disabled`. Disabling Container Insights also disables that Terraform-owned task-deficit alarm path; it does not disable ECS services themselves.

## Tags

The ECS cluster receives the standard workload tags:

```text
Name
Environment
Terraform
```

The `Name` tag matches the rendered cluster name.

## Outputs

The module exposes:

| Output | Description |
|---|---|
| `cluster_arn` | ARN of the ECS cluster. |
| `cluster_name` | Name of the ECS cluster. Used by ECS services, Application Auto Scaling resource IDs, and Container Insights alarm dimensions. |
| `container_insights` | Resource-backed Container Insights setting configured on the cluster. |
| `container_insights_log_group` | Resource-backed ARN, name, retention, and KMS metadata; `null` when Container Insights is disabled. |

Baseline exposes all four values through the workload-root `ecs_cluster` object.

The runtime validator compares the live cluster setting and, when enabled, the performance log-group identity, retention, and KMS key with these resource-backed values.

`cluster_name` is also passed to `modules/ecs_service` so autoscaled services can register the exact Application Auto Scaling resource ID:

```text
service/<cluster_name>/<ecs-service-name>
```

Baseline separately uses the same resource-backed cluster name as the `ClusterName` dimension for task-deficit monitoring.

## Ownership Boundary

This module owns only environment-level ECS cluster infrastructure.

It owns:

- ECS cluster creation
- Cluster naming
- Container Insights configuration
- Container Insights performance log-group creation, retention, encryption, and tags
- Standard cluster tags
- Cluster and Container Insights metadata outputs

It does **not** own:

- ECS services
- ECS task definitions
- Container definitions
- ECS task or execution IAM roles
- ECS task security groups
- Per-service CloudWatch log groups for application containers
- ECS Service Auto Scaling targets or policies
- Terraform-owned ECS operational CloudWatch alarms
- AWS-managed target-tracking alarms
- Application Load Balancers
- Target groups or listener rules
- ECR repositories
- VPC networking
- Runtime secrets
- Deployment image selection
- ECS Exec configuration
- Capacity-provider strategies

Those responsibilities belong to other modules, AWS-managed Application Auto Scaling behavior, or the baseline integration layer.

## Runtime Model

The v1.9 runtime architecture uses one ECS cluster per workload environment with multiple ECS services able to consume the same cluster.

Conceptually:

```text
Workload Environment
        |
        +-- ECS Cluster
              |
              +-- Service A
              +-- Service B
              +-- Service N
```

The cluster is shared environment-level infrastructure rather than service-owned infrastructure.

For autoscaled services, the cluster name becomes part of the Application Auto Scaling resource identity:

```text
service/<cluster_name>/<service_name>
```

For ECS operational monitoring, the same cluster name is used as the `ClusterName` dimension of Container Insights task-count metrics.

One cluster still exists when `ecs_services = {}`; an empty service map creates no task definitions, ECS services, scaling targets, or service-level operational alarms.

## Example

```hcl
module "ecs_cluster" {
  source = "../modules/ecs_cluster"

  name_prefix = "tf-secure-baseline-dev"
  environment = "dev"

  container_insights        = "enhanced"
  cloudwatch_retention_days = 30
  logs_cmk_arn              = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
}
```

## Runtime Integration

The baseline connects this cluster to:

- ECS/Fargate services
- Per-service task definitions
- ECS IAM role pairs
- Task security groups
- CloudWatch container log groups
- Optional Application Load Balancer integration
- Digest-pinned ECR images
- Application Auto Scaling resource IDs for autoscaled services
- Container Insights task-deficit monitoring when Container Insights is enabled

The cluster module intentionally remains independent of those service-specific resources.

Baseline passes both `cluster_arn` and `cluster_name` to `modules/ecs_service`:

- `cluster_arn` identifies the ECS cluster hosting each service.
- `cluster_name` is used to build Application Auto Scaling resource IDs.

Baseline also passes the cluster name into `modules/monitoring` for deployable-service task-deficit alarms whenever Container Insights is enabled.

One cluster exists even when `ecs_services = {}`; an empty service map creates no task definitions or ECS services.
