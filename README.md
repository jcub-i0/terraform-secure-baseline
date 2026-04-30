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
- Centralized logging and monitoring
- Automated detection and response
- GitHub OIDC-based CI/CD
- Environment isolation across `dev`, `staging`, and `prod`
- SOC 2 / ISO 27001-aligned security architecture

This project is intended for SaaS companies, startups, and engineering teams that need a repeatable AWS security foundation without building every security control from scratch.

---

## What This Project Provides

This repository deploys a production-aligned AWS security baseline using Terraform.

Key capabilities include:

- Multi-account AWS architecture
- Centralized control plane
- IAM Identity Center access management
- GitHub Actions OIDC federation
- Private-first networking
- AWS Network Firewall egress inspection
- Centralized CloudTrail, Config, and VPC Flow Logs
- GuardDuty, Security Hub, Inspector, and AWS Config
- Event-driven security automation
- EC2 isolation and rollback workflows
- Tamper detection
- Break-glass role monitoring
- Encrypted S3, KMS, SNS, CloudWatch, and Lambda resources
- AWS Backup and SSM patching support

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
GitHub Actions
    |
    | OIDC
    v
GitHub Plan / Apply IAM Roles
    |
    v
Terraform Stacks
    |
    +--> bootstrap/control_plane
    |       +--> state
    |       +--> account
    |       +--> organizations
    |       +--> identity_center
    |
    +--> environments/dev
    +--> environments/staging
    +--> environments/prod
```

The platform separates the control plane from the workload environments.

The **control plane** manages:
- Terraform backend infrastructure
- GitHub OIDC execution roles
- AWS Organizations structure
- IAM Identity Center access

The **environment** stacks manage:
- Networking
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
│   ├── backup
│   ├── compute
│   ├── firewall
│   ├── github_oidc
│   ├── iam
│   ├── identity_center
│   ├── logging
│   ├── monitoring
│   ├── networking
│   ├── patch_management
│   ├── security
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
├── .github
│   └── workflows
│
├── README.md
└── SECURITY.md
```

---

## Core Design Principles

### Private-First Infrastructure

Compute workloads are deployed in private subnets by default.

The baseline avoids public IPs for application infrastructure and uses controlled outbound access.

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

Each environment stack deploys the full security baseline into its respective AWS account.

Environment stacks include:
- VPC and subnets
- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- EC2 workloads
- S3 storage
- KMS keys
- CloudTrail
- CloudWatch
- AWS Config
- GuardDuty
- Security Hub
- Inspector
- Lambda automation
- EventBridge rules
- SNS topics
- Backup and patching resources

### Modules

Reusable Terraform modules live under:
```text
modules/
```

Each module contains its own `README.md` describing its purpose, inputs, outputs, and behavior.

## Security Services

This baseline integrates several AWS-native security services:

| Service |	Purpose |
|---------|---------|
| GuardDuty | Threat detection |
| Security Hub | Security findings aggregation |
| AWS Config | Compliance rule evaluation |
| CloudTrail | API activity logging |
| CloudWatch | Metrics, logs, and alarms |
| Inspector	| Vulnerability scanning |
| EventBridge | Security event routing |
| SNS |	Alert delivery |
| KMS |	Encryption key management |
| IAM Identity Center |	Centralized human access |
| AWS Backup | Backup orchestration |
| SSM Patch Manager | Patch management |

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
- KMS

### Break-Glass Monitoring

Detects use of the break-glass administrator role and sends a high-priority alert.

### CI/CD

GitHub Actions workflows use GitHub OIDC to assume AWS IAM roles.

Typical workflows include:
- `Terraform Plan`
- `Terraform Apply`
- `Terraform Destroy`
- `Terraform Static Analysis`
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
5. Deploy or re-apply **IAM Identity Center** assignments
6. Validate **security automation workflows**

Detailed instructions are provided in:
```text
docs/quickstart.md
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

This baseline uses **AWS Network Firewall** for centralized egress inspection.

AWS Network Firewall provides strong security controls, but it can increase cost, especially when deployed across multiple environments and Availability Zones.

Recommended usage:
- Use the full architecture for production or sensitive workloads
- Consider a reduced-cost profile for dev or staging environments
- Review NAT Gateway, Network Firewall, VPC endpoint, CloudWatch, and logging costs regularly

Future versions may include configurable egress profiles such as:
- network_firewall
- nat_only
- vpc_endpoints_only

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
| docs/architecture-overview.md	| Architecture explanation |
| docs/design-principles.md	| Design principles and rationale |
| docs/adoption-guide.md | Guidance for adapting the baseline |
| docs/validation-checklist.md | Post-deployment validation checklist |
| docs/assurance/ | Compliance-oriented documentation |
| docs/lambda_tests/ | Automation testing documentation |

Each module also includes its own local README.md.

---

## Roadmap

### v1.1
Potential improvements:

- Add configurable egress inspection modes:
  - network_firewall
  - nat_only
  - vpc_endpoints_only
- Refactor IAM policies from jsonencode() to aws_iam_policy_document
- Add additional Service Control Policies
- Add cross-account GuardDuty aggregation
- Add cross-account Security Hub aggregation
- Improve automated validation and test coverage

---

## Intended Audience

This project is intended for:

- Cloud security engineers
- DevSecOps engineers
- Platform engineers
- SaaS founders
- Security consultants
- Teams preparing for SOC 2 / ISO 27001