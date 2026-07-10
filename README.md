# terraform-secure-baseline

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

## NOTICE: PROPRIETARY CODE

This repository is the property of *NanoNexus Consulting*.

This code is made publicly viewable for demonstration purposes only.
No license is granted to use, copy, modify, or distribute this code
without explicit written permission.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security baseline designed for organizations running applications that handle PII or other sensitive data.

It provides a secure, multi-account cloud foundation with:

- Centralized identity and access management
- Secure-by-default networking
- Configurable deployment profiles
- Configurable egress modes
- Centralized logging, monitoring, and alert routing
- Automated detection and response
- Durable SNS/SQS notification paths with DLQs for failed alert delivery
- GitHub OIDC-based CI/CD
- Environment isolation across `dev`, `staging`, and `prod`
- SOC 2 / ISO 27001-aligned security architecture to support audit readiness

This project is intended for SaaS companies, startups, and engineering teams that need a repeatable AWS security foundation without building every security control from scratch.

> This baseline supports SOC 2 and ISO 27001 readiness, but it does not replace an organization’s full compliance program, ISMS, policies, risk management process, or formal audit requirements.

---

## What This Project Provides

This repository deploys a production-aligned AWS security baseline using Terraform.

Key capabilities include:

- Multi-account AWS architecture
- Centralized control plane
- IAM Identity Center access management
- GitHub Actions OIDC federation
- Private-first networking
- Configurable deployment profiles for production, development, and minimal deployments
- Configurable egress modes for Network Firewall, NAT-only, or VPC-endpoints-only operation
- AWS Network Firewall egress inspection when enabled
- Dedicated private subnets for Interface VPC Endpoints
- Private AWS service access through VPC endpoints
- Centralized CloudTrail, Config, and VPC Flow Logs
- GuardDuty, Security Hub, Inspector, and AWS Config
- Event-driven security automation
- EC2 isolation and rollback workflows
- IP threat enrichment
- Tamper detection
- Break-glass role monitoring
- SQS-backed security and compliance notification queues
- EventBridge target DLQs and workflow-specific automation DLQs
- Encrypted S3, KMS, SNS, SQS, CloudWatch, and Lambda resources
- AWS Backup and SSM patching support
- Safe, read-only post-deployment validation suite
- Layer-specific validation evidence export with Markdown and JSON summaries

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
Manual / Local Bootstrap
    |
    v
Bootstrap Stacks
    |
    +--> bootstrap/control_plane/state
    +--> bootstrap/control_plane/account
    +--> bootstrap/control_plane/organizations
    |
    +--> bootstrap/dev/state
    +--> bootstrap/dev/account
    |
    +--> bootstrap/staging/state
    +--> bootstrap/staging/account
    |
    +--> bootstrap/prod/state
    +--> bootstrap/prod/account

GitHub Actions
    |
    | OIDC
    v
Environment Plan / Apply Roles
    |
    v
Workload Environment Stacks
    |
    +--> environments/dev/baseline
    +--> environments/staging/baseline
    +--> environments/prod/baseline

Control Plane Governance
    |
    +--> bootstrap/control_plane/identity_center
```

Initial `state`, `account`, and `organizations` bootstrap stacks are applied locally/manual-first. After the environment GitHub OIDC roles exist, GitHub Actions can plan/apply supported workload baseline stacks. The Terraform Destroy workflow uses the control-plane apply role first to clean up Identity Center policy attachments, then uses the selected workload environment apply role to destroy that environment.

The platform separates the control plane from the workload environments.

The **control plane** manages:

- Control-plane Terraform backend infrastructure
- Control-plane GitHub OIDC execution roles
- AWS Organizations structure
- IAM Identity Center access

The **environment** stacks manage:

- Networking
- Deployment profile and egress mode behavior
- Logging
- Monitoring
- Security services
- Automation
- Compute
- Storage
- Backup
- Patch management

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
│   ├── automation
|   |   └── lambda
│   ├── backup
│   ├── compute
|   |   └── user_data
│   ├── firewall
│   ├── github_oidc
│   ├── iam
│   ├── identity_center
│   ├── logging
│   ├── monitoring
│   ├── networking
|   │   └── security_policy
│   ├── patch_management
│   ├── security
|   |   ├── config_baseline
|   |   └── tamper_detection
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
│   └── validation
│       ├── lib
│       │   └── common.sh
|       ├── export-baseline.sh
|       ├── export-bootstrap.sh
|       ├── export-control-plane.sh
│       ├── validate-backup.sh
│       ├── validate-baseline.sh
│       ├── validate-bootstrap.sh
│       ├── validate-control-plane.sh
│       ├── validate-compute.sh
│       ├── validate-env.sh
│       ├── validate-eventbridge.sh
│       ├── validate-iam.sh
│       ├── validate-kms.sh
│       ├── validate-lambda.sh
│       ├── validate-logging.sh
│       ├── validate-networking.sh
│       ├── validate-security-services.sh
│       ├── validate-sns.sh
│       ├── validate-sqs.sh
│       ├── validate-ssm.sh
│       └── validate-vpc-endpoints.sh
|
├── .github
│   └── workflows
│
├── CHANGELOG.md
├── README.md
└── SECURITY.md
```

