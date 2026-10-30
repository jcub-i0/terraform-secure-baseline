# Application Load Balancer Module

## Overview

The `application_load_balancer` module creates the shared Application Load Balancer ingress layer for ECS/Fargate workloads in a workload environment.

It owns the public-facing ALB, its security group, HTTPS listener, per-service target groups, HTTPS listener rules, an optional dedicated S3 bucket for ALB access logs, and an optional regional AWS WAFv2 Web ACL associated with the shared ALB. ECS services consume the target groups created by this module but remain owned by `modules/ecs_service`.

The baseline instantiates this module only when one or more deployable ECS services have ingress enabled. Registered services with a null image digest do not instantiate it. This condition is owned by `baseline/main.tf`, not by the module: a direct module call with `services = {}` still creates the shared ALB, security group, ingress rule, and listener.

The module also exposes resource-backed ALB and target-group ARN suffixes used by:

- `ALBRequestCountPerTarget` Application Auto Scaling resource labels; and
- Terraform-owned unhealthy-target operational alarms.

The module does not own scaling policies or operational alarms; it supplies the exact resource identities required by those consumers.

## Resources Created

The module creates:

- One Application Load Balancer
- One ALB security group
- One HTTPS ingress security-group rule
- One HTTPS listener
- One target group per configured service
- One listener rule per configured service
- When access logging is enabled, one dedicated S3 bucket with encryption, public-access, ownership, versioning, lifecycle, and bucket-policy controls
- When WAF is enabled, one regional WAFv2 Web ACL and one association to this ALB

The ALB is internet-facing and placed only in the workload environment's `ingress_public` subnets.

## Inputs

| Input | Type | Required | Default | Description |
|---|---|---:|---|---|
| `name_prefix` | `string` | Yes | — | Baseline naming prefix used to construct ALB-related resource names. |
| `environment` | `string` | Yes | — | Workload environment identity used for tagging. |
| `vpc_id` | `string` | Yes | — | VPC ID in which the ALB and target groups are created. |
| `ingress_public_subnet_ids` | `set(string)` | Yes | — | Ingress-public subnet IDs used by the internet-facing ALB. At least two subnet IDs are required. |
| `certificate_arn` | `string` | Yes when instantiated | — | ACM certificate ARN used by the HTTPS listener. |
| `ingress_cidrs` | `set(string)` | Yes | — | IPv4 CIDR blocks allowed to reach the ALB over HTTPS. |
| `ssl_policy` | `string` | No | `ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09` | TLS security policy used by the HTTPS listener. |
| `enable_deletion_protection` | `bool` | Yes | — | Whether ALB deletion protection is enabled. Baseline supplies the profile/retirement-resolved value. |
| `account_id` | `string` | Yes | — | Owning workload AWS account ID for ALB log delivery. |
| `random_id` | `string` | Yes | — | Existing workload suffix for globally unique ALB log-bucket naming. |
| `bucket_admin_principals` | `list(string)` | Yes | — | Approved IAM principals exempt from log-bucket policy/versioning change denies. |
| `access_logs_enabled` | `bool` | No | `false` | Create a dedicated log bucket and enable ALB log delivery. Baseline resolves profile defaults. |
| `access_logs_retention_days` | `number` | No | `14` | S3 Lifecycle current-object expiration period; baseline resolves profile defaults. |
| `access_logs_force_destroy` | `bool` | No | `true` | Terraform bucket teardown behavior; baseline resolves production retirement safeguards. |
| `waf_enabled` | `bool` | No | `false` | Create and associate a regional Web ACL with the shared ALB when enabled. |
| `waf_mode` | `string` | No | `"count"` | `count` (observe at the group-result level) or `enforce` (use managed rule actions). |
| `waf_rate_limit_requests` | `number` | No | `null` | Optional per-IP rate rule over a 300-second window; null omits the rule. |
| `waf_sampled_requests_enabled` | `bool` | No | `false` | Explicitly enable sampled requests; sampling can expose request metadata. |
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

Each configured service must define at least one `host_headers` or `path_patterns` condition. Listener priorities must be unique and between 1 and 50000; container ports must be between 1 and 65535. Resource preconditions limit the rendered ALB name and each rendered target-group name to 32 characters.

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

The ECS service module consumes the target-group ARN and attaches the service to that target group.

