# SOC 2 Control Mapping - tf-secure-baseline

## Purpose

This document describes how `tf-secure-baseline` infrastructure controls align with selected SOC 2 Trust Services Criteria, primarily within the Security category.

The baseline is designed to support SOC 2 readiness by implementing preventative, detective, and responsive safeguards across AWS environments handling sensitive data, such as PII.

This mapping does **not** claim SOC 2 compliance.

It demonstrates how deployed technical controls can support audit-aligned expectations when paired with appropriate organizational policies, procedures, evidence collection, and human review.

---

## Scope

This document focuses on infrastructure-level technical controls implemented by `tf-secure-baseline`.

Covered areas include:

- Logical access controls
- Network access controls
- CI/CD access control
- Centralized identity
- Logging and monitoring
- Threat detection
- Incident response support
- Configuration monitoring
- Change visibility
- Encryption and data protection
- Backup and recovery support

Out of scope:

- HR onboarding and offboarding procedures
- Vendor management
- Formal risk assessments
- Board or executive governance
- Application-level authorization
- Secure SDLC process
- Customer support procedures
- Legal/compliance review
- Business continuity planning
- Manual incident response process
- Evidence collection procedures outside AWS/Terraform

This baseline supports technical readiness. It does not replace a broader SOC 2 compliance program.

---

## Shared Responsibility Boundary

`tf-secure-baseline` provides infrastructure-level safeguards within AWS.

It does not address every organizational, administrative, or procedural control required for SOC 2.

Examples of controls outside the scope of this baseline include:

- Employee background checks
- Security awareness training
- Vendor risk management
- Formal access review procedures
- Change approval policy
- Incident response policy ownership
- Customer communication procedures
- Business continuity exercises
- Legal and contractual controls
- Secure software development lifecycle controls

Organizations adopting this baseline must pair it with appropriate people, process, and governance controls.

---

# Control Alignment Overview

| Area | SOC 2 Domain | Description |
|------|-------------|-------------|
| Logical access | CC6 | Restricts access to systems and data |
| Network access | CC6 | Reduces exposure and enforces controlled communication paths |
| CI/CD access | CC6 / CC8 | Controls infrastructure deployment permissions |
| Identity management | CC6 | Centralizes human access through IAM Identity Center |
| Logging and monitoring | CC7 | Captures security-relevant activity |
| Threat detection | CC7 | Identifies suspicious activity and misconfiguration |
| Incident response support | CC7.4 | Supports containment, triage, and recovery workflows |
| Change and configuration monitoring | CC8 | Detects infrastructure drift and unauthorized changes |
| Encryption and data protection | CC6.7 | Protects sensitive data and operational evidence |
| Backup and recovery | Availability-supporting controls | Supports operational resilience and recovery readiness |

---

# Control Function Classification

| Function | Description | Examples |
|----------|-------------|----------|
| Preventative | Reduces likelihood of unauthorized access, exposure, or misconfiguration | Private subnets, IAM policies, Identity Center, KMS encryption |
| Detective | Identifies activity, misconfiguration, or security events | CloudTrail, GuardDuty, Security Hub, AWS Config, EventBridge |
| Responsive | Supports containment, recovery, or escalation | EC2 isolation, EC2 rollback, SNS alerts, tamper detection |
| Corrective | Supports restoration or remediation | Rollback workflow, backup vaults, patching resources |

`tf-secure-baseline` implements controls across all four categories.

---

# CC6 - Logical and Network Access Controls

## Multi-Account Environment Segmentation

### Baseline Control

The platform separates AWS environments into dedicated accounts:

```text
control-plane
dev
staging
prod
```

The control-plane account manages centralized governance and identity resources.

Workload accounts host environment-specific infrastructure.

### SOC 2 Alignment

- CC6.1 - Logical access to systems is restricted.
- CC6.2 - Access credentials and privileges are managed.
- CC6.6 - Network and system access is restricted to authorized users and services.

### Narrative

Separating environments into different AWS accounts reduces blast radius and supports stronger access boundaries.

Development, staging, and production infrastructure are isolated from each other, limiting the risk that activity in one environment affects another.

---

## Centralized Human Access Through IAM Identity Center

### Baseline Control

IAM Identity Center is used to manage human access centrally.

The baseline creates environment-specific groups and permission sets, such as:

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

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - User access credentials and privileges are managed.
- CC6.3 - Access is authorized based on roles and responsibilities.
- CC6.6 - Access to systems is limited to authorized users.

### Narrative

IAM Identity Center supports centralized identity and role-based access across AWS accounts.

