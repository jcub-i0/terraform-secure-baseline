# ISO 27001 Control Mapping - tf-secure-baseline

## Purpose

This document describes how `tf-secure-baseline` infrastructure controls align with selected **ISO/IEC 27001:2022 Annex A** control themes.

The baseline is designed to support ISO 27001 readiness by implementing technical safeguards across AWS environments that handle sensitive data, such as PII.

This mapping does **not** claim ISO 27001 compliance or certification.

It demonstrates how deployed infrastructure controls can support ISO 27001-aligned expectations when paired with an Information Security Management System (ISMS), organizational policies, risk management, evidence collection, and human operational procedures.

---

## Scope

This document focuses on infrastructure-level technical controls implemented by `tf-secure-baseline`.

Covered areas include:

- Access control
- Identity management
- Privileged access
- Cloud service security
- Network security
- Logging and monitoring
- Threat detection
- Incident response support
- Configuration management
- Change management
- Vulnerability management support
- Cryptography
- Backup and recovery support
- Protection of records and security evidence

Out of scope:

- Full ISMS implementation
- Security governance ownership
- HR onboarding and offboarding
- Security awareness training
- Vendor risk management
- Legal and regulatory reviews
- Internal audit process
- Formal risk assessment process
- Statement of Applicability ownership
- Business continuity exercises
- Secure SDLC process
- Application-layer controls
- Manual incident response procedures

This baseline supports technical readiness. It does not replace the broader ISO 27001 management system requirements.

---

## ISO 27001 Context

ISO/IEC 27001:2022 includes Annex A controls that organizations may select based on risk, scope, and applicability.

Annex A controls are grouped into four categories:

```text
A.5 Organizational controls
A.6 People controls
A.7 Physical controls
A.8 Technological controls
```

`tf-secure-baseline` primarily supports selected **A.5 Organizational** and **A.8 Technological** control themes.

It provides limited or indirect support for people and physical controls because those areas are mostly organizational and procedural rather than Terraform/AWS infrastructure controls.

---

# Control Alignment Overview

| ISO 27001 Area | Control Theme | Baseline Support |
|---------------|---------------|------------------|
| A.5 Organizational | Access control, cloud services, incident management, evidence, records | IAM Identity Center, GitHub OIDC, logging, detection, incident workflows |
| A.6 People | Awareness, responsibilities, access lifecycle | Mostly out of scope; requires organizational process |
| A.7 Physical | Physical security | Mostly inherited from AWS shared responsibility model |
| A.8 Technological | Network security, logging, monitoring, cryptography, backup, configuration management | Strong technical support through AWS/Terraform controls |

---

# Control Function Classification

| Function | Description | Examples |
|----------|-------------|----------|
| Preventative | Reduces likelihood of unauthorized access, exposure, or misconfiguration | IAM Identity Center, private subnets, KMS encryption, security groups |
| Detective | Identifies security-relevant activity or configuration drift | CloudTrail, GuardDuty, Security Hub, AWS Config, EventBridge |
| Responsive | Supports containment, escalation, and investigation | EC2 isolation, rollback workflow, SNS alerts, IP enrichment |
| Corrective | Supports restoration or remediation | AWS Backup, EC2 rollback, patch management, Config remediations where enabled |

---

# A.5 Organizational Controls

## A.5.15 - Access Control

### Baseline Control

The baseline restricts access through:

- IAM Identity Center groups and permission sets
- Environment-specific AWS account assignments
- Least-privilege IAM policies
- GitHub OIDC roles for CI/CD
- Security group and network controls
- Private subnet placement

### ISO 27001 Alignment

A.5.15 expects access to information and associated assets to be controlled based on business and security requirements.

### Narrative

`tf-secure-baseline` supports access control by centralizing human AWS access through IAM Identity Center and restricting CI/CD access through GitHub OIDC roles.

Access is scoped by environment and workflow so that users and automation receive only the access required for their role.

---

## A.5.16 - Identity Management

### Baseline Control

IAM Identity Center is used to manage human access across AWS accounts.

