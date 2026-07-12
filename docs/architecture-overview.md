# Architecture Overview - tf-secure-baseline

## Purpose

This document describes the high-level architecture implemented by `tf-secure-baseline` and how its components work together to support secure AWS cloud environments.

It focuses on system relationships, trust boundaries, and operational flow rather than low-level Terraform implementation details.

`tf-secure-baseline` is designed for SaaS companies and engineering teams running workloads that handle PII or other sensitive data and need a secure, repeatable cloud foundation aligned with **SOC 2 / ISO 27001-style** security expectations.

---

## High-Level Architecture

The platform is organized around a **multi-account AWS architecture** with a centralized control plane and isolated workload environments.

```text
Manual-First State Bootstrap
    |
    v
Create S3 State Bucket and State CMK
    |
    v
migrate-state-stack.sh
    |
    v
Remote S3 State with Native Lockfiles
    |
    +--> bootstrap/control_plane/state
    +--> bootstrap/dev/state
    +--> bootstrap/staging/state
    +--> bootstrap/prod/state

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
    |       +--> account
    |       +--> organizations
    |       +--> identity_center
    |
    +--> bootstrap/dev/account
    +--> bootstrap/staging/account
    +--> bootstrap/prod/account
    |
    +--> environments/dev
    +--> environments/staging
    +--> environments/prod
```

At a high level:

- The **control plane** manages organization-wide structure, centralized identity, and control-plane CI/CD access.
- Each **state substack** is initialized and applied locally first so it can create its S3 state bucket and KMS key.
- The state-stack migration helper then materializes the ignored active backend configuration from `backend.tf.migrated.example`, migrates the state into S3, and verifies the remote state.
- Each **account substack** creates the GitHub OIDC roles used by CI/CD for that account/environment.
- Each **environment stack** deploys the actual security baseline into its dedicated AWS account.
- GitHub Actions uses OIDC to assume environment-specific roles.
- Read-only evidence workflows use the applicable `*-plan` role and materialize the state-stack backend at runtime.
- IAM Identity Center provides centralized human access.
- EventBridge, Security Hub, Lambda, and SNS provide event-driven detection and response.

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
    +--> Prod account infrastructure
```

This model provides:

- Environment isolation
- Reduced blast radius
- Separate Terraform state per account/environment
- Cleaner access boundaries
- Production-aligned account segmentation
- Multi-AZ / Multi-region capabilities, if configured

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
| `state` | Creates the control-plane state bucket and CMK, then stores its own state in that remote backend after migration |
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

Each environment is deployed into its own AWS account and contains the `baseline` infrastructure.

Depending on the selected `deployment_profile` and `egress_mode`, each environment may deploy different cost/security combinations.

Environment stacks can include:

- VPC and subnet segmentation
- Deployment profile and egress mode resolution
- AWS Network Firewall, when enabled by egress mode
- NAT Gateways, when required by egress mode
- VPC endpoints
- Dedicated VPC endpoint subnets
- EC2 workloads
- S3 buckets
- KMS keys
- CloudTrail
- CloudWatch
- AWS Config, when enabled by profile or override
- GuardDuty
- Security Hub
- Inspector, when enabled by profile
- EventBridge rules
- Lambda automation
- SNS topics
- Backup and patch management resources

Each environment is independently deployable, destroyable, and testable.

---

## Deployment Profiles

The baseline supports deployment profiles that set environment-appropriate defaults.

Profiles are intended to provide a clear cost/security posture while still allowing explicit overrides.

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

The profile defines defaults only. Explicit variables can override profile defaults.

For example:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

This allows a development environment to use the production-style egress inspection path when needed.

---

## Egress Modes

The baseline supports configurable egress modes for private compute subnet routing.

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route | Intended use |
|---|---:|---:|---|---|
| `network_firewall` | Yes | Yes | `0.0.0.0/0` to Network Firewall endpoint | Production / sensitive workloads |
| `nat_only` | No | Yes | `0.0.0.0/0` to NAT Gateway | Lower-cost dev/staging |
| `vpc_endpoints_only` | No | No | No default route | Private AWS-only / minimal testing |

When `egress_mode = "auto"`, the effective egress mode is selected from the `deployment_profile`.

Important:

When `egress_mode = "vpc_endpoints_only"`, Network Firewall and NAT Gateways are not deployed, and compute private subnets do not receive a default internet route. This mode is intended for AWS-private testing or workloads that do not require external package repositories or third-party internet access. EC2 user data package installation may fail unless package access is provided another way.

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
- Configurable cost/security profiles
- Automated containment
- Human-approved recovery
- Immutable and encrypted logging
- Least-privilege access

These principles guide the structure of the Terraform modules, account layout, IAM model, deployment profiles, egress modes, and security automation workflows.

---

## Networking Architecture

Each workload environment is deployed into a segmented VPC.

The VPC includes subnet tiers such as:

- Public subnets
- Private compute subnets
- Private data subnets
- Private serverless subnets
- Private firewall subnets
- Private VPC endpoint subnets

Application and compute workloads are placed in private subnets and do not receive public IP addresses.

For production-style inspected egress, the typical outbound path is:

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

For lower-cost development egress, the typical outbound path is:

```text
Private Compute Subnets
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

