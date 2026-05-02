# Architecture Overview - tf-secure-baseline

## Purpose

This document describes the high-level architecture implemented by `tf-secure-baseline` and how its components work together to support secure AWS cloud environments.

It focuses on system relationships, trust boundaries, and operational flow rather than low-level Terraform implementation details.

`tf-secure-baseline` is designed for SaaS companies and engineering teams running workloads that handle PII or other sensitive data and need a secure, repeatable cloud foundation aligned with **SOC 2 / ISO 27001-style** security expectations.

---

## High-Level Architecture

The platform is organized around a **multi-account AWS architecture** with a centralized control plane and isolated workload environments.

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
    +--> bootstrap/dev
    |       +--> state
    |       +--> account
    |
    +--> bootstrap/prod
    |       +--> state
    |       +--> account
    |
    |--> bootstrap/staging
    |       +--> state
    |       +--> account
    |
    +--> environments/dev
    |       +--> baseline
    |
    +--> environments/staging
    |       +--> baseline
    |
    +--> environments/prod
    |       +--> baseline
```

At a high level:

- The **control plane** manages organization-wide structure, centralized identity, and control-plane CI/CD access.
- Each **environment bootstrap stack** prepares that environment for Terraform automation.
- Each **state substack** is applied locally first and creates the remote backend resources for that account/environment.
- Each **account substack** creates the GitHub OIDC roles used by CI/CD for that account/environment.
- Each **environment stack** deploys the actual security baseline into its dedicated AWS account.
- GitHub Actions uses OIDC to assume environment-specific roles.
- IAM Identity Center provides centralized human access.
- EventBridge, Security Hub, Lambda, and SNS provide event-driven detection and response.

---

## Account Model

The architecture separates platform responsibilities across multiple AWS accounts.

```text
bootstrap / control-plane account
    |
    +--> AWS Organizations
    +--> IAM Identity Center
    +--> Control-plane Terraform state
    +--> Control-plane GitHub OIDC roles

dev account
    |
    +--> Dev baseline infrastructure
    +--> Dev account infrastructure

staging account
    |
    +--> Staging baseline infrastructure
    +--> Staging account infrastructure

prod account
    |
    +--> Prod baseline infrastructure
    +--> Staging account infrastructure
```

This model provides:

- Environment isolation
- Reduced blast radius
- Separate Terraform state per account/environment
- Cleaner access boundaries
- Production-aligned account segmentation
- Multi-AZ / Multi-region capabilities (if configured)

---

## Control Plane

The control plane is deployed in the bootstrap/control-plane account and manages organization-wide platform foundations.

Located at:

```text
bootstrap/control_plane
```

The control plane consists of four substacks:

| Substack | Purpose |
|---------|---------|
| `state` | Creates Terraform backend resources for control-plane state |
| `account` | Creates GitHub OIDC roles used by CI/CD |
| `organizations` | Defines AWS Organizations OU structure |
| `identity_center` | Manages IAM Identity Center groups, permission sets, and account assignments |

The control plane does **not** deploy application or workload infrastructure.

Its purpose is to define:

- How accounts are organized
- How humans access accounts
- How GitHub Actions authenticates to AWS
- How Terraform state is stored for control-plane resources

---

## Workload Environments

Workload environments are deployed from:

```text
environments/dev
environments/staging
environments/prod
```

Each environment is deployed into its own AWS account and contains the full `baseline` infrastructure, including:

- VPC and subnet segmentation
- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- EC2 workloads
- S3 buckets
- KMS keys
- CloudTrail
- CloudWatch
- AWS Config
- GuardDuty
- Security Hub
- Inspector
- EventBridge rules
- Lambda automation
- SNS topics
- Backup and patch management resources

Each environment is independently deployable, destroyable, and testable.

---

## Core Design Principles

The `baseline` is designed around the following principles:

- Private-by-default infrastructure
- Multi-account isolation
- Centralized identity
- No long-lived CI/CD credentials
- Centralized visibility
- Detection integrity
- Controlled egress
- Automated containment
- Human-approved recovery
- Immutable and encrypted logging
- Least-privilege access

These principles guide the structure of the Terraform modules, account layout, IAM model, and security automation workflows.

---

## Networking Architecture

Each workload environment is deployed into a segmented VPC.

The VPC includes subnet tiers such as:

- Public subnets
- Private compute subnets
- Private data subnets
- Private serverless subnets
- Network Firewall subnets

Application and compute workloads are placed in private subnets and do not receive public IP addresses.

Typical outbound path:

```text
Private Compute Subnets
    |
    v
AWS Network Firewall
    |
    v
NAT Gateway
    |
    v
Internet Gateway
    |
    v
