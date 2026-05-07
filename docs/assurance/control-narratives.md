# Control Narratives - tf-secure-baseline

## Purpose

This document describes the operational intent and security impact of the infrastructure controls implemented by `tf-secure-baseline`.

Where the SOC 2 control mapping explains **alignment**, this document explains **function**.

It is intended to provide human-readable context for how the baseline supports:

- Access control
- Logging and monitoring
- Exposure reduction
- Incident response
- Configuration integrity
- Data protection
- Change visibility
- Operational resilience

This document is not an audit report and does not guarantee SOC 2, ISO 27001, or other certification outcomes. It provides control narratives that can support customer due diligence, internal security reviews, and audit preparation.

---

## Platform Control Context

`tf-secure-baseline` is designed as an AWS security baseline for SaaS environments handling PII or other sensitive data.

The platform is built around:

- Multi-account environment isolation
- Centralized control plane
- IAM Identity Center access
- GitHub OIDC-based CI/CD
- Private-first networking
- Centralized logging
- AWS-native detection services
- Event-driven security automation
- Encrypted and protected operational evidence

The controls described below are infrastructure-level controls. They should be paired with organizational policies, application security controls, risk management, incident response procedures, and human review processes.

---

# Account and Environment Segmentation

## Control Intent

Separate AWS environments to reduce blast radius and prevent non-production activity from affecting production systems.

## Implementation

The baseline uses separate AWS accounts for:

```text
control-plane
dev
staging
prod
```

The control-plane account manages shared governance and access resources, including:

- AWS Organizations structure
- IAM Identity Center
- Control-plane Terraform state
- Control-plane GitHub OIDC roles

Workload accounts host environment-specific baseline infrastructure.

## Security Impact

This supports:

- Environment isolation
- Reduced blast radius
- Cleaner access boundaries
- Safer experimentation in non-production
- More controlled production access
- Improved auditability of environment-specific activity

---

# Control Plane Separation

## Control Intent

Prevent foundational access, identity, and state resources from being accidentally modified or destroyed by workload infrastructure changes.

## Implementation

Control-plane resources are deployed separately from workload baseline resources.

The control plane contains:

- `state`
- `account`
- `organizations`
- `identity_center`

Workload environments are deployed separately from:

```text
environments/dev
environments/staging
environments/prod
```

## Security Impact

This separation helps prevent:

- Terraform destroying the IAM roles it is actively using
- Workload changes affecting centralized identity
- Environment teardown breaking control-plane access
- Accidental cross-stack dependency failures

It improves operational stability and reduces the chance of CI/CD lockout.

---

# Terraform State Protection

## Control Intent

Protect Terraform state because it contains sensitive infrastructure metadata and controls how infrastructure changes are applied.

## Implementation

The baseline uses dedicated state resources per account/environment, including:

- S3 bucket for Terraform state
- KMS encryption
- State locking
- Restricted bucket administration
- Separate state files per stack

The `state` substacks are applied locally first to create remote backend resources for later stacks.

## Security Impact

This supports:

- Controlled infrastructure change management
- Reduced risk of state corruption
- Reduced blast radius between stacks
- Encrypted state storage
- Protection against unauthorized backend modification

---

# CI/CD Access Control

## Control Intent

Allow GitHub Actions to deploy infrastructure without using long-lived AWS access keys.

## Implementation

The baseline uses GitHub OIDC to allow GitHub Actions workflows to assume AWS IAM roles.

Each environment can have separate roles for:

- Terraform plan
- Terraform apply
- Terraform destroy

Example role mapping:

```text
dev-plan        -> GitHub-Plan role in dev account
dev             -> GitHub-Apply role in dev account

staging-plan    -> GitHub-Plan role in staging account
staging         -> GitHub-Apply role in staging account

prod-plan       -> GitHub-Plan role in prod account
prod            -> GitHub-Apply role in prod account
```

OIDC trust conditions restrict which GitHub repository, branch, or GitHub environment can assume the roles.

## Security Impact

This reduces risk from:

- Long-lived AWS access keys
- Leaked CI/CD credentials
- Shared machine users
- Manual key rotation gaps

It also improves auditability because CI/CD activity is tied to assumed roles and CloudTrail events.

---

# Human Access Management

## Control Intent

Provide centralized, role-based human access to AWS accounts.

## Implementation

Human access is managed through IAM Identity Center.

The baseline creates environment-specific groups and permission sets such as:

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

The `SecOps-Operator` role is intentionally limited to submitting rollback events to the environment-specific SecOps EventBridge bus.