The control-plane Identity Center stack can define groups such as:

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

### ISO 27001 Alignment

A.5.16 expects identities to be managed throughout their lifecycle.

### Narrative

The baseline supports centralized identity management for AWS access.

It does not replace organizational joiner/mover/leaver procedures, but it provides a technical mechanism for assigning access through managed groups and permission sets.

---

## A.5.17 - Authentication Information

### Baseline Control

The baseline avoids long-lived AWS access keys for CI/CD after bootstrap by using GitHub OIDC.

Human access is intended to use IAM Identity Center.

### ISO 27001 Alignment

A.5.17 addresses protection and management of authentication information.

### Narrative

GitHub OIDC reduces reliance on static AWS credentials for automation.

IAM Identity Center reduces the need for long-lived IAM users for humans.

During initial bootstrap, admin-level IAM user access keys may be used for simplicity, but this should be treated as a bootstrap mechanism rather than the desired long-term access model.

---

## A.5.18 - Access Rights

### Baseline Control

Access rights are structured through:

- IAM Identity Center permission sets
- Environment-specific group assignments
- Separate plan/apply GitHub roles
- Separate SecOps roles
- Least-privilege Lambda execution roles
- Optional customer-managed policy attachments by environment

### ISO 27001 Alignment

A.5.18 expects access rights to be provisioned, reviewed, modified, and removed according to access control policies.

### Narrative

The baseline supports structured AWS access rights through permission sets and role-based assignments.

Organizations must still perform periodic access reviews and maintain approval workflows outside Terraform.

---

## A.5.23 - Information Security for Use of Cloud Services

### Baseline Control

The baseline provides a secure AWS cloud foundation using:

- Multi-account structure
- Control-plane separation
- Private networking
- Centralized logging
- Detection services
- KMS encryption
- Backup and patch management
- IAM Identity Center
- GitHub OIDC
- Event-driven response

### ISO 27001 Alignment

A.5.23 addresses establishing and managing information security for cloud service usage.

### Narrative

`tf-secure-baseline` supports secure AWS usage by providing repeatable Terraform patterns for access, networking, logging, monitoring, encryption, and incident response.

It helps define a secure cloud operating baseline but does not replace cloud governance policies, vendor reviews, or contractual controls.

---

## A.5.24 - Information Security Incident Management Planning and Preparation

### Baseline Control

The baseline provides technical foundations that support incident response, including:

- Security Hub findings
- GuardDuty findings
- EventBridge routing
- SNS notifications
- EC2 isolation
- EC2 rollback
- IP enrichment
- Tamper detection
- Break-glass monitoring

### ISO 27001 Alignment

A.5.24 addresses planning and preparation for managing information security incidents.

### Narrative

The baseline supports incident readiness by providing event-driven detection and response capabilities.

Organizations must still define incident response roles, escalation paths, communications procedures, severity criteria, and tabletop exercises.

---

## A.5.25 - Assessment and Decision on Information Security Events

### Baseline Control

The baseline supports event assessment through:

- Security Hub findings
- GuardDuty findings
- AWS Config evaluations
- IP enrichment
- SNS notifications
- CloudWatch Logs
- Centralized logs

### ISO 27001 Alignment

A.5.25 addresses assessing information security events and deciding whether they are incidents.

### Narrative

The baseline provides telemetry and enrichment that help teams evaluate events.

Human triage and decision-making remain an organizational responsibility.

---

## A.5.26 - Response to Information Security Incidents

### Baseline Control

The baseline provides response automation such as:

- EC2 isolation for high/critical findings
- Controlled EC2 rollback
- SNS alerting
- Tamper detection alerts
- Break-glass monitoring

### ISO 27001 Alignment

A.5.26 addresses responding to information security incidents according to documented procedures.

### Narrative

The EC2 isolation workflow supports rapid containment, while rollback requires controlled human action through the `SecOps-Operator` role.

This supports incident response execution but does not replace formal incident response procedures.

---

## A.5.27 - Learning from Information Security Incidents

### Baseline Control

The baseline preserves investigation data through:

- CloudTrail
- Security Hub
- GuardDuty
- AWS Config
- CloudWatch Logs
- Lambda logs
- VPC Flow Logs
- SNS notifications

### ISO 27001 Alignment

A.5.27 addresses learning from incidents to reduce future likelihood or impact.

### Narrative

The baseline provides evidence and telemetry that can support post-incident review.

Organizations must still conduct lessons-learned reviews and track corrective actions.

---

## A.5.28 - Collection of Evidence

### Baseline Control

The baseline supports evidence collection through:

- Centralized CloudTrail logs
- AWS Config records
- VPC Flow Logs
- CloudWatch Logs
- Security Hub findings
- GuardDuty findings
- EventBridge events
- Lambda logs
- SNS notifications
- Terraform plan/apply history
- GitHub Actions logs

### ISO 27001 Alignment

A.5.28 addresses identification, collection, acquisition, and preservation of evidence.

### Narrative

Centralized, encrypted, versioned, and object-locked logging supports preservation of technical evidence.

Organizations must still define evidence handling procedures and chain-of-custody expectations.

---

## A.5.30 - ICT Readiness for Business Continuity

### Baseline Control

The baseline supports operational resilience through:

- AWS Backup
- KMS-encrypted backup vaults
- Retention policies
- Centralized logs
- Terraform-managed infrastructure
- EC2 rollback
- Patch management

### ISO 27001 Alignment

A.5.30 addresses readiness of ICT systems for business continuity.

### Narrative

The baseline supports technical recovery readiness.

It does not define business continuity plans, recovery time objectives, recovery point objectives, or continuity exercises.

---

## A.5.33 - Protection of Records

### Baseline Control

Operational and security records are protected using:

- KMS encryption
- S3 versioning
- Object Lock
- Restricted bucket policies
- Lifecycle retention
- Centralized log storage

### ISO 27001 Alignment

A.5.33 addresses protection of records from loss, destruction, falsification, unauthorized access, or unauthorized release.

### Narrative

The centralized logging architecture treats logs as security evidence and protects them from unauthorized alteration or deletion.

---

## A.5.34 - Privacy and Protection of PII

### Baseline Control

The baseline supports protection of PII-handling environments through:

- Private networking
- KMS encryption
- Access control
- Logging and monitoring
- Secrets Manager
- Controlled egress
- Security Hub / GuardDuty
- Backup support

### ISO 27001 Alignment

A.5.34 addresses privacy and protection of personally identifiable information.

### Narrative

The baseline provides infrastructure safeguards that support PII protection.

It does not implement privacy policies, data inventories, data subject request processes, retention governance, or legal privacy compliance obligations.

---

## A.5.36 - Compliance with Policies, Rules and Standards for Information Security

### Baseline Control

The baseline supports policy and standards alignment through:

- Terraform-managed infrastructure
- AWS Config rules
- Security Hub standards
- Centralized logs
- Validation checklist
- Lambda test documentation
- Assurance documentation

### ISO 27001 Alignment

A.5.36 addresses compliance with information security policies, standards, and technical requirements.

### Narrative

The baseline helps enforce and validate selected technical standards.

Organizations must still define internal policies, assign control owners, and perform compliance reviews.

---

## A.5.37 - Documented Operating Procedures

### Baseline Control

The repository includes documentation such as:

```text
docs/quickstart.md
docs/validation-checklist.md
docs/architecture-overview.md
docs/design-principles.md
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
docs/assurance/control-narratives.md
docs/assurance/soc2-control-mapping.md
```

### ISO 27001 Alignment

A.5.37 addresses documenting operating procedures for information processing facilities.

### Narrative

The baseline includes operational documentation for deployment, validation, testing, and teardown.

Organizations should adapt these documents into formal internal procedures where required.

---

# A.8 Technological Controls

## A.8.2 - Privileged Access Rights

### Baseline Control

Privileged access is controlled through:

- IAM Identity Center
- Environment-specific permission sets
- GitHub OIDC apply roles
- Break-glass role monitoring
- Least-privilege IAM policies
- Separation of plan and apply roles

