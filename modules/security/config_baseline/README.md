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
```

## Inputs

| Variable | Description |
| --- | --- |
| `config_role_arn` | IAM role used by AWS Config |
| `centralized_logs_bucket_name` | S3 bucket for Config history |
| `compliance_topic_arn` | SNS topic for notifications |
| `config_remediation_role_arn` | IAM role used for auto-remediation |
| `logs_kms_key_arn` | KMS key used for encryption |
| `enable_rules` | Toggle rule families |
| `config_rule_name_prefix` | Naming prefix for rules |
| `tags` | Tags applied to Config rules |

## Outputs

The module exposes:
- Managed rule names
- Recorder name
- Remediation rule names

These can be used for:
- Compliance reporting
- Monitoring integration
- Downstream automation

---

## Design Philosophy

This module intentionally avoids:
- Overly aggressive auto-remediation
- Application-breaking controls
- Operational-level enforcement (patching, AMI selection, etc.)

---

## Compliance Alignment

This baseline supports common security control expectations such as:
- Logging integrity
- Encryption enforcement
- Public exposure prevention
- Identity hygiene
- Compute hardening

Applicable to:
- SOC 2
- ISO 27001
- HIPAA-style environments

---

## Intended Use

This module is designed as a foundational layer for:
- Secure-by-default SaaS infrastructure
- Cloud security consulting engagements
- Continuous compliance monitoring