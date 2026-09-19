# terraform-secure-baseline

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security and application-hosting baseline for organizations running workloads that handle PII or other sensitive data.

**Current release:** `v1.10.0 — ECS Runtime Security` extends the ECS/Fargate runtime with GuardDuty Runtime Monitoring, deployment-profile-driven cluster enrollment, least-privilege managed-agent prerequisites, runtime coverage-health notification, exact live validation, and corrected profile-aware AWS Backup semantics.

The platform provides:

- Five-account AWS separation across `control-plane`, `security-operations`, `dev`, `staging`, and `prod`
- AWS Organizations and IAM Identity Center governance
- Dedicated centralized security administration
- Private-first workload networking with configurable egress
- Centralized logging, monitoring, threat detection, and alerting
- Workload-local AWS Config, Inspector, remediation, and response automation
- EC2 as a supported host-based runtime
- ECS/Fargate as the preferred modern application runtime
- Optional ECS target-tracking auto scaling with explicit service-count ownership
- ECS deployment-health configuration and Terraform-owned operational alarms
- GuardDuty Fargate Runtime Monitoring for production/development with explicit minimal-profile opt-out
- GuardDuty ECS coverage-health notification through the existing SecOps path
- GitHub OIDC-based CI/CD without long-lived AWS access keys
- Exact reviewed-plan Terraform application through protected environments
- Four-layer read-only validation and evidence export
- SOC 2 / ISO 27001-aligned technical safeguards that support audit readiness

> This baseline supports SOC 2 and ISO 27001 readiness, but it does not replace an organization’s full compliance program, ISMS, policies, risk management process, or formal audit requirements.

---

## What This Project Provides

### Governance and identity

- AWS Organizations OU separation for `Security`, `Workloads/NonProd`, and `Workloads/Prod`
- Centralized IAM Identity Center access management
- Dedicated `SecOps-Administrator` access for security operations
- Environment-specific workload access boundaries
- GitHub Actions OIDC federation for Terraform and application publication

### Networking and data protection

- Segmented VPC networking across public, compute-private, data-private, serverless-private, firewall-private, and endpoint-private subnet tiers
- `network_firewall`, `nat_only`, and `vpc_endpoints_only` egress modes
- AWS Network Firewall inspection when enabled
- Terraform-managed VPC endpoints for private AWS service access
- KMS-backed encryption across state, logs, messaging, application resources, and backups
- Protected S3 storage for Terraform state and operational evidence

### Security operations

- Centralized Security Hub CSPM and GuardDuty governance
- Centralized GuardDuty Runtime Monitoring with EC2 and ECS/Fargate automated agent management
- Security Hub V2 organization policy governance
- Workload-local AWS Config, Inspector, remediation, and supporting controls
- GuardDuty-scoped EC2 automatic isolation with configurable severity eligibility, defaulting to `CRITICAL`
- Controlled EC2 rollback, IP enrichment, tamper detection, and break-glass monitoring
- SNS/SQS alerting and DLQ-backed failure retention

### Application runtimes

- EC2 hosting with dependency-safe first boot and scheduled patching
- One ECS cluster per workload environment
- Generic long-running Fargate services using digest-pinned ECR images
- Conditional shared HTTPS Application Load Balancer
- Separate task execution and application task IAM roles
- Per-service task security groups and encrypted logs
- Terraform-owned Container Insights performance logging
- Registered-but-unreleased ECS services whose ECR repositories can exist before an image digest is selected
- Optional Application Auto Scaling with CPU, memory, and ALB request-count target tracking
- Explicit Terraform-vs-autoscaler ownership of ECS `desired_count`
- Configurable ECS deployment minimum/maximum percentages and health-check grace period
- Terraform-owned task-deficit and ingress unhealthy-target operational alarms
- Deployment-profile-driven `GuardDutyManaged` ECS cluster enrollment
- GuardDuty-managed Fargate runtime agent with Terraform-owned IAM/network prerequisites and live coverage validation

---

## Target Use Case

This baseline is designed for SaaS companies handling sensitive data, teams preparing for SOC 2 or ISO 27001, cloud security and platform teams building reusable AWS foundations, startups that need production-aligned controls early, and consultants implementing secure client environments.