## Security Impact

This supports:

- Centralized human access management
- Environment-specific access boundaries
- Least-privilege role design
- Reduced reliance on IAM users
- Better auditability of human access

---

# Break-Glass Access Monitoring

## Control Intent

Provide emergency administrative access while ensuring that use of that access is visible.

## Implementation

The baseline includes a break-glass role intended for emergency use.

Use of the break-glass role is monitored through:

- CloudTrail
- EventBridge
- SNS notifications

When the role is assumed, an alert is sent through the configured SecOps notification path.

## Security Impact

This supports:

- Emergency recovery capability
- Auditability of privileged access
- Detection of unusual or unauthorized emergency access
- Operational accountability

---

# Network Exposure Reduction

## Control Intent

Reduce external attack surface by keeping workloads private by default.

## Implementation

Workloads are deployed into private subnets and do not receive public IP addresses by default.

The baseline uses:

- Private compute subnets
- Private data subnets
- Security groups
- Route table segmentation
- VPC endpoints
- NAT Gateway
- AWS Network Firewall for controlled egress

## Security Impact

This reduces:

- Direct internet exposure
- Publicly reachable workloads
- External attack paths
- Accidental public access
- Risk of broad inbound access to compute resources

---

# Controlled Egress

## Control Intent

Reduce data exfiltration risk and improve visibility over outbound network traffic.

## Implementation

Outbound traffic from private workloads follows controlled paths.

Typical egress path:

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
```

AWS service access can use VPC endpoints where available.

## Security Impact

This supports:

- Centralized outbound traffic inspection
- Reduced unmonitored internet access
- Better control over external communication
- Improved security posture for workloads handling sensitive data

---

# Private AWS Service Access

## Control Intent

Reduce reliance on public internet paths for AWS service communication.

## Implementation

The baseline deploys VPC endpoints for AWS services used by workloads and automation.

Examples may include:

- SSM
- SSM Messages
- EC2 Messages
- CloudWatch Logs
- KMS
- Secrets Manager
- EC2
- S3

## Security Impact

This supports:

- Private connectivity to AWS services
- Reduced public internet dependency
- Improved management access for private workloads
- Better alignment with private-by-default architecture

---

# Logging Integrity

## Control Intent

Ensure that security-relevant activity is captured and protected from tampering.

## Implementation

The baseline captures logs and activity from:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs

Logs are stored in protected locations with controls such as:

- KMS encryption
- S3 versioning
- Object Lock
- Restricted bucket policies
- Lifecycle retention

## Security Impact

This supports:

- Forensic readiness
- Incident visibility
- Monitoring continuity
- Evidence preservation
- Audit support

---

# Detection and Monitoring

## Control Intent

Provide continuous visibility into threats, misconfigurations, and security-relevant activity.

## Implementation

The baseline enables AWS-native detection and posture services such as:

- GuardDuty
- Security Hub
- AWS Config
- Inspector
- CloudTrail
- EventBridge

These services monitor for:

- Suspicious activity
- Vulnerable resources
- Misconfigurations
- Public exposure
- Policy violations
- Security service changes

## Security Impact

This supports:

- Threat detection
- Configuration monitoring
- Centralized findings visibility
- Faster triage
- Audit and compliance readiness

---

# Monitoring Integrity and Tamper Detection

## Control Intent

Detect attempts to weaken or disable security monitoring.

## Implementation

The tamper detection module monitors for actions that modify or disable critical security services.

Examples include attempts to modify or disable:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS keys
- Logging destinations

Tamper events are detected through CloudTrail/EventBridge and routed to SNS.

## Security Impact

This helps ensure that detection capabilities cannot be silently degraded.

It supports:

- Monitoring continuity
- Alerting on suspicious administrative activity
- Detection of defense evasion behavior
- Increased confidence in security telemetry

---

# Automated EC2 Isolation

## Control Intent

Contain potentially compromised EC2 instances quickly when high-severity findings occur.

## Implementation

The EC2 Isolation Lambda responds to qualifying Security Hub findings.

When a high or critical EC2-related finding is detected, the Lambda can:

- Identify the affected EC2 instance
- Preserve original security group information
- Replace current security groups with a quarantine security group
- Tag the instance for visibility
- Send an SNS notification

## Security Impact

This limits:

- Lateral movement
- Continued network communication
- Potential data exposure
- Blast radius during security events

It provides rapid containment while preserving metadata needed for controlled rollback.

---

# Controlled EC2 Rollback

## Control Intent

Allow recovery from quarantine only after human review and approval.

## Implementation

The EC2 Rollback Lambda is triggered through a custom EventBridge event sent to the environment-specific SecOps event bus.

A user assigned to the `SecOps-Operator` role can submit a rollback event, but cannot directly modify EC2 security groups.

Rollback event flow:

```text
SecOps-Operator
    |
    v