---

## Core Design Principles

### Private-First Infrastructure

Compute workloads are deployed in private subnets by default.

The baseline avoids public IPs for application infrastructure and routes private compute egress through controlled paths, including AWS Network Firewall, NAT Gateway, and VPC endpoints where appropriate.

### Configurable Cost/Security Profiles

The baseline supports deployment profiles that select sensible defaults for each environment type.

Profiles allow teams to run a full production-style architecture where needed while using lower-cost defaults for development or minimal testing environments.

### Multi-Account Isolation

The platform separates environments into dedicated AWS accounts:

```text
dev
staging
prod
bootstrap / control-plane
```

This improves blast-radius reduction, access control, and operational isolation.

### Control Plane Separation

The control plane is isolated from workload infrastructure.

This prevents Terraform from destroying or modifying the execution roles, state resources, and identity infrastructure it depends on.

### No Long-Lived CI/CD Credentials

GitHub Actions authenticates to AWS using OIDC.

No static AWS access keys are required for CI/CD workflows.

### Centralized Identity

IAM Identity Center is used for human access.

Permission sets and account assignments are managed centrally from the control plane.

### Event-Driven Security Automation

Security events are routed through EventBridge and trigger automated workflows such as:

- EC2 isolation
- EC2 rollback
- IP threat enrichment
- Tamper detection alerts
- Break-glass role usage alerts

Critical EventBridge and Lambda delivery paths use retry policies and DLQs so failed security events are retained for review instead of silently disappearing.

---

## Major Components

### Control Plane

Located at:

```text
bootstrap/control_plane
```

The **control plane** manages foundational platform resources.

Substacks include:

| Substack | Purpose |
|----------|---------|
| `state` | Creates Terraform backend resources |
| `account` | Creates GitHub OIDC execution roles |
| `organizations` | Defines AWS Organizations OU structure |
| `identity_center` | Manages centralized IAM Identity Center access |

### Environment Stacks

Located at:

```text
environments/dev
environments/staging
environments/prod
```

Each environment stack deploys the security baseline into its respective AWS account.

Environment stacks include:

- Deployment profile and egress mode resolution
- VPC and subnets
- Dedicated VPC endpoint subnets
- AWS Network Firewall, when enabled by egress mode
- NAT Gateway, when required by egress mode
- VPC endpoints
- EC2 workloads
- S3 storage
- KMS keys
- CloudTrail
- CloudWatch
- AWS Config, when enabled by profile or override
- GuardDuty
- Security Hub
- Inspector, when enabled by profile
- Lambda automation
- EventBridge rules and targets
- SNS topics
- SQS notification queues and DLQs
- Backup and patching resources
- IAM service roles and shared access policies

### Modules

Reusable Terraform modules live under:

```text
modules/
```

Each module contains its own `README.md` describing its purpose, inputs, outputs, and behavior.

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

When `egress_mode = "vpc_endpoints_only"`, Network Firewall and NAT Gateways are not deployed, and compute private subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access. EC2 user data package installation may fail unless package access is provided another way.

---

## Security Services

This baseline integrates several AWS-native security services:

| Service | Purpose |
|---------|---------|
| GuardDuty | Threat detection |
| Security Hub | Security findings aggregation |
| AWS Config | Compliance rule evaluation |
| CloudTrail | API activity logging |
| CloudWatch | Metrics, logs, and alarms |
| Inspector | Vulnerability scanning |
| EventBridge | Security event routing |
| SNS | Alert fanout and human notification |
| SQS | Durable notification queues and DLQs |
| KMS | Encryption key management |
| IAM Identity Center | Centralized human access |
| AWS Backup | Backup orchestration |
| SSM Patch Manager | Patch management |

Some services are profile-aware. For example, AWS Config and Inspector are enabled by default in `production` and `development`, while `minimal` disables them by default unless explicitly overridden.

---

## Automation Workflows

The baseline includes several security automation workflows.

### EC2 Isolation

Triggered by High- and Critical-severity Security Hub findings.

Actions include:

- Replacing existing security groups with a quarantine security group
- Snapshotting the EBS volume(s)
- Tagging the instance
- Sending an SNS alert