---

## High-Level Architecture

```text
AWS Organizations management account
└── control-plane
    ├── state / GitHub OIDC
    ├── Organizations + OU topology
    ├── delegated-administrator prerequisites
    └── IAM Identity Center

Security OU
└── security-operations
    ├── state / GitHub OIDC
    └── centralized security services
        ├── Security Hub CSPM
        ├── GuardDuty
        └── Security Hub V2 policy governance

Workloads OU
├── NonProd
│   ├── dev
│   └── staging
└── Prod
    └── prod
```

The platform separates three Terraform ownership domains:

| Domain | Primary responsibilities |
|---|---|
| Control plane | Organizations structure, account placement, trusted-service access, delegated-administrator registration, IAM Identity Center, and management-account prerequisites |
| Security operations | Delegated-administrator-side Security Hub CSPM, GuardDuty, and Security Hub V2 organization policy configuration |
| Workload environments | Networking, EC2, ECS/Fargate, ECR, logging, AWS Config, Inspector, remediation, automation, storage, backup, patching, and workload IAM |

Architectural deployment order:

```text
control-plane -> security-operations -> bootstrap-workloads -> workloads
```

The generic workload Apply and Destroy workflows intentionally do not operate the centralized security layer because that layer has organization-wide blast radius.

---

## Core Design Principles

### Private-first infrastructure

Compute workloads are placed in private subnets by default. Internet-bound egress follows an explicitly selected Network Firewall, NAT-only, or no-default-route path, while supported AWS service traffic can remain private through VPC endpoints.

### Explicit ownership boundaries

Organization prerequisites, centralized security administration, and workload-local resources are owned by distinct Terraform roots. The same Security Hub, GuardDuty, or Security Hub V2 resource is not intentionally managed from multiple states.

### No long-lived CI/CD credentials

GitHub Actions authenticates to AWS using OIDC. Plan, Apply, image-publication, and repository-write responsibilities use distinct trust boundaries where required.

### Exact reviewed-plan application

The protected workload Apply workflow generates its own saved Terraform plan, readable output, metadata, and checksum before approval. The Apply job verifies and applies that exact binary plan without replanning.

### Resource-granular readiness

EC2 and ECS/Fargate launch paths wait on the specific security-policy, IAM, and endpoint resources they require instead of relying on broad module-level dependencies.

### Single canonical ECS service interface

Operators maintain one `ecs_services` map. Baseline derives narrower ECR, IAM, ALB, security-policy, runtime, scaling, and monitoring inputs from it.

### Explicit ECS service-count ownership

A service with `scaling = null` remains fixed-count and Terraform owns `desired_count`. A service with non-null scaling configuration uses `desired_count` only as bootstrap capacity; Application Auto Scaling owns subsequent live count changes within the configured minimum and maximum.

---

## Deployment Profiles and Egress Modes

| `deployment_profile` | Default `egress_mode` | AWS Config | Scheduled Backup | Inspector | GuardDuty Fargate Runtime Monitoring | Log retention | Intended use |
|---|---|---:|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | Enabled | 30 days | Lower-cost development/testing with production-aligned runtime detection |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

Explicit egress behavior:

| `egress_mode` | Network Firewall | NAT Gateway | Compute-private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective mode is selected from `deployment_profile`.

GuardDuty Fargate Runtime Monitoring also follows the deployment profile directly in v1.10. There is no independent top-level Runtime Monitoring toggle:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

The Scheduled Backup column controls the plan/selection behavior, not whether the environment backup vault exists. The KMS-encrypted backup vault is retained in all profiles. When scheduled backup is disabled, effective schedule/retention are null, the plan/selection are absent, and workload EC2/RDS resources use `Backup=false`. Production defaults to `cron(0 5 * * ? *)` with 30-day retention; explicitly enabled non-production backup defaults to 7-day retention unless overridden.

`vpc_endpoints_only` is intended for AWS-private testing or workloads that do not require general internet access. Public package repositories and third-party services require another explicitly approved path.
## Security Architecture

The baseline combines centralized security governance with workload-local enforcement.