Internet
```

This provides centralized egress inspection while keeping workloads private.

---

## Controlled Egress

Outbound access is intentionally restricted and routed through controlled paths.

The baseline supports:

- AWS Network Firewall for egress inspection
- NAT Gateway for controlled internet access
- VPC endpoints for AWS service access
- Route table segmentation
- Security group restrictions

Where possible, access to AWS services should occur through VPC endpoints instead of public internet paths.

This reduces unnecessary internet exposure and improves control over workload communication.

---

## VPC Endpoints

VPC endpoints are used to reduce dependency on public internet access for AWS service communication.

Examples include endpoints for services such as:

- S3
- Systems Manager
- CloudWatch Logs
- Secrets Manager
- KMS
- EC2 Messages
- SSM Messages
- Security Hub
- Lambda

This supports private connectivity for management, logging, secrets retrieval, and automation workflows.

---

## Identity and Access Architecture

Human access is managed through IAM Identity Center in the control plane.

The Identity Center stack manages:

- Groups
- Permission sets
- Account assignments

Example groups include:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

Optional groups may include:

```text
SecOps-Analyst
SecOps-Engineer
```

The access model separates operational duties:

| Role | Purpose |
|-----|---------|
| SecOps-Operator | Submit approved rollback events |
| SecOps-Analyst | Read-only investigation and visibility |
| SecOps-Engineer | Investigation and limited response actions |
| Break-glass admin | Emergency administrative access |

The `SecOps-Operator` role is intentionally limited. It can submit events to the environment-specific SecOps event bus, but it does not directly modify EC2 instances or invoke Lambda functions.

---

## CI/CD Architecture

GitHub Actions authenticates to AWS using OIDC.

No long-lived AWS access keys are required for CI/CD.

Each environment has dedicated GitHub plan and apply roles.

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

The GitHub OIDC roles are created by account substacks and are intentionally separated from the baseline infrastructure they manage.

This prevents Terraform workflows from destroying the IAM roles they are actively using.

---

## Terraform State Architecture

Terraform state is separated by account, environment, and substack.

The `state` substacks are special bootstrap stacks. They are applied locally and use local Terraform state because their purpose is to create the remote backend resources that other stacks depend on. While initially stored locally, the `state` stacks can use a remote backend following initial deployment.

State substacks create resources such as:

- S3 bucket for Terraform state
- KMS key for state encryption
- DynamoDB table or S3 lockfile support for state locking

After the state resources exist, other stacks use remote state backends.

Example environment state layout:

```text
bootstrap/dev/state
    -> local Terraform state
    -> creates remote backend resources for dev

bootstrap/dev/account
    -> remote backend key: bootstrap/dev.tfstate

environments/dev
    -> remote backend key: baseline/dev.tfstate
```

Control-plane layout:

```text
bootstrap/control_plane/state
    -> local Terraform state
    -> creates remote backend resources for control-plane stacks

bootstrap/control_plane/account
    -> remote backend key: control-plane/account.tfstate

bootstrap/control_plane/identity_center
    -> remote backend key: control-plane/identity-center.tfstate

bootstrap/control_plane/organizations
    -> remote backend key: control-plane/organizations.tfstate
```

This separation reduces blast radius and prevents unrelated Terraform operations from affecting each other.

It also avoids the bootstrapping problem where Terraform would need a remote backend before the backend resources exist.

---

## Centralized Logging

Operational and security activity is captured through:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs
- Flow logs

Logs are designed to be:

- Stored centrally
- Encrypted
- Versioned
- Lifecycle-managed
- Protected against tampering
- Retained for long-term audit and forensic use

The centralized logs bucket is configured with controls such as:

- KMS encryption
- S3 versioning
- Object Lock
- Restricted bucket policies
- Lifecycle transitions

This supports monitoring continuity, incident response, and evidence preservation.

---

## Detection Layer

Continuous monitoring is enabled through AWS-native detection and posture management services.

Core detection services include:

| Service | Purpose |
|--------|---------|
| `GuardDuty` | Threat detection |
| `Security Hub` | Findings aggregation |
| `AWS Config` | Configuration compliance |
| `Inspector` | Vulnerability detection |
| `CloudTrail` | API activity logging |
| `EventBridge` | Event routing and automation trigger |

These services provide visibility into:

- Suspicious behavior
- Misconfiguration
- Public exposure
- Vulnerable resources
- Security service tampering
- Policy violations

---

## Monitoring Integrity and Tamper Detection

The baseline includes tamper detection mechanisms that monitor for attempts to modify or disable critical security controls.

Examples include attempts to disable or alter:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS keys
- Logging destinations

Tamper-related events are routed through EventBridge and sent to SNS for notification.

This helps detect attempts to weaken monitoring, logging, or encryption controls.

---

## Event-Driven Security Automation

Security automation is implemented using EventBridge and Lambda.

Common event flow:

```text
Security Event
    |
    v
EventBridge Rule
    |
    v
