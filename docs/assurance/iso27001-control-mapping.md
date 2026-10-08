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

## Mapping Method and Evidence Scope

These are **selected thematic associations**, not verbatim Annex A requirements,
a complete Statement of Applicability, or a finding of conformity. The
[ISO/IEC 27001 overview](https://www.iso.org/standard/27001) describes an
organization-wide, risk-based management system; Terraform features do not
establish that management system or certification. The overview is publicly
accessible; the complete standard is available separately from ISO.

Use the applicable authoritative standard and the organization's risk assessment,
system scope, Statement of Applicability, and assessor review to determine which
controls apply. The descriptions below summarize how repository mechanisms might
contribute. They do not mark entire controls as implemented or effective.

For each adopted association, record the owner, approved design, actual account
and Region, evidence period, deployment and validation provenance, observed
operation, exceptions, and review decision. Keep configured capability,
point-in-time assertions, behavioral tests, and continuing operating evidence
separate. See [control narratives](control-narratives.md), the
[evidence guide](validation-evidence-guide.md), and the
[report template](validation-report-template.md). Unresolved authorization,
retention, response, and coverage gaps are not resolved by this mapping.

---

# Control Alignment Overview

| ISO 27001 Area | Control Theme | Baseline Support |
|---------------|---------------|------------------|
| A.5 Organizational | Access control, cloud services, incident management, evidence, records | IAM Identity Center, GitHub OIDC, logging, detection, incident workflows |
| A.6 People | Awareness, responsibilities, access lifecycle | Mostly out of scope; requires organizational process |
| A.7 Physical | Physical security | AWS facility controls and customer responsibilities require separate supplier/scope evidence; not assessed here |
| A.8 Technological | Network security, logging, monitoring, cryptography, backup, configuration management | Selected technical mechanisms with the coverage and evidence limits described below |

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
- IAM policies with explicitly reviewed privilege and scope
- GitHub OIDC roles for CI/CD
- Security group and network controls
- Private subnet placement

### ISO 27001 Alignment

A.5.15 expects access to information and associated assets to be controlled based on business and security requirements.

### Narrative

The [Identity Center](../../modules/identity_center/main.tf),
[OIDC](../../modules/github_oidc/main.tf), and network-policy resources provide
access mechanisms, not a uniform least-privilege guarantee. Apply and the central
administrator attach `AdministratorAccess`; Plan also has custom state-write and
selected secret permissions. The Operator bus-name/policy boundary is unresolved.

Review actual principals, policies, membership, trust subjects, allowed/denied
access, and business approval. Resource separation and names alone do not prove
access is limited to the intended business purpose.

---

## A.5.16 - Identity Management

### Baseline Control

The [Identity Center root](../../bootstrap/control_plane/identity_center/main.tf)
discovers an existing instance and configures groups, permission sets, policy
attachments, and account assignments. Example **group names** are
`SecOps-Operator-Dev`, `SecOps-Operator-Staging`, and `SecOps-Operator-Prod`;
permission-set names use the environment suffix, such as `SecOps-Operator-dev`.
The central security account requires
`SecOps-Administrator-secops`; Analyst and Engineer are optional.

The module does not create human users, manage group membership, or configure
the upstream identity provider's authentication policy.

### ISO 27001 Alignment

A.5.16 expects identities to be managed throughout their lifecycle.

### Narrative

These resources support structured AWS assignment. Joiner/mover/leaver actions,
identity proofing, timely removal, membership review, and upstream identity
controls remain organizational responsibilities. The control-plane validator's
assignment-presence check does not compare each assignment principal to the
created group, inspect full policies, or verify membership. Retain those records
and actual access observations separately.

---

## A.5.17 - Authentication Information

### Baseline Control

The baseline avoids long-lived AWS access keys for CI/CD after bootstrap by using GitHub OIDC.

Human access is intended to use IAM Identity Center.

### ISO 27001 Alignment

A.5.17 addresses protection and management of authentication information.

### Narrative

GitHub OIDC and Identity Center reduce reliance on static access keys for routine
operations. Initial bootstrap needs an independently authorized administrative
credential path; the repository does not require creation of a long-lived IAM
user key. Secure emergency identities, secret retrieval, runner credentials,
state backups, and plan artifacts separately.

The [publication script](../../scripts/deployment/deploy-application.sh) uses an
ECR credential helper with temporary Docker push configuration and token-file
caching disabled. That limits local persistence, not all credential exposure.
RDS uses ephemeral/write-only password arguments, while the ordinary AbuseIPDB
secret-version value has different state/plan exposure. Retain credential issuance,
revocation, secret-handling, and access-review evidence.

---

## A.5.18 - Access Rights

### Baseline Control

Access rights are structured through:

- IAM Identity Center permission sets
- Environment-specific group assignments
- Separate GitHub Plan, Apply, and Image Publisher roles
- Separate SecOps roles
- Function-specific Lambda roles, including wildcard-resource response grants
- Optional customer-managed policy attachments by environment

### ISO 27001 Alignment

A.5.18 expects access rights to be provisioned, reviewed, modified, and removed according to access control policies.

### Narrative

Separate Plan, Apply, Publisher, and GitHub-only PR jobs make authority reviewable.
They do not alone establish approved rights or separation of duties. Plan trusts
an Environment subject; Apply selects Environment or branch subjects, not both as
an AND condition. Actual GitHub reviewer/branch protections are separately managed.

The [persona module](../../modules/identity_center/main.tf) includes
`AdministratorAccess` and Engineer response actions on wildcard resources.
Customer-managed policy references neither create target-account policies nor
certify their contents. Retain exact grants, membership, approved provisioning,
periodic review, removal, and exception handling rather than relying on role names.

---

## A.5.23 - Information Security for Use of Cloud Services

### Baseline Control

The baseline provides a secure AWS cloud foundation using:

- Multi-account structure with dedicated `control-plane`, `security-operations`, `dev`, `staging`, and `prod` accounts
- Control-plane and delegated security-administrator separation
- Private networking
- Centralized logging
- Detection services, including profile-driven GuardDuty ECS/Fargate Runtime Monitoring
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

**Implementation boundary:** Review the [adoption guide](../adoption-guide.md)
for licensing, existing-organization adoption, service prerequisites, actual
resource cost, ownership, and exit requirements. AWS account separation does not
supply a full SCP strategy or account vending. Central-security resources and
workload realization have separate state and validation layers; cloud-provider
assurance and customer governance are outside this repository's evidence.

---

## A.5.24 - Information Security Incident Management Planning and Preparation

### Baseline Control

The baseline provides technical foundations that support incident response, including:

- Security Hub findings
- GuardDuty findings
- GuardDuty ECS/Fargate Runtime Monitoring and coverage-health notifications
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

The baseline supports incident readiness by providing event-driven detection, notification, and selected response capabilities. Runtime Monitoring extends detection into protected Fargate tasks and reports coverage degradation/recovery to SecOps.

Automatic containment remains EC2-specific; ECS/Fargate Runtime Monitoring is a detection and visibility capability.

Organizations must still define incident response roles, escalation paths, communications procedures, severity criteria, and tabletop exercises.

**Evidence:** Exercise the approved response path on a dedicated target, retain
independent pre-incident state, and plan for partial mutation and shared
notification failure. The [test guides](../lambda_tests/ec2_isolation.md) are
procedures, not records that tests ran. A working direct Lambda invocation does
not prove authentic upstream finding ingestion or intended Operator authorization.

## A.5.25 - Assessment and Decision on Information Security Events

### Baseline Control

The baseline supports event assessment through:

- Security Hub findings
- GuardDuty findings
- GuardDuty ECS Runtime Monitoring coverage status and issue reporting
- AWS Config evaluations
- IP enrichment
- SNS notifications
- CloudWatch Logs
- Centralized logs

### ISO 27001 Alignment

A.5.25 addresses assessing information security events and deciding whether they are incidents.

### Narrative

The baseline provides telemetry, enrichment, and runtime-coverage context that help teams evaluate events.

A healthy Runtime Monitoring coverage state is evidence that GuardDuty reports coverage for the protected cluster at the time checked; it is not a determination that the workload is free of compromise. Human triage and incident classification remain organizational responsibilities.

**Boundary:** Insight names do not filter by workload environment, and selected
SNS transformations represent only the first finding/resource. Missing telemetry,
empty results, `OK` alarms, or absent DLQ messages can coexist with coverage or
delivery failures. Retain original events, scope/freshness, triage decisions, and
response records alongside [monitoring](../../modules/monitoring/main.tf)
configuration.

## A.5.26 - Response to Information Security Incidents

### Baseline Control

The baseline provides response automation such as:

- EC2 isolation for qualifying findings, with `CRITICAL` as the default automated threshold
- Controlled EC2 rollback
- SNS alerting
- Tamper detection alerts
- Break-glass monitoring

### ISO 27001 Alignment

A.5.26 addresses responding to information security incidents according to documented procedures.

### Narrative

The [isolation handler](../../modules/automation/lambda/ec2_isolation.py) requests
snapshots without waiting for completion, replaces security groups, then writes
recovery tags and attempts notification. Caught errors can return ordinary
summaries, so invocation success and empty DLQs do not prove containment.
Quarantine retains shared-endpoint HTTPS access. All supplied workload roots
default isolation authorization to true; this needs an explicit policy decision.

The [rollback handler](../../modules/automation/lambda/ec2_rollback.py) does not
authenticate its supplied approver/ticket fields, does not check detail type, and
sets `IsolationAllowed=true`. Operator's caller uses an unprefixed bus ARN while
automation creates a prefixed bus; the bus policy has a wildcard-principal source
allow. Human approval and Operator exclusivity are not established by those
mechanisms. Review effective authorization, preserve pre-state, and retain observed
recovery, partial-failure handling, and organizational approval evidence.

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

**Boundary:** Collection does not guarantee preservation: workload logs are
mutable and key deletion can make retained ciphertext unavailable. Learning
requires incident review, assigned corrective actions, completion records, and
verification that changes actually reduced the identified risk.

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

Evidence can include publication metadata and digest, the selected configuration
change, saved-plan metadata/checksum, actual approvals, apply logs, and
post-deployment observations. Generated summaries are not a signed chain of
custody and do not automatically include every deployment commit, image digest,
input set, or artifact checksum.

The [logs bucket](../../modules/storage/main.tf) uses encryption and versioning
but has Object Lock disabled and permits force destruction. The
[workload keys](../../modules/security/main.tf) have no effective production
destruction guards. Define independent preservation and usable-key retention,
access controls, collection timestamps, and custody procedures. Review warnings
and skipped branches; retain earlier tests under their original provenance rather
than attributing them to a later deployment.

---

## A.5.30 - ICT Readiness for Business Continuity

### Baseline Control

[Production policy](../../baseline/locals.tf) supplies three-AZ network defaults,
redundant ECS capacity requirements and AZ rebalancing, an RDS PostgreSQL Multi-AZ
DB instance, default-enabled AWS Backup, and conditional RDS Restore Testing.
An explicit false backup override is honored and disables Restore Testing as well;
this is different from the enforced RDS Multi-AZ requirement. RDS-native
automated backups have a separate 14-day retention setting.

A vault remains declared when non-production scheduling is disabled; that is not
indefinite preservation of its data or key. EC2 is a set of standalone instances,
not an Auto Scaling Group with a supplied application recovery mechanism.

### ISO 27001 Alignment

A.5.30 addresses readiness of ICT systems for business continuity.

### Narrative

The infrastructure contributes to continuity readiness, not business continuity
acceptance. Test actual task placement/replacement, database failover, restored
application/data behavior, cleanup, and measured recovery objectives. A Multi-AZ
DB instance is not a three-node database or cross-Region recovery.

[Retirement](../production-retirement.md) separates Stage-1 quiescence, durable
cleanup, Identity Center cleanup, and final exact workload destruction. Later
rejection does not reverse earlier changes; the complete cleanup workflow is
`prod`-only. Retain required data and usable keys outside destruction scope and
maintain organizational continuity plans, ownership, and exercises.

## A.5.33 - Protection of Records

### Baseline Control

The workload logs bucket uses KMS-backed encryption, public access blocks,
versioning, access policies, and lifecycle transitions/expiration. It explicitly
has `object_lock_enabled=false`, `force_destroy=true`, and no Terraform
destruction guard. Other CloudWatch log groups have configured retention, not
universal archival to that bucket. See [storage](../../modules/storage/main.tf).

### ISO 27001 Alignment

A.5.33 addresses protection of records from loss, destruction, falsification, unauthorized access, or unauthorized release.

### Narrative

These settings do not provide immutable records or guarantee survival through
approved destruction. Define record classes, retention/erasure rules, required
integrity verification, independent preservation, and usable key access. Preserve
custody and access-review evidence; a lifecycle policy is not proof that records
cannot be altered or deleted before expiration.

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

**Boundary:** Encryption and private networks do not implement tenant isolation,
data minimization, application/database authorization, or every transport path.
The ALB frontend is HTTPS but target traffic is HTTP. Enrichment sends indicators
to an external provider, and operational findings/logs may contain sensitive data.
Review actual data flows, third-party disclosure, access and retention policies,
and privacy obligations for the adopting system.

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

The repository evaluates selected technical conditions; it does not determine
legal, contractual, ISMS, or policy compliance. Config catalog presence does not
prove complete recorder coverage or compliant resources. A disabled S3 family does
not disable the separate automatic remediation when Config remains enabled.
Retain applicability, scope, evaluation freshness, exceptions, remediation impact,
and accountable review against the organization's approved policies.

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

**Evidence:** Adopt and approve procedures for the actual environment, record
operator authorization, and keep executed test results separate from examples.
The [retirement runbook](../production-retirement.md) and
[evidence guide](validation-evidence-guide.md) define additional operational
boundaries. Documentation presence is not evidence that staff followed a procedure
or that its effects were reviewed.

---

# A.8 Technological Controls

## A.8.2 - Privileged Access Rights

### Baseline Control

Privileged access is controlled through:

- IAM Identity Center
- Environment-specific permission sets
- GitHub OIDC apply roles
- Break-glass role monitoring
- IAM policies with explicitly reviewed privilege and scope
- Separation of plan and apply roles

### ISO 27001 Alignment

A.8.2 addresses restricting and managing privileged access rights.

### Narrative

Review actual policies rather than assuming least privilege from environment or
role names. Apply and central Administrator are broadly privileged; Plan can write
state and read selected secrets. Lambda response roles grant selected EC2 actions
on wildcard resources without tag-based IAM restrictions.

Break-glass has an MFA trust condition and administrator authority. Its alert
pattern matches a request for the role, not necessarily a successful assumption.
Evidence must include privileged-rights approval/review/removal, real request
outcomes, recipient delivery, and emergency follow-up.

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

**Boundary:** Private reachability, KMS encryption, and SG references do not
replace effective IAM/resource-policy evaluation or application authorization.
The endpoint resources supply no custom endpoint-policy restrictions, and shared
endpoint access is broader than a single service. Review actual API access and
both identity/resource policies, including the unresolved rollback bus boundary.

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

**Evidence:** Retain the actual identity-provider settings, authentication and
role-assumption records, OIDC audience/subject restrictions, and emergency
credential controls. The module does not configure upstream MFA or make a role
unusable outside an independently enforced approval process.

---

## A.8.8 - Management of Technical Vulnerabilities

### Baseline Control

Inspector is enabled for the effective selected resource types where configured;
ECR is added when effective repositories exist. Coverage and findings are distinct
from account-level enablement.

The [patch module](../../modules/patch_management/main.tf) configures a tagged
SSM maintenance-window task using `AWS-RunPatchBaseline` Install with
`RebootIfNeeded`. It does not define a custom patch baseline, application-health
gates, draining, or quarantine-exclusion targeting.

### ISO 27001 Alignment

A.8.8 addresses obtaining, evaluating, and addressing technical vulnerabilities.

### Narrative

Retain per-resource scan coverage/freshness, findings, prioritized remediation,
exceptions, and per-target patch results, missing/failed counts, reboot state,
and application recovery. An Online managed node or existing window does not
prove successful patching. Application secure coding and vulnerability management
outside these infrastructure services remain separate responsibilities.

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

Terraform defines selected desired properties with explicit exceptions. EC2
security-group attachments and incident tags are ignored for drift correction;
AMI lookup can change a plan without a source change. Config uses a fixed recorder
scope and selected rules, not complete evaluation of every AWS resource.

Retain effective inputs, provider/lockfile context, desired/observed comparisons,
reviewed exceptions and change records. [Config recording](../../modules/security/config_baseline/main.tf)
still includes IAM types when IAM rules are disabled and omits KMS keys despite
enabled KMS rules. Validate actual applicability/results before asserting coverage.

---

## A.8.12 - Data Leakage Prevention

### Baseline Control

The following mechanisms can support selected exposure and data-movement controls, but are not a complete data leakage prevention implementation:

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

The network and storage controls can reduce exposure and constrain selected
outbound paths; they are not a content-aware DLP implementation or an assurance
that data cannot be exfiltrated. NAT-only egress is not inspected, and non-VPC
enrichment bypasses workload routes. Domain matching does not inspect encrypted
payload content. Application/endpoint DLP, authorized transfer controls,
classification, and data-sharing decisions require separate design and evidence.

---

## A.8.13 - Information Backup

### Baseline Control

AWS Backup support includes:

- a retained KMS-encrypted backup vault per workload environment;
- conditional backup plans and selections;
- tag-based selection using `Backup=true` when scheduled backup is enabled;
- profile-aware effective schedule and retention; and
- validation that EC2/RDS `Backup` tags match the effective enablement state.

Default behavior is:

```text
production  -> scheduled backup enabled by default, 30-day retention
development -> scheduled backup disabled
minimal     -> scheduled backup disabled
```

When disabled, the effective schedule and retention are null, plan/selection resources are absent, and the encrypted vault remains present.

### ISO 27001 Alignment

A.8.13 addresses maintaining backup copies of information, software, and systems.

### Narrative

[Backup configuration](../../modules/backup/main.tf) includes RDS Restore
Testing when both production profile and effective backup enablement are true,
distinct from RDS-native backups and source Multi-AZ availability.
A temporary private Single-AZ restore is used; the module does not supply an
application-specific data validator.

Record configuration, completed restore execution, application/data validation,
and temporary-resource cleanup separately. The backup validator can PASS with
absent-job, application-validation, or cleanup warnings. Scheduling alone does
not establish successful recovery or objectives. Verify source scope, retained
backup copies, required keys and access, actual restoration, retention decisions,
and approved destructive lifecycle before accepting this association.

## A.8.15 - Logging

### Baseline Control

The [logging module](../../modules/logging/main.tf) configures management-event
CloudTrail collection and VPC Flow Logs with CloudWatch/S3 paths. Config,
application, Lambda, RDS, and Container Insights records have their own resources
and retention. There is no universal S3 archival path for every log group.

The logs bucket has encryption, versioning, access policy and lifecycle rules,
but Object Lock is disabled and force destruction is allowed. CloudTrail is not
configured as an organization trail or general data-event trail.

### ISO 27001 Alignment

A.8.15 addresses producing, storing, protecting, and analyzing logs.

### Narrative

Review collection scope, actual delivery/freshness, record content, access,
retention, archival and usable key access. Configured log-file validation does not
perform a digest-chain verification. The logging validator permits delivery and
missing-retention warnings and does not inspect Firehose archival or fresh objects.
ECS log checks compare their resource-backed key/retention metadata, not every
application log's completeness or continuing operation.

---

## A.8.16 - Monitoring Activities

### Baseline Control

Monitoring is supported through a combination of centrally governed and workload-local services:

- centrally administered GuardDuty organization enrollment and protection plans;
- GuardDuty Runtime Monitoring with `ECS_FARGATE_AGENT_MANAGEMENT = ALL`, `EC2_AGENT_MANAGEMENT = ALL`, and `EKS_ADDON_MANAGEMENT = NONE`;
- deployment-profile-driven ECS cluster participation (`GuardDutyManaged=true` for production/development and `false` for minimal);
- exact GuardDuty-agent ECR pull authority for protected ECS task execution roles;
- live validation of injected GuardDuty agent state and ECS coverage health;
- EventBridge/SNS notification for GuardDuty Runtime Protection unhealthy and healthy ECS coverage-state changes;
- centralized Security Hub CSPM finding aggregation and configuration policies;
- Security Hub V2 organization policy for workload enablement;
- workload-local AWS Config and Inspector; and
- EventBridge, CloudWatch, CloudTrail, and SNS.

### ISO 27001 Alignment

A.8.16 addresses monitoring networks, systems, and applications for anomalous behavior and security events.

### Narrative

Centralized GuardDuty and Security Hub governance reduce account-level drift and provide common security visibility, while workload-local Config and Inspector preserve environment-specific configuration and vulnerability evidence.

The workload runtime includes protected Fargate instrumentation and coverage-health notification. The baseline validates that protected running tasks have one running GuardDuty agent and that GuardDuty reports the expected cluster as `AUTO_MANAGED`, `HEALTHY`, and without unresolved issues.

These are technical monitoring mechanisms; organizations must still define review, escalation, investigation, and response procedures.

**Acceptance boundary:** Empty-runtime validation does not prove live agent
injection. Coverage health is not proof of no compromise. ECS alarms treat missing
data as non-breaching and cannot establish application availability from zero
counts. Coverage events are account/regional ECS scoped, not a baseline-only
cluster health poll. Notification DLQs protect selected edges, not every SNS
subscriber; alarms reuse the same topic/key. Retain coverage, signal freshness,
correlated receipt, triage, response, and independently reviewed gaps.

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

**Scope:** Effective modes differ: firewall inspection, NAT-only, or endpoint-only
compute routing. Validate the selected mode, full subnet/route inventory, private
resource placement and exact SG rules, rather than inferring all traffic is
inspected. Application TLS and intended public ALB ingress require separate
review. [Baseline composition](../../baseline/main.tf) is the implementation
authority, not an environment label.

---

## A.8.21 - Security of Network Services

### Baseline Control

Network services are secured through:

- Terraform-owned VPC endpoints;
- security group restrictions;
- private DNS;
- controlled egress routing;
- Network Firewall inspection; and
- route table design.

For Runtime Monitoring, the `guardduty-data` Interface Endpoint remains Terraform-owned and shared with eligible workloads. Workload validation requires exactly one live endpoint for that service and requires its ID to match Terraform output, reducing unmanaged network-service drift.

Protected ECS task security groups use the shared Interface Endpoint security group for private AWS API/telemetry paths and the S3 Gateway Endpoint for the S3/ECR layer path.

### ISO 27001 Alignment

A.8.21 addresses security mechanisms, service levels, and management requirements for network services.

### Narrative

The baseline defines secure network-service access paths for AWS services and workloads and keeps the Runtime Monitoring telemetry endpoint inside the same Terraform ownership, placement, and validation model as other private service endpoints.

**Boundary:** Endpoint readiness is Terraform resource ordering, not proof of DNS,
service health, authorization, or package-repository reachability. The SG
relationship does not restrict an API to a single intended action. Observe actual
allowed/denied service use and agree service levels outside the Terraform
configuration.

## A.8.22 - Segregation of Networks

### Baseline Control

The seven subnet families are `ingress_public`, `egress_public`,
`compute_private`, `data_private`, `serverless_private`, `endpoint_private`, and
`firewall_private`. Public ALB ingress and NAT egress have separate subnet and
route-table roles. Production defaults to three AZs; other profiles default to
two. Environments are separated by workload accounts.

The [security-policy layer](../../modules/networking/security_policy/main.tf)
defines the actual cross-tier traffic rules. Quarantine retains shared endpoint
HTTPS connectivity.

### ISO 27001 Alignment

A.8.22 addresses segregation of networks, systems, and information services.

### Narrative

Account and network structure provide segregation mechanisms, not an automatic
prohibition on every cross-tier or cross-account action. Validate effective routes,
SGs and identity/resource grants against the intended system boundary. Tenant
segregation remains an application/data-plane responsibility.

---

## A.8.23 - Web Filtering

### Baseline Control

When the effective mode is `network_firewall`, the
[firewall](../../modules/firewall/main.tf) applies domain-based filtering on the
inspected compute path using platform-required and approved application domains.
This is implemented behavior, not a future-only capability. `nat_only` does not
apply that inspection; non-VPC enrichment is outside workload firewall routing.

### ISO 27001 Alignment

A.8.23 addresses managing access to external websites to reduce exposure to malicious content.

### Narrative

Domain allowlisting is not comprehensive malicious-content classification,
full-URL control, TLS payload inspection, or organization-wide web filtering.
Review approved destinations, exact routing and rules, observed allowed/denied
requests, and exceptional service paths for the actual workload.

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

**Implementation limits:** The workload keys have rotation and deletion windows,
not effective production destruction guards. Pending deletion makes a key
unavailable for KMS cryptographic operations. Preserve usable keys for retained
ciphertext. RDS storage is encrypted without an explicit database key argument;
the Lambda key concerns environment variables, not proof of code signing.
ALB-to-task traffic is HTTP, distinct from HTTPS on the frontend. Review actual
keys/grants, data paths, transport configuration, secrets in artifacts, rotation,
and disposal against the organization's cryptographic policy.

---

## A.8.27 - Secure System Architecture and Engineering Principles

### Baseline Control

The baseline is designed around secure architecture principles such as:

- Multi-account isolation
- Control-plane and delegated-security separation
- Private-first networking
- Centralized identity
- Explicit privilege review and documented exceptions
- Immutable application release selection
- Profile-driven Fargate Runtime Monitoring
- Terraform-owned Runtime Monitoring IAM/network prerequisites with GuardDuty-owned live agent lifecycle
- Event-driven response and coverage-health notification
- Encrypted and versioned logging with explicit preservation limitations
- KMS encryption
- Secure CI/CD

### ISO 27001 Alignment

A.8.27 addresses secure system architecture and engineering principles.

### Narrative

The Terraform architecture provides reusable secure-default patterns while preserving explicit ownership boundaries between organization governance, workload infrastructure, and AWS service-managed runtime instrumentation.

Automatic ECS/Fargate containment is not implemented; the EC2 isolation handler is not a supported Fargate containment mechanism.

The architecture should still be reviewed and adapted for each organization’s system and risk context.

**Boundary:** Digest selection does not prove image signing, vulnerability
acceptance, application authorization, or immutable execution. Review source,
trust boundaries, broad IAM grants, mutable log/key lifecycle, and partial-response
behavior. An architecture principle is not evidence that every implementation
component satisfies it.

## A.8.28 - Secure Coding

### Baseline Control

The baseline is infrastructure-as-code and includes Terraform modules and Python Lambda functions.

It supports secure infrastructure deployment, but it does not implement a full secure coding program.

### ISO 27001 Alignment

A.8.28 addresses applying secure coding principles.

### Narrative

Secure coding for application workloads is mostly out of scope.

Organizations should implement code review, dependency scanning, SAST/DAST, secrets scanning, and secure SDLC processes separately.

**Evidence:** Review the repository's own Python and shell behavior as well as
application code. Handled error responses, partial state changes, unchecked
partial API failures, and external dependencies need explicit tests and defect
tracking. A syntax check or documentation example is not secure-code assurance.

---

## A.8.31 - Separation of Development, Test and Production Environments

### Baseline Control

Development, staging, and production workloads run in separate AWS accounts. Central platform responsibilities are also separated into dedicated accounts:

```text
control-plane
security-operations
dev
staging
prod
```

### ISO 27001 Alignment

A.8.31 addresses separation of development, testing, and production environments.

### Narrative

Separate workload accounts create strong boundaries between development, staging, and production. Keeping control-plane and security-operations responsibilities outside the workload accounts further reduces the chance that workload lifecycle activity affects organization governance or centralized security administration.

**Boundary:** Confirm actual account ownership and access paths; names and state
separation are not IAM denies. Shared human administrators and authorized
cross-account grants require their own review. Resilience policy follows
`deployment_profile`, not only the directory name; the complete protected cleanup
workflow remains limited to `prod`.

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

The [Apply workflow](../../.github/workflows/terraform-apply.yml) creates its
own saved plan before protected approval and verifies/applies that artifact rather
than the standalone Plan output. Image publication, digest PR, merge, Apply, and
post-deployment evidence are separate actions.

Document actual reviewers and GitHub protections, sensitive artifact handling,
provenance, tests, results, convergence and emergency/out-of-band changes. A
checksum is not an independent signature or proof of separation of duties.
Retirement approvals are staged: rejecting final destruction does not undo earlier
approved data or Identity Center cleanup.

---

# Evidence Examples

The following artifacts can support ISO 27001 readiness discussions. They should be reviewed with organizational policies, risk treatment, control ownership, and operating evidence rather than treated as certification evidence by themselves.

## Generated Validation Evidence

```text
validation-results/control-plane/<timestamp>/
validation-results/security-operations/security-services/<timestamp>/
validation-results/<env>/bootstrap/<timestamp>/
validation-results/<env>/baseline/<timestamp>/
```

The four evidence layers distinguish organization/access foundations, centralized security governance, workload bootstrap foundations, and deployed workload realization.

A baseline summary reports 16 child-script exits, not every assertion. Warnings,
disabled branches, and empty runtime paths remain visible acceptance limits. The
exporter reruns the scripts; its static manual-work list is not proof that those
exercises were performed or remain outstanding in an organization's records.
Record deployment/validation commits, effective inputs/digests, account/Region,
execution time and evidence location separately. Never attach earlier behavioral
results to a later deployment without preserving their original provenance.

## Terraform / CI/CD Evidence

```text
Terraform plans and apply logs
GitHub Actions workflow history
GitHub OIDC trust and role configuration
Terraform state backend / native-locking configuration
AWS Organizations and Identity Center state
security_operations/security_services state
```

## AWS Evidence

```text
CloudTrail scope/status, fresh delivery, performed integrity checks and actual retention/key availability
AWS Config recorder and rule state
Security Hub CSPM central configuration, finding aggregation, policies, and associations
Security Hub V2 effective workload policies
GuardDuty detector, organization enrollment, exact Runtime Monitoring organization feature state, ECS `GuardDutyManaged` intent, live agent/coverage state, and coverage-health notification configuration
Inspector account status
KMS aliases and policies
S3 encryption, versioning, Object Lock disabled-state, lifecycle and destruction configuration
VPC Flow Logs and VPC endpoint state
Backup jobs/scope, Restore Testing execution/data validation/cleanup, RDS/ECS availability observations, retained key access, and per-target patch results
```

## Identity / Incident Evidence

```text
IAM Identity Center groups, permission sets, and account assignments
SecOps-Administrator assignment for security-operations
AWSReservedSSO role assumptions in CloudTrail
Break-glass events
EC2 isolation and rollback test results
IP enrichment results
Tamper alerts and SNS notifications
Security Hub / GuardDuty findings
```

## Control-Owner Evidence Review

| Themes | Repository authority | Acceptance evidence and unresolved responsibility |
|---|---|---|
| Access and privileged identity | [OIDC](../../modules/github_oidc/main.tf), [Identity Center](../../modules/identity_center/main.tf) | Effective grants, assignment principals/membership, approvals, authentication and rights lifecycle; resolve Operator bus authorization and broad-grant decisions |
| Evidence and records | [Logging](../../modules/logging/main.tf), [storage](../../modules/storage/main.tf), [keys](../../modules/security/main.tf) | Actual delivery, performed integrity verification, retention/custody, independent preservation and usable keys |
| Incident handling | [Automation](../../modules/automation/main.tf), [response code](../../modules/automation/lambda/) | Authentic event path, approved caller/target, pre-state, partial failures, containment/recovery and human decisions |
| Configuration and monitoring | [Config](../../modules/security/config_baseline/main.tf), [monitoring](../../modules/monitoring/main.tf) | Evaluated resources/freshness, signal gaps, receipt and triage, remediation impact and exceptions |
| Networks and data movement | [Baseline](../../baseline/main.tf), [security policy](../../modules/networking/security_policy/main.tf) | Selected routing, intended ingress/egress, API grants, transport and application/tenant boundaries |
| Continuity and maintenance | [Backup](../../modules/backup/main.tf), [patching](../../modules/patch_management/main.tf) | Scope, successful restoration, application validation, cleanup, measured objectives and per-target maintenance results |

These associations do not replace a Statement of Applicability, risk treatment,
internal audit, management review, or customer/supplier assurance. The repository
does not establish that a named organization has performed or accepted them.

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
| A.5.30 ICT readiness | Production RDS/ECS resilience, Backup/Restore Testing and retirement procedures; measured recovery requires exercises |
| A.5.33 Records | Encryption/versioning and lifecycle settings; no immutable retention or guaranteed key preservation |
| A.5.34 PII | Encryption, private networking, access control, monitoring |
| A.8.2 Privileged access | Identity Center, OIDC and emergency roles; broad grants and actual approvals require review |
| A.8.3 Information access restriction | IAM, KMS, S3 policies, network controls |
| A.8.8 Vulnerabilities | Inspector, Security Hub, patch management |
| A.8.9 Configuration management | Terraform, AWS Config |
| A.8.12 Data leakage prevention | Exposure/path constraints only; no content-aware DLP implementation |
| A.8.13 Backup | Backup/Restore Testing configuration and resource tags; execution, data validation, cleanup and key availability need evidence |
| A.8.15 Logging | CloudTrail, Config, VPC Flow Logs, CloudWatch Logs |
| A.8.16 Monitoring | GuardDuty/Fargate Runtime Monitoring and coverage health, Security Hub, EventBridge, SNS |
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
- Monitor cloud activity and protected ECS/Fargate runtime coverage
- Detect security-relevant events and monitoring-coverage degradation
- Support incident containment and recovery
- Support evidence collection subject to retention and key-lifecycle limitations
- Encrypt sensitive infrastructure data
- Support backup and recovery
- Manage secure configurations through Terraform

These mechanisms are candidate contributions to selected ISO/IEC 27001:2022 Annex A organizational and technological control themes; actual applicability and conformity require organization-specific assessment.

This baseline should be considered an enabling technical foundation within a broader ISMS.

It does not guarantee ISO 27001 compliance or certification without supporting governance, policies, procedures, risk assessment, Statement of Applicability, internal audit, management review, and continual improvement processes.
