# Design Document

## Target Client Type

This cloud environment is intended for use by early-mid stage SaaS startups handling customer PII.

## Security Assumptions & Threats

### Primary Threats
- Unauthorized access to customer PII (credential compromise, IAM misconfiguration)
- Data exfiltration via misconfigured S3, EC2, or container workloads
- Persistence after compromise (backdoors, long-lived credentials)
- Lack of visibility into malicious activity
- Accidental data loss (operator error, ransomware, region failure)

### Data Protection Controls
- All S3 buckets enforce encryption, versioning, and access logging
- Cross-region replication is enabled for durability and ransomware recovery
- AWS Backup is used for point-in-time recovery of supported resources

### Detection & Visibility
- CloudTrail enabled in all regions with centralized, immutable storage
- GuardDuty enabled for threat detection
- Security Hub aggregates findings and maps to relevant frameworks
- CloudWatch and AWS Config provide operational and configuration visibility

### Automated Response
- Lambda-based responders perform scoped isolation of compromised resources
- Threat enrichment integrates external intelligence (VirusTotal, AbuseIPDB)
- SNS provides real-time alerting for high-severity findings
- AWS Config Remediations configured for deviations from preconfigured baselines (i.e., IAM, S3 public access, etc.)

## Controls / Architectural Decisions

### HA (High Availability)
- Support for multi-region deployments and failover
- Primary/secondary region patterns are supported but optional

### IAM
- No IAM users for humans
- Role-based access only
- MFA enforced via IAM policy conditions
- Explicit deny guardrails for risky actions

### CI/CD Workflows
- Terraform fmt / validate
- Static analysis (checkov)
- Plan visibility before apply
- No direct applies from developer machines

### Visibility
- CloudTrail logging to a centralized data store
- CloudWatch monitoring resource utilization
- Lambda functions to increase security awareness (i.e., IP Enrichment)

## Security Priorities

The following priorities balance risk reduction, operational efficiency, and cost-effectiveness, providing a secure yet manageable baseline environment:
- Data security
- CI/CD pipeline hardening
- Budget costs
- Manageability

## Non-goals

- NOT a compliance certification guarantee
  - This environment supports alignment with frameworks (SOC 2, ISO27001, etc.)
  - It does NOT guarantee audit pass or certification without additional process controls

- NOT designed for extreme scale or hyperscale workloads
  - This environment is NOT optimized for:
  - Millions of RPS
  - Global CDN-heavy architectures
  - Very high-throughput data pipelines

- NOT zero-trust at the application layer
  - Network and IAM controls are strong
  - Application-layer zero trust (mTLS everywhere, service mesh, etc.) is out of scope by default

- NOT responsible for third-party SaaS risk
  - External SaaS platforms (Stripe, Auth0, Salesforce, etc.) are out of scope
  - Integration security is the client’s responsibility unless explicitly contracted

- NOT providing 24/7 SOC or human monitoring
  - Automated detection and response is provided
  - Continuous human monitoring and incident response retainers are out of scope

- NOT eliminating all risk
  - The environment reduces risk and increases visibility
  - The environment does NOT prevent all breaches or misconfigurations

- CI/CD workflows are limited to Terraform validation, security scanning, and change visibility
  - Automated production deployment and environment promotion are out of scope

## Intended Outcomes / Purpose

This environment is tailored for businesses concerned with securing customer PII and ensuring high availability for application deployments, while also maintaining cost efficiency through opinionated resource sizing, automated lifecycle management, and pay-for-what-you-use design principles.

The environment is designed as a reusable baseline, enabling rapid deployment and consistent security practices across multiple client engagements.