| Service / capability | Primary Terraform ownership | Purpose |
|---|---|---|
| Security Hub CSPM | `security_operations/security_services` | Central policy, standards, finding aggregation, workload associations |
| GuardDuty organization policy | `security_operations/security_services` | Organization enrollment, protection plans, Runtime Monitoring and automated agent policy |
| ECS Runtime Monitoring intent | Workload | `GuardDutyManaged` cluster participation, exact task-execution IAM, networking, validation |
| GuardDuty live Fargate agent | GuardDuty service-managed | Agent injection/upgrades and runtime telemetry |
| Security Hub V2 | Control-plane prerequisites + security-operations policy | Workload enablement through `SECURITYHUB_POLICY` |
| AWS Config / Inspector | Workload | Configuration monitoring, remediation support, vulnerability scanning |
| CloudTrail / CloudWatch | Workload | API activity, logs, metrics, and alarms |
| EventBridge / Lambda | Workload | Detection routing, coverage-health notification, deterministic response automation |
| SNS / SQS | Workload | Alert delivery, retention, and failure paths |
| IAM Identity Center | Control plane | Centralized workforce access |
| AWS Backup / SSM Patch Manager | Workload | Recovery and patch-management foundations |

The v1.10 centralized GuardDuty Runtime Monitoring contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

Central Security Hub CSPM and GuardDuty governance reduce account-level drift while workload Terraform retains AWS Config, Inspector, remediation, logging, and incident-response responsibilities.

The workload VPC endpoint layer pre-creates `guardduty-data`; runtime validation requires exactly one such endpoint and exact agreement between the live VPC Endpoint ID and Terraform output. Protected Fargate tasks also use Terraform-owned `ecr.api`, `ecr.dkr`, and S3 private paths.

EC2 remains supported with fail-closed isolation authorization, first-boot package updating, scheduled SSM patching, controlled rollback, and Terraform lifecycle handling that does not silently undo active quarantine.

Automatic EC2 isolation is intentionally narrower than the general Security Hub alert/enrichment path. EventBridge forwards only active, `NEW`, HIGH/CRITICAL GuardDuty findings for `AwsEc2Instance` resources to the isolation Lambda. The Lambda then independently revalidates GuardDuty product identity, workflow state, record state, and the configured `ec2_auto_isolation_severities` set, which defaults to `CRITICAL`, before evaluating the instance-level `IsolationAllowed` and quarantine gates.

Automatic ECS/Fargate containment is not implemented in v1.10; Runtime Monitoring provides detection and coverage visibility while a separate fail-closed containment design remains future work.
## ECS/Fargate Runtime and Operations

`v1.8.0 — Secure Container Workloads` established the generic ECS/Fargate runtime. `v1.9.0` added explicit runtime-operations ownership, target-tracking auto scaling, deployment-health configuration, and operational alarms. `v1.10.0 — ECS Runtime Security` adds GuardDuty Fargate Runtime Monitoring and exact runtime-security validation without changing the canonical application-service model.

The runtime remains composed from:

```text
modules/ecr
modules/ecs_cluster
modules/application_load_balancer
modules/ecs_service
```

A canonical service can be registered with:

```hcl
image_digest = null
```

That state is **registered but unreleased**: the required ECR repository can exist while the task definition, ECS service, per-service runtime IAM, task security group, runtime log group, scaling resources, and optional ALB attachment remain absent.

Selecting a valid digest materializes the deployable runtime from the same service entry.

Deployable images use exact immutable references:

```text
<repository_url>@sha256:<digest>
```

Fargate tasks run in compute-private subnets with `awsvpc` and no public IP. Per-service logs use:

```text
/aws/ecs/<name-prefix>/<service>
```

Container Insights performance logs use:

```text
/aws/ecs/containerinsights/<cluster-name>/performance
```

Both logging paths are Terraform-owned and use the effective workload retention policy and logs CMK.

### Scaling ownership

Scaling is optional per service.

```hcl
scaling = null
```

means no platform-owned Application Auto Scaling target or scaling policy is created, and Terraform owns the exact ECS `desired_count`.

A non-null scaling object defines minimum/maximum capacity plus at least one target-tracking metric:

```hcl
scaling = {
  min_capacity               = 1
  max_capacity               = 3
  cpu_target_percent         = 50
  memory_target_percent      = 60
  alb_requests_per_target    = null
  scale_in_cooldown_seconds  = 300
  scale_out_cooldown_seconds = 300
}
```

