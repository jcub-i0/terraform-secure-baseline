# terraform-secure-baseline

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security baseline designed for organizations running applications that handle PII or other sensitive data.

**Current tagged release:** `v1.7.0` — centralized Security Hub CSPM, GuardDuty, and Security Hub V2 governance through a dedicated `security-operations` account, with corresponding CI planning and validation evidence.

**Current development theme:** unreleased `v1.8.0 — Secure Container
Workloads`; the core ECS/Fargate runtime and its validation are implemented on
`main`.

It provides a secure, multi-account cloud foundation with:

- A centralized AWS Organizations and identity control plane
- A dedicated security-operations delegated-administrator account
- Environment isolation across `dev`, `staging`, and `prod`
- Secure-by-default networking and private AWS service access
- Configurable deployment profiles and egress modes
- Centralized logging, monitoring, and alert routing
- Centralized Security Hub CSPM and GuardDuty organization governance
- Security Hub V2 workload enablement through AWS Organizations policy
- Automated detection and response with fail-closed EC2 isolation
- Durable SNS/SQS notification paths and DLQs for failed delivery
- GitHub OIDC-based plan-before-approval CI/CD
- Exact reviewed-plan application through protected workload Apply environments
- Four-layer read-only validation and evidence export
- SOC 2 / ISO 27001-aligned technical safeguards to support audit readiness

This project is intended for SaaS companies, startups, and engineering teams that need a repeatable AWS security foundation without building every security control from scratch.

> This baseline supports SOC 2 and ISO 27001 readiness, but it does not replace an organization’s full compliance program, ISMS, policies, risk management process, or formal audit requirements.

---

## What This Project Provides

This repository deploys a production-aligned AWS security baseline using Terraform.

Key capabilities include:

- Five-account architecture: `control-plane`, `security-operations`, `dev`, `staging`, and `prod`
- AWS Organizations OU separation for `Security`, `Workloads/NonProd`, and `Workloads/Prod`
- IAM Identity Center access management, including dedicated `SecOps-Administrator` access for security operations
- GitHub Actions OIDC federation without long-lived CI/CD access keys
- Private-first VPC networking with dedicated Interface Endpoint subnets
- Configurable deployment profiles for production, development, and minimal deployments
- Configurable egress modes for Network Firewall, NAT-only, or VPC-endpoints-only operation
- AWS Network Firewall egress inspection when enabled
- Private AWS service access through Terraform-managed VPC endpoints
- Centralized CloudTrail, Config, and VPC Flow Log storage
- Centralized Security Hub CSPM configuration policies and finding aggregation
- Centralized GuardDuty member enrollment and protection-plan governance
- GuardDuty Runtime Monitoring with Terraform-owned `guardduty-data` VPC endpoints
- Security Hub V2 organization policy governance for workload accounts
- Workload-local AWS Config, Inspector, remediation, and incident-response automation
- Event-driven EC2 isolation, controlled rollback, IP enrichment, tamper detection, and break-glass monitoring
- SQS-backed security and compliance notification queues
- EventBridge target DLQs and workflow-specific automation DLQs
- Encrypted S3, KMS, SNS, SQS, CloudWatch, Lambda, EBS, and backup resources
- First-boot Ubuntu package updates and scheduled SSM patching
- Dependency-aware EC2 launch ordering for security-policy rules and Interface VPC Endpoints
- A shared-per-environment ECS cluster and generic long-running Fargate services using digest-pinned ECR images
- Conditional shared HTTPS Application Load Balancers with explicit host/path routing and fail-closed defaults
- Per-service least-privilege ECS IAM roles, task security groups, encrypted application log groups, and resource-granular launch readiness
- Layer-specific validation evidence export with Markdown, JSON, and per-script logs

---

## Target Use Case

This baseline is designed for:

