# terraform-secure-baseline

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security and application-hosting baseline for organizations running workloads that handle PII or other sensitive data.

**Current published release:** `v1.8.0 — Secure Container Workloads`.

**Main branch release candidate:** `v1.9.0` extends the ECS/Fargate runtime with Application Auto Scaling, explicit fixed-vs-autoscaled service-count ownership, deployment-health controls, operational alarms, exact runtime validation, and GuardDuty-scoped EC2 isolation hardening. The v1.9 implementation through live qualification is merged to `main`; the release is not yet published.

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

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | Log retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

Explicit egress behavior:

| `egress_mode` | Network Firewall | NAT Gateway | Compute-private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective mode is selected from `deployment_profile`.

`vpc_endpoints_only` is intended for AWS-private testing or workloads that do not require general internet access. Public package repositories and third-party services require another explicitly approved path.

---

## Security Architecture

The baseline combines centralized security governance with workload-local enforcement.

| Service / capability | Primary Terraform ownership | Purpose |
|---|---|---|
| Security Hub CSPM | `security_operations/security_services` | Central policy, standards, finding aggregation, workload associations |
| GuardDuty | `security_operations/security_services` | Organization enrollment, protection plans, Runtime Monitoring |
| Security Hub V2 | Control-plane prerequisites + security-operations policy | Workload enablement through `SECURITYHUB_POLICY` |
| AWS Config / Inspector | Workload | Configuration monitoring, remediation support, vulnerability scanning |
| CloudTrail / CloudWatch | Workload | API activity, logs, metrics, and alarms |
| EventBridge / Lambda | Workload | Detection routing and deterministic response automation |
| SNS / SQS | Workload | Alert delivery, retention, and failure paths |
| IAM Identity Center | Control plane | Centralized workforce access |
| AWS Backup / SSM Patch Manager | Workload | Recovery and patch-management foundations |

Central Security Hub CSPM and GuardDuty governance reduce account-level drift while workload Terraform retains AWS Config, Inspector, remediation, logging, and incident-response responsibilities.

The workload VPC endpoint layer pre-creates `guardduty-data` so Runtime Monitoring does not introduce unmanaged workload networking.

EC2 remains supported with fail-closed isolation authorization, first-boot package updating, scheduled SSM patching, controlled rollback, and Terraform lifecycle handling that does not silently undo active quarantine.

Automatic EC2 isolation is intentionally narrower than the general Security Hub alert/enrichment path. EventBridge forwards only active, `NEW`, HIGH/CRITICAL GuardDuty findings for `AwsEc2Instance` resources to the isolation Lambda. The Lambda then independently revalidates GuardDuty product identity, workflow state, record state, and the configured `ec2_auto_isolation_severities` set, which defaults to `CRITICAL`, before evaluating the instance-level `IsolationAllowed` and quarantine gates.

---

## ECS/Fargate Runtime and Operations

`v1.8.0 — Secure Container Workloads` established the generic ECS/Fargate runtime without replacing the existing EC2 path. The qualified v1.9 implementation on `main` adds explicit runtime-operations ownership, target-tracking auto scaling, deployment-health configuration, and operational signals.

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

Supported v1.9 target-tracking metrics are:

- ECS average CPU utilization
- ECS average memory utilization
- ALB request count per target

`ALBRequestCountPerTarget` requires service ingress. Its Application Auto Scaling resource label is derived from Terraform-owned ALB and target-group ARN suffixes rather than reconstructed from names.

### Deployment health

Each service also supports deployment-health configuration:

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

See [`docs/ecs-runtime-design.md`](docs/ecs-runtime-design.md) for the full runtime contract.

---

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

ECS runtime operations remain inside the existing workload-baseline layer; v1.9 does not introduce a fifth validation/evidence layer.

The ECS runtime validator now verifies:

- exact fixed-count versus autoscaled service ownership;
- live desired count equality for fixed services and configured bounds for autoscaled services;
- exact Application Auto Scaling target inventory;
- exact CPU, memory, and conditional ALB request-count target-tracking policy configuration;
- deployment minimum/maximum percentages and health-check grace period;
- task-deficit operational alarm configuration and current state;
- ingress unhealthy-target alarm configuration and current state;
- the existing cluster, task-definition, logging, networking, database, and ALB runtime contracts.