For autoscaled services, the configured `desired_count` is bootstrap capacity only. Application Auto Scaling owns subsequent live desired count changes within the configured bounds, and Terraform intentionally does not reconcile legitimate autoscaler changes back to the bootstrap count.

Supported target-tracking metrics are:

- ECS average CPU utilization
- ECS average memory utilization
- ALB request count per target

`ALBRequestCountPerTarget` requires service ingress. Its Application Auto Scaling resource label is derived from Terraform-owned ALB and target-group ARN suffixes rather than reconstructed from names.

### Deployment health

Each service supports deployment-health configuration:

```hcl
deployment = {
  minimum_healthy_percent           = 100
  maximum_percent                   = 200
  health_check_grace_period_seconds = 0
}
```

Those values apply to both fixed-count and autoscaled services, while the existing ECS deployment circuit breaker and automatic rollback remain enabled.

### Operational signals

Terraform owns two ECS operational alarm classes:

- sustained `DesiredTaskCount - RunningTaskCount > 0` for services monitored through Container Insights; and
- sustained `UnHealthyHostCount > 0` for ingress-enabled services.

Both alarm classes notify the SecOps SNS topic on `ALARM` and `OK`.

These alarms are separate from the CloudWatch alarms that AWS creates internally for target-tracking policies. AWS-managed target-tracking alarms remain AWS-managed.

### GuardDuty Fargate Runtime Monitoring

The shared ECS cluster expresses profile-derived participation through the exact `GuardDutyManaged` tag:

```text
production/development -> true
minimal                -> false
```

For protected profiles, each deployable service's task execution role receives only the additional ECR pull scope for the regional AWS-hosted `aws-guardduty-agent-fargate` repository. Application image permissions remain independently resource-scoped.

Terraform's task definition remains application-only. GuardDuty injects and manages the runtime agent on protected tasks. Live ECS may report the agent as `aws-gd-agent` or an AWS-generated `aws-guardduty-agent-<suffix>` name.

For protected running tasks, `validate-ecs-runtime.sh` requires exactly one running GuardDuty agent, a valid application container, and GuardDuty ECS coverage of `AUTO_MANAGED` / `HEALTHY` with no unresolved issues.

Coverage-state changes are routed through the existing SecOps notification architecture. The default-bus rule matches both `GuardDuty Runtime Protection Unhealthy` and `GuardDuty Runtime Protection Healthy` for ECS resources and uses the shared EventBridge security-notification DLQ/retry policy.

See [`docs/ecs-runtime-design.md`](docs/ecs-runtime-design.md) for the full runtime and runtime-security contract.
## CI/CD and Application Releases

GitHub Actions uses OIDC to assume account-specific AWS roles without storing long-lived AWS access keys.

Core workflows include:

- `Deploy Application`
- `Terraform Plan`
- `Terraform Apply`
- `Reconcile Workload Account`
- `Terraform Destroy`
- Static analysis and documentation validation
- Workload, control-plane, and security-operations evidence export

### Terraform Plan and Apply

The standalone `Terraform Plan` workflow is informational and does not produce the artifact consumed by Apply.

The self-contained `Terraform Apply` workflow follows:

```text
internal Plan job
  -> readable plan
  -> binary saved plan
  -> metadata + checksum
  -> protected approval
  -> verify exact artifact
  -> apply exact binary plan
```

Workload Plan/Apply paths require a valid `DEPLOYMENT_PROFILE` and fail closed when it is missing or invalid.

### Application publication

Application publication is separate from Terraform infrastructure deployment:

```text
application source + Dockerfile
  -> branch-trusted GitHub OIDC image publisher
  -> build and push image to ECR
  -> resolve authoritative sha256 digest
  -> separate repository-write job
  -> update only ecs_services.<service>.image_digest
  -> release PR
  -> human review and merge
  -> protected Terraform Apply
  -> ECS convergence
  -> validation
```

The image-publisher job has AWS/ECR authority but not repository-write authority. The release-PR job has repository-write authority but no AWS credentials or OIDC token.

Terraform never builds or pushes application images.