The use of environment-specific groups supports least privilege and reduces the risk of broad access across all accounts.

---

## Least-Privilege Operational Roles

### Baseline Control

The `SecOps-Operator` role is intentionally limited.

It can submit approved rollback events to the environment-specific SecOps EventBridge bus, but it cannot directly modify EC2 security groups or invoke Lambda functions.

### SOC 2 Alignment

- CC6.1 - Access is restricted to authorized users.
- CC6.3 - Access is granted according to job responsibilities.
- CC6.6 - System access is limited to authorized activities.

### Narrative

The operator role is scoped to a specific operational workflow.

This reduces the risk that an operator can directly modify infrastructure outside the approved rollback path.

---

## Break-Glass Access Monitoring

### Baseline Control

The baseline includes a break-glass administrative role for emergency access.

Use of this role is monitored through:

- CloudTrail
- EventBridge
- SNS notifications

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - Privileged access is managed.
- CC7.2 - Security events are monitored.
- CC7.4 - Incident response processes are supported.

### Narrative

Emergency access is available when needed, but use of that access is visible.

This supports accountability and review of privileged administrative activity.

---

## Private Workload Isolation

### Baseline Control

Compute workloads are deployed in private subnets and do not receive public IP addresses by default.

The VPC includes segmented subnet tiers, such as:

- Public subnets
- Private compute subnets
- Private data subnets
- Private serverless subnets
- Endpoint subnets

### SOC 2 Alignment

- CC6.1 - Logical access to systems is restricted.
- CC6.6 - Network access is limited to authorized paths.

### Narrative

Removing public IPs from workloads reduces direct internet exposure and helps prevent unauthorized inbound access.

Private subnet placement makes public exposure the exception rather than the default.

---

## Controlled Egress

### Baseline Control

Outbound workload traffic is routed through controlled network paths.

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

The baseline may also use VPC endpoints for AWS service access.

### SOC 2 Alignment

- CC6.6 - Network access is restricted to authorized paths.
- CC6.7 - Transmission paths for sensitive data are protected.

### Narrative

Controlled egress reduces unmonitored outbound communication and supports data exfiltration risk reduction.

AWS Network Firewall and route table segmentation help enforce outbound inspection and control.

---

## Private AWS Service Access

### Baseline Control

VPC endpoints are used where practical to provide private access to AWS services.

Common endpoints may include:

- SSM
- SSM Messages
- EC2 Messages
- CloudWatch Logs
- KMS
- Secrets Manager
- EC2
- S3

### SOC 2 Alignment

- CC6.6 - Network access is limited to authorized endpoints.
- CC6.7 - Data transmission is protected.

### Narrative

VPC endpoints reduce dependency on public internet paths for AWS service communication.

This supports private management access and reduces unnecessary exposure.

---

## S3 Public Access Prevention

### Baseline Control

The baseline uses S3 security controls such as:

- Public access blocks
- Bucket policies
- Encryption
- Versioning
- Object Lock for log storage
- AWS Config monitoring

### SOC 2 Alignment

- CC6.1 - Unauthorized access is prevented.
- CC6.6 - Access to resources is restricted.
- CC6.7 - Data is protected.

### Narrative

S3 controls reduce the likelihood of accidental public exposure and help protect sensitive logs and operational evidence.

---

# CC6 - CI/CD and Infrastructure Access Controls

## GitHub OIDC Federation

### Baseline Control

GitHub Actions authenticates to AWS using OIDC.

No long-lived AWS access keys are required for CI/CD workflows.

Each environment can have separate roles for:

- Terraform plan
- Terraform apply
- Terraform destroy

Example mapping:

```text
dev-plan        -> dev GitHub-Plan role
dev             -> dev GitHub-Apply role

staging-plan    -> staging GitHub-Plan role
staging         -> staging GitHub-Apply role

prod-plan       -> prod GitHub-Plan role
prod            -> prod GitHub-Apply role
```

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - Credentials and privileges are managed.
- CC6.3 - Access is authorized based on responsibility.
- CC8.1 - Infrastructure changes are controlled.

### Narrative

OIDC reduces risk from static credentials and allows GitHub workflows to assume AWS roles only when trust conditions are satisfied.

This improves CI/CD security and supports auditable infrastructure change activity.

---

## Separation of Plan and Apply Roles

### Baseline Control

Plan and apply roles are separated.

Plan roles are intended for lower-risk read/plan operations.

Apply roles are used for create, update, and destroy operations.

### SOC 2 Alignment

