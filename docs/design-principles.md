# Design Principles - tf-secure-baseline

## Purpose

This document describes the design principles behind `tf-secure-baseline`.

It explains why the platform is structured the way it is, what tradeoffs were made, and what security outcomes the baseline is intended to support.

This document is not a deployment guide. For deployment instructions, see:

```text
docs/quickstart.md
```

For system structure, see:

```text
docs/architecture-overview.md
```

---

## Target Client Type

`tf-secure-baseline` is designed for early- to mid-stage SaaS companies and engineering teams that:

- Run workloads in AWS
- Handle customer PII or other sensitive data
- Need stronger cloud security defaults
- Want a reusable AWS foundation
- Are preparing for SOC 2, ISO 27001, or similar assurance efforts
- Need security architecture that is understandable and operable by a small team

The baseline is opinionated, but it is intended to be adaptable.

It provides a secure starting point rather than a one-size-fits-all production platform.

---

## Primary Design Goals

The baseline is designed to provide:

- Secure-by-default AWS infrastructure
- Multi-account environment isolation
- Centralized identity and access management
- No long-lived CI/CD credentials
- Private-first networking
- Controlled outbound access
- Configurable deployment profiles
- Configurable egress modes
- Dedicated private subnets for Interface VPC Endpoints
- Centralized logging and monitoring
- Automated detection and response
- Human-approved recovery workflows
- Encrypted and tamper-resistant operational evidence
- A structure that is understandable enough to be adopted by small teams

---

## Core Principles

## 1. Multi-Account Isolation

Each major environment is deployed into a dedicated AWS account.

```text
control-plane
dev
staging
prod
```

This reduces blast radius and creates cleaner separation between:

- Development workloads
- Staging workloads
- Production workloads
- Control-plane resources
- Human access management
- CI/CD execution roles

A compromise or misconfiguration in one workload account should not automatically compromise every environment.

---

## 2. Control Plane Separation

Control-plane resources are separated from workload infrastructure.

The control plane manages:

- AWS Organizations structure
- IAM Identity Center access
- Control-plane Terraform state
- GitHub OIDC roles for control-plane automation

Environment bootstrap stacks manage:

- Environment-specific Terraform state resources
- Environment-specific GitHub OIDC roles for CI/CD

Workload baseline stacks manage:

- Networking
- Compute
- Logging
- Security services
- Automation
- Storage
- Backup
- Patch management

This separation prevents workload changes from accidentally impacting foundational access and governance resources.

It also prevents Terraform from destroying the roles or state resources it depends on to operate.

---

## 3. Bootstrap Before Automation

Some resources must exist before automation can safely manage the rest of the platform.

Each `state` substack follows a two-phase lifecycle:

1. It is initialized and applied locally without an active `backend.tf`.
2. After it creates the S3 state bucket and state CMK, its local state is migrated into the new S3 backend.

The repository tracks the intended post-migration configuration as:

```text
backend.tf.migrated.example
```

The active runtime file is:

```text
backend.tf
```

The active file is generated only after the backend resources exist and is ignored by Git. The guarded migration helper:

```text
scripts/bootstrap/migrate-state-stack.sh
```

checks the AWS account, validates the backend template against the state-stack output, backs up local state, refuses to overwrite an existing remote state object, runs `terraform init -migrate-state`, and verifies the resulting remote state.

State locking uses Terraform S3 native lockfiles with:

```hcl
use_lockfile = true
```

After the state stack has been migrated and the account stack has created GitHub OIDC roles, GitHub Actions can safely initialize the remote backends and manage supported stacks.

This preserves the required bootstrap sequence without leaving long-lived Terraform state only on an operator workstation.

---

## 4. No Long-Lived CI/CD Credentials

GitHub Actions uses OIDC to assume AWS IAM roles.

The platform does not require static AWS access keys for CI/CD.

This reduces risk from:

- Leaked repository secrets
- Long-lived access keys
- Over-permissive machine users
- Manual key rotation failures

Each environment has its own plan and apply roles.

Example:

```text
dev-plan        -> dev GitHub-Plan role
dev             -> dev GitHub-Apply role

staging-plan    -> staging GitHub-Plan role
staging         -> staging GitHub-Apply role

prod-plan       -> prod GitHub-Plan role
prod            -> prod GitHub-Apply role
```

This keeps CI/CD access scoped to the environment being operated on.

---

## 5. Human Access Through IAM Identity Center

Human access is managed through IAM Identity Center instead of long-lived IAM users.

The design favors:

- Group-based access
- Permission sets
- Account assignments
- Environment-specific roles
- Least-privilege operational workflows

Example Identity Center groups:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

Optional roles may include:

```text
SecOps-Analyst
SecOps-Engineer
```

The access model is designed so that humans receive only the access needed for their function.