HTTPS terminates at the ALB. The configured target-group and health-check protocols are HTTP, so this module does not provide TLS encryption on the ALB-to-task leg. Optional WAF protects the shared ALB but does not provide application authentication. ALB access-log delivery is a separate opt-in setting, resolved by baseline according to deployment profile.

Each target-group output also exposes the resource-backed `arn_suffix`. Baseline uses that suffix for:

- the `ALBRequestCountPerTarget` resource label when ALB request-count scaling is configured; and
- the `TargetGroup` dimension of the Terraform-owned ingress unhealthy-target alarm.

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

`ingress_cidrs` is an environment-level set on the shared ALB SG. It therefore represents the client CIDR union for every ingress-enabled service; the current module does not implement per-service source-IP isolation. Service separation at the listener is routing separation through explicit host-header and/or path-pattern conditions, not a per-service authorization boundary.

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
- Attached to the workload `ingress_public` subnets
- Configured to drop invalid HTTP header fields
- Deletion protection controlled by the required `enable_deletion_protection` input

At the baseline integration layer, deletion protection is profile-derived:

```text
production + retirement mode false -> enabled
production + retirement mode true  -> disabled
development/minimal                 -> disabled
```

The ALB module itself does not infer deployment profiles; it applies the already-resolved boolean supplied by `baseline`.

Production baseline defaults supply the exact three-AZ `ingress_public` subnet set. The module validates a minimum of two supplied subnet IDs; it does not independently enforce the production AZ count or verify subnet roles. Baseline topology and the live runtime validator provide those integration checks. NAT Gateways belong to the separate `egress_public` family; ALB-to-task traffic stays on VPC-local routing, not the stateful firewall egress return path.

Retirement relaxes ALB deletion protection through the reviewed Stage-1 plan. It does not change the ALB to use egress-public subnets or remove the shared ingress layer merely to stop task capacity. Follow the [production retirement runbook](../../docs/production-retirement.md).

## ALB Access Logging

The module enables ALB-to-S3 delivery only when `access_logs_enabled=true`. It then creates a dedicated bucket using **SSE-S3 (`AES256`)**, versioning, BucketOwnerEnforced ownership, all four public-access blocks, and a TLS-only policy. Log delivery is restricted to `alb/AWSLogs/<account-id>/*` from the expected ALB. The bucket policy denies direct object/version deletion and restricts policy/versioning changes to approved administrators.

Baseline defaults logging to **enabled for `production`** and disabled for `development`/`minimal`, whenever a deployable ingress ALB exists. Optional `alb_access_logs_enabled` and `alb_access_logs_retention_days` overrides are passed through each workload root (and its GitHub Plan/Apply/Destroy configuration). With no ingress ALB, no ALB log bucket is created.

The S3 Lifecycle rule expires current log objects after **90/30/14 days** by default for production/development/minimal (or the configured positive-day override), and noncurrent versions after one day. Expiration is asynchronous, not guaranteed deletion at an exact timestamp.

In ordinary production the logging bucket has `force_destroy=false`. The reviewed Stage-1 retirement Apply changes it to `true` without deleting the bucket; final deletion requires separately authorized durable-data disposition and the protected saved-plan Destroy sequence. The retained [Stage-1 plan validator](../../scripts/deployment/validate-production-retirement-plan.sh) checks the retirement posture and permitted plan actions, not individual S3 bucket-policy statements. Runtime validation checks deployed logging settings and bucket protections; neither check proves actual log delivery or bucket deletion ordering. See the [retirement runbook](../../docs/production-retirement.md).

## Optional AWS WAF Protection

WAF is disabled by default in all deployment profiles. With `waf_enabled = true`, the module creates one regional WAFv2 Web ACL and associates it with the existing shared ALB; enabling WAF does not replace the ALB. In the baseline, neither ALB nor WAF is created unless an ECS service has both an image digest and ingress configuration. Direct module calls still create the ALB regardless of the `services` map.

The Web ACL has a default `allow` action and two standard AWS-managed rule groups: `AWSManagedRulesCommonRuleSet` (priority 10) and `AWSManagedRulesKnownBadInputsRuleSet` (priority 20). An optional per-source-IP rate rule (priority 30) is created only when `waf_rate_limit_requests` is an integer from 10 to 2,000,000,000; its evaluation window is 300 seconds. AWS rate limiting is approximate, not an exact request quota.