- CC6.1 - Access is restricted.
- CC6.3 - Access is granted according to responsibility.
- CC8.1 - Changes are managed and controlled.

### Narrative

Separating plan and apply access supports least privilege and helps distinguish between read-only change visibility and actual infrastructure modification.

---

## Control Plane Account Stack Isolation

### Baseline Control

GitHub OIDC account stacks are separated from the baseline infrastructure they manage.

The control-plane account stack is generally treated as manual/local-only because it creates the roles GitHub Actions uses to access the control plane.

### SOC 2 Alignment

- CC6.1 - Access is restricted.
- CC6.2 - Privileged access is managed.
- CC8.1 - Changes to infrastructure are controlled.

### Narrative

Separating execution-plane resources from workload resources prevents Terraform from accidentally destroying the IAM roles it is actively using.

This improves CI/CD reliability and reduces the risk of lockout or failed infrastructure changes.

---

# CC7 - System Operations, Monitoring, and Detection

## Activity Logging

### Baseline Control

The baseline captures security-relevant activity using:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs

CloudTrail is configured to send logs to protected storage.

### SOC 2 Alignment

- CC7.2 - System activity is monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Security incidents are responded to.

### Narrative

CloudTrail and supporting logs provide visibility into AWS API activity, configuration changes, network activity, and automation behavior.

This supports investigation, evidence collection, and incident response.

---

## Centralized Log Protection

### Baseline Control

Operational logs are protected using controls such as:

- KMS encryption
- S3 versioning
- Object Lock
- Restricted bucket policies
- Lifecycle retention

### SOC 2 Alignment

- CC6.7 - Data is protected cryptographically.
- CC7.2 - Security-relevant activity is monitored.
- CC7.3 - Monitoring data is protected from unauthorized alteration.

### Narrative

Logs are treated as security evidence.

Encryption, versioning, and Object Lock help protect log integrity and support forensic readiness.

---

## GuardDuty Threat Detection

### Baseline Control

GuardDuty is enabled in workload accounts to detect suspicious activity.

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.

### Narrative

GuardDuty provides continuous threat detection for AWS accounts and workloads.

Findings can be routed through EventBridge and Security Hub for visibility and response.

---

## Security Hub Findings Aggregation

### Baseline Control

Security Hub is enabled to aggregate and normalize security findings.

Security Hub standards may include AWS Foundational Security Best Practices, CIS, NIST, PCI, and tagging standards depending on configuration.

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Security events are used to support response activities.

### Narrative

Security Hub centralizes findings from AWS security services and provides a common findings format for event-driven automation.

---

## AWS Config Monitoring

### Baseline Control

AWS Config records resource configuration and evaluates selected managed rules.

The baseline can monitor posture related to:

- S3 security
- CloudTrail configuration
- RDS security
- EBS encryption
- Security group exposure
- IAM posture
- EC2 hardening
- KMS key hygiene

### SOC 2 Alignment

- CC7.2 - System activity and changes are monitored.
- CC8.1 - Changes to systems are managed and evaluated.

### Narrative

AWS Config supports continuous configuration monitoring and helps identify drift from expected security posture.

---

## Inspector Vulnerability Detection

### Baseline Control

Amazon Inspector is enabled where configured to provide vulnerability scanning for supported resources.

### SOC 2 Alignment

- CC7.1 - Vulnerabilities and threats are identified.
- CC7.2 - Security events are monitored.
- CC7.3 - Findings are evaluated.

### Narrative

Inspector supports vulnerability awareness and can feed findings into Security Hub for centralized visibility.

---

## Tamper Detection

### Baseline Control

The tamper detection module monitors for attempts to disable or modify critical security services.

Examples include changes to:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS keys
- Logging destinations

Events are routed through EventBridge and sent to SNS.

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.
- CC8.1 - Unauthorized changes are identified.

### Narrative

The baseline detects attempts to weaken logging, monitoring, and encryption controls.

This helps prevent monitoring degradation from going unnoticed.

---

# CC7.4 - Incident Response Support

## Automated EC2 Isolation

### Baseline Control

High and critical EC2-related Security Hub findings can trigger the EC2 Isolation Lambda.

The Lambda can:

- Identify the affected EC2 instance
- Preserve original security group information
- Replace existing security groups with a quarantine security group
- Tag the affected instance
- Send an SNS notification

### SOC 2 Alignment

- CC7.4 - Security incidents are responded to.
- CC7.5 - Identified security events are evaluated and remediated where appropriate.

### Narrative

Automated isolation supports rapid containment of potentially compromised EC2 instances.