See [`scripts/deployment/README.md`](scripts/deployment/README.md) for detailed operator behavior.

---

## Deployment Overview

Recommended high-level sequence:

1. Bootstrap and migrate the control-plane state stack.
2. Deploy the control-plane account and Organizations stacks.
3. Bootstrap and migrate the security-operations state stack.
4. Deploy the security-operations account and centralized security-services stack.
5. Bootstrap and migrate each workload state stack and deploy its account/OIDC stack.
6. Deploy `environments/<env>` through the local or protected plan-first path.
7. Reconcile workload account-stack permissions when GitHub OIDC is enabled.
8. Deploy or re-apply IAM Identity Center assignments.
9. Run the applicable validation and evidence workflows.
10. Complete approved live/manual security tests and destroy-safety review.

Supported state migration targets:

```text
control-plane
security-operations
dev
staging
prod
```

For detailed deployment instructions, use [`docs/quickstart.md`](docs/quickstart.md).

---

## Validation and Evidence

The repository uses four read-only validation layers:

| Layer | Validator | Evidence exporter |
|---|---|---|
| Control plane | `validate-control-plane.sh` | `export-control-plane.sh` |
| Security operations | `validate-security-operations.sh` | `export-security-operations.sh` |
| Workload bootstrap | `validate-bootstrap.sh <env>` | `export-bootstrap.sh <env>` |
| Workload baseline | `validate-baseline.sh <env>` | `export-baseline.sh <env>` |

The workload baseline suite contains 16 validators covering environment identity, networking, VPC endpoints, ECR, logging, workload security, KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, EC2 compute, ECS runtime, and IAM.

ECS Runtime Monitoring stays inside the existing workload-baseline layer; v1.10 does not introduce a fifth validation/evidence layer or a seventeenth workload validator.

The v1.10 runtime-security evidence chain verifies:

- deployment-profile Runtime Monitoring intent;
- exact Terraform/live `GuardDutyManaged` cluster tag;
- one `RUNNING` GuardDuty agent on each protected running task;
- the canonical Terraform task definition remaining application-only;
- GuardDuty ECS coverage `AUTO_MANAGED` / `HEALTHY` with no unresolved issues for protected running workloads;
- disabled-state coverage semantics for `minimal`;
- exact GuardDuty-agent ECR pull scope and absence of broad/unexpected ECR authority;
- exact Terraform-owned `guardduty-data` endpoint reuse;
- exact healthy/unhealthy GuardDuty coverage EventBridge rule, SecOps SNS target, shared DLQ, retry policy, and input transformer; and
- the existing scaling, deployment-health, logging, networking, ALB/database, and ECS operational-alarm contracts.

Security-operations validation separately proves the centralized organization policy and permits AWS-returned GuardDuty features outside Terraform management only when they remain disabled.

`validate-backup.sh` now owns the exact profile-aware Backup contract: the encrypted vault is retained in enabled and disabled states; plan/selection resources and resource `Backup` tags follow `effective_backup_enabled`; schedule/retention are null when disabled.

The merged R6 live qualification against development infrastructure confirmed:

- centralized `ECS_FARGATE_AGENT_MANAGEMENT = ALL`;
- live `GuardDutyManaged=true`;
- injected GuardDuty agent `RUNNING`;
- application steady state preserved;
- GuardDuty ECS coverage `AUTO_MANAGED` and `HEALTHY`;
- zero unresolved coverage issues;
- Terraform-owned `guardduty-data` reuse;
- exact agent ECR IAM scope;
- corrected disabled-backup semantics;
- `validate-ecs-runtime.sh` PASS; and
- full workload baseline `16/16` PASS.

The final workload evidence export completed with overall `PASS`.

Generated evidence includes Markdown, JSON, and per-validator logs. These results provide point-in-time technical-control and audit-readiness evidence; they are not SOC 2 or ISO 27001 certification.

Detailed guidance:

- [`scripts/validation/README.md`](scripts/validation/README.md)
- [`docs/validation-checklist.md`](docs/validation-checklist.md)
- [`docs/assurance/validation-evidence-guide.md`](docs/assurance/validation-evidence-guide.md)
- [`docs/assurance/validation-report-template.md`](docs/assurance/validation-report-template.md)

