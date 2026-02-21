# Control Narratives — tf-secure-baseline

## Purpose

This document describes the operational intent and impact of the infrastructure security controls implemented by tf-secure-baseline.

Where the SOC2 Control Mapping explains *alignment*, this document explains *function*.

It is intended to provide clear, human-readable context for how the baseline supports:

- Monitoring
- Exposure reduction
- Incident response
- Configuration integrity
- Data protection

---

# Logging Integrity

tf-secure-baseline ensures that account activity logging cannot be silently disabled.

Attempts to:

- Stop CloudTrail logging
- Modify monitoring services
- Disable detection capabilities

are detected in near real-time and escalated to SecOps.

This supports:

- Forensic readiness
- Incident visibility
- Monitoring continuity

---

# Network Exposure Reduction

Workloads are deployed without public IP addresses.

Access to AWS services occurs through private endpoints rather than public internet paths.

Outbound traffic is restricted to:

- Approved AWS services
- Authorized internal resources

This reduces:

- External attack surface
- Data exfiltration pathways
- Unintended internet exposure

---

# Detection & Monitoring

The baseline enables continuous monitoring through:

- CloudTrail activity logging
- GuardDuty threat detection
- Security Hub aggregation
- AWS Config configuration monitoring

This provides visibility into:

- Suspicious activity
- Misconfigurations
- Policy violations

In addition to monitoring system activity, the baseline protects the integrity of monitoring services themselves.

The Tamper Detection module generates alerts when attempts are made to modify or disable critical security services, including:

- CloudTrail
- GuardDuty
- Security Hub
- KMS encryption controls

This helps ensure that detection capabilities remain operational and cannot be silently degraded.

---

# Automated Incident Containment

High-severity EC2 security findings can trigger automated containment actions.

Affected instances are:

- Removed from existing security groups
- Moved into a quarantine security group

This limits:

- Lateral movement
- Potential data exposure
- Blast radius during security events

---

# Configuration Integrity

The baseline monitors for unauthorized changes to critical security services such as:

- Logging systems
- Detection services
- Encryption configurations

This helps ensure:

- Monitoring remains active
- Detection systems are not disabled
- Security posture remains intact

---

# Encryption & Data Protection

Centralized operational logs are protected using managed encryption.

Log storage includes:

- KMS-backed encryption
- Versioning
- Object-lock
- Key rotation

This supports:

- Confidentiality of operational data
- Integrity of monitoring evidence
- Long-term retention of security events

---

# Operational Impact

Together, these controls help ensure that:

- Infrastructure exposure is minimized
- Security-relevant activity is visible
- Monitoring cannot be silently disabled
- Security incidents can be contained
- Configuration integrity is maintained
- Operational logs are protected

These capabilities support infrastructure-level readiness for security-focused audits and customer due diligence.