This reduces lateral movement risk and limits potential blast radius while preserving information needed for rollback.

---

## Controlled EC2 Rollback

### Baseline Control

Rollback is performed through a controlled EventBridge workflow.

A user assigned to the environment-specific `SecOps-Operator` role can submit a rollback event to the SecOps event bus.

The rollback Lambda restores original security groups.

### SOC 2 Alignment

- CC7.4 - Security incidents are responded to.
- CC7.5 - Remediation activities are performed and tracked.
- CC6.3 - Access is aligned to role responsibilities.

### Narrative

Rollback requires human review and approved event submission.

The operator can trigger rollback but cannot directly modify EC2 security groups, supporting separation of duties.

---

## IP Threat Enrichment

### Baseline Control

The IP Enrichment Lambda extracts public IP addresses from Security Hub findings and enriches them using threat intelligence data.

Enrichment results are sent to SNS and may optionally be written back to Security Hub findings.

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Incident response activities are supported.

### Narrative

Threat enrichment improves triage quality by adding context about suspicious IP indicators.

This supports faster and more informed investigation.

---

## SNS Alerting

### Baseline Control

SNS topics notify SecOps or compliance contacts about security-relevant events.

Alerts may include:

- High-severity findings
- EC2 isolation
- EC2 rollback
- IP enrichment results
- Tamper detection
- Break-glass role usage
- AWS Config compliance events

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Personnel are notified of incidents and events.

### Narrative

SNS alerts provide near real-time notification of important security activity and support operational escalation.

---

# CC8 - Change Management and Configuration Integrity

## Terraform-Based Infrastructure Management

### Baseline Control

Infrastructure is managed through Terraform modules and environment-specific stacks.

Terraform provides:

- Version-controlled infrastructure definitions
- Plan visibility before apply
- Repeatable deployments
- Environment-specific state separation

### SOC 2 Alignment

- CC8.1 - Changes are authorized, designed, developed, configured, documented, tested, approved, and implemented.

### Narrative

Terraform provides a repeatable and reviewable mechanism for infrastructure changes.

When paired with GitHub workflows and approval processes, it supports auditable change management.

---

## GitHub Actions Plan and Apply Workflows

### Baseline Control

GitHub Actions workflows support Terraform plan, apply, and destroy operations.

Plan workflows provide change visibility.

Apply workflows execute approved changes.

Destroy workflows include Identity Center cleanup logic to prevent IAM dependency conflicts.

### SOC 2 Alignment

- CC8.1 - Changes are managed through defined processes.
- CC6.1 - Infrastructure modification access is restricted.

### Narrative

CI/CD workflows help standardize how infrastructure changes are evaluated and applied.

Environment-scoped roles and GitHub environments support controlled deployment behavior.

---

## AWS Config Baseline

### Baseline Control

AWS Config evaluates resource configuration against security expectations.

Examples include:

- Encryption checks
- Public access restrictions
- CloudTrail status
- Security group exposure
- IAM best practices

### SOC 2 Alignment

- CC8.1 - System changes are monitored and evaluated.
- CC7.2 - Security-relevant configuration changes are monitored.

### Narrative

AWS Config supports detection of configuration drift and security posture deviations.

---

## Logging Configuration Protection

### Baseline Control

Tamper detection monitors attempts to modify logging and monitoring services.

Examples include:

- StopLogging
- DeleteTrail
- UpdateTrail
- DisableSecurityHub
- DeleteDetector
- StopConfigurationRecorder

### SOC 2 Alignment

- CC8.1 - Unauthorized changes to critical systems are identified.
- CC7.2 - Monitoring systems are observed.
- CC7.3 - Security-relevant changes are evaluated.

### Narrative

Critical monitoring controls are protected through real-time detection of unauthorized or suspicious changes.

---

## KMS Protection

### Baseline Control

Tamper detection alerts on actions affecting KMS keys.

Examples include:

- ScheduleKeyDeletion
- DisableKey
- Key policy changes

### SOC 2 Alignment

- CC6.7 - Data is protected cryptographically.
- CC8.1 - Critical system changes are monitored.

### Narrative

KMS keys protect sensitive infrastructure data and operational evidence.

Detecting key modification or deletion attempts helps preserve confidentiality and evidence integrity.

---

# CC6.7 - Encryption and Data Protection

## KMS-Backed Encryption

### Baseline Control

The baseline uses KMS-backed encryption for resources such as:

- S3 logs
- Lambda
- EBS
- Backup vaults
- Secrets Manager
- SNS topics
- CloudWatch Logs

