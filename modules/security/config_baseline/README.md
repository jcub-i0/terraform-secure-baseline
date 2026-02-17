# AWS Config Baseline Module

## Overview

The `config_baseline` module establishes an opinionated AWS Config security baseline designed for small–mid scale SaaS environments handling sensitive data (e.g., PII).

It provides:

- Continuous configuration monitoring  
- Foundational security guardrails  
- Minimal but high-signal compliance checks  
- Safe auto-remediation for critical misconfigurations  

This module is designed to:

✔ Improve security posture  
✔ Reduce misconfiguration risk  
✔ Support audit readiness (SOC2 / ISO-style controls)  
✔ Avoid breaking workloads  

---

## What This Module Deploys

### AWS Config Recorder

Enables configuration tracking across supported AWS resources.

Includes:

- Delivery channel to centralized logging S3 bucket  
- KMS encryption support  
- SNS integration for compliance alerts  

---

### Auto-Remediation

Currently enabled:

| Control | Behavior |
|---|---|
| **S3 Public Access** | Automatically disables public access on non-compliant buckets |

This prevents accidental data exposure without requiring manual intervention.

---

### Managed Rule Pack

The module deploys a curated set of AWS-managed Config rules across key security domains.

Rules are grouped into toggleable families.

---

## Rule Families

### S3 Baseline

Protects against accidental data exposure.

Includes:

- Public access prohibited  
- Public read prohibited  
- Public write prohibited  
- Server-side encryption required  
- Versioning enabled  

---

### CloudTrail Baseline

Ensures audit logging remains active.

Includes:

- CloudTrail enabled  
- Multi-region trails enabled  
- Log file validation enabled  

---

### RDS Baseline

Protects data at rest and prevents exposure.

Includes:

- Storage encryption required  
- Public accessibility prohibited  

---

### EBS Baseline

Protects data at rest.

Includes:

- EBS volumes must be encrypted  

---

### Security Group Baseline

Prevents common remote access exposure.

Includes:

- SSH from 0.0.0.0/0 prohibited  

---

### IAM Baseline *(Optional)*

Improves identity security.

Includes:

- Root MFA required  
- Password policy enforcement  

Disabled by default to avoid conflicts in federated environments.

---

### EC2 Baseline

Improves compute-level security posture.

Includes:

- IMDSv2 required  
- EBS optimization required  
- Orphaned volume detection  
- Public IP assignment prohibited  

---

## Rule Family Toggles

Each rule family can be enabled or disabled via:

```hcl
enable_rules = {
  s3_baseline         = true
  cloudtrail_baseline = true
  rds_baseline        = true
  ebs_baseline        = true
  sg_baseline         = true
  iam_baseline        = false
  ec2_baseline        = true
}