AWS-managed target-tracking alarms are intentionally excluded from Terraform-owned operational alarm inventory.

When the GitHub Image Publisher role is enabled, workload bootstrap validation also verifies its exact branch-based OIDC trust and ECR publication/query authority. Strict release/client evidence can require the publisher role explicitly.

The v1.9 live qualification gate completed successfully on development infrastructure:

- CPU target-tracking scale-out/in: PASS
- Memory target tracking: PASS
- ALB request-count target tracking: PASS
- Fixed-count ownership: PASS
- Autoscaled desired-count ownership: PASS
- Digest release while scaled: PASS
- Deployment-health configuration: PASS
- Operational alarm configuration: PASS
- `validate-ecs-runtime.sh`: PASS
- Full workload baseline: `16/16` PASS
- Strict workload bootstrap: `1/1` PASS
- Final Terraform plan: no changes

Generated evidence includes Markdown, JSON, and per-validator logs. These results provide point-in-time technical-control and audit-readiness evidence; they are not SOC 2 or ISO 27001 certification.

Detailed guidance:

- [`scripts/validation/README.md`](scripts/validation/README.md)
- [`docs/validation-checklist.md`](docs/validation-checklist.md)
- [`docs/assurance/validation-evidence-guide.md`](docs/assurance/validation-evidence-guide.md)
- [`docs/assurance/validation-report-template.md`](docs/assurance/validation-report-template.md)

Live EC2 isolation/rollback, IP enrichment, IAM Identity Center end-user login, tamper simulation, break-glass assumption, and destroy-safety testing remain separately controlled activities.

---

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

Major cost drivers can include AWS Network Firewall, NAT Gateways, Interface VPC Endpoints, CloudWatch, AWS Config, Inspector, Security Hub/GuardDuty features, Backup, ECS/Fargate workloads, and Application Load Balancers.

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

### Current Published Release: `v1.8.0`

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

### Upcoming Release Candidate: `v1.9.0`

The qualified v1.9 implementation on `main` adds:

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
- Completed live O7 qualification with full workload and strict bootstrap validation plus a final no-change Terraform plan

`v1.9.0` is not yet the latest published GitHub release; O8 documentation and release preparation must complete before publication.

### Previous Release: `v1.7.0`

`v1.7.0` introduced the dedicated `security-operations` administration layer and centralized Security Hub CSPM, GuardDuty, and Security Hub V2 governance.

For complete release history, see [`CHANGELOG.md`](CHANGELOG.md).

---

## Future Roadmap

After the qualified v1.9 runtime-operations work, remaining candidates include:

- GuardDuty Fargate managed-agent enablement
- Fail-closed ECS task-level containment/remediation
- ReconoSense reference deployment
- Scheduled/run-to-completion ECS task abstractions
- Audited ECS Exec
- Advanced WAF and DNS ownership
- Multi-container service abstractions
- Application database-user lifecycle
- More sophisticated historical ECR retention

Other potential improvements include expanded dashboarding and visual evidence, configurable VPC endpoint service lists, additional deployment-profile-controlled services, a deliberate Service Control Policy strategy, multi-region centralized security/evidence patterns, and additional synthetic workload examples.

---

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

It combines five-account isolation, Organizations and Identity Center governance, centralized security administration, private-first networking, configurable egress, Security Hub/GuardDuty governance, workload-local remediation, supported EC2 hosting, digest-pinned ECS/Fargate workloads, optional target-tracking auto scaling, explicit service-count ownership, ECS deployment-health controls, operational alarms, durable alerting, protected Terraform CI/CD, and layered validation evidence into a reusable Terraform platform.

The current published release is v1.8.0. The v1.9.0 implementation on `main` has completed live qualification and is in documentation/release preparation.

The goal is to provide a secure-by-default foundation that can be adapted and extended without representing the infrastructure alone as a complete compliance program.

---

## License

Copyright © 2026 Jacob Molland.

This project is licensed under the Apache License 2.0.

Terraform Secure Baseline is developed and maintained under the Nano Nexus Consulting brand, operated by Nano Nexus Holdings LLC. See [LICENSE](LICENSE) for details.