- SaaS companies handling PII
- Teams preparing for SOC 2 or ISO 27001
- Organizations that need secure AWS account separation
- Cloud security teams building reusable landing-zone patterns
- Startups that need production-ready security architecture early
- Consultants implementing secure AWS foundations for clients

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

Each state stack is initialized and applied locally first because it creates the S3 bucket and KMS key that will store its own Terraform state. After those resources exist, `scripts/bootstrap/migrate-state-stack.sh` materializes the ignored active `backend.tf` from the tracked `backend.tf.migrated.example`, migrates the local state into S3, and verifies that the remote state is readable.

The platform separates three Terraform ownership domains:

- The **control plane** owns organization structure, account placement, trusted service access, delegated-administrator registration, Identity Center, and management-account prerequisites.
- The **security-operations layer** owns delegated-administrator-side Security Hub CSPM, GuardDuty, and Security Hub V2 organization policy configuration.
- The **workload environments** own workload networking, compute, logging, AWS Config, Inspector, remediation, automation, storage, backup, patching, and supporting controls while deferring centrally governed service ownership.

GitHub Actions uses OIDC-based Plan roles for workload, control-plane, and supported security-operations planning/evidence paths. Protected workload Apply environments continue to use exact saved-plan application. The generic workload Apply and Destroy workflows intentionally do not operate the centralized security layer.

Architectural deployment order:

```text
control-plane -> security-operations -> bootstrap-workloads -> workloads
```

---

## Repository Structure

```text
.
├── bootstrap
│   ├── control_plane
│   │   ├── account
│   │   ├── identity_center
│   │   ├── organizations
│   │   └── state
│   ├── security_operations
│   │   ├── account
│   │   ├── security_services
│   │   └── state
│   ├── dev
│   │   ├── account
│   │   └── state
│   ├── staging
│   │   ├── account
│   │   └── state
│   └── prod
│       ├── account
│       └── state
│
├── environments
│   ├── dev
│   ├── staging
│   └── prod
│
├── modules
│   ├── application_load_balancer
│   ├── automation
│   ├── backup
│   ├── compute
│   ├── ecr
│   ├── ecs_cluster
│   ├── ecs_service
│   ├── firewall
│   ├── github_oidc
│   ├── iam
│   ├── identity_center
│   ├── logging
│   ├── monitoring
│   ├── networking
│   │   └── security_policy
│   ├── patch_management
│   ├── security
│   │   ├── config_baseline
│   │   └── tamper_detection
│   ├── security_dashboard
│   ├── state
│   ├── storage
│   └── vpc_endpoints
│
├── docs
│   ├── architecture-overview.md
│   ├── design-principles.md
│   ├── quickstart.md
│   ├── adoption-guide.md
│   ├── validation-checklist.md
│   ├── assurance
│   └── lambda_tests
│
├── scripts
│   ├── bootstrap
│   │   ├── migrate-state-stack.sh
│   │   └── reconcile-workload-account.sh
│   └── validation
│       ├── export-baseline.sh
│       ├── export-bootstrap.sh
│       ├── export-control-plane.sh
│       ├── export-security-operations.sh
│       ├── validate-baseline.sh
│       ├── validate-bootstrap.sh
│       ├── validate-control-plane.sh
│       ├── validate-security-operations.sh
│       ├── validate-security-workload.sh
│       └── validate-*.sh
│
├── .github/workflows
├── CHANGELOG.md
├── LICENSE
├── README.md
└── SECURITY.md
```

---

## Terraform Variable Templates

Terraform roots that require local configuration include a tracked `terraform.tfvars.example` template. Terraform does not automatically load files ending in `.example`, so copy the applicable template before running Terraform locally:

```bash
cp environments/dev/terraform.tfvars.example \
  environments/dev/terraform.tfvars
```

Review the copied file and replace example values with the correct deployment-specific configuration. Runtime `terraform.tfvars` files are ignored by Git and must not be committed. GitHub Actions receives its deployment values separately through workflow matrices, GitHub variables, and GitHub secrets rather than loading the example files.