Lambda Automation
    |
    v
Resource Action / Notification / Enrichment
```

Automation functions include:

| Function | Purpose |
|---------|---------|
| `EC2 Isolation` | Quarantines EC2 instances based on high-severity findings |
| `EC2 Rollback` | Restores original security groups after approval |
| `IP Enrichment` | Enriches public IPs from Security Hub findings |
| `Tamper Detection` | Sends alerts for security control changes |
| `Break-glass Detection` | Alerts on emergency admin role usage |

---

## EC2 Isolation Workflow

The `EC2 Isolation` workflow provides automated containment for high- and critical-severity EC2-related Security Hub findings.

Workflow:

```text
Security Hub Finding
    |
    v
Default EventBridge Bus
    |
    v
EC2 Isolation Lambda
    |
    v
Snapshot attached EBS volumes
    |
    v
Replace instance security groups with quarantine security group
    |
    v
Tag instance and send SNS notification
```

The isolation Lambda:

- Identifies qualifying EC2 findings
- Snapshots attached EBS volumes prior to isolation
- Stores or preserves original security group information
- Replaces existing security groups with a quarantine security group
- Tags the affected instance
- Sends a SecOps notification

This enables rapid containment of potentially compromised instances.

---

## EC2 Rollback Workflow

The `EC2 Rollback` workflow provides controlled recovery after isolation.

Rollback is intentionally human-approved and triggered through the environment-specific SecOps event bus.

Workflow:

```text
SecOps review / approval
    |
    v
SecOps-Operator sends rollback event
    |
    v
SecOps EventBridge Bus
    |
    v
EC2 Rollback Lambda
    |
    v
Restore original security groups
    |
    v
Send SNS notification
```

The `SecOps-Operator` role can submit rollback events but cannot directly modify EC2 security groups.

This creates a separation between:

- Human approval
- Event submission
- Automated infrastructure modification

---

## IP Enrichment Workflow

The `IP Enrichment` workflow enriches public IP addresses found in Security Hub findings.

Workflow:

```text
Security Hub Finding
    |
    v
EventBridge Rule
    |
    v
IP Enrichment Lambda
    |
    v
Secrets Manager retrieves AbuseIPDB API key
    |
    v
AbuseIPDB lookup
    |
    +--> SNS notification
    |
    +--> Optional Security Hub note writeback
```

This provides additional context for investigation and triage.

---

## Configuration Monitoring

AWS Config continuously evaluates infrastructure posture against defined managed rules.

The configuration baseline supports checks related to:

- S3 security
- CloudTrail configuration
- RDS security
- EBS encryption
- Security group exposure
- IAM posture
- EC2 hardening
- KMS key hygiene

This supports exposure prevention, encryption enforcement, and monitoring consistency.

---

## Encryption Architecture

The baseline uses KMS-backed encryption for sensitive platform resources.

KMS keys are used for resources such as:

- S3 logs
- Lambda
- EBS
- Backup vaults
- Secrets Manager
- SNS topics
- CloudWatch Logs

This supports confidentiality, integrity, and separation of encryption domains.

---

## Backup and Patch Management

The baseline includes support for operational resilience through:

- AWS Backup
- Backup vault encryption
- Tag-based backup selection
- Retention policies
- SSM Patch Manager
- Maintenance windows
- Patch groups

These controls support recovery readiness and operational hygiene.

---

## Break-Glass Monitoring

The baseline includes a break-glass administrative role for emergency access.

Use of this role is monitored through CloudTrail and EventBridge.

When the break-glass role is used, an alert is sent to the configured SecOps notification path.

This provides emergency access while preserving visibility and auditability.

---

## Role Within a Security Program

`tf-secure-baseline` provides a deployable infrastructure security foundation.

It complements:

- Application security controls
- SDLC and CI/CD controls
- Identity governance
- Organizational policies
- Vulnerability management
- Incident response procedures
- Compliance evidence collection

It does not replace:

- Secure application development
- Formal risk management
- Human incident response
- Governance processes
- Business-specific compliance controls

---

## Cost Considerations

The baseline uses security services that can generate meaningful cost, especially when deployed across multiple environments.

Notable cost drivers include:

- AWS Network Firewall
- AWS Config
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- Security services
- KMS requests
- Backup storage

The default design prioritizes security and production readiness.

Future enhancements may include configurable deployment profiles, such as:

```text
network_firewall
nat_only
vpc_endpoints_only
```

This would allow teams to choose different cost/security tradeoffs per environment.

---

## Summary

`tf-secure-baseline` implements a multi-account AWS security baseline with centralized identity, secure networking, encrypted logging, continuous detection, event-driven response, and GitHub OIDC-based CI/CD.

The architecture is designed to provide a secure starting point for SaaS companies and teams handling sensitive data while remaining modular enough to adapt to different environments and organizational requirements.