For example, `SecOps-Operator` can submit approved rollback events, but it does not directly modify EC2 instances or invoke Lambda functions.

---

## 6. Private-First Infrastructure

Workloads are placed in private subnets by default.

Compute resources should not receive public IP addresses.

Inbound exposure is minimized, and outbound traffic is controlled through explicit network paths.

The exact outbound path depends on the selected `deployment_profile` and effective `egress_mode`.

Production-style inspected egress:

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

Lower-cost NAT-only egress:

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

Private AWS-only egress:

```text
Private Compute Subnets
    |
    v
VPC Endpoints for supported AWS services
```

This makes private networking the default and public exposure the exception.

---

## 7. Controlled Egress

Outbound access is treated as a security boundary.

The baseline uses controls such as:

- AWS Network Firewall
- NAT Gateway
- Route table segmentation
- VPC endpoints
- Security groups
- Explicit service access paths
- Egress mode selection

The goal is to reduce unmonitored outbound communication and create a central location for inspection and restriction.

This is especially important for workloads that process sensitive data.

The supported egress modes are:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route | Intended use |
|---|---:|---:|---|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint | Production / sensitive workloads |
| `nat_only` | No | Yes | NAT Gateway | Lower-cost dev/staging |
| `vpc_endpoints_only` | No | No | No default route | Private AWS-only / minimal testing |

When `egress_mode = "auto"`, the effective egress mode is selected from the `deployment_profile`.

---

## 8. Deployment Profiles Should Provide Safe Defaults

Deployment profiles provide a practical way to balance security, cost, and operational needs across environments.

The baseline supports profiles such as:

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

Profiles define defaults, not hard limits.

Explicit variables can override profile defaults when needed.

For example, a development environment can still use Network Firewall by setting:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

This keeps the baseline adaptable while preserving clear default behavior.

---

## 9. Prefer Private AWS Service Access

Where practical, AWS service access should use VPC endpoints instead of public internet paths.

This improves:

- Network privacy
- Egress control
- Reliability
- Auditability
- Dependency reduction on public internet routes

Examples of services commonly accessed through VPC endpoints include:

- S3
- Systems Manager
- CloudWatch Logs
- Secrets Manager
- KMS
- SSM Messages
- Security Hub
- Lambda
- EventBridge
- SNS
- SQS
- STS

Interface VPC Endpoints are deployed into dedicated private endpoint subnets.

This keeps endpoint ENIs separate from compute, data, serverless, firewall, and public subnet tiers.

The S3 Gateway Endpoint is associated with the private route tables that need S3 access.

---

## 10. Endpoint Subnets Should Be Dedicated

Interface Endpoint ENIs should not compete with workload ENIs in compute subnets when the architecture can avoid it.

The baseline uses dedicated private subnets for Interface VPC Endpoints.

This provides:

- Cleaner subnet segmentation
- Reduced private IP pressure in compute subnets
- Easier endpoint inventory and troubleshooting
- Clearer route table ownership
- Better separation between workload placement and AWS service access infrastructure

Endpoint private subnets do not require a default internet route.

Workloads reach Interface Endpoints through normal VPC-local routing and security group rules.

---

## 11. Centralized Logging and Evidence Preservation

Security and operational logs should be centralized, encrypted, and protected from tampering.

The baseline captures data from services such as:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs
- Network Firewall logs, when Network Firewall is deployed

The logging design emphasizes:

- KMS encryption
- Versioning
- Restricted bucket policies
- Object Lock, where enabled
- Lifecycle retention
- Profile-aware CloudWatch retention
- Long-term forensic usefulness

Logs are treated as security evidence, not just operational telemetry.

---

## 12. Detection Integrity

Detection systems must be protected from tampering.

The baseline monitors for attempts to disable or modify security services such as:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS
- Logging destinations

Tamper-related events are routed through EventBridge and surfaced through SNS notifications.

A security platform should detect attempts to weaken the security platform itself.

---

## 13. Event-Driven Security Automation

The baseline uses EventBridge and Lambda for security automation.

Security events are routed into controlled workflows that can:

- Isolate and snapshot EC2 instances
- Restore EC2 security groups after approval
- Enrich IP addresses from findings
- Alert on tampering
- Alert on break-glass role usage

This enables rapid response without requiring humans to manually execute every action.

---

## 14. Automated Containment, Human-Approved Recovery

Containment can happen automatically when a high-confidence security condition is detected.

Recovery should require human review.

For example:

```text
Security Hub finding
    |
    v
EC2 Isolation Lambda
    |
    v
Instance quarantine
    |
    v
Human review
    |
    v
SecOps-Operator rollback event
    |
    v
EC2 Rollback Lambda
```

This design supports fast containment while preventing uncontrolled automatic restoration.

---

## 15. Least Privilege by Workflow

Permissions are designed around workflows rather than broad job titles.

Examples:

- CI/CD roles can manage Terraform resources for a specific environment.
- Lambda execution roles receive only the permissions needed by their automation.
- SecOps operators can submit rollback events but cannot directly modify EC2 resources.
- Analysts can be granted visibility without response permissions.
- Engineers can be granted limited response actions where required.

This reduces the chance that one compromised credential can perform every action.

---

## 16. Environment-Specific Permissions

Many resources are environment-specific, including:

- KMS keys
- Cloudwatch and CloudTrail Logs
- S3 buckets
- RDS instances
- IAM policies
- EventBridge buses
- Lambda functions
- SNS topics

The design avoids assuming that one environment's policies or keys apply to another environment.

Identity Center can assign access centrally, but the actual resource permissions are created in the target workload accounts.

This avoids circular dependencies and preserves environment isolation.

---

## 17. Immutable and Encrypted State

Terraform state is sensitive because it can contain resource identifiers, outputs, and sometimes secrets or references to sensitive infrastructure.

The baseline treats Terraform state as a protected asset.

State resources use:

- S3 storage
- KMS encryption
- S3 native lockfiles
- Versioning
- Restricted administrative access
- Separate state object keys per Terraform root

The state stacks are a controlled bootstrap exception: they initially use local state only long enough to create their backend resources, then migrate their own state into those protected S3 backends.

A tracked `backend.tf.migrated.example` documents the intended remote configuration, while the active `backend.tf` is created only after the backend exists and is ignored by Git.

Migration is not considered complete merely because `backend.tf` exists. Validation also confirms that:

- The remote S3 state object exists and is readable.
- `terraform state pull` succeeds through the configured backend.
- The backend bucket matches the state stack's `tf_state_bucket_name` output.
- State, account, and workload roots use distinct state object keys.

---

## 18. Modular but Opinionated

The repository is organized into reusable modules, but the baseline remains opinionated.

Modules support clear boundaries such as:

- Networking
- Firewall
- Logging
- Monitoring
- Security
- IAM
- Automation
- Backup
- Patch management
- Storage
- VPC endpoints
- Compute

This makes the platform easier to understand, test, and adapt.

The goal is not maximum abstraction. The goal is a secure and maintainable baseline.

---

## 19. Secure Defaults Over Maximum Flexibility

The baseline favors secure defaults even if they require more setup.

Examples include:

- Private subnets for compute
- KMS encryption
- Centralized logging
- Security Hub and GuardDuty
- Event-driven alerting
- Identity Center access
- GitHub OIDC instead of static credentials
- Profile defaults that keep production security controls enabled
- Egress defaults that route production workloads through Network Firewall

The platform can be customized, but defaults should guide users toward safer outcomes.

---

## 20. Cost Controls Should Be Explicit

Security controls have cost implications.

The baseline makes major cost/security tradeoffs explicit through deployment profiles and egress modes rather than hiding them inside ad hoc environment differences.

Examples:

- `production` keeps the full baseline enabled by default.
- `development` lowers cost by using NAT-only egress and disabling backup by default.
- `minimal` removes Network Firewall and NAT Gateway by default and relies on VPC endpoints for supported AWS services.

This helps teams understand why an environment costs what it costs and what security tradeoffs are being made.

---

## 21. Operational Recoverability

Security architecture must support recovery, not just prevention.

The baseline includes controls such as:

- AWS Backup
- Backup vault encryption
- Retention policies
- EC2 rollback workflow
- Patch management support
- Centralized logs for investigation

Backup defaults are profile-aware.

Production enables backup by default, while lower-cost profiles can disable backup unless explicitly overridden.

This supports operational resilience after incidents, mistakes, or misconfigurations while keeping development costs manageable.

---

## 22. Audit and Assurance Readiness

The baseline is designed to support security assurance efforts, but it does not guarantee certification.

It can help produce evidence for areas such as:

- Least privilege access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery
- Network segmentation
- Controlled egress

However, SOC 2 and ISO 27001 also require business processes, policies, risk management, vendor management, and human operational controls.

Infrastructure alone is not a certification.

---

## Threat Model Assumptions

The baseline is designed to reduce risk from common cloud security threats.

### Primary Threats

- Unauthorized access to customer PII
- Credential compromise
- Over-permissive IAM access
- Misconfigured public exposure
- Data exfiltration from workloads
- Disabling or weakening logging
- Disabling or weakening detection services
- Compromise of EC2 workloads
- Lack of visibility into malicious activity
- Accidental data loss
- Operator mistakes
- Weak CI/CD credential handling
- Unrestricted outbound internet access from private workloads
- Excessive cloud security cost causing teams to disable controls informally

---

## Key Security Controls

### Data Protection

The baseline supports data protection through:

- S3 encryption
- S3 versioning
- S3 Object Lock for log storage
- KMS-backed encryption
- Restricted bucket policies
- Backup vault encryption
- Secrets Manager encryption