### EC2 Rollback

Triggered manually through a controlled EventBridge event.

This allows a SecOps operator to restore previously isolated EC2 instances after review and approval.

### IP Threat Enrichment

Enriches IP-related Security Hub findings using threat intelligence sources and sends the results to SNS.

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

GitHub Actions workflows use GitHub OIDC to assume AWS IAM roles.

Typical workflows include:

- `Terraform Plan`
- `Terraform Apply`
- `Terraform Destroy`
- `Terraform Static Analysis`
- `Docs Validation`
- `Lint PR`

Each environment uses its own GitHub environment and AWS role for `Terraform Plan`, `Terraform Apply`, and `Terraform Destroy` workflows.

Example mapping:

```text
dev-plan        -> dev GitHub-Plan role
dev             -> dev GitHub-Apply role

staging-plan    -> staging GitHub-Plan role
staging         -> staging GitHub-Apply role

prod-plan       -> prod GitHub-Plan role
prod            -> prod GitHub-Apply role

control-plane-plan -> control-plane GitHub-Plan role
control-plane      -> control-plane GitHub-Apply role
```

---

## Deployment Order

At a high level, deployment follows this order:

1. Deploy **state** resources
2. Deploy **account / GitHub OIDC** resources
3. Deploy **AWS Organizations** structure
4. Deploy **environment baseline**
5. Re-apply workload **account / GitHub OIDC** resources with current workload-created CMK ARNs where strict workload bootstrap evidence is required
6. Deploy or re-apply **IAM Identity Center** assignments
7. Validate **security automation workflows**
8. Export validation evidence for the applicable validation layers

Detailed instructions are provided in:

```text
docs/quickstart.md
```

---

## Validation

The repository includes safe, read-only validation scripts under:

```text
scripts/validation/
```

Validation is split into three layers, with matching evidence exporters:

```text
Workload bootstrap validation  -> validate-bootstrap.sh <dev|staging|prod>
Workload baseline validation   -> validate-baseline.sh <dev|staging|prod>
Control-plane validation       -> validate-control-plane.sh

Workload bootstrap evidence    -> export-bootstrap.sh <dev|staging|prod>
Workload baseline evidence     -> export-baseline.sh <dev|staging|prod>
Control-plane evidence         -> export-control-plane.sh
```

### Workload Bootstrap Validation

Use `validate-bootstrap.sh` to validate workload bootstrap resources such as Terraform state backend configuration, state bucket security, state CMK configuration, GitHub OIDC roles, and GitHub role access to state and workload-created CMKs.

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/validate-bootstrap.sh dev
```

`validate-bootstrap.sh` does not require local `terraform.tfstate` from `bootstrap/<env>/state`. It treats the remote backend files as the source of truth for state bucket location and S3 native locking with `use_lockfile = true`, then validates the live S3 state bucket and KMS encryption configuration through AWS APIs.

When running from a fresh checkout or a manual GitHub workflow, initialize the remote-backed stacks first so Terraform outputs can be read from the S3 backend:

```bash
terraform -chdir=bootstrap/dev/account init -input=false
terraform -chdir=environments/dev init -input=false
```

Bootstrap validation is strict by default for workload-created CMK policy evidence. `STRICT_WORKLOAD_CMK_POLICY_CHECKS` defaults to `true`, which means stale or missing GitHub Apply role policy references to the current workload Lambda and Secrets Manager CMKs fail validation. Set `STRICT_WORKLOAD_CMK_POLICY_CHECKS=false` only for transitional validation where those checks should be warnings instead of failures.

### Workload Baseline Validation

Use `validate-baseline.sh` to validate deployed workload baseline resources.

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/validate-baseline.sh dev
```

The workload baseline validation suite checks deployed environments for account identity, Terraform outputs, networking, VPC endpoints, logging, security services, KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, Compute, and IAM posture. It also validates notification and failure-retention paths such as SNS subscriptions, SQS queues, EventBridge target DLQs, retry policies, and Lambda workflow wiring.

A successful workload baseline validation run should end with:

```text
Validation scripts passed:  14/14
Validation scripts failed:  0/14
```

Individual scripts can also be run directly when troubleshooting a specific architecture area.

### Control-Plane Validation

Use `validate-control-plane.sh` to validate control-plane bootstrap and governance resources.

```bash
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/validate-control-plane.sh
```

Control-plane validation checks state backend resources, GitHub OIDC roles, AWS Organizations OU structure, IAM Identity Center instance discovery, permission sets, groups, and optional account assignment presence.

Detailed validation guidance is provided in:

```text
scripts/validation/README.md
docs/validation-checklist.md
```