SecOps EventBridge Bus
    |
    v
EC2 Rollback Lambda
    |
    v
Restore original security groups
```

## Security Impact

This supports:

- Human-approved recovery
- Separation of duties
- Controlled restoration
- Reduced risk of accidental or unauthorized rollback
- Auditable recovery actions

---

# IP Threat Enrichment

## Control Intent

Improve triage context for findings that contain public IP addresses.

## Implementation

The IP Enrichment Lambda processes Security Hub findings and extracts public IP addresses.

It uses threat intelligence data, such as AbuseIPDB, to enrich IP addresses and send results to SecOps.

If enabled, enrichment context may also be written back to Security Hub findings.

## Security Impact

This supports:

- Faster investigation
- Better triage context
- Improved prioritization
- Enhanced visibility into suspicious network indicators

---

# Configuration Integrity

## Control Intent

Continuously evaluate infrastructure configuration against expected security posture.

## Implementation

AWS Config is used to record supported resource configuration and evaluate managed rules.

The baseline can evaluate controls related to:

- S3 bucket security
- CloudTrail configuration
- RDS security
- EBS encryption
- Security group exposure
- IAM posture
- EC2 hardening
- KMS key hygiene

## Security Impact

This supports:

- Configuration drift detection
- Exposure prevention
- Encryption enforcement
- Continuous compliance monitoring
- Faster identification of misconfigurations

---

# Encryption and Data Protection

## Control Intent

Protect sensitive infrastructure data, operational logs, secrets, and backups.

## Implementation

The baseline uses KMS-backed encryption for resources such as:

- S3 logs
- Lambda
- EBS
- Backup vaults
- Secrets Manager
- SNS topics
- CloudWatch Logs

The centralized logging bucket also supports:

- Versioning
- Object Lock
- Lifecycle retention

## Security Impact

This supports:

- Confidentiality of operational data
- Integrity of monitoring evidence
- Protection of secrets
- Long-term retention of security events
- Stronger audit evidence posture

---

# Backup and Recovery

## Control Intent

Support recovery from accidental deletion, misconfiguration, or destructive events.

## Implementation

The baseline includes AWS Backup support, including:

- Backup vault
- KMS encryption
- Tag-based resource selection
- Retention policies

Patch management support is provided through SSM Patch Manager.

## Security Impact

This supports:

- Recovery readiness
- Operational resilience
- Reduced impact from data loss
- Improved patch hygiene
- Support for audit expectations around recoverability

---

# Alerting and Notification

## Control Intent

Ensure security-relevant events reach the appropriate operational contacts.

## Implementation

SNS topics are used to notify SecOps or compliance contacts.

Alerts may include:

- High-severity Security Hub findings
- EC2 isolation events
- EC2 rollback events
- IP enrichment results
- Tamper detection
- Break-glass role usage
- AWS Config compliance events

## Security Impact

This supports:

- Timely awareness
- Operational escalation
- Centralized notification patterns
- Improved incident response readiness

---

# Operational Impact

Together, these controls help ensure that:

- Infrastructure exposure is minimized
- Human and CI/CD access is controlled
- Security-relevant activity is visible
- Monitoring cannot be silently disabled
- Security incidents can be contained
- Recovery actions are controlled
- Configuration integrity is monitored
- Operational logs are protected
- Terraform state is secured
- Sensitive data paths are better protected

These capabilities support infrastructure-level readiness for security-focused audits, customer due diligence, and internal security reviews.

---

# Limitations

`tf-secure-baseline` provides infrastructure-level controls.

It does not replace:

- Secure application development
- Formal risk management
- Human incident response
- Security policies and procedures
- Vendor risk management
- Business continuity planning
- Compliance evidence management
- Security awareness training
- Continuous SOC monitoring

Organizations should treat this baseline as a technical foundation that supports, but does not replace, a broader security program.

---

# Summary

`tf-secure-baseline` implements a secure AWS infrastructure baseline with controls for identity, networking, logging, monitoring, detection, response, encryption, backup, and operational resilience.

The control narratives in this document explain how those controls function and what security outcomes they are intended to support.