### SOC 2 Alignment

- CC6.7 - Confidential information is protected during transmission and storage.

### Narrative

KMS-backed encryption helps protect sensitive infrastructure data, secrets, logs, backups, and operational telemetry.

---

## Secrets Manager Protection

### Baseline Control

Secrets Manager is used to store sensitive values such as threat intelligence API keys.

Secrets are encrypted with KMS.

Lambda roles are granted access only where required.

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.7 - Confidential information is protected.

### Narrative

Secrets Manager reduces the need to store secrets in code or plain environment variables.

IAM and KMS permissions restrict which workloads can retrieve secret values.

---

## Protected Log Storage

### Baseline Control

Centralized logs are stored with:

- KMS encryption
- Versioning
- Object Lock
- Lifecycle policies
- Restricted bucket access

### SOC 2 Alignment

- CC6.7 - Data is protected cryptographically.
- CC7.2 - Monitoring information is retained.
- CC7.3 - Monitoring data integrity is supported.

### Narrative

Protected log storage supports confidentiality, integrity, and retention of security evidence.

---

# Availability-Supporting Controls

SOC 2 Availability criteria are broader than this technical baseline, but some deployed controls support recoverability and operational resilience.

## AWS Backup

### Baseline Control

The baseline includes AWS Backup support, including:

- Backup vaults
- KMS encryption
- Tag-based backup selection
- Retention policies

### SOC 2 Alignment

- Availability-supporting control
- Supports recoverability expectations

### Narrative

Backup resources support recovery from accidental deletion, ransomware, operator error, or destructive changes.

---

## Patch Management

### Baseline Control

SSM Patch Manager support includes:

- Patch baselines
- Maintenance windows
- Patch groups

### SOC 2 Alignment

- CC7.1 - Vulnerabilities are identified and addressed.
- CC7.2 - System conditions are monitored.

### Narrative

Patch management supports vulnerability reduction and operational hygiene for managed instances.

---

# Evidence Examples

The following artifacts can support audit or customer due diligence discussions.

## Terraform Evidence

```text
Terraform plan output
Terraform apply output
Git commit history
Pull request approvals
GitHub Actions workflow logs
Terraform state backend configuration
```

## AWS Evidence

```text
CloudTrail trail configuration
CloudTrail trail status
AWS Config recorder status
AWS Config rule evaluations
Security Hub enabled standards
GuardDuty detector status
Inspector account status
KMS key aliases and policies
S3 bucket encryption settings
S3 Object Lock configuration
VPC Flow Logs status
SNS topic subscriptions
EventBridge rule configuration
Lambda logs
Backup vault configuration
```

## Identity Evidence

```text
IAM Identity Center groups
Permission sets
Account assignments
GitHub OIDC role trust policies
Break-glass role CloudTrail events
```

## Response Evidence

```text
EC2 isolation test results
EC2 rollback test results
IP enrichment test results
Tamper detection alerts
SNS notifications
Security Hub finding notes
```

---

# Control Coverage Summary

| Control Area | Baseline Support |
|-------------|------------------|
| Logical access | IAM Identity Center, least-privilege IAM, GitHub OIDC |
| Network access | Private subnets, security groups, Network Firewall, VPC endpoints |
| CI/CD access | OIDC roles, plan/apply separation, GitHub environments |
| Logging | CloudTrail, Config, VPC Flow Logs, CloudWatch Logs |
| Monitoring | GuardDuty, Security Hub, Config, Inspector |
| Tamper detection | EventBridge alerts for security service modification |
| Incident response | EC2 isolation, rollback workflow, SNS alerts |
| Data protection | KMS encryption, protected S3 logs, Secrets Manager |
| Change management | Terraform, GitHub workflows, Config monitoring |
| Recovery | AWS Backup, rollback workflow, patch management support |

---

# Assurance Position

`tf-secure-baseline` implements infrastructure-level controls that support SOC 2 readiness by helping organizations:

- Restrict system access
- Reduce public exposure
- Protect CI/CD access
- Centralize identity
- Enable continuous monitoring
- Detect security-relevant events
- Support incident containment
- Maintain configuration integrity
- Protect operational data through encryption
- Preserve security evidence
- Support recovery readiness

These capabilities align with selected SOC 2 Security criteria, especially CC6, CC7, and CC8.

This baseline should be considered an enabling technical foundation within a broader compliance program.

It does not guarantee SOC 2 compliance or audit success without supporting organizational controls, policies, procedures, evidence management, and operational review.