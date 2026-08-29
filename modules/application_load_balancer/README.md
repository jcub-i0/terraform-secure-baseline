# Application Load Balancer Module

## Overview

The `application_load_balancer` module creates the shared Application Load Balancer ingress layer for ECS/Fargate workloads in a workload environment.

It owns the public-facing ALB, its security group, HTTPS listener, per-service target groups, and HTTPS listener rules. ECS services consume the target groups created by this module but remain owned by `modules/ecs_service`.

The module is intended to be instantiated only when one or more ingress-enabled ECS services are configured.

## Resources Created

The module creates:

- One Application Load Balancer
- One ALB security group
- One HTTPS ingress security-group rule
- One HTTPS listener
- One target group per configured service
- One listener rule per configured service

The ALB is internet-facing and placed in the workload environment's public subnets.

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct ALB-related resource names. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `vpc_id` | `string` | Yes | — | VPC ID in which the ALB and target groups are created. |
| `public_subnet_ids` | `set(string)` | Yes | — | Public subnet IDs used by the internet-facing ALB. At least two subnet IDs are required. |
| `certificate_arn` | `string` | Yes when instantiated | — | ACM certificate ARN used by the HTTPS listener. |
| `ingress_cidrs` | `set(string)` | Yes | — | IPv4 CIDR blocks allowed to reach the ALB over HTTPS. |
| `ssl_policy` | `string` | No | `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` | TLS security policy used by the HTTPS listener. |
| `services` | `map(object(...))` | No | `{}` | Per-service target-group and HTTPS routing configuration keyed by ECS service name. |

## Service Configuration

The `services` map defines the ingress-facing configuration for each ECS service exposed through the shared ALB.

Example:

```hcl
services = {
  api = {
    container_port    = 8080
    priority          = 100
    host_headers      = ["api.example.com"]
    path_patterns     = []
    health_check_path = "/health"
  }

  frontend = {
    container_port    = 3000
    priority          = 200
    host_headers      = ["app.example.com"]
    health_check_path = "/health"
  }
}
```

Each service entry supports:

| Field | Type | Required | Default | Description |
|---|---|---:|---|---|
| `container_port` | `number` | Yes | — | Port used by the target group for the ECS service. |
| `priority` | `number` | Yes | — | Unique HTTPS listener-rule priority. |
| `host_headers` | `set(string)` | No | `[]` | Host-header values used to route requests to the service. |
| `path_patterns` | `set(string)` | No | `[]` | URL path patterns used to route requests to the service. |
| `health_check_path` | `string` | No | `"/health"` | HTTP path used by the target-group health check. |

Each configured service must define at least one `host_headers` or `path_patterns` condition.

If both host-header and path-pattern conditions are configured for the same service, both conditions must match for the listener rule to forward the request.

## HTTPS-Only Ingress

The module exposes HTTPS on TCP/443 only.

It intentionally does not create a public HTTP listener or HTTP-to-HTTPS redirect. Clients are expected to connect directly over HTTPS.

The caller supplies an ACM certificate ARN for the HTTPS listener.

At the baseline integration layer, the ALB is instantiated only when ALB services are configured, and a valid ACM certificate ARN is required whenever that service map is non-empty.

## Default Listener Behavior

The HTTPS listener uses a fixed `404` response when no configured listener rule matches.

Conceptually:

```text
HTTPS :443
   |
   +-- matching service rule
   |      -> service target group
   |
   +-- no matching rule
          -> fixed 404 response
```

This prevents unmatched requests from being forwarded to an arbitrary default workload.

## Target Groups

The module creates one target group per configured service.

Target groups use:

```hcl
target_type = "ip"
protocol    = "HTTP"
```

The `ip` target type is required for the Fargate/`awsvpc` runtime model because ECS tasks register their task ENI IP addresses rather than EC2 instance IDs.

The ECS service module later consumes the target-group ARN and is responsible for attaching the service to that target group.

## Health Checks

Each target group uses an HTTP health check.

The default path is:

```text
/health
```

The accepted HTTP response matcher is:

```text
200-399
```

The health-check path can be overridden per service through `health_check_path`.

## Security Group Ownership

This module owns the Application Load Balancer security-group object.

It also owns public HTTPS ingress into that security group from `ingress_cidrs`.

The module intentionally does **not** create broad ALB egress.

The cross-component relationship:

```text
ALB security group
        |
        | service container port
        v
ECS task security group
```

is owned by `modules/networking/security_policy`.

