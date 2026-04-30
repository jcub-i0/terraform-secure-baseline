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

---

## Roadmap / Future Improvements

### v1.1
- Refactor IAM policies from `jsonencode()` to `aws_iam_policy_document`
- Improve policy reuse patterns (Lambda, KMS, SNS, logging)
- Add configurable egress inspection modes:
  - network_firewall (current)
  - nat_only
  - vpc_endpoints_only

---