## Core Design Principles

### Private-First Infrastructure

Compute workloads are deployed in private subnets by default. Internet-bound egress follows an explicitly selected Network Firewall, NAT-only, or no-default-route path, while supported AWS service traffic can remain private through VPC endpoints.

### Dependency-Safe First Boot

EC2 instances wait on two resource-level readiness checkpoints before launch:

```text
security_policy.compute_sg_rule_ids ───┐
                                      ├──> aws_instance.ec2
vpc_endpoints.interface_endpoint_ids ──┘
```

This avoids broad module dependencies while ensuring required security-group rules and Terraform-managed Interface Endpoints—including `guardduty-data`—exist before eligible instances launch. Route, NAT Gateway, Network Firewall, DNS, and external repository health remain separate runtime dependencies.

ECS services use the same resource-granular principle without introducing a module dependency cycle:

```text
IAM execution policy IDs ───────────────┐
                                       ├──> aws_ecs_service.services
security-policy rule IDs ──────────────┘
```

`modules/ecs_service` records those IDs in `terraform_data` readiness resources. Only service launch depends on the checkpoints; task security groups remain independently creatable so `modules/networking/security_policy` can attach cross-component rules.

### Configurable Cost/Security Profiles

Deployment profiles provide production, development, and minimal defaults while allowing explicit egress and service overrides where supported.

### Multi-Account Isolation

The platform separates responsibilities across:

```text
control-plane
security-operations
dev
staging
prod
```

This reduces workload blast radius and places organization management, centralized security administration, and workload execution in distinct account boundaries.

### Explicit Central-Security Ownership

The management account owns organization prerequisites. The security-operations account owns delegated-administrator configuration. Workload accounts retain workload-local controls and deterministic remediation.

This avoids duplicating the same Security Hub, GuardDuty, or Security Hub V2 ownership in multiple Terraform states.

### No Long-Lived CI/CD Credentials

GitHub Actions authenticates to AWS using OIDC. Plan and Apply trust paths remain separated where privileged workload deployment is supported.

### Centralized Human Access

IAM Identity Center manages workforce access. Workload accounts receive environment-specific Operator access, while the security-operations account uses a distinct required Administrator persona.

### Event-Driven Security Automation

EventBridge and Lambda support EC2 isolation, rollback, IP enrichment, tamper detection, and break-glass alerts. Critical delivery paths use retries and DLQs so failed events are retained for investigation.

---

## Major Components

### Control Plane

Located at:

```text
bootstrap/control_plane
```

| Substack | Purpose |
|---|---|
| `state` | Creates the control-plane state bucket and CMK, then migrates its own state to S3 |
| `account` | Creates control-plane GitHub OIDC execution roles |
| `organizations` | Owns Organizations structure, account placement, central-security prerequisites, and delegated-administrator registration |
| `identity_center` | Manages workforce groups, permission sets, and account assignments across workload and security-operations accounts |

### Security Operations

Located at:

```text
bootstrap/security_operations
```

| Substack | Purpose |
|---|---|
| `state` | Creates and protects the security-operations Terraform backend |
| `account` | Creates security-operations GitHub OIDC roles |
| `security_services` | Manages centralized Security Hub CSPM, GuardDuty, and Security Hub V2 delegated-administrator configuration |

See `bootstrap/security_operations/README.md` for the ownership boundary and lifecycle.

### Environment Stacks

Located at:

```text
environments/dev
environments/staging
environments/prod
```

Each workload environment includes the applicable profile-driven combination of:

- VPC, subnet, and route-table segmentation
- Dedicated Interface Endpoint subnets
- Network Firewall and/or NAT Gateway egress
- Terraform-managed VPC endpoints, including `guardduty-data`
- EC2 workloads with first-boot updates and readiness gating
- One shared ECS cluster, optional digest-pinned Fargate services, ECR repositories, and a conditional shared HTTPS ALB
- S3 and purpose-specific KMS keys
- CloudTrail, CloudWatch, and centralized log delivery
- AWS Config and Config remediation when enabled
- Amazon Inspector when enabled
- Workload Security Hub/GuardDuty integration that defers local ownership under central governance
- Lambda/EventBridge security automation
- SNS/SQS notification and failure-retention paths
- Backup and patch-management resources
- IAM service roles and access policies

### Modules

Reusable Terraform modules live under `modules/`. Each module contains its own README describing its inputs, outputs, ownership, and behavior.

---

## Deployment Profiles and Egress Modes

The baseline supports deployment profiles that set default cost/security behavior per environment.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

The profile sets defaults only. Explicit variables can override profile defaults.

For example:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

The baseline also supports explicit egress modes:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective egress mode is selected from `deployment_profile`.

Important:

When `egress_mode = "vpc_endpoints_only"`, Network Firewall and NAT Gateways are not deployed, compute private subnets do not receive a default internet route, and the general compute TCP/443 egress rule is not created. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access. EC2 user data package installation and Patch Manager operations against public Ubuntu repositories require an approved package mirror or another explicitly provided path.

---

## Security Services

The baseline combines centralized governance with workload-local security controls.

| Service / Capability | Primary Terraform ownership | Purpose |
|---|---|---|
| Security Hub CSPM | `security_operations/security_services` | Central configuration policies, standards, findings aggregation, workload associations |
| GuardDuty | `security_operations/security_services` | Organization enrollment, protection plans, Runtime Monitoring |
| Security Hub V2 | control-plane prerequisites + security-operations policy | Workload enablement through `SECURITYHUB_POLICY` |
| AWS Config | workload | Configuration recording, evaluation, and remediation support |
| Inspector | workload | Vulnerability scanning |
| CloudTrail / CloudWatch | workload | API activity, logs, metrics, and alarms |
| EventBridge / Lambda | workload | Detection routing and deterministic response automation |
| SNS / SQS | workload | Alert delivery, retention, and DLQs |
| KMS | workload and bootstrap layers | Encryption key management |
| IAM Identity Center | control plane | Centralized workforce access |
| AWS Backup / SSM Patch Manager | workload | Recovery and patch-management foundations |

Central Security Hub CSPM configuration uses configuration policies associated with the workload accounts. Central GuardDuty configuration manages organization membership and supported features, including Runtime Monitoring with EC2 agent management. Security Hub V2 is enabled for workload accounts through an Organizations policy attached to the `Workloads` OU.

Workload Terraform exposes explicit ownership flags so standalone uses can manage Security Hub/GuardDuty locally while the centrally governed `dev`, `staging`, and `prod` roots defer those account-level resources.

### GuardDuty Runtime Monitoring and VPC Endpoint Ownership

The workload VPC endpoint module pre-creates the regional `guardduty-data` Interface Endpoint. This keeps the endpoint in Terraform ownership instead of allowing GuardDuty to create an unmanaged endpoint when Runtime Monitoring enrolls eligible EC2 instances.

Compute receives the Interface Endpoint ID map and waits for those endpoints before EC2 launch. This sequencing reduces drift and avoids teardown dependencies on GuardDuty-created VPC resources.

### EC2 Vulnerability Remediation and Patching

Amazon Inspector package vulnerabilities may appear as Security Hub findings. The baseline addresses stale operating-system package findings through two complementary controls:

1. **First-boot update:** Ubuntu package sources are rewritten to HTTPS, APT is forced over IPv4, transient failures are retried, incomplete metadata refreshes fail provisioning, and a noninteractive distribution upgrade runs before required packages are installed.
2. **Ongoing patching:** SSM Patch Manager targets instances by `PatchGroup` tag and applies baseline-approved patches on a schedule.