---

### Detection and Visibility

Detection and visibility are provided through:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- Inspector
- CloudWatch
- EventBridge
- VPC Flow Logs
- Lambda automation logs
- Network Firewall logs, when deployed

---

### Access Control

Access control is implemented through:

- IAM Identity Center
- Environment-specific groups
- Permission sets
- GitHub OIDC roles
- Least-privilege IAM policies
- Break-glass monitoring
- No long-lived CI/CD credentials

---

### Network Control

Network control is implemented through:

- Private subnet placement
- Public subnet public IP auto-assignment disabled
- Configurable egress modes
- AWS Network Firewall, when enabled
- NAT Gateway, when required
- Dedicated endpoint private subnets
- Interface VPC Endpoints
- S3 Gateway Endpoint
- Security group-to-security group rules

---

### Response Automation

Response automation includes:

- EC2 isolation
- EC2 rollback
- IP enrichment
- Tamper detection alerts
- Break-glass role usage alerts
- Config Auto-Remediation
- SNS notifications

---

### Recovery and Resilience

Recovery and resilience are supported through:

- AWS Backup, when enabled
- Backup vaults
- Retention policies
- Pre-EC2 isolation snapshots
- EC2 rollback
- Patch management
- Immutable logs
- Terraform state separation

---

## Security Priorities

The platform balances:

- Data security
- Identity security
- Detection and response
- CI/CD hardening
- Operational manageability
- Cost awareness
- Audit readiness

The design intentionally prioritizes security and visibility over lowest possible cost for production environments, while still allowing lower-cost development and minimal profiles.

---

## Cost Tradeoffs

Some controls increase cost, especially when deployed across multiple environments.

Notable cost drivers include:

- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- Security services
- KMS requests
- Backup storage

The default production design favors stronger security.

Deployment profiles and egress modes allow teams to choose different cost/security tradeoffs for dev, staging, and production environments.

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

These profiles do not replace environment-specific review.

Production deployments should still review deletion protection, retention periods, Object Lock, KMS lifecycle protections, backup requirements, and access controls before use.

---

## Non-Goals

### Not a Compliance Certification Guarantee

This baseline supports alignment with frameworks such as SOC 2 and ISO 27001.

It does not guarantee audit success or certification by itself.

Certification also requires organizational controls, policies, risk management, human procedures, and evidence collection.

---

### Not a Complete Landing Zone Replacement

This project provides a secure Terraform baseline, but it is not a full enterprise landing zone product.

Some organizations may still need:

- Account vending
- Centralized billing automation
- Organization-wide SCP strategy
- Enterprise network connectivity
- Centralized SIEM integration
- Custom compliance guardrails

---

### Not a 24/7 SOC

The baseline provides automated detection, response, enrichment, and alerting.

It does not provide continuous human monitoring, managed detection and response, or incident response retainers.

---

### Not a Zero-Trust Application Platform

The baseline provides strong cloud infrastructure controls.

It does not implement application-layer zero trust by default, such as:

- Service mesh
- mTLS between all services
- Fine-grained application identity
- Runtime authorization between services

---

### Not a Substitute for Secure Application Development

Infrastructure security does not replace secure application engineering.

Clients still need:

- Secure SDLC
- Code review
- Dependency scanning
- Application logging
- Secrets management practices
- Authentication and authorization controls
- Secure API design

---

### Not Designed for Hyperscale by Default

The baseline is intended for small and mid-sized SaaS environments.

It is not optimized out of the box for:

- Millions of requests per second
- Global active-active architectures
- High-throughput streaming systems
- Extremely large data lake environments
- Complex multi-region failover

Those patterns can be added later, but they are not default assumptions.

---

### Not Risk Elimination

The baseline reduces risk and improves visibility.

It does not prevent every possible breach, misconfiguration, or operational mistake.

Security still requires people, process, monitoring, review, and continuous improvement.

---

## Intended Outcomes

The intended outcomes of this baseline are:

- Faster deployment of secure AWS environments
- Reduced risk of public exposure
- Stronger logging and detection posture
- Safer CI/CD authentication
- More consistent access control
- Faster containment of EC2-related incidents
- Better security evidence collection
- Clearer cost/security tradeoffs by environment
- A reusable foundation for client or internal SaaS environments

---

## Summary

`tf-secure-baseline` is designed to be a secure, modular, multi-account AWS baseline for sensitive SaaS workloads.

Its design favors:

- Separation of duties
- Private infrastructure
- Centralized identity
- Immutable logging
- Event-driven detection and response
- Configurable egress control
- Dedicated private endpoint access
- Secure CI/CD
- Practical audit readiness

The goal is to provide a strong security foundation that can be understood, operated, and extended by small technical teams without requiring them to design every control from scratch.