### ISO 27001 Alignment

A.8.2 addresses restricting and managing privileged access rights.

### Narrative

Privileged access is scoped by environment and workflow.

Use of break-glass access is monitored and alerted.

Organizations must still perform access reviews and maintain approval records.

---

## A.8.3 - Information Access Restriction

### Baseline Control

The baseline restricts information access through:

- IAM policies
- Security groups
- Private subnets
- VPC endpoints
- S3 bucket policies
- KMS key policies
- Secrets Manager permissions
- Identity Center permission sets

### ISO 27001 Alignment

A.8.3 addresses restricting access to information and associated assets.

### Narrative

Access to infrastructure resources is restricted through identity, network, and encryption controls.

This supports protection of sensitive infrastructure and workload data.

---

## A.8.5 - Secure Authentication

### Baseline Control

The baseline supports secure authentication through:

- IAM Identity Center for human AWS access
- GitHub OIDC for CI/CD access
- No static CI/CD AWS access keys after bootstrap
- Role-based access patterns

### ISO 27001 Alignment

A.8.5 addresses secure authentication technologies and procedures.

### Narrative

OIDC and Identity Center reduce reliance on static credentials.

Organizations should also enforce MFA, SSO policies, and identity provider controls outside this Terraform baseline.

---

## A.8.8 - Management of Technical Vulnerabilities

### Baseline Control

The baseline supports vulnerability management through:

- Amazon Inspector
- Security Hub aggregation
- SSM Patch Manager
- Patch baselines
- Maintenance windows
- SNS notifications

### ISO 27001 Alignment

A.8.8 addresses obtaining, evaluating, and addressing technical vulnerabilities.

### Narrative

Inspector and patch management support technical vulnerability identification and remediation workflows.

Organizations must still define vulnerability SLAs, ownership, exception handling, and reporting procedures.

---

## A.8.9 - Configuration Management

### Baseline Control

Configuration is managed through:

- Terraform modules
- Environment-specific stacks
- AWS Config
- Security Hub standards
- Version-controlled infrastructure code
- Validation checklist

### ISO 27001 Alignment

A.8.9 addresses establishing and maintaining secure configurations.

### Narrative

Terraform defines expected infrastructure state, while AWS Config monitors deployed resource configuration.

This supports configuration consistency and drift detection.

---

## A.8.12 - Data Leakage Prevention

### Baseline Control

The baseline supports data leakage prevention through:

- Private subnets
- Controlled egress
- AWS Network Firewall
- Security groups
- VPC endpoints
- S3 public access blocks
- KMS encryption
- Logging and monitoring

### ISO 27001 Alignment

A.8.12 addresses preventing unauthorized disclosure or extraction of information.

### Narrative

The baseline reduces exposure and provides controls around outbound paths.

It does not replace application-layer DLP, endpoint DLP, or data classification processes.

---

## A.8.13 - Information Backup

### Baseline Control

AWS Backup support includes:

- Backup vaults
- KMS encryption
- Tag-based backup selection
- Retention policies

### ISO 27001 Alignment

A.8.13 addresses maintaining backup copies of information, software, and systems.

### Narrative

The baseline provides backup infrastructure that supports recovery readiness.

Organizations must define backup scope, RPO/RTO targets, restoration testing, and retention requirements.

---

## A.8.15 - Logging

### Baseline Control

The baseline captures logs from:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs

Logs are stored with protections such as:

- KMS encryption
- S3 versioning
- Object Lock
- Restricted bucket policies
- Lifecycle retention

### ISO 27001 Alignment

A.8.15 addresses producing, storing, protecting, and analyzing logs.

### Narrative

Logging supports investigation, monitoring, and evidence preservation.

The baseline provides technical log collection and protection, while organizations remain responsible for review procedures and alert handling.

---

## A.8.16 - Monitoring Activities

### Baseline Control

Monitoring is supported through:

- GuardDuty
- Security Hub
- AWS Config
- Inspector
- EventBridge
- CloudWatch
- SNS notifications
- Lambda automation logs

### ISO 27001 Alignment

