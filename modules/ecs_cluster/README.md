# ECS Cluster Module

## Overview

The `ecs_cluster` module creates one Amazon ECS cluster for a workload environment.

It provides the shared cluster-level substrate for future ECS/Fargate services while keeping service-specific concerns in separate modules.

## Resources Created

The module creates:

- One `aws_ecs_cluster`
- CloudWatch Container Insights configuration for the cluster

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
| `cluster_name` | Name of the ECS cluster. |

These outputs are intended for later consumption by ECS service/runtime modules.

## Ownership Boundary

This module owns only environment-level ECS cluster infrastructure.

It owns:

- ECS cluster creation
- Cluster naming
- Container Insights configuration
- Standard cluster tags
- Cluster ARN/name outputs

It does **not** own:

- ECS services
- ECS task definitions
- Container definitions
- ECS task or execution IAM roles
- ECS task security groups
- CloudWatch log groups for containers
- Application Load Balancers
- Target groups or listener rules
- ECR repositories
- VPC networking
- Runtime secrets
- Deployment image selection
- ECS Exec configuration
- Capacity-provider strategies

Those responsibilities belong to other modules or later runtime integration work.

## Runtime Model

The v1.8.0 runtime architecture uses one ECS cluster per workload environment with multiple ECS services able to consume the same cluster.

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

The cluster is therefore shared environment-level infrastructure rather than service-owned infrastructure.

## Example

```hcl
module "ecs_cluster" {
  source = "../modules/ecs_cluster"

  name_prefix = "tf-secure-baseline-dev"
  environment = "dev"

  container_insights = "enhanced"
}
```

## Deferred Runtime Integration

Later v1.8.0 runtime work will connect this cluster to:

- ECS/Fargate services
- Per-service task definitions
- ECS IAM role pairs
- Task security groups
- CloudWatch container log groups
- Optional Application Load Balancer integration
- Digest-pinned ECR images

The cluster module intentionally remains independent of those service-specific resources.