Selecting the latest Ubuntu AMI alone does not guarantee every installed package is current at launch. First-boot update closes the image-publication gap, while Patch Manager handles later maintenance.

---

## Automation Workflows

The baseline includes several security automation workflows.

### EC2 Isolation

The EventBridge rule receives new HIGH- and CRITICAL-severity Security Hub findings involving EC2 instances. The Lambda function then applies additional fail-closed eligibility checks before changing the instance.

Default behavior:

- Automatic isolation defaults to `CRITICAL` findings only.
- `AUTO_ISOLATION_SEVERITIES` can explicitly enable additional severities, such as `HIGH,CRITICAL`.
- The finding must be `ACTIVE` with workflow status `NEW`.
- The resource must be an EC2 instance in the `running` or `stopped` state.
- The instance must explicitly have `IsolationAllowed=true`.
- Already-isolated instances and duplicate instance references in the same invocation are skipped.

For an eligible instance, the workflow:

1. records the existing security groups;
2. requests tagged snapshots for attached EBS volumes;
3. fails closed if snapshot creation fails;
4. replaces the existing security groups with the quarantine security group;
5. adds isolation and recovery metadata tags; and
6. sends an SNS notification when a topic is configured.

The explicit `IsolationAllowed=true` requirement prevents a matching finding from isolating an instance unless the workload has opted into automatic response. The reusable defaults are `false`; the current environment policy enables isolation for development and disables it for staging and production.

Terraform also ignores automation-managed changes to the instance security group attachments and isolation metadata tags. A routine `terraform apply` therefore does not automatically reattach the normal compute security group or remove the recovery context from an isolated instance.

### EC2 Rollback

Triggered manually through a controlled EventBridge event on the custom SecOps event bus.

This allows a SecOps operator to restore previously isolated EC2 instances after review and approval without granting operators broad direct EC2 modification access.

### IP Threat Enrichment

Enriches IP-related Security Hub findings using the configured threat intelligence source and sends the results to SNS. The function intentionally runs outside a VPC so it can reach the external API without requiring NAT.

### Lambda Deployment Packaging

The automation module packages its three Lambda source files with managed Terraform `archive_file` resources:

```text
lambda/ec2_isolation.py  -> lambda/ec2_isolation.zip
lambda/ec2_rollback.py   -> lambda/ec2_rollback.zip
lambda/ip_enrichment.py  -> lambda/ip_enrichment.zip
```

The ZIP files are generated build outputs rather than manually maintained source artifacts. The Lambda functions depend directly on the matching archive resources, so Terraform creates each package before creating or updating the function.

This resource-based packaging is required by the plan-before-approval workflow. Plan and Apply run on separate GitHub Actions runners, and the protected Apply job can execute the archive-resource operations contained in the reviewed saved plan. No Lambda filename list or ZIP-copying logic is required in the workflow. Adding a future Lambda should remain encapsulated within the Terraform module.

### Tamper Detection

Detects attempts to disable, delete, or modify critical security services such as:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS

### Break-Glass Monitoring

Detects use of the break-glass administrator role and sends a high-priority alert.

### Notification and Failure Retention

Security and compliance notifications use encrypted SNS and SQS resources so alerts can be delivered to humans while also being retained for operational review.

Key paths include:

- Compliance notifications: compliance SNS topic to compliance SQS queue
- Security notifications: security notifications SNS topic to security notifications SQS queue
- Security notification queue failures: security notifications SQS queue to security notifications DLQ
- EventBridge-to-SNS delivery failures: shared security notifications EventBridge DLQ
- Automation workflow failures: dedicated EC2 Isolation, EC2 Rollback, and IP Enrichment DLQs

The DLQs are terminal failure-retention queues. They are intended for SecOps review, troubleshooting, and manual replay or remediation where appropriate.

### CI/CD

GitHub Actions uses OIDC to assume account-specific AWS IAM roles without storing long-lived AWS access keys.