A.8.16 addresses monitoring networks, systems, and applications for anomalous behavior.

### Narrative

The baseline enables AWS-native monitoring and event routing.

It supports detection of suspicious behavior, misconfiguration, and security service tampering.

---

## A.8.20 - Network Security

### Baseline Control

Network security controls include:

- Segmented VPC
- Private subnets
- Security groups
- Route table segmentation
- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- Endpoint security groups

### ISO 27001 Alignment

A.8.20 addresses securing networks and network devices.

### Narrative

The baseline uses layered AWS network controls to reduce public exposure and control outbound traffic.

---

## A.8.21 - Security of Network Services

### Baseline Control

Network services are secured through:

- VPC endpoints
- Security group restrictions
- Private DNS
- Controlled egress routing
- Network Firewall inspection
- Route table design

### ISO 27001 Alignment

A.8.21 addresses security mechanisms, service levels, and management requirements for network services.

### Narrative

The baseline defines secure network service access paths for AWS services and workloads.

---

## A.8.22 - Segregation of Networks

### Baseline Control

The baseline separates network zones through subnet tiers:

- Public
- Private compute
- Private data
- Private serverless
- Endpoint subnets

It also separates environments by AWS account.

### ISO 27001 Alignment

A.8.22 addresses segregation of networks, systems, and information services.

### Narrative

Network segmentation and account separation reduce blast radius and improve control over sensitive workloads.

---

## A.8.23 - Web Filtering

### Baseline Control

The baseline supports controlled outbound web access through:

- AWS Network Firewall
- Route table control
- NAT Gateway egress path
- Future potential domain-based egress profiles

### ISO 27001 Alignment

A.8.23 addresses managing access to external websites to reduce exposure to malicious content.

### Narrative

AWS Network Firewall can support egress filtering patterns.

Current implementation provides controlled egress foundations, but organizations should review and customize firewall rules for their specific web filtering needs.

---

## A.8.24 - Use of Cryptography

### Baseline Control

The baseline uses KMS-backed encryption for:

- S3 logs
- Lambda
- EBS
- Backup vaults
- Secrets Manager
- SNS topics
- CloudWatch Logs
- Terraform state

### ISO 27001 Alignment

A.8.24 addresses use of cryptography to protect confidentiality, authenticity, and integrity.

### Narrative

KMS-backed encryption helps protect operational data, secrets, logs, backups, and state.

Organizations must still define cryptographic policies, key ownership, and key rotation procedures.

---

## A.8.27 - Secure System Architecture and Engineering Principles

### Baseline Control

The baseline is designed around secure architecture principles such as:

- Multi-account isolation
- Control-plane separation
- Private-first networking
- Centralized identity
- Least privilege
- Event-driven response
- Immutable logging
- KMS encryption
- Secure CI/CD

### ISO 27001 Alignment

A.8.27 addresses secure system architecture and engineering principles.

### Narrative

The Terraform architecture provides secure default patterns that can be reused across environments.

It should be reviewed and adapted for each organization’s system architecture.

---

## A.8.28 - Secure Coding

### Baseline Control

The baseline is infrastructure-as-code and includes Terraform modules and Python Lambda functions.

It supports secure infrastructure deployment, but it does not implement a full secure coding program.

### ISO 27001 Alignment

A.8.28 addresses applying secure coding principles.

### Narrative

Secure coding for application workloads is mostly out of scope.

Organizations should implement code review, dependency scanning, SAST/DAST, secrets scanning, and secure SDLC processes separately.

---

## A.8.31 - Separation of Development, Test and Production Environments

### Baseline Control

The baseline separates environments into different AWS accounts:

```text
dev
staging
prod
```

### ISO 27001 Alignment

A.8.31 addresses separating development, test, and production environments.

### Narrative

Dedicated AWS accounts enforce strong separation between environments and reduce the risk of non-production activity impacting production.

---

## A.8.32 - Change Management

### Baseline Control

Infrastructure change is managed through:

- Terraform
- Git version control
- GitHub Actions workflows
- Plan and apply separation
- Environment-specific roles
- Terraform state separation
- Validation checklist

### ISO 27001 Alignment

A.8.32 addresses changes to information processing facilities and systems.

### Narrative

Terraform and GitHub workflows support controlled, reviewable, and repeatable infrastructure changes.

Organizations must still define approval requirements, emergency change procedures, and change records.

---

# Evidence Examples

The following artifacts can support ISO 27001 readiness discussions.

## Terraform / CI/CD Evidence

```text
Terraform plan output
Terraform apply output
Terraform destroy workflow logs
Git commit history
Pull request approvals
GitHub Actions workflow logs
GitHub OIDC role trust policies
Terraform backend configuration
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
Patch baseline configuration
```

## Identity Evidence

```text
IAM Identity Center groups
IAM Identity Center permission sets
IAM Identity Center account assignments
AWSReservedSSO role assumptions in CloudTrail
Break-glass role CloudTrail events
GitHub OIDC role assumptions
```

## Incident / Response Evidence

```text
EC2 isolation test results
EC2 rollback test results
IP enrichment test results
Tamper detection alerts
SNS notifications
Security Hub finding notes
GuardDuty findings
Security Hub findings
```

---

# Control Coverage Summary

| ISO 27001 Control Theme | Baseline Support |
|-------------------------|------------------|
| A.5.15 Access control | IAM Identity Center, IAM policies, GitHub OIDC, network restrictions |
| A.5.16 Identity management | Identity Center groups, permission sets, account assignments |
| A.5.17 Authentication information | OIDC, SSO-oriented access model, reduced static credentials |
| A.5.18 Access rights | Role-based access, environment-specific permissions |
| A.5.23 Cloud services | Secure AWS baseline, multi-account architecture |
| A.5.24-A.5.27 Incident management | Detection, alerting, isolation, rollback, logs |
| A.5.28 Evidence | Centralized logs, Security Hub, CloudTrail, Config |
| A.5.30 ICT readiness | Backup, Terraform rebuildability, logging, rollback |
| A.5.33 Records | Protected logs, Object Lock, retention |
| A.5.34 PII | Encryption, private networking, access control, monitoring |
| A.8.2 Privileged access | Identity Center, break-glass monitoring, least privilege |
| A.8.3 Information access restriction | IAM, KMS, S3 policies, network controls |
| A.8.8 Vulnerabilities | Inspector, Security Hub, patch management |
| A.8.9 Configuration management | Terraform, AWS Config |
| A.8.12 Data leakage prevention | Controlled egress, private networking, S3 public access controls |
| A.8.13 Backup | AWS Backup, encrypted vaults |
| A.8.15 Logging | CloudTrail, Config, VPC Flow Logs, CloudWatch Logs |
| A.8.16 Monitoring | GuardDuty, Security Hub, EventBridge, SNS |
| A.8.20 Network security | VPC segmentation, firewall, endpoints, security groups |
| A.8.21 Network services | VPC endpoints, private DNS, controlled service access |
| A.8.22 Network segregation | Account separation, subnet tiers |
| A.8.24 Cryptography | KMS-backed encryption |
| A.8.31 Environment separation | Dev/staging/prod AWS accounts |
| A.8.32 Change management | Terraform, GitHub Actions, plan/apply workflows |

---

# Assurance Position

`tf-secure-baseline` implements infrastructure-level controls that support ISO 27001 readiness by helping organizations:

- Restrict access to AWS resources
- Centralize identity management
- Reduce public exposure
- Protect CI/CD access
- Monitor cloud activity
- Detect security-relevant events
- Support incident containment and recovery
- Preserve security evidence
- Encrypt sensitive infrastructure data
- Support backup and recovery
- Manage secure configurations through Terraform

These capabilities align with selected ISO/IEC 27001:2022 Annex A organizational and technological control themes.

This baseline should be considered an enabling technical foundation within a broader ISMS.

It does not guarantee ISO 27001 compliance or certification without supporting governance, policies, procedures, risk assessment, Statement of Applicability, internal audit, management review, and continual improvement processes.