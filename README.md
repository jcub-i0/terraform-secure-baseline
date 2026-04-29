# terraform-secure-baseline

Opinionated Terraform baseline for deploying secure, cost-efficient AWS environments for early-to-mid-stage SaaS businesses handling customer data.

## NOTICE: PROPRIETARY CODE

This repository is the property of *NanoNexus Consulting*.

This code is made publicly viewable for demonstration purposes only.
No license is granted to use, copy, modify, or distribute this code
without explicit written permission.

---

## Overview

terraform-secure-baseline provides a deployable AWS security foundation designed for SaaS environments that must demonstrate strong infrastructure safeguards without the overhead of a full security engineering team.

It enables teams to launch cloud environments that are:

- Private by default
- Continuously monitored
- Resistant to silent logging disablement
- Configured to limit exposure
- Capable of automated containment

The baseline is implemented entirely as Infrastructure-as-Code.

---

## What This Provides

terraform-secure-baseline implements:

- Private-by-default infrastructure
- Centralized, tamper-resistant logging
- Continuous monitoring and threat detection
- Automated containment of high-severity EC2 threats
- Configuration integrity protections
- Encryption-backed operational evidence

Together, these controls help:

- Reduce external attack surface
- Ensure monitoring cannot be silently disabled
- Maintain visibility into security-relevant activity
- Limit blast radius during incidents
- Preserve integrity of operational logs

---

## Who This Is For

This baseline is intended for:

- Early-stage SaaS companies
- Mid-stage SaaS companies preparing for audits
- Teams handling sensitive customer data (e.g., PII)

It is especially useful where:

- Security engineering resources are limited
- Infrastructure maturity is growing
- Audit readiness is becoming a requirement

---

## Compliance Alignment

terraform-secure-baseline includes assurance documentation that supports alignment with security frameworks such as SOC 2.

See:

- `docs/assurance/soc2-control-mapping.md`
- `docs/assurance/control-narratives.md`

These documents describe how implemented controls align with infrastructure-level expectations.

---

## Design Goals

The baseline focuses on:

- Exposure reduction
- Monitoring visibility
- Detection integrity
- Incident containment
- Configuration stability
- Log protection

---

## Implementation Model

All components are deployed using Terraform modules.

Key capabilities include:

- Centralized logging
- Private networking
- Detection services
- Configuration monitoring
- Automated response actions

---

## Scope

terraform-secure-baseline provides infrastructure-level safeguards.

It does not replace:

- Organizational policies
- Application security practices
- Identity governance processes
- Operational procedures

It should be considered a technical foundation within a broader security program.

---

## File Structure

Below is the file structure for this repository:

```
├── baseline
│   ├── main.tf
│   ├── outputs.tf
│   ├── providers.tf
│   └── variables.tf
├── bootstrap
│   ├── control_plane
│   │   ├── account
│   │   │   ├── backend.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── providers.tf
│   │   │   ├── README.md
│   │   │   ├── terraform.tfvars
│   │   │   └── variables.tf
│   │   ├── identity_center
│   │   │   ├── backend.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── providers.tf
│   │   │   ├── README.md
│   │   │   ├── terraform.tfvars
│   │   │   └── variables.tf
│   │   ├── organizations
│   │   │   ├── backend.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── providers.tf
│   │   │   ├── README.md
│   │   │   ├── terraform.tfvars
│   │   │   └── variables.tf
│   │   ├── README.md
│   │   └── state
│   │       ├── main.tf
│   │       ├── outputs.tf
│   │       ├── providers.tf
│   │       ├── README.md
│   │       ├── terraform.tfvars
│   │       └── variables.tf
│   ├── dev
│   │   ├── account
│   │   │   ├── backend.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── providers.tf
│   │   │   ├── README.md
│   │   │   ├── terraform.tfvars
│   │   │   └── variables.tf
│   │   └── state
│   │       ├── main.tf
│   │       ├── outputs.tf
│   │       ├── providers.tf
│   │       ├── README.md
│   │       ├── terraform.tfvars
│   │       └── variables.tf
│   ├── prod
│   │   ├── account
│   │   │   ├── backend.tf
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── providers.tf
│   │   │   ├── README.md
│   │   │   ├── terraform.tfvars
│   │   │   └── variables.tf
│   │   └── state
│   │       ├── main.tf
│   │       ├── outputs.tf
│   │       ├── providers.tf
│   │       ├── README.md
│   │       ├── terraform.tfstate
│   │       ├── terraform.tfstate.backup
│   │       ├── terraform.tfvars
│   │       └── variables.tf
│   └── staging
│       ├── account
│       │   ├── backend.tf
│       │   ├── main.tf
│       │   ├── outputs.tf
│       │   ├── providers.tf
│       │   ├── README.md
│       │   ├── terraform.tfvars
│       │   └── variables.tf
│       └── state
│           ├── main.tf
│           ├── outputs.tf
│           ├── providers.tf
│           ├── README.md
│           ├── terraform.tfstate
│           ├── terraform.tfstate.backup
│           ├── terraform.tfvars
│           └── variables.tf
├── docs
│   ├── adoption-guide.md
│   ├── architecture-diagram.png
│   ├── architecture-overview.md
│   ├── assurance
│   │   ├── control-narratives.md
│   │   └── soc2-control-mapping.md
│   ├── design-principles.md
│   ├── lambda_tests
│   │   ├── ec2_isolation.md
│   │   ├── ec2_rollback.md
│   │   └── ip_enrichment.md
│   ├── quickstart.md
│   └── validation-checklist.md
├── environments
│   ├── dev
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── terraform.tfvars
│   │   └── variables.tf
│   ├── prod
│   │   ├── backend.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── providers.tf
│   │   ├── terraform.tfvars
│   │   └── variables.tf
│   └── staging
│       ├── backend.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── providers.tf
│       ├── terraform.tfvars
│       └── variables.tf
├── modules
│   ├── automation
│   │   ├── lambda
│   │   │   ├── ec2_isolation.py
│   │   │   ├── ec2_rollback.py
│   │   │   ├── ip_enrichment.py
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── backup
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── compute
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   ├── user_data
│   │   │   └── bootstrap.sh.tpl
│   │   └── variables.tf
│   ├── firewall
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── github_oidc
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── iam
│   │   ├── backup.tf
│   │   ├── break_glass.tf
│   │   ├── config.tf
│   │   ├── ec2.tf
│   │   ├── lambda.tf
│   │   ├── logging.tf
│   │   ├── outputs.tf
│   │   ├── patch_management.tf
│   │   ├── README.md
│   │   ├── security_integrations.tf
│   │   ├── shared_policies.tf
│   │   └── variables.tf
│   ├── identity_center
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── logging
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── monitoring
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── networking
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   ├── security_policy
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── README.md
│   │   │   └── variables.tf
│   │   └── variables.tf
│   ├── patch_management
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── security
│   │   ├── config_baseline
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── README.md
│   │   │   ├── remediations.tf
│   │   │   ├── rules.tf
│   │   │   └── variables.tf
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   ├── tamper_detection
│   │   │   ├── main.tf
│   │   │   ├── outputs.tf
│   │   │   ├── README.md
│   │   │   └── variables.tf
│   │   └── variables.tf
│   ├── security_dashboard
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── state
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   ├── storage
│   │   ├── main.tf
│   │   ├── outputs.tf
│   │   ├── README.md
│   │   └── variables.tf
│   └── vpc_endpoints
│       ├── main.tf
│       ├── outputs.tf
│       └── variables.tf
├── README.md
├── SECURITY.md
└── terraform.tfstate.backup
```