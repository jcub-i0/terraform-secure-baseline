# SOC2 Control Mapping — tf-secure-baseline

## Purpose

This document describes how tf-secure-baseline’s infrastructure security controls align with SOC 2 Security Trust Criteria (CC6, CC7, CC8).

The baseline is designed to support SOC 2 readiness by implementing preventative, detective, and responsive safeguards across AWS environments handling sensitive data (e.g., PII).

This mapping does **not** claim compliance.  
It demonstrates how deployed controls support audit-aligned expectations.

---

## Shared Responsibility Boundary

tf-secure-baseline provides infrastructure-level technical safeguards.

It does NOT replace organizational, administrative, or procedural controls required for SOC 2.

Examples of controls outside the scope of this baseline include:

- HR onboarding/offboarding
- Vendor management
- Application-level security
- Incident response policies
- Change management procedures

This baseline supports infrastructure security criteria and must be paired with organizational controls to achieve SOC 2 compliance.

---

# Control Alignment Overview

| Category | SOC2 Domain | Description |
|----------|-------------|-------------|
| Access Restriction | CC6 | Limits system exposure and enforces least privilege |
| Monitoring & Detection | CC7 | Enables visibility and threat detection |
| Response & Containment | CC7.4 | Supports timely incident response |
| Configuration Integrity | CC8 | Maintains secure system configurations |
| Encryption & Data Protection | CC6.7 | Protects data confidentiality |

---

# Control Function Classification

| Function | Description |
|----------|-------------|
| Preventative | Reduces likelihood of misconfiguration or exposure |
| Detective | Identifies security-relevant events |
| Responsive | Enables containment or remediation |

tf-secure-baseline implements controls across all three categories.

---

# CC6 — Logical & Network Access Controls

## Private Workload Isolation

**Baseline Control**

- Compute and serverless workloads are deployed without public IPs
- Access to AWS services occurs via VPC Interface Endpoints
- Outbound traffic is restricted to approved services and databases

**SOC2 Alignment**

CC6.1 — Logical access to systems is restricted.

**Narrative**

Network exposure is minimized by eliminating direct internet access to workloads and enforcing service access through private endpoints.

---

## Egress Restriction

**Baseline Control**

- Security groups restrict outbound traffic
- No default 0.0.0.0/0 egress allowed

**SOC2 Alignment**

CC6.6 — Network access is limited to authorized endpoints.

**Narrative**

Outbound communication is limited to explicitly approved services, reducing risk of data exfiltration.

---

## Public Access Prevention (S3)

**Baseline Control**

- AWS Config rules detect public exposure
- Auto-remediation removes violations

**SOC2 Alignment**

CC6.1 — Unauthorized access is prevented.

**Narrative**

Misconfigured storage access is automatically corrected to prevent unintended public exposure.

---

# CC7 — Monitoring & Detection

## Activity Logging

**Baseline Control**

- CloudTrail enabled
- Multi-region logging
- Log validation enabled
- Logs stored centrally with encryption, versioning, and object-lock

**SOC2 Alignment**

CC7.2 — System activity is logged and monitored.

**Narrative**

Account activity is continuously logged and retained to support monitoring and investigation.

---

## Logging Integrity (Tamper Detection)

**Baseline Control**

EventBridge detects:

- StopLogging  
- DeleteTrail  
- UpdateTrail  

Alerts routed to SecOps.

**SOC2 Alignment**

CC7.3 — Monitoring cannot be silently disabled.

**Narrative**

Attempts to modify or disable logging are detected in near real-time and escalated.

---

## Threat Detection

**Baseline Control**

- GuardDuty enabled
- Security Hub aggregates findings

**SOC2 Alignment**

CC7.2 — Security events are identified.

**Narrative**

Automated threat detection provides continuous monitoring of suspicious activity.

---

# CC7.4 — Incident Response

## Automated Containment

**Baseline Control**

- HIGH/CRITICAL EC2 findings trigger isolation
- Instance is moved to quarantine security group

**SOC2 Alignment**

CC7.4 — Security incidents are responded to.

**Narrative**

Security findings can trigger automated containment actions to limit potential impact.

---

## Manual Rollback

**Baseline Control**

- SecOps-Operator can restore quarantined instances

**SOC2 Alignment**

CC7.4 — Remediation actions are supported.

**Narrative**

Authorized operators can perform controlled recovery actions.

---

# CC8 — Change Management & Configuration Integrity

## Config Baseline Enforcement

**Baseline Control**

AWS Config monitors:

- Encryption
- Public exposure
- Logging status
- Resource posture

**SOC2 Alignment**

CC8.1 — Secure configurations are maintained.

**Narrative**

Configuration monitoring ensures systems remain aligned with defined security standards.

## Logging Configuration Protection

**Baseline Control**

Tamper detection monitors:

- CloudTrail modification attempts
- Security Hub disablement
- GuardDuty configuration changes
- KMS configuration changes

**SOC2 Alignment**

CC8.1 — Critical monitoring controls are protected from unauthorized change.

**Narrative**

Security monitoring services are protected through real-time detection of configuration changes.

---

## KMS Protection

**Baseline Control**

Tamper detection alerts on:

- ScheduleKeyDeletion  
- DisableKey  
- Policy changes  

**SOC2 Alignment**

CC8.1 — Critical services are protected from unauthorized modification.

**Narrative**

Attempts to alter encryption controls are detected and escalated.

---

# Encryption & Data Protection

## Centralized Log Encryption

**Baseline Control**

- Logs encrypted via KMS
- Object-Lock and Versioning enabled on S3 buckets
- Key rotation enabled

**SOC2 Alignment**

CC6.7 — Data is protected cryptographically.

**Narrative**

Sensitive operational logs are protected using managed encryption.

---

# Summary

tf-secure-baseline supports:

- Access restriction
- Continuous monitoring
- Automated detection
- Incident containment
- Configuration enforcement
- Encryption protection

These capabilities align with SOC 2 CC6, CC7, and CC8 expectations and support audit readiness for cloud infrastructure environments.

---

# Assurance Position

tf-secure-baseline implements infrastructure-level controls that:

- Restrict system access
- Enable continuous monitoring
- Detect security-relevant events
- Support automated containment
- Maintain configuration integrity
- Protect operational data through encryption

These capabilities align with SOC 2 CC6, CC7, and CC8 expectations and support infrastructure readiness for security-focused audits.

This baseline should be considered an enabling technical foundation within a broader compliance program.