The automated validation scripts are intentionally read-only. GitHub Actions workflow execution, end-user Identity Center login testing, live Lambda workflow tests, tamper tests, break-glass tests, and destroy safety review remain manual validation steps.

### Validation Reporting

Validation evidence can be exported for client handoff, troubleshooting, or internal deployment records.

Each validation layer has its own exporter and output directory:

| Validation layer | Export script | Output directory |
|---|---|---|
| Workload bootstrap | `export-bootstrap.sh <dev/staging/prod>` | `validation-results/<environment>/bootstrap/<timestamp>/` |
| Workload baseline | `export-baseline.sh <dev/staging/prod>` | `validation-results/<environment>/baseline/<timestamp>/` |
| Control plane | `export-control-plane.sh` | `validation-results/control-plane/<timestamp>/` |

Example workload bootstrap evidence export:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-bootstrap.sh dev
```

Example workload baseline evidence export:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-baseline.sh dev
```

Example control-plane evidence export:

```bash
AWS_PROFILE="control-plane" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-control-plane.sh
```

Each report package includes:

- `summary.md`
- `summary.json`
- one or more validation logs

Generated validation results are ignored by Git by default.

Additional validation evidence guidance is provided in:

```text
docs/assurance/validation-report-template.md
docs/assurance/validation-evidence-guide.md
```

---

## State Management

Terraform state is separated by **stack** and **environment**.

Example layout:

```text
bootstrap/dev.tfstate
baseline/dev.tfstate

bootstrap/staging.tfstate
baseline/staging.tfstate

bootstrap/prod.tfstate
baseline/prod.tfstate
```

Control-plane substacks use separate state files:

```text
control-plane/account.tfstate
control-plane/identity-center.tfstate
control-plane/organizations.tfstate
```

This separation prevents accidental cross-stack changes and reduces the blast radius of Terraform operations.

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

System-level documentation is located in:

```text
docs/
```

Important docs include:

| Document | Purpose |
|----------|---------|
| docs/quickstart.md | End-to-end deployment guide |
| docs/architecture-overview.md | Architecture explanation |
| docs/design-principles.md | Design principles and rationale |
| docs/adoption-guide.md | Guidance for adapting the baseline |
| docs/validation-checklist.md | Post-deployment validation checklist |
| docs/assurance/ | Validation evidence, report templates, and compliance-oriented documentation |
| docs/lambda_tests/ | Automation testing documentation |

Each module also includes its own local README.md.

---

## Current Release Highlights

### v1.3.5

This release improves client-readiness validation evidence by adding layer-specific evidence exporters, standardizing naming behavior across validation scripts, and strengthening workload bootstrap validation around current workload-created CMK policy access.

Highlights:

- Added workload bootstrap evidence export with `export-bootstrap.sh`.
- Added control-plane evidence export with `export-control-plane.sh`.
- Standardized workload baseline evidence export through `export-baseline.sh`.
- Updated evidence output paths to separate workload bootstrap, workload baseline, and control-plane report packages.
- Added strict-by-default workload CMK policy validation with `STRICT_WORKLOAD_CMK_POLICY_CHECKS=true`.
- Validates that the workload GitHub Apply role references the current workload-created Lambda and Secrets Manager CMK ARNs.
- Supports transitional workload CMK validation with `STRICT_WORKLOAD_CMK_POLICY_CHECKS=false`, where stale or missing workload CMK references are warnings instead of failures.
- Standardized validation script naming behavior around `CLOUD_NAME` and derived `NAME_PREFIX` values.
- Preserved the three-layer validation model: workload bootstrap, workload baseline, and control plane.
- Preserved manual-only status for GitHub Actions execution, end-user SSO testing, live Lambda workflow tests, tamper tests, break-glass tests, and destroy safety review.

For previous release highlights and detailed change history, see `CHANGELOG.md`.

---

## Future Roadmap

Potential future improvements include:

- Improve dashboarding and visual evidence outputs
- Add configurable VPC endpoint service lists
- Add additional deployment profile-controlled services
- Add SCP strategy and Terraform implementation
- Add cross-account GuardDuty aggregation
- Add cross-account Security Hub aggregation
- Add org-level validation scripts for SCP / GuardDuty / Security Hub aggregation
- Optional dummy SaaS app using fake data

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

`tf-secure-baseline` is a deployable AWS security foundation for sensitive workloads.

It combines multi-account architecture, centralized identity, secure networking, deployment profiles, configurable egress modes, dedicated VPC endpoint subnets, logging, monitoring, durable notification paths, automated response, and GitHub OIDC CI/CD into a **reusable Terraform platform**.

The goal is to provide a **secure-by-default foundation** that can be adapted, extended, and used as the starting point for production SaaS environments.