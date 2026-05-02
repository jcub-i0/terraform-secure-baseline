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

Workload environments manage:

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

The `state` substacks are applied locally first because they create the remote backend resources used by later Terraform stacks.

Examples include:

- S3 bucket for Terraform state
- KMS key for state encryption
- DynamoDB table or S3 lockfile support for state locking

After backend resources exist, GitHub Actions can safely manage the remaining stacks through OIDC roles.

This avoids the bootstrapping problem where Terraform would need a remote backend before the backend exists.

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

The goal is to reduce unmonitored outbound communication and create a central location for inspection and restriction.

This is especially important for workloads that process sensitive data.

---

## 8. Prefer Private AWS Service Access

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
- EC2 Messages
- SSM Messages

---

## 9. Centralized Logging and Evidence Preservation

Security and operational logs should be centralized, encrypted, and protected from tampering.

The baseline captures data from services such as:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs

The logging design emphasizes:

- KMS encryption
- Versioning
- Restricted bucket policies
- Object Lock
- Lifecycle retention
- Long-term forensic usefulness

Logs are treated as security evidence, not just operational telemetry.

---

## 10. Detection Integrity

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

## 11. Event-Driven Security Automation

The baseline uses EventBridge and Lambda for security automation.

Security events are routed into controlled workflows that can:

- Isolate EC2 instances
- Restore EC2 security groups after approval
- Enrich IP addresses from findings
- Alert on tampering
- Alert on break-glass role usage

This enables rapid response without requiring humans to manually execute every action.

---

## 12. Automated Containment, Human-Approved Recovery

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

## 13. Least Privilege by Workflow

Permissions are designed around workflows rather than broad job titles.

Examples:

- CI/CD roles can manage Terraform resources for a specific environment.
- Lambda execution roles receive only the permissions needed by their automation.
- SecOps operators can submit rollback events but cannot directly modify EC2 resources.
- Analysts can be granted visibility without response permissions.
- Engineers can be granted limited response actions where required.

This reduces the chance that one compromised credential can perform every action.

---

## 14. Environment-Specific Permissions

Many resources are environment-specific, including:

- KMS keys
- S3 buckets
- IAM policies
- EventBridge buses
- Lambda functions
- SNS topics

The design avoids assuming that one environment's policies or keys apply to another environment.

Identity Center can assign access centrally, but the actual resource permissions are created in the target workload accounts.

This avoids circular dependencies and preserves environment isolation.

---

## 15. Immutable and Encrypted State

Terraform state is sensitive because it can contain resource identifiers, outputs, and sometimes secrets or references to sensitive infrastructure.

The baseline treats Terraform state as a protected asset.

State resources use:

- S3 storage
- KMS encryption
- Locking
- Restricted administrative access
- Separate state files per stack

The state backend is intentionally separated from the infrastructure it manages.

---

## 16. Modular but Opinionated

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

This makes the platform easier to understand, test, and adapt.

The goal is not maximum abstraction. The goal is a secure and maintainable baseline.

---

## 17. Secure Defaults Over Maximum Flexibility

The baseline favors secure defaults even if they require more setup.

Examples include:

- Private subnets for compute
- KMS encryption
- Centralized logging
- Security Hub and GuardDuty
- Event-driven alerting
- Identity Center access
- GitHub OIDC instead of static credentials

The platform can be customized, but defaults should guide users toward safer outcomes.

---

## 18. Operational Recoverability

Security architecture must support recovery, not just prevention.

The baseline includes controls such as:

- AWS Backup
- Backup vault encryption
- Retention policies
- EC2 rollback workflow
- Patch management support
- Centralized logs for investigation

This supports operational resilience after incidents, mistakes, or misconfigurations.

---

## 19. Audit and Assurance Readiness

The baseline is designed to support security assurance efforts, but it does not guarantee certification.

It can help produce evidence for areas such as:

- Access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery

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

### Response Automation

Response automation includes:

- EC2 isolation
- EC2 rollback
- IP enrichment
- Tamper detection alerts
- Break-glass role usage alerts
- SNS notifications

---

### Recovery and Resilience

Recovery and resilience are supported through:

- AWS Backup
- Backup vaults
- Retention policies
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

The design intentionally prioritizes security and visibility over lowest possible cost.

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

The default design favors stronger production security.

Future versions may introduce configurable cost/security profiles, such as:

```text
network_firewall
nat_only
vpc_endpoints_only
```

This would allow teams to choose different profiles for dev, staging, and production environments.

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
- Secure CI/CD
- Practical audit readiness

The goal is to provide a strong security foundation that can be understood, operated, and extended by small technical teams without requiring them to design every control from scratch.