Live EC2 isolation/rollback, IP enrichment, IAM Identity Center end-user login, tamper simulation, break-glass assumption, and destroy-safety testing remain separately controlled activities.
## State Management

Terraform state is separated by account and Terraform root.

State bootstrap stacks follow a two-phase lifecycle:

```text
1. Initial local apply creates the S3 state bucket and KMS CMK.
2. migrate-state-stack.sh migrates the state into that protected S3 backend.
```

Remote-backed roots use Terraform S3 native locking with:

```hcl
use_lockfile = true
```

Tracked `backend.tf.migrated.example` files document intended post-migration configuration, while active state-stack `backend.tf` files are ignored by Git.

A state stack must never destroy the bucket containing its own active state. Intentional teardown requires moving that state to an independent backend or local state and retaining an external backup first.

See [`scripts/bootstrap/README.md`](scripts/bootstrap/README.md) for migration and reconciliation details.

---

## Cost Considerations

Major cost drivers can include AWS Network Firewall, NAT Gateways, Interface VPC Endpoints, CloudWatch, AWS Config, Inspector, Security Hub/GuardDuty features, GuardDuty Runtime Monitoring monitored-vCPU/runtime-agent overhead, Backup storage/scheduling, ECS/Fargate workloads, and Application Load Balancers.

Recommended defaults:

- `production` for production or sensitive workloads
- `development` for lower-cost development/testing
- `minimal` for private AWS-only testing without general internet access

Review environment-specific usage and AWS pricing before treating the default profiles as a fixed cost model.

---

## Repository Layout

```text
bootstrap/       account, state, Organizations, Identity Center, and security-operations roots
environments/    dev, staging, and prod workload roots
modules/         reusable infrastructure modules
scripts/         bootstrap, deployment, and validation tooling
docs/            architecture, adoption, validation, assurance, and runtime design
.github/         CI/CD, static-analysis, and evidence workflows
```

---

## Documentation

| Document | Purpose |
|---|---|
| [`docs/quickstart.md`](docs/quickstart.md) | End-to-end deployment guide |
| [`docs/architecture-overview.md`](docs/architecture-overview.md) | Architecture and ownership boundaries |
| [`docs/design-principles.md`](docs/design-principles.md) | Design rationale and tradeoffs |
| [`docs/adoption-guide.md`](docs/adoption-guide.md) | Guidance for adapting the baseline |
| [`docs/ecs-runtime-design.md`](docs/ecs-runtime-design.md) | ECS/Fargate runtime and release architecture |
| [`docs/validation-checklist.md`](docs/validation-checklist.md) | Post-deployment validation checklist |
| [`docs/assurance/`](docs/assurance/) | Evidence guidance and SOC 2 / ISO 27001-aligned mappings |
| [`scripts/bootstrap/README.md`](scripts/bootstrap/README.md) | State migration and workload-account reconciliation |
| [`scripts/deployment/README.md`](scripts/deployment/README.md) | Application publication and digest promotion |
| [`scripts/validation/README.md`](scripts/validation/README.md) | Validation layers, usage, and safety boundaries |
| [`bootstrap/control_plane/README.md`](bootstrap/control_plane/README.md) | Control-plane responsibilities |
| [`bootstrap/security_operations/README.md`](bootstrap/security_operations/README.md) | Central-security responsibilities |

---

## Release Highlights

### Current Release: `v1.10.0 — ECS Runtime Security`

`v1.10.0` adds:

- Centralized `ECS_FARGATE_AGENT_MANAGEMENT = ALL` while preserving `EC2_AGENT_MANAGEMENT = ALL` and `EKS_ADDON_MANAGEMENT = NONE`
- Secure-by-default Runtime Monitoring for `production` and `development`, with deliberate `minimal` exclusion
- Exact `GuardDutyManaged=true|false` ECS cluster intent
- Region-aware, least-privilege GuardDuty agent ECR image-pull scope
- GuardDuty-managed live agent injection while Terraform task definitions remain application-only
- Exact live validation of injected agent state and GuardDuty ECS coverage
- `AUTO_MANAGED` / `HEALTHY` coverage requirements with zero unresolved issues for protected running workloads
- Terraform-owned `guardduty-data` endpoint reuse and duplicate-endpoint rejection
- Healthy/unhealthy GuardDuty Runtime coverage events routed to the existing SecOps SNS path with DLQ/retry protection
- Security-operations validation aligned with AWS's full returned feature inventory while failing closed on unmanaged enabled features
- Corrected profile-aware AWS Backup behavior: retained encrypted vault, conditional plan/selection, nullable schedule/retention, and exact EC2/RDS `Backup` tags
- Live R6 development qualification with `validate-ecs-runtime.sh` PASS and the full workload baseline at `16/16` PASS