`waf_mode = "count"` is the initial observation posture: each managed group uses a **group-level** Count result override, and the optional rate rule counts instead of blocking. This override does **not** change the actions of individual managed rules; a terminating match can stop evaluation inside a group, so Count mode is not exhaustive per-rule false-positive testing. In `waf_mode = "enforce"`, AWS applies the managed groups' rule actions and the optional rate rule blocks. Review observed traffic before changing modes. Per-rule overrides, if needed, require a separately reviewed change.

CloudWatch metrics are enabled for the Web ACL and its rules. Request sampling is off unless explicitly enabled, because samples can include sensitive request paths, query parameters, or headers. M3 does not create full WAF request logging, a new log destination, paid Bot/Fraud Control rule groups, or application authentication. WAF does not replace the existing ALB security-group CIDR restrictions or M2 access logging.

Example optional configuration:

```hcl
waf_enabled                  = true
waf_mode                     = "count"
waf_rate_limit_requests      = null
waf_sampled_requests_enabled = false
```

The `waf` output reports `enabled`, `mode`, `web_acl_arn`, `web_acl_id`, `association_id`, and `rate_limit_requests`. When disabled, the resource-backed identifiers and operating mode are null. At baseline level, `application_load_balancer` is null when no ALB is instantiated.

## Conditional Baseline Integration

The baseline derives this module's service configuration from the canonical `ecs_services` map.

Only deployable ECS services with both a selected image digest and non-null `ingress` configuration are included in the derived ALB service map. A registered service with `image_digest = null` does not create an ALB target group or listener rule, even when its canonical ingress configuration is already present.

Conceptually:

```text
ecs_services = {}
    -> no ALB resources

ecs_services contains no services with ingress
    -> no ALB resources

ecs_services contains one or more deployable services with ingress
    -> one shared ALB
    -> one HTTPS listener
    -> one target group per ingress-enabled service
    -> one listener rule per ingress-enabled service
```

For example, this is an ingress-field excerpt, not a complete canonical service definition:

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

In this example, only a digest-selected `api` is included in the ALB routing configuration. The `worker` service does not receive a target group or listener rule. A null digest would also exclude either service from ALB materialization.

The canonical baseline requires ingress whenever a service configures:

```text
scaling.alb_requests_per_target
```

For such a service, baseline derives the Application Auto Scaling resource label from this module's resource-backed outputs:

```text
<load_balancer_arn_suffix>/<target_group_arn_suffix>
```

The label is not reconstructed from resource names in Bash or other deployment tooling.

Baseline also uses the same ARN suffixes to build exact `AWS/ApplicationELB` dimensions for the Terraform-owned unhealthy-target operational alarm.

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
| `load_balancer_arn_suffix` | Resource-backed ALB ARN suffix used by CloudWatch dimensions and Application Auto Scaling resource labels. |
| `dns_name` | DNS name assigned to the Application Load Balancer. |
| `https_listener` | HTTPS listener metadata, including ARN, certificate ARN, and SSL policy. |
| `target_groups` | Target-group metadata keyed by ECS service name, including ARN, ARN suffix, and name. |
| `access_logs` | Logging enabled status, bucket name/ARN, `alb` prefix, retention, and `force_destroy` metadata (null bucket fields when disabled). |
| `waf` | WAF enabled status, mode, Web ACL ARN/ID, association ID, and optional rate limit (resource fields null when disabled). |

The `target_groups` output is consumed by baseline when deriving ECS service runtime inputs.

Example shape:

```hcl
target_groups = {
  api = {
    arn        = "arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/tf-secure-baseline-dev-api/0123456789abcdef"
    arn_suffix = "targetgroup/tf-secure-baseline-dev-api/0123456789abcdef"
    name       = "tf-secure-baseline-dev-api"
  }
}
```

The ALB request-count scaling resource label is derived by baseline as:

```text
${load_balancer_arn_suffix}/${target_groups[service].arn_suffix}
```

The same suffix outputs are used as the exact `LoadBalancer` and `TargetGroup` dimensions for ingress unhealthy-target monitoring.

## Ownership Boundary

This module owns:

- Application Load Balancer
- ALB security group
- Public HTTPS ingress rule
- HTTPS listener
- Fixed default listener response
- Target groups
- Listener rules
- Optional dedicated ALB log bucket and its security/lifecycle controls
- Resource-backed ALB and target-group metadata outputs, including ARN suffixes and access logs

This module does **not** own:

- ACM certificate creation
- DNS records
- ECS clusters
- ECS services
- ECS task definitions
- ECS task security groups
- ECS task or execution IAM roles
- ECS Service Auto Scaling targets or policies
- Terraform-owned ECS operational alarms
- AWS-managed target-tracking alarms
- ECR repositories
- Container images
- Runtime secrets
- Cross-component ALB-to-task security-group rules
- Application deployment orchestration

`modules/ecs_service` owns Application Auto Scaling policies. `modules/monitoring` owns the Terraform-managed ingress unhealthy-target alarm. This module supplies resource-backed identifiers to both consumers.

Those responsibilities belong to other modules or the baseline integration layer.

## Runtime Model

The runtime architecture retains one shared ALB per workload environment when ingress is required.

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

For an ingress-enabled autoscaled service, the same Terraform-owned ALB resources also provide:

```text
ALB ARN suffix + target-group ARN suffix
        |
        +--> ALBRequestCountPerTarget resource label
        |
        +--> AWS/ApplicationELB unhealthy-target alarm dimensions
```

The ALB remains ingress infrastructure; scaling and monitoring ownership stay in their respective modules.

## Example

Illustrative two-AZ development module call. Replace all sample resource IDs, certificate ARN, hostname, and client CIDR with approved values from the same workload deployment. Production baseline composition supplies its own three-AZ subnet set and lifecycle-protection value; do not copy the development boolean into production.

```hcl
module "application_load_balancer" {
  source = "../modules/application_load_balancer"

  name_prefix = "tf-secure-baseline-dev"
  environment = "dev"
  vpc_id      = "vpc-0123456789abcdef0"

  ingress_public_subnet_ids = [
    "subnet-aaaaaaaaaaaaaaaaa",
    "subnet-bbbbbbbbbbbbbbbbb",
  ]

  certificate_arn = "arn:aws:acm:us-east-1:123456789012:certificate/00000000-0000-0000-0000-000000000000"

  ingress_cidrs = [
    "203.0.113.10/32",
  ]

  enable_deletion_protection = false

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

## Runtime Integration

The current baseline connects the module's target groups and ALB security-group metadata to:

- ECS/Fargate services
- ECS task security groups
- Cross-component security-policy rules
- Runtime service definitions
- Application Auto Scaling resource labels for `ALBRequestCountPerTarget`
- Terraform-owned ingress unhealthy-target CloudWatch alarms

Baseline derives a plan-time-known `alb_access` boolean from whether the canonical service has non-null `ingress`. The security-policy module uses that semantic value for `for_each` filtering. It does not filter on whether the resource-derived ALB security-group ID is non-null, because that value is unknown during planning.

For request-count scaling, baseline derives:

```text
<ALB ARN suffix>/<target-group ARN suffix>
```

from this module's resource-backed outputs and passes that value to `modules/ecs_service`.

For operational ingress monitoring, baseline passes the ALB and target-group ARN suffixes separately to `modules/monitoring`.

Workload DNS configuration remains outside the module and current runtime scope.

The module intentionally remains independent of ECS service implementation details, scaling policy implementation, and operational alarm implementation.

## Validation and Sources

Within the workload suite, `validate-ecs-runtime.sh` compares the live ALB deletion-protection attribute, exact ingress-public subnet membership, target-group/listener relationships, and declared security-group paths with Terraform. Operational unhealthy-target alarms are validated separately within that same entry point. For WAF acceptance, independently check the live Web ACL association, observed Count metrics, and reviewed enforcement behavior using synthetic HTTPS requests; the existing ECS validator does not establish those outcomes. A configured ALB or Web ACL is not by itself proof of application correctness or protection effectiveness.

Implementation references: [ALB resources](main.tf), [WAF resources](waf.tf), [inputs](variables.tf), [outputs](outputs.tf), [baseline composition](../../baseline/main.tf), and [ingress validation helper](../../scripts/validation/lib/ecs-runtime/ingress.sh).