That module creates both:

- ALB SG egress to the ECS task SG
- ECS task SG ingress from the ALB SG

This preserves the baseline's existing cross-component security-policy ownership model.

## Load Balancer Posture

The ALB is created as:

- Internet-facing
- Application Load Balancer type
- HTTPS-only
- Attached to the workload public subnets
- Configured to drop invalid HTTP header fields
- Deletion protection disabled for the current ephemeral development/test workflow

The Terraform configuration includes:

```hcl
enable_deletion_protection = false # CHANGE THIS IN PROD
```

The current workload environments are regularly applied and destroyed for development, testing, and cost control.

Persistent production use must reconsider ALB deletion protection before deployment.

## Conditional Baseline Integration

The baseline derives this module's service configuration from the canonical `ecs_services` map.

Only ECS services with a non-null `ingress` configuration are included in the derived ALB service map.

Conceptually:

```text
ecs_services = {}
    -> no ALB resources

ecs_services contains no services with ingress
    -> no ALB resources

ecs_services contains one or more services with ingress
    -> one shared ALB
    -> one HTTPS listener
    -> one target group per ingress-enabled service
    -> one listener rule per ingress-enabled service
```

For example:

```hcl
ecs_services = {
  api = {
    # ...

    ingress = {
      priority     = 100
      host_headers = ["api.example.com"]
    }
  }

  worker = {
    # ...

    ingress = null
  }
}
```

In this example, only `api` is included in the ALB routing configuration. The `worker` service does not receive a target group or listener rule.

This avoids requiring callers to maintain a separate ALB service map and prevents creation of an idle ALB when no ingress-enabled ECS workloads exist.

## Tags

ALB resources receive the standard workload tags where supported:

```text
Name
Environment
Terraform
```

## Outputs

The module exposes:

| Output | Description |
|---|---|
| `security_group_id` | Security group ID of the Application Load Balancer. |
| `load_balancer_arn` | ARN of the Application Load Balancer. |
| `dns_name` | DNS name assigned to the Application Load Balancer. |
| `https_listener_arn` | ARN of the HTTPS listener. |
| `target_groups` | Target-group metadata keyed by ECS service name. |

The `target_groups` output is intended to be consumed by later ECS service integration.

Example shape:

```hcl
target_groups = {
  api = {
    arn  = "arn:aws:elasticloadbalancing:..."
    name = "tf-secure-baseline-dev-api"
  }
}
```

## Ownership Boundary

This module owns:

- Application Load Balancer
- ALB security group
- Public HTTPS ingress rule
- HTTPS listener
- Fixed default listener response
- Target groups
- Listener rules
- ALB-related outputs

This module does **not** own:

- ACM certificate creation
- DNS records
- ECS clusters
- ECS services
- ECS task definitions
- ECS task security groups
- ECS task or execution IAM roles
- ECR repositories
- Container images
- Runtime secrets
- Cross-component ALB-to-task security-group rules
- Application deployment orchestration

Those responsibilities belong to other modules or later runtime integration work.

## Runtime Model

The v1.8.0 architecture uses one shared ALB per workload environment when ingress is required.

Multiple ECS services can be routed through the same listener using explicit host-header and/or path-pattern rules.

Conceptually:

```text
Internet / Approved CIDRs
          |
        HTTPS
          |
          v
   Shared Application
    Load Balancer
      /        \
     /          \
  rule A       rule B
    |             |
    v             v
target A       target B
    |             |
    v             v
service A      service B
```

## Example

```hcl
module "application_load_balancer" {
  source = "../modules/application_load_balancer"

  name_prefix = "tf-secure-baseline-dev"
  environment = "dev"
  vpc_id      = "vpc-0123456789abcdef0"

  public_subnet_ids = [
    "subnet-aaaaaaaaaaaaaaaaa",
    "subnet-bbbbbbbbbbbbbbbbb",
  ]

  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  ingress_cidrs = [
    "0.0.0.0/0",
  ]

  services = {
    api = {
      container_port    = 8080
      priority          = 100
      host_headers      = ["api.example.com"]
      health_check_path = "/health"
    }
  }
}
```

## Deferred Runtime Integration

Later v1.8.0 runtime work will connect the module's target groups and ALB security-group metadata to:

- ECS/Fargate services
- ECS task security groups
- Cross-component security-policy rules
- Runtime service definitions
- Workload DNS configuration where applicable

The module intentionally remains independent of ECS service implementation details.