### Previous Release: `v1.9.0`

`v1.9.0` added:

- Explicit fixed-count versus autoscaled ECS `desired_count` ownership
- Application Auto Scaling targets for autoscaled services
- CPU and memory target-tracking policies
- Conditional `ALBRequestCountPerTarget` target tracking
- Resource-backed ALB/target-group identifiers for scaling and monitoring
- Configurable deployment minimum/maximum percentages and health-check grace period
- Terraform-owned ECS task-deficit and ingress unhealthy-target alarms
- Exact runtime validation for scaling targets, policies, deployment configuration, dynamic desired count, and operational alarms
- Modularized ECS runtime validator internals while preserving one workload-baseline validator entry point
- GuardDuty-scoped EC2 isolation EventBridge filtering
- Configurable `ec2_auto_isolation_severities`, defaulting to `CRITICAL`
- Lambda-side fail-closed revalidation of GuardDuty product, severity, workflow status, and record state

### Earlier Release: `v1.8.0`

`v1.8.0 — Secure Container Workloads` established:

- Canonical `ecs_services` configuration with nullable `image_digest`
- KMS-encrypted immutable ECR repositories
- Exact digest-pinned Fargate task images
- Shared ECS cluster and optional shared HTTPS ALB
- Separate least-privilege task execution and application task roles
- Terraform-owned application and Container Insights logging
- GitHub OIDC image publication and authoritative ECR digest resolution
- Automated one-field release PR generation
- Protected exact saved-plan Terraform Apply
- 16-validator workload baseline coverage including ECR and ECS runtime validation

For complete release history, see [`CHANGELOG.md`](CHANGELOG.md).
## Future Roadmap

After v1.10.0, remaining candidates include:

- Fail-closed ECS/Fargate task-level containment/remediation
- Platform resilience improvements such as third-AZ and stronger RDS resilience/validation
- ReconoSense reference deployment
- Scheduled/run-to-completion ECS task abstractions
- Audited ECS Exec
- Advanced WAF and DNS ownership
- Multi-container service abstractions
- Application database-user lifecycle
- More sophisticated historical ECR retention

Other potential improvements include expanded dashboarding and visual evidence, configurable VPC endpoint service lists, additional deployment-profile-controlled services, a deliberate Service Control Policy strategy, multi-region centralized security/evidence patterns, and additional synthetic workload examples.
## Intended Audience

- Cloud security engineers
- DevSecOps engineers
- Platform engineers
- SaaS founders
- Security consultants
- Teams preparing for SOC 2 / ISO 27001

---

## Summary

`tf-secure-baseline` is a deployable AWS security foundation and generic application-hosting baseline for sensitive workloads.

It combines five-account isolation, Organizations and Identity Center governance, centralized security administration, private-first networking, configurable egress, Security Hub/GuardDuty governance, profile-driven GuardDuty ECS/Fargate Runtime Monitoring, workload-local remediation, supported EC2 hosting, digest-pinned ECS/Fargate workloads, optional target-tracking auto scaling, explicit service-count ownership, ECS deployment-health controls, runtime coverage notification, durable alerting, protected Terraform CI/CD, profile-aware backup controls, and layered validation evidence into a reusable Terraform platform.

The goal is to provide a secure-by-default foundation that can be adapted and extended without representing the infrastructure alone as a complete compliance program.

---

## License

Copyright © 2026 Jacob Molland.

This project is licensed under the Apache License 2.0.

Terraform Secure Baseline is developed and maintained under the Nano Nexus Consulting brand, operated by Nano Nexus Holdings LLC. See [LICENSE](LICENSE) for details.