Current workflows include:

- `Terraform Plan`
- `Terraform Apply`
- `Reconcile Workload Account`
- `Terraform Destroy`
- `Terraform Static Analysis`
- `Docs Validation`
- `Lint PR`
- `Workload Bootstrap Evidence Export`
- `Workload Baseline Evidence Export`
- `Control-Plane Evidence Export`
- `Export Security Operations Evidence`

Workload deployment follows the plan-before-approval model: a Plan role generates a readable and saved plan, the protected Apply environment waits for approval, and the Apply role verifies and applies that exact artifact without replanning.

The standalone `Terraform Plan` workflow also covers selected control-plane roots and `bootstrap/security_operations/security_services`. The security-operations Plan and evidence jobs use the `security-operations-plan` GitHub Environment.

The generic workload Apply and Destroy workflows intentionally exclude `bootstrap/security_operations/*`. Centralized security configuration has organization-wide blast radius and should use a deliberately protected platform change path rather than the workload lifecycle.

Layer-specific evidence workflows use Plan roles and read-only validators. On clean runners they materialize ignored state-stack backend files when required before Terraform initialization.

## Deployment Order

At a high level:

```text
control-plane -> security-operations -> bootstrap-workloads -> workloads
```

Recommended sequence:

1. Bootstrap and migrate `bootstrap/control_plane/state`.
2. Deploy the control-plane account and Organizations stacks.
3. Bootstrap and migrate `bootstrap/security_operations/state`.
4. Deploy `bootstrap/security_operations/account` and `security_services`.
5. Bootstrap and migrate each workload state stack and deploy its account/OIDC stack.
6. Deploy `environments/<env>` through the local or plan-first workload path.
7. Reconcile workload account-stack permissions when GitHub OIDC is enabled.
8. Deploy or re-apply control-plane IAM Identity Center assignments.
9. Run control-plane, security-operations, workload bootstrap, and workload baseline evidence workflows.
10. Complete approved live/manual security tests and destroy-safety review.

Supported state migration targets are:

```text
control-plane
security-operations
dev
staging
prod
```

Detailed instructions are in `docs/quickstart.md` and `scripts/bootstrap/README.md`.

---

## Validation

The repository uses four read-only validation layers with matching evidence exporters:

| Layer | Validator | Evidence exporter |
|---|---|---|
| Control plane | `validate-control-plane.sh` | `export-control-plane.sh` |
| Security operations | `validate-security-operations.sh` | `export-security-operations.sh` |
| Workload bootstrap | `validate-bootstrap.sh <env>` | `export-bootstrap.sh <env>` |
| Workload baseline | `validate-baseline.sh <env>` | `export-baseline.sh <env>` |

### Control-Plane Validation

Validates the management-account control plane, including remote state, GitHub OIDC, Organizations topology/account placement, centralized-security prerequisites, and IAM Identity Center groups, permission sets, and account assignments.

The validator consumes the consolidated Identity Center configuration objects:

```text
IDENTITY_CENTER_WORKLOADS
IDENTITY_CENTER_SECOPS
```

### Security Operations Validation

Validates delegated-administrator-side centralized security configuration from the `security-operations` account:

```bash
AWS_PROFILE=security-operations \
AWS_REGION=us-east-1 \
./scripts/validation/validate-security-operations.sh
```

Coverage includes Security Hub CSPM administrator state, CENTRAL configuration, configuration-policy associations, GuardDuty organization features and Runtime Monitoring, Security Hub V2 organization policy attachment, and effective workload policy state.

The corresponding evidence package is written beneath:

```text
validation-results/security-operations/security-services/<timestamp>/
```

### Workload Bootstrap Validation

`validate-bootstrap.sh` verifies workload state/backend security and GitHub OIDC execution-plane resources. Strict workload CMK checks ensure the workload Apply role references current Lambda and Secrets Manager CMKs after reconciliation.

### Workload Baseline Validation

`validate-baseline.sh` currently runs 16 workload validators covering environment identity, networking, VPC endpoints, ECR, logging, workload security realization, KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, EC2 compute, ECS runtime, and IAM.

A successful run ends with:

```text
Validation scripts passed:  16/16
Validation scripts failed:  0/16
```

### Validation Reporting

Generated packages include `summary.md`, `summary.json`, and the relevant validation logs. Evidence workflows use GitHub OIDC Plan roles and are intentionally read-only.

Cross-layer validation is kept separate by ownership. For example, Security Operations evidence does not replace full Organizations topology validation, and workload evidence does not replace delegated-administrator validation.

Live EC2 isolation/rollback, IP enrichment, end-user SSO login, tamper detection, break-glass assumption, and destroy-safety review remain separate approved tests where applicable.

Detailed guidance:

```text
scripts/validation/README.md
docs/validation-checklist.md
docs/assurance/validation-evidence-guide.md
docs/assurance/validation-report-template.md
```

---

## State Management

Terraform state is separated by account and Terraform root. State bootstrap stacks use a two-phase lifecycle:

```text
1. Initial local apply creates the state S3 bucket and CMK.
2. migrate-state-stack.sh materializes backend.tf, migrates state to S3,
   and verifies terraform state pull.
```

Tracked `backend.tf.migrated.example` files document the intended post-migration configuration. Active state-stack `backend.tf` files are ignored by Git.

Representative state object separation includes:

```text
control-plane/state.tfstate
control-plane/account.tfstate
control-plane/organizations.tfstate
control-plane/identity-center.tfstate

security-operations/state.tfstate
security-operations/account.tfstate
security-operation/security-services.tfstate

bootstrap/state/dev.tfstate
bootstrap/dev.tfstate
baseline/dev.tfstate
```

Staging and production follow the same workload pattern. All remote-backed stacks use S3 native state locking with `use_lockfile = true`.

A state stack must never destroy the bucket that contains its own active state. Before intentional state-stack teardown, migrate that state to an independent backend or local state and retain an external backup.

---

## Cost Considerations

This baseline supports multiple cost/security profiles.

The full production-style baseline uses AWS Network Firewall for centralized egress inspection. AWS Network Firewall provides strong security controls, but it can increase cost, especially when deployed across multiple environments and Availability Zones.

Recommended usage:

- Use `deployment_profile = "production"` for production or sensitive workloads.
- Use `deployment_profile = "development"` for lower-cost development/testing environments.
- Use `deployment_profile = "minimal"` for private AWS-only testing where general internet access is not required.
- Review NAT Gateway, Network Firewall, VPC endpoint, CloudWatch, logging, SNS/SQS, Inspector, AWS Config, and Backup costs regularly.

Cost-sensitive behavior includes:

| Setting | Production | Development | Minimal |
|---|---:|---:|---:|
| Network Firewall | Enabled | Disabled by default | Disabled |
| NAT Gateway | Enabled | Enabled | Disabled |
| AWS Config | Enabled | Enabled | Disabled by default |
| Inspector | Enabled | Enabled | Disabled |
| AWS Backup | Enabled | Disabled | Disabled |
| CloudWatch retention | 90 days | 30 days | 14 days |

The exact behavior can be overridden with explicit variables where supported.

---

## Documentation

Important system-level documentation includes:

| Document | Purpose |
|---|---|
| `docs/quickstart.md` | End-to-end deployment guide |
| `docs/architecture-overview.md` | Architecture and ownership boundaries |
| `docs/design-principles.md` | Design rationale and tradeoffs |
| `docs/adoption-guide.md` | Guidance for adapting the baseline |
| `docs/validation-checklist.md` | Post-deployment validation checklist |
| `docs/assurance/` | Evidence guidance and SOC 2 / ISO 27001-aligned mappings |
| `bootstrap/control_plane/README.md` | Control-plane responsibilities and lifecycle |
| `bootstrap/security_operations/README.md` | Central security responsibilities and lifecycle |
| `scripts/validation/README.md` | Validation layers, usage, and safety boundaries |

Each reusable module and major bootstrap substack also carries local documentation.

---

## Release Status and Highlights

### Current Tagged Release: `v1.7.0`

`v1.7.0` adds the dedicated `security-operations` administration layer and completes the centralized-security architecture:

- Security Hub CSPM CENTRAL configuration with workload policies and finding aggregation
- GuardDuty delegated administration, organization enrollment, protection plans, and Runtime Monitoring
- Security Hub V2 organization-policy governance for the `Workloads` OU
- Security-operations state and GitHub OIDC bootstrap roots
- Terraform Plan coverage for the security-services stack
- A dedicated Security Operations validation/evidence workflow
- Terraform-owned `guardduty-data` Interface Endpoints and endpoint-before-compute ordering
- Five-account Organizations / Identity Center documentation and validation
- Four-layer validation and evidence architecture

### Previous Release: `v1.6.0`

`v1.6.0` hardened EC2 launch ordering, first-boot patching, and automated isolation.

Key release outcomes included dependency-safe security-policy readiness, fail-closed isolation authorization, pre-quarantine snapshots, `user_data_replace_on_change`, and stronger first-boot Ubuntu patching behavior.

For detailed release history, see `CHANGELOG.md`.

## Future Roadmap

The immediate unreleased v1.8.0 milestone is an application image build, publish, and deployment workflow. Terraform does not build or push images. The intended delivery path is:

```text
application source + Dockerfile
  -> short-lived AWS/OIDC authentication
  -> build and push image to ECR
  -> resolve the authoritative sha256 digest
  -> Terraform Plan with that digest
  -> checksum/metadata/reviewer approval
  -> Apply the exact reviewed plan
  -> wait for ECS convergence
  -> run ECR, IAM, and ECS validation
```

Subsequent v1.8.0 work is expected to cover ECS Service Auto Scaling, GuardDuty Fargate Runtime Monitoring, fail-closed task-level containment, a ReconoSense reference deployment, and release readiness. GuardDuty `ECS_FARGATE_AGENT_MANAGEMENT` remains `NONE` today.

Other potential improvements include:

- Expand dashboarding and visual evidence outputs
- Add configurable VPC endpoint service lists
- Add additional deployment profile-controlled services
- Add a deliberate Service Control Policy strategy and Terraform implementation
- Evaluate multi-region centralized security and evidence patterns
- Add optional platform Apply automation for centralized security with stronger approval boundaries
- Add additional workload examples using fake data

---

## Intended Audience

This project is intended for:

- Cloud security engineers
- DevSecOps engineers
- Platform engineers
- SaaS founders
- Security consultants
- Teams preparing for SOC 2 / ISO 27001

---

## Summary

`tf-secure-baseline` is a deployable AWS security foundation and generic application-hosting baseline for sensitive workloads.

It combines five-account isolation, centralized Organizations and Identity Center governance, a dedicated security-operations administration layer, private-first networking, configurable egress, centralized Security Hub/GuardDuty governance, workload-local remediation, supported EC2 hosting, a preferred digest-pinned ECS/Fargate runtime, durable alerting, fail-closed automated response, protected Terraform CI/CD, and layered validation evidence into a reusable Terraform platform.

The goal is to provide a secure-by-default foundation that can be adapted, extended, and used as the starting point for production SaaS environments without representing the infrastructure alone as a complete compliance program.

---

## License

Copyright © 2026 Jacob Molland.

This project is licensed under the Apache License 2.0.

Terraform Secure Baseline is developed and maintained under the Nano Nexus
Consulting brand, operated by Nano Nexus Holdings LLC. See [LICENSE](LICENSE) for details.