For private AWS-only operation, compute private subnets do not receive a default internet route and rely on VPC endpoints for supported AWS service access.

---

## Controlled Egress

Outbound access is intentionally restricted and routed through controlled paths.

The baseline supports:

- AWS Network Firewall for egress inspection
- NAT Gateway for controlled internet access
- VPC endpoints for AWS service access
- Route table segmentation
- Security group restrictions
- Deployment profile-based cost/security defaults
- Egress mode overrides per environment

Where possible, access to AWS services should occur through VPC endpoints instead of public internet paths.

This reduces unnecessary internet exposure and improves control over workload communication.

### Network Firewall Mode

When the effective egress mode is `network_firewall`, private compute traffic is routed through AWS Network Firewall before reaching NAT Gateway.

```text
Private Compute Subnets
    |
    v
AWS Network Firewall policy enforcement
    |
    v
NAT Gateway
    |
    v
Internet Gateway
```

This allows the environment to enforce centralized outbound inspection and domain/protocol restrictions.

### NAT-Only Mode

When the effective egress mode is `nat_only`, Network Firewall is not deployed and private compute traffic routes directly to NAT Gateway.

```text
Private Compute Subnets
    |
    v
NAT Gateway
    |
    v
Internet Gateway
```

This mode is intended for lower-cost development and staging environments where full egress inspection is not required.

### VPC-Endpoints-Only Mode

When the effective egress mode is `vpc_endpoints_only`, neither Network Firewall nor NAT Gateway is deployed.

```text
Private Compute Subnets
    |
    v
VPC Endpoints for supported AWS services
```

This mode is intended for minimal/private testing and workloads that do not require general internet access.

---

## VPC Endpoints

VPC endpoints are used to reduce dependency on public internet access for AWS service communication.

The baseline deploys Interface VPC Endpoints into dedicated private endpoint subnets.

These endpoint subnets:

- Are separate from compute, data, serverless, public, and firewall subnets
- Have their own route tables
- Do not require a default internet route
- Host Interface Endpoint ENIs
- Allow workloads to reach supported AWS services over private VPC-local paths

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
- EventBridge
- SNS
- STS

Interface Endpoints are placed in dedicated endpoint private subnets, while the S3 Gateway Endpoint is associated with the private route tables that need S3 access.

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

Layer-specific evidence workflows use the Plan roles and their corresponding `*-plan` GitHub environments. Because active state-stack `backend.tf` files are ignored, these workflows copy `backend.tf.migrated.example` to `backend.tf` before initializing and validating the migrated state stacks.

## Terraform State Architecture

Terraform state is separated by account, environment, and substack.

The `state` substacks are special bootstrap stacks because they create the S3 bucket and KMS key that will ultimately store their own state. They therefore use a two-phase lifecycle.

### Phase 1: Initial local bootstrap

A new state stack has no active `backend.tf`. Terraform is initialized and applied locally so the stack can create:

- the S3 state bucket
- the customer-managed KMS key for state encryption
- the bucket security, versioning, encryption, and access controls

The repository tracks the post-migration backend configuration as:

```text
backend.tf.migrated.example
```

Terraform ignores that filename during the initial local bootstrap.

### Phase 2: Remote-state migration

After the state resources exist, the operator runs:

```bash
AWS_PROFILE="<profile>" \
EXPECTED_ACCOUNT_ID="<account-id>" \
./scripts/bootstrap/migrate-state-stack.sh <dev|staging|prod|control-plane>
```

The helper:

- validates the AWS identity and optional expected account ID
- confirms the backend template bucket matches `tf_state_bucket_name`
- saves pre-migration state backups outside the repository
- refuses to overwrite an existing destination state object
- copies `backend.tf.migrated.example` to the ignored active `backend.tf`
- runs interactive `terraform init -migrate-state`
- verifies the S3 object, `terraform state pull`, outputs, and resource addresses

The active `backend.tf` remains local and ignored by Git. GitHub evidence workflows materialize the same file from the tracked template at runtime.

### Remote state layout

Example environment state layout:

```text
bootstrap/dev/state
    -> remote backend key: bootstrap/state/dev.tfstate

bootstrap/dev/account
    -> remote backend key: bootstrap/dev.tfstate

environments/dev
    -> remote backend key: baseline/dev.tfstate
```

The staging and production accounts follow the same key structure.

Control-plane layout:

```text
bootstrap/control_plane/state
    -> remote backend key: control-plane/state.tfstate

bootstrap/control_plane/account
    -> remote backend key: control-plane/account.tfstate

bootstrap/control_plane/identity_center
    -> remote backend key: control-plane/identity-center.tfstate

bootstrap/control_plane/organizations
    -> remote backend key: control-plane/organizations.tfstate
```

All remote-backed stacks use S3 native locking with:

```hcl
use_lockfile = true
```

Each Terraform root uses a distinct state object key. This separation reduces blast radius and prevents unrelated Terraform operations from affecting each other while still solving the initial backend bootstrapping dependency.

## Centralized Logging

Operational and security activity is captured through:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs
- Network Firewall flow and alert logs, when Network Firewall is deployed

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
- Object Lock, where enabled
- Restricted bucket policies
- Lifecycle transitions

CloudWatch Logs retention is profile-aware by default:

| `deployment_profile` | Default CloudWatch retention |
|---|---:|
| `production` | 90 days |
| `development` | 30 days |
| `minimal` | 14 days |

This supports monitoring continuity, incident response, and evidence preservation while allowing lower-cost profiles for non-production environments.

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

Some detection and compliance services are profile-aware. For example, AWS Config remains enabled by default for `production` and `development`, while `minimal` disables it by default unless explicitly overridden. Inspector is enabled by default for `production` and `development`, and disabled by default for `minimal`.

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

AWS Config continuously evaluates infrastructure posture against defined managed rules when enabled.

The configuration baseline supports checks related to:

- S3 security
- CloudTrail configuration
- RDS security
- EBS encryption
- Security group exposure
- IAM posture
- EC2 hardening
- KMS key hygiene

AWS Config enablement is profile-aware:

| `deployment_profile` | AWS Config default |
|---|---:|
| `production` | Enabled |
| `development` | Enabled |
| `minimal` | Disabled |

If AWS Config is disabled, Config rule groups are forced off. If AWS Config is explicitly enabled, rule group settings follow the configured `enable_rules` object.

This supports exposure prevention, encryption enforcement, and monitoring consistency while still allowing lower-cost minimal deployments.

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

AWS Backup enablement is profile-aware:

| `deployment_profile` | Backup default |
|---|---:|
| `production` | Enabled |
| `development` | Disabled |
| `minimal` | Disabled |

This keeps production recovery controls enabled by default while reducing cost in lower-cost profiles unless backup is explicitly enabled.

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

The default design prioritizes security and production readiness, but deployment profiles and egress modes allow teams to choose different cost/security tradeoffs per environment.

| `deployment_profile` | Cost/security intent |
|---|---|
| `production` | Full baseline for sensitive workloads |
| `development` | Lower-cost development baseline with NAT-only egress |
| `minimal` | Lowest-cost AWS-private testing profile |

| `egress_mode` | Cost/security intent |
|---|---|
| `network_firewall` | Highest egress control, highest network inspection cost |
| `nat_only` | Lower-cost internet egress without Network Firewall |
| `vpc_endpoints_only` | Lowest egress cost, no general internet route |

These profiles do not replace environment-specific review. Production deployments should still review deletion protection, retention periods, Object Lock, KMS lifecycle protections, backup requirements, and access controls before use.

---

## Summary

`tf-secure-baseline` implements a multi-account AWS security baseline with centralized identity, secure networking, encrypted logging, continuous detection, event-driven response, deployment profile support, configurable egress modes, dedicated VPC endpoint subnets, and GitHub OIDC-based CI/CD.

The architecture is designed to provide a secure starting point for SaaS companies and teams handling sensitive data while remaining modular enough to adapt to different environments, cost requirements, and organizational security expectations.