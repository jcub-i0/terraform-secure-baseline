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

## Mapping Method and Acceptance

The criterion references below are **interpretive associations**, not quotations
of the Trust Services Criteria, a complete control matrix, or assertions that
any criterion is satisfied. The authoritative
[AICPA Trust Services Criteria](https://www.aicpa-cima.com/resources/download/2017-trust-services-criteria-with-revised-points-of-focus-2022)
and the agreed examination scope determine applicable requirements. Validate the
mapping with the organization responsible for the system and its assessor.

Repository implementation is only one input to a control conclusion. For each
adopted control, record its owner, relevant system boundary, approved design,
actual configuration, evidence period, operating records, exceptions, and review
result. Source configuration, point-in-time script checks, behavioral exercises,
and continuing operation are different evidence levels. Neither a feature list
nor a successful deployment establishes operating effectiveness.

The [control narratives](control-narratives.md) explain implementation limits;
the [evidence guide](validation-evidence-guide.md) and
[report template](validation-report-template.md) keep generated results separate
from reviewer acceptance. Known authorization, retention, response, and coverage
gaps below are not closed merely because they are documented.

---

# Control Alignment Overview

| Area | SOC 2 Domain | Description |
|------|-------------|-------------|
| Logical access | CC6 | Restricts access to systems and data |
| Network access | CC6 | Reduces exposure and enforces controlled communication paths |
| CI/CD access | CC6 / CC8 | Controls infrastructure deployment permissions |
| Identity management | CC6 | Centralizes human access through IAM Identity Center across workload and security-operations accounts |
| Logging and monitoring | CC7 | Captures security-relevant activity |
| Threat detection | CC7 | Identifies suspicious activity, runtime threats, coverage degradation, and misconfiguration |
| Incident response support | CC7.4 | Supports containment, triage, and recovery workflows |
| Change and configuration monitoring | CC8 | Detects infrastructure drift and unauthorized changes |
| Encryption and data protection | CC6.1 / CC6.7 | Supports selected storage and transmission safeguards; transport and authorized data movement require separate evidence |
| Backup and recovery | Availability-supporting controls | Supports operational resilience and recovery readiness |

---

# Control Function Classification

| Function | Description | Examples |
|----------|-------------|----------|
| Preventative | Reduces likelihood of unauthorized access, exposure, or misconfiguration | Private subnets, IAM policies, Identity Center, KMS encryption |
| Detective | Identifies selected activity, misconfiguration, or security events | CloudTrail, GuardDuty, Security Hub, AWS Config, tamper-event matching |
| Responsive | Supports containment, recovery, or escalation | EC2 isolation, EC2 rollback, SNS alerts |
| Corrective | Supports restoration or remediation | Rollback workflow, backup vaults, patching resources |

`tf-secure-baseline` implements controls across all four categories.

---

# CC6 - Logical and Network Access Controls

## Multi-Account Environment Segmentation

### Baseline Control

The platform separates governance, centralized security administration, and workloads into dedicated AWS accounts:

```text
control-plane
security-operations
dev
staging
prod
```

The organization places `dev` and `staging` under `Workloads/NonProd`, `prod` under `Workloads/Prod`, and `security-operations` under the root-level `Security` OU.

The control-plane account manages organization structure and centralized identity. The security-operations account is the delegated administrator for centralized security services. Workload accounts host environment-specific infrastructure.

### SOC 2 Alignment

- CC6.1 - Logical access to systems is restricted.
- CC6.2 - Access credentials and privileges are managed.
- CC6.6 - Network and system access is restricted to authorized users and services.

### Narrative

Account separation establishes distinct administration and resource boundaries;
it does not deny every cross-account grant or implement an organization's full
access lifecycle. Review actual account IDs, OU placement, trust/resource
policies, and external policy restrictions against the
[Organizations root](../../bootstrap/control_plane/organizations/main.tf).
The repository does not provide account vending or a complete SCP strategy.
Control-plane validation is evidence of its specific topology checks, not a
universal test that non-production identities cannot reach production.

---

## Centralized Human Access Through IAM Identity Center

### Baseline Control

The [Identity Center caller](../../bootstrap/control_plane/identity_center/main.tf)
and [module](../../modules/identity_center/main.tf) discover an existing instance
and create configured groups, permission sets, policy attachments, and account
assignments. Workload group names such as `SecOps-Operator-Dev` differ from
permission-set names such as `SecOps-Operator-dev`. The central security account
requires `SecOps-Administrator-secops`; Analyst and Engineer are
optional, and Operator is disabled there.

Human users, group membership, upstream authentication/MFA policy, employment
status, and periodic access reviews are not managed by this module.

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - User access credentials and privileges are managed.
- CC6.3 - Access is authorized based on roles and responsibilities.
- CC6.6 - Access to systems is limited to authorized users.

### Narrative

The resources support centralized AWS role assignment, but group naming and
assignment presence do not prove least privilege or an approved access lifecycle.
Administrator attaches `AdministratorAccess`; Engineer includes response actions
on wildcard resources. Review effective permissions, membership, assignment
principals, approval/removal records, and actual access tests. The
[control-plane validator](../../scripts/validation/validate-control-plane.sh)
does not compare complete policies, membership, or each assignment principal to
the created group.

---

## Least-Privilege Operational Roles

### Baseline Control

Operator submits rollback events without direct EC2 mutation or
Lambda-invocation grants in its inline policy. The workload bus policy
restricts `custom.rollback` publication to matching Identity Center
Operator role ARNs via `aws:PrincipalArn` and explicitly denies non-Operator
publishers. This identity enforcement does not authenticate human approval.

The [caller](../../bootstrap/control_plane/identity_center/main.tf) derives
the same prefixed bus name as [automation](../../modules/automation/main.tf).
The rollback handler does not independently authenticate the submitted
approver or ticket metadata.

### SOC 2 Alignment

- CC6.1 - Access is restricted to authorized users.
- CC6.3 - Access is granted according to job responsibilities.
- CC6.6 - System access is limited to authorized activities.

### Narrative

The bus implements a role-scoped `custom.rollback` publisher boundary, but
actual group assignments, effective permissions, human approval, and
successful recovery remain separate claims. Retain positive/negative access
evidence in addition to source and policy review; `PutEvents` acceptance
alone does not prove human approval.

---

## Break-Glass Access Monitoring

### Baseline Control

The [emergency role](../../modules/iam/break_glass.tf) attaches
`AdministratorAccess` and requires the configured trusted principals to satisfy
an MFA condition. The organization supplies and controls the emergency identity.

[Monitoring](../../modules/monitoring/main.tf) matches CloudTrail AssumeRole
requests for that role and targets SecOps SNS. Its pattern does not require a
successful request, and it does not verify an emergency ticket.

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - Privileged access is managed.
- CC7.2 - Security events are monitored.
- CC7.4 - Incident response processes are supported.

### Narrative

Retain trust/MFA configuration, an approved access exercise, the actual API
outcome, notification receipt, and emergency-access review/revocation records.
The alert title is not proof of successful assumption, and configured routing
is not proof that a person received or acknowledged the alert.

---

## Private Workload Isolation

### Baseline Control

The [baseline](../../baseline/main.tf) uses seven subnet families:
`ingress_public`, `egress_public`, `compute_private`, `data_private`,
`serverless_private`, `endpoint_private`, and `firewall_private`. Production
defaults to three standard AZs; other profiles default to two.

The optional internet-facing ALB uses ingress-public subnets, while NAT Gateways
use separate egress-public subnets. ECS tasks have no public task IP and RDS is
private. EC2 instances use private compute subnets. The enrichment Lambda has no
workload VPC attachment and is not governed by those subnet routes.

### SOC 2 Alignment

- CC6.1 - Logical access to systems is restricted.
- CC6.6 - Network access is limited to authorized paths.

### Narrative

Private placement reduces direct workload exposure. Subnet names alone do not
create deny boundaries: review security groups, routes, endpoint policies,
resource/identity permissions, public ALB access, and actual traffic tests.
Three AZs do not prove three healthy application replicas or end-to-end isolation.
Use [networking validation](../../scripts/validation/validate-networking.sh)
and application-specific reachability evidence for the intended configuration.

---

## Controlled Egress

### Baseline Control

[Profile resolution](../../baseline/locals.tf) selects the effective mode when
`egress_mode = "auto"`:

| Mode | Private compute path |
|---|---|
| `network_firewall` | Same-AZ Network Firewall and NAT Gateway path |
| `nat_only` | NAT Gateway without Network Firewall inspection |
| `vpc_endpoints_only` | No general default internet route |

The [firewall](../../modules/firewall/main.tf) applies the configured domain
allowlist on the inspected path. Endpoints provide supported AWS-service paths.
The non-VPC enrichment Lambda is outside workload firewall routing.

### SOC 2 Alignment

- CC6.6 - Network access is restricted to authorized paths.
- CC6.7 - Transmission paths for sensitive data are protected.

### Narrative

These mechanisms contribute to selected network-path and data-movement controls.
They do not provide content-aware DLP, TLS payload inspection, application
transport configuration, or a universal prohibition on exfiltration. Record the
effective mode, approved domains, exact routing, necessary external destinations,
and allowed/denied traffic observations. NAT alone is not domain filtering.

---

## Private AWS Service Access

### Baseline Control

VPC endpoints are used where practical to provide private access to AWS services.

Common endpoints include:

- SSM
- SSM Messages
- SQS
- CloudWatch Logs
- KMS
- Secrets Manager
- EC2
- S3
- ECR API and Docker Registry
- GuardDuty data (`guardduty-data`) for Runtime Monitoring

The `guardduty-data` Interface Endpoint is Terraform-owned. Workload validation requires exactly one live endpoint for that service and requires its ID to match Terraform output. Protected ECS/Fargate tasks reach the shared Interface Endpoint security group over TCP/443 and use the S3 Gateway Endpoint for the S3/ECR layer path.

### SOC 2 Alignment

- CC6.6 - Network access is limited to authorized endpoints.
- CC6.7 - Data transmission is protected.

### Narrative

VPC endpoints reduce public-route dependence but do not replace service IAM,
resource policy, or application authorization. The endpoint resources do not
supply custom endpoint policy restrictions. Quarantined EC2 instances retain
TCP/443 access to the shared Interface Endpoint SG, not only SSM.

Use [endpoint validation](../../scripts/validation/validate-vpc-endpoints.sh)
for its exact topology checks and review effective API authorization separately.
A matching endpoint ID is not proof of every permitted API or a complete
transmission-protection control.

## S3 Public Access Prevention

### Baseline Control

The workload logs bucket uses public access blocks, bucket-policy controls,
KMS-backed default encryption, versioning, and lifecycle configuration.
**Object Lock is disabled**, and the bucket permits force destruction without
a Terraform destruction guard. See [storage](../../modules/storage/main.tf).

The [Config remediation](../../modules/security/config_baseline/remediations.tf)
can automatically apply bucket public-access blocking when Config is enabled,
independently of the S3 rule-family toggle.

### SOC 2 Alignment

- CC6.1 - Selected logical-access safeguards contribute to access protection.
- CC6.6 - Access to resources is restricted.
- CC6.7 - Resource access controls can support authorized information movement.

### Narrative

Public-access controls and storage confidentiality are distinct from immutable
retention. The remediation has no workload-name/tag scoping or human approval
integration and can affect intentionally public buckets. Review actual bucket
scope, policies, exceptions, and remediation outcomes; do not equate a Config rule
or a naming prefix with preventative coverage for every S3 resource.

---

# CC6 - CI/CD and Infrastructure Access Controls

## GitHub OIDC Federation

### Baseline Control

GitHub Actions authenticates to AWS using OIDC rather than long-lived AWS access keys. Workload accounts separate Plan, Apply, and Image Publisher IAM authorities. The Image Publisher role is trusted only from configured repository branches and is limited to ECR publication/query operations. The release/PR job has GitHub repository write permission but no AWS credentials or OIDC token.

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.2 - Credentials and privileges are managed.
- CC6.3 - Access is authorized according to role responsibilities.
- CC8.1 - Changes are subject to controlled, reviewable workflows.

### Narrative

Short-lived OIDC sessions reduce reliance on static AWS keys. The
[OIDC module](../../modules/github_oidc/main.tf) still grants Apply
`AdministratorAccess`; Plan combines `ReadOnlyAccess` with custom state-object
writes/deletes and selected secret/KMS permissions. Role separation does not
make every role least-privilege. Publisher ECR scope is the workload naming
prefix, not an IAM restriction to the selected application service.

Retain exact OIDC subjects and policies plus actual GitHub Environment reviewers,
branch restrictions, and repository protections. Those external protections are
not established merely by a workflow referencing an Environment.

## Separation of Plan and Apply Roles

### Baseline Control

Workload Terraform separates Plan and Apply roles. The standalone Terraform Plan workflow provides informational/review plans, while `Terraform Apply` creates its own saved binary plan, readable plan, metadata, and checksum before protected approval. The protected Apply job verifies and applies that exact artifact without replanning.

Application release adds another separation: `Deploy Application` publishes an image and creates a one-field digest release PR, but merge and Terraform Apply remain separate reviewed actions.

### SOC 2 Alignment

- CC6.3 - Privileged access follows role responsibilities.
- CC8.1 - Infrastructure changes are authorized, reviewed, and traceable.

### Narrative

The [Apply workflow](../../.github/workflows/terraform-apply.yml) preserves a
reviewable saved-plan boundary. Its checksum/metadata checks bind the artifact;
they are not an independent signature or proof of approval independence. The
standalone Plan run is not the artifact later applied.

Plan uses an Environment subject; Apply selects an Environment subject or branch
subjects rather than combining them as an AND restriction. Capture the actual
approval configuration, approving identity, artifact provenance, apply result,
and post-apply convergence. State, binary plans, and readable plan exports need
sensitive-data handling.

## Control Plane Account Stack Isolation

### Baseline Control

GitHub OIDC account stacks are separated from the baseline infrastructure they manage.

The control-plane account stack is generally treated as manual/local-only because it creates the roles GitHub Actions uses to access the control plane.

### SOC 2 Alignment

- CC6.1 - Access is restricted.
- CC6.2 - Privileged access is managed.
- CC8.1 - Changes to infrastructure are controlled.

### Narrative

Separate account and workload Terraform roots reduce the risk of deleting the
role used to execute workload changes; they do not make that impossible under
administrative credentials. Follow documented sequencing and inspect the full
plan. Workload retirement deliberately includes separately approved Identity
Center cleanup before final workload-destroy approval. Rejecting a later gate
does not reverse earlier cleanup. See the
[retirement runbook](../production-retirement.md).

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
- ECS service application logs
- ECS Container Insights performance logs when enabled

CloudTrail is configured to send logs to protected storage.

### SOC 2 Alignment

- CC7.2 - System activity is monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Security incidents are responded to.

### Narrative

The [logging module](../../modules/logging/main.tf) configures a multi-Region
management-event trail, not an organization trail or general data-event logging.
It archives CloudTrail and VPC Flow Logs; it does not automatically archive every
application, RDS, Lambda, or Container Insights log group to S3.

Collection supports monitoring, but does not itself perform human event
assessment, declare incidents, or respond to them. Retain actual delivery and
review records, timestamps, coverage exclusions, and tested alert routing.
A multi-Region trail is not a cross-Region workload recovery architecture.

---

## Centralized Log Protection

### Baseline Control

Logs use KMS encryption, S3 versioning, selected bucket policies, and lifecycle
rules. The workload logs bucket explicitly disables Object Lock and allows force
destruction without a Terraform destruction guard. CloudWatch retention is
caller/profile-resolved rather than universally fixed. See
[storage](../../modules/storage/main.tf) and [logging](../../modules/logging/main.tf).

ECS application and enabled Container Insights log groups have resource-backed
retention/key checks. Other validator paths permit warnings and are not complete
checks of every log resource, archival edge, or delivered object.

### SOC 2 Alignment

- CC6.7 - Cryptography is supporting context; assess actual transmission and movement controls separately.
- CC7.2 - Security-relevant activity is monitored.
- CC7.3 - Protected monitoring evidence can support evaluation of security events.

### Narrative

Encryption contributes to confidentiality and versioning aids recovery, but neither
establishes immutable retention or completed integrity verification. Configured
CloudTrail log-file validation is not an executed digest-chain check. The logging
validator does not validate Firehose archival or fresh S3 objects; delivery
warnings may coexist with PASS. Collect those observations and retain usable key
access for the evidence lifetime before accepting preservation claims.

---

## GuardDuty Threat Detection and Fargate Runtime Monitoring

### Baseline Control

GuardDuty is centrally governed from the `security-operations` delegated administrator account. Organization member enrollment and protection plans are managed centrally.

The managed Runtime Monitoring organization contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

For ECS/Fargate, workload Terraform expresses participation by deployment profile:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

Protected ECS task execution roles receive only the exact GuardDuty agent ECR image-pull scope in addition to their existing application repository permissions. Terraform does not define the GuardDuty agent in the application task definition; GuardDuty service-manages injection and telemetry.

Workload validation verifies one running GuardDuty agent on protected running tasks and requires GuardDuty ECS coverage to report `AUTO_MANAGED`, `HEALTHY`, and no unresolved issues. A workload EventBridge rule routes both Runtime Protection unhealthy and healthy ECS coverage-state changes to the existing SecOps notification path.

### SOC 2 Alignment

- CC7.1 - Threats and vulnerabilities are identified.
- CC7.2 - Security and system events are monitored.
- CC7.3 - Security events and monitoring conditions are evaluated.
- CC7.4 - Personnel can be notified when runtime coverage degrades.

### Narrative

Central GuardDuty administration provides consistent threat-detection policy across workload accounts and reduces account-level configuration drift. Fargate Runtime Monitoring extends detection into protected running containers without transferring the live agent lifecycle into Terraform.

The coverage-health notification path improves visibility when GuardDuty may be unable to receive runtime telemetry. This is a detective and notification control; automatic ECS/Fargate containment is not implemented.

**Evidence boundary:** A run with no deployable services or protected running
tasks cannot demonstrate live task instrumentation. Healthy coverage is a
point-in-time service report, not proof of no compromise. Actual task placement,
application health, per-resource coverage, and correlated notification receipt
need their own evidence. The coverage rule is account/regional ECS scoped rather
than an exclusive baseline-cluster filter. Consult the
[runtime reference](../ecs-runtime-design.md) and
[monitoring implementation](../../modules/monitoring/main.tf).

## Security Hub CSPM and Security Hub V2 Governance

### Baseline Control

The `security-operations` account centrally manages Security Hub CSPM finding aggregation and `CENTRAL` organization configuration. Workload accounts receive centrally associated configuration policies; the selected standards and exclusions are defined in the administrator configuration policies.

Security Hub V2 workload enablement is governed by an AWS Organizations `SECURITYHUB_POLICY` attached to the `Workloads` OU. The control plane owns the organization-level prerequisite and delegated-administrator boundary; the security-operations account owns the administrator-side policy.

### SOC 2 Alignment

- CC7.2 - Security events and control states are monitored.
- CC7.3 - Security events and configuration results are evaluated.
- CC7.4 - Findings support response activities.
- CC8.1 - Central policy reduces uncontrolled configuration divergence.

### Narrative

Centralized Security Hub governance creates a common findings and posture-management plane while keeping organization ownership separate from delegated security operations. Workload-local AWS Config remains necessary for controls that depend on Config recording.

**Boundary:** The [central root](../../bootstrap/security_operations/security_services/main.tf)
uses `NO_REGIONS` for CSPM aggregation. A local ownership flag does not prove
central enrollment succeeded. Validate organization prerequisites, intended
administrator/account relationships, configuration-policy associations, effective
policies, and workload prerequisites through their separate evidence layers.
Service enablement is not an audit conclusion or proof that all controls pass.

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

The [recorder](../../modules/security/config_baseline/main.tf) uses a fixed list
of ten resource types, including IAM types independently of the IAM rule flag.
KMS keys are absent from that list despite the enabled KMS rule family. Verify
actual rule applicability, evaluated resources, timestamps, and exceptions rather
than treating catalog presence as complete coverage.

`enable_config=false` leaves recorder/channel resources declared with recording
stopped. The workload security validator checks selected existence/status fields,
not complete recorder scope, catalog equality, rule compliance, or remediation
success. A Config PASS is not continuous control-effectiveness evidence.

---

## Inspector Vulnerability Detection

### Baseline Control

Amazon Inspector is enabled where configured to provide vulnerability scanning for supported resources.

### SOC 2 Alignment

- CC7.1 - Vulnerabilities and threats are identified.
- CC7.2 - Security events are monitored.
- CC7.3 - Findings are evaluated.

### Narrative

Enablement and selected resource-state checks support vulnerability management;
they do not prove per-resource coverage, clean scans, timely remediation, or
application security. ECR scanning is added to the effective resource set when
repositories exist; disabled Inspector validation does not prove service absence.
Review scan coverage/freshness, findings, triage, exceptions, and remediation
records against the [security implementation](../../modules/security/main.tf).

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

The [tamper rule](../../modules/security/tamper_detection/main.tf) detects a
selected flat set of API names across five service sources. It does not require
request success, identify whether a change was authorized, or prevent the change.
Coverage depends on CloudTrail/EventBridge emission, regional routing, SNS/KMS,
and recipients. Pattern tests are not end-to-end alert tests. Record original
API outcomes, correlated delivery, and investigation rather than treating every
alert as confirmed tampering or claiming monitoring cannot be silently degraded.

---

# CC7.4 - Incident Response Support

## Automated EC2 Isolation

### Baseline Control

The [automation rule and handler](../../modules/automation/main.tf) accept
eligible GuardDuty findings imported through Security Hub. The handler applies
configured severity, ACTIVE/NEW, instance-state, opt-in-tag, and already-isolated
gates. The default severity is CRITICAL.

The [handler](../../modules/automation/lambda/ec2_isolation.py) requests EBS
snapshots, changes security groups, then writes original-group/incident tags and
attempts notification. It does not wait for snapshot completion. A tagging failure
after the group change can leave partial containment without normal rollback
metadata. Processing exceptions can be caught and returned in counters rather
than causing a failed Lambda invocation.

### SOC 2 Alignment

- CC7.4 - Security incidents are responded to.
- CC7.5 - Selected mechanisms can support recovery after an identified security incident.

### Narrative

Isolation narrows networking but retains shared-endpoint HTTPS access and is not
a universal quarantine or credential-revocation mechanism. Eligibility gates are
code behavior, not tag conditions in the wildcard-resource EC2 IAM grant.
All supplied workload roots default `isolation_allowed` to true despite the
reusable module's false default. Require an explicit policy decision and approved
test target, independent original-group records, snapshot state, actual final
groups/tags, alert receipt, and reviewed recovery. A successful invocation or
empty DLQ does not establish successful containment.

---

## Controlled EC2 Rollback

### Baseline Control

The [rollback handler](../../modules/automation/lambda/ec2_rollback.py) uses the
saved original-security-group tag to restore groups, then writes release tags and
notifies SNS. It requires supplied instance, approver, and ticket fields but does
not authenticate the approver or validate the ticket. The event rule matches only
`source=custom.rollback`, not detail type.

The Identity Center caller now matches the prefixed workload bus, and the
resource policy explicitly denies `custom.rollback` publishers outside the
configured Operator role ARN patterns. The handler still sets
`IsolationAllowed=true` rather than restoring its previous value.

### SOC 2 Alignment

- CC7.4 - Security incidents are responded to.
- CC7.5 - Recovery activities require defined procedures and outcome evidence.
- CC6.3 - Access is aligned to role responsibilities.

### Narrative

The mechanism supports recovery through an Operator-restricted publisher
path, but does not prove that every recovery is human-approved or successful.
Retain actual submitter and approval evidence, the independent pre-isolation
group set, per-entry event acceptance, resulting exact group/tag state, and
notification receipt. Failures after mutation may require manual handling.
Effective access and human approval remain deployment-specific.

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

Enrichment supports triage, not incident classification or proof that a public
IP is malicious. The [handler](../../modules/automation/lambda/ip_enrichment.py)
sends indicators to an external provider, caches the secret in warm environments,
and may return ordinary payloads after handled errors. It does not inspect
Security Hub `UnprocessedFindings` before its success log. Disabling runtime
writeback does not remove the IAM grant.

Record provider/data-sharing approval, exact test inputs and outcome, correlated
SNS receipt, and before/after real-finding notes where explicitly authorized.
Use synthetic identifiers for non-writeback tests in the
[enrichment guide](../lambda_tests/ip_enrichment.md).

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
- ECS operational alarm transitions
- GuardDuty ECS Runtime Monitoring coverage unhealthy/healthy transitions

The GuardDuty coverage rule targets the existing SecOps SNS topic through the default EventBridge bus and uses the shared security-notification EventBridge DLQ, three retry attempts, and a 3600-second maximum event age.

### SOC 2 Alignment

- CC7.2 - Security events are monitored.
- CC7.3 - Security events are evaluated.
- CC7.4 - Personnel are notified of incidents and events.

### Narrative

Routing can support escalation but does not itself establish human receipt,
assessment, or response. [Monitoring](../../modules/monitoring/main.tf) provides
an EventBridge-to-SNS DLQ and a security-queue receive-count DLQ, not complete
subscriber-delivery coverage. No SNS subscription redrive or queue consumer is
supplied; unreceived messages can expire without redrive. DLQ alarms reuse the
same SNS topic and logs key, not an independent fallback.

Review recipients, confirmed subscriptions, actual delivery, queue age/retention,
consumer behavior, and incident records. ECS alarms treat missing data as
non-breaching and do not prove application availability or healthy minimum
capacity. The general SNS transformer represents only the first finding/resource,
not a complete event archive.

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

**Boundary:** Declared infrastructure is not continuous enforcement of every
property. EC2 security-group attachments and incident tags have deliberate drift
exceptions; AMI lookup can change a plan without a code change. Distinguish
`primary_region`, `state_region`, and backend coordinates. Require reviewed
configuration/lockfiles, actual plans and approvals, apply results, justified
exceptions, and convergence evidence.

---

## GitHub Actions Plan and Apply Workflows

### Baseline Control

Terraform changes are managed through source-controlled configuration and GitHub Actions. For workload application releases, `Deploy Application` resolves the authoritative ECR digest and a separate release job updates only the selected canonical service digest in `container-workloads.auto.tfvars.json`. The resulting pull request is reviewable before merge.

After merge, infrastructure deployment is a separate `Terraform Apply` run whose internal Plan job produces the exact saved artifact later verified/applied after protected approval. Image publication alone does not deploy infrastructure.

### SOC 2 Alignment

- CC8.1 - Changes are authorized, designed, tested, approved, and implemented in a controlled manner.

### Narrative

The release history, publication metadata, one-field digest PR, saved-plan metadata/checksum, protected approval, and post-deployment validation create a traceable technical evidence chain for application-runtime changes.

**Evidence boundary:** Retain the actual configured protection rules and approval
records. Neither source-controlled workflow YAML nor a checksummed artifact alone
proves independent human approval or that every deployed change used the workflow.
Document out-of-band changes, bootstrap actions, and emergency exceptions.

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

Selected rules support configuration evaluation, not universal prevention. The
[automatic S3 remediation](../../modules/security/config_baseline/remediations.tf)
follows `enable_config` even when the S3 catalog family is disabled, and is not
restricted by workload naming/tag boundaries. Review its target scope and impact
before deployment, retain evaluation/remediation records, and distinguish
configured automation from a successful, non-disruptive correction.

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

Selected configuration-change events can be surfaced for investigation. This is
detective routing, not prevention or a guarantee that an unauthorized change is
identified in time. Preserve independent records where loss of the monitored
CloudTrail, topic, key, or account could also impair notification. Pattern-only
checks do not prove live emission, delivery, or response.

---

## KMS Protection

### Baseline Control

Tamper detection alerts on actions affecting KMS keys.

Examples include:

- ScheduleKeyDeletion
- DisableKey
- Key policy changes

### SOC 2 Alignment

- CC6.7 - Cryptography is supporting context; assess actual transmission and movement controls separately.
- CC8.1 - Critical system changes are monitored.

### Narrative

Encryption and key-change visibility support data protection, but production
selection does not add workload-key destruction guards. The six keys in
[security](../../modules/security/main.tf) have rotation and deletion windows;
five explicitly allow Terraform destruction and the Lambda key has no guard.
Scheduling deletion makes a key unavailable for cryptographic operations while
pending. Preserve the keys and access paths required by retained data; a tamper
alert does not reverse deletion or establish recoverability.

---

# CC6.7 - Encryption and Data Protection

This section retains the document's encryption grouping. At-rest encryption is
only supporting evidence for selected access/data-protection objectives; it does
not by itself establish CC6.7 transmission, movement, or removal protections.
Assess actual data flows and controls against the authoritative criterion.

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

- CC6.7 - Data transmission and movement safeguards require separate evaluation; at-rest encryption is supporting context.

### Narrative

Review actual keys, grants, resource/identity policies, and retained-data
requirements. The [storage resource](../../modules/storage/main.tf) encrypts
RDS storage without an explicit database key input; do not identify it as the
logs or secret CMK. The [ALB](../../modules/application_load_balancer/main.tf)
terminates HTTPS but uses HTTP to task target groups. Application/database TLS,
authorized data movement, and tenant access are separate controls.

---

## Secrets Manager Protection

### Baseline Control

Secrets Manager holds threat-intelligence credentials and RDS master credentials
with KMS encryption. RDS generation uses ephemeral/write-only inputs in
[storage](../../modules/storage/main.tf); the AbuseIPDB secret uses an ordinary
secret-version value in [automation](../../modules/automation/main.tf).
These have different Terraform state/plan exposure characteristics.

### SOC 2 Alignment

- CC6.1 - Logical access is restricted.
- CC6.7 - Secret handling can support authorized information movement; at-rest storage alone is insufficient.

### Narrative

Secret storage is not universal absence of secrets from state, plans, local
backups, logs, or build environments. Review retrieval privileges, key access,
rotation/refresh procedures, artifacts, and the actual consumer identity.
Application credential rotation and secret use are not proven by resource
existence or a successful Secrets Manager metadata read.

---

## Protected Log Storage

### Baseline Control

Logs use KMS encryption, S3 versioning, selected bucket policies, and lifecycle
rules. The workload logs bucket explicitly disables Object Lock and allows force
destruction without a Terraform destruction guard. CloudWatch retention is
caller/profile-resolved rather than universally fixed. See
[storage](../../modules/storage/main.tf) and [logging](../../modules/logging/main.tf).

ECS application and enabled Container Insights log groups have resource-backed
retention/key checks. Other validator paths permit warnings and are not complete
checks of every log resource, archival edge, or delivered object.

### SOC 2 Alignment

- CC6.7 - Cryptography is supporting context; assess actual transmission and movement controls separately.
- CC7.2 - Monitoring information is retained.
- CC7.3 - Retained monitoring evidence can support security-event evaluation.

### Narrative

Treat retention, integrity verification, confidentiality, and continued
recoverability as separate acceptance questions. Neither a versioned bucket nor
lifecycle retention makes evidence immutable. Export required evidence before
approved destruction and preserve usable decryption keys and access; record
chain-of-custody and reviewer handling outside the generated summaries.

---

# Availability-Supporting Controls

SOC 2 Availability criteria are broader than this technical baseline, but some deployed controls support recoverability and operational resilience.

## AWS Backup

### Baseline Control

The baseline maintains a KMS-encrypted backup vault per workload environment and applies profile-aware scheduled-backup behavior.

When scheduled backup is enabled, Terraform creates a backup plan and tag-based selection, applies `Backup=true` to workload EC2/RDS resources, and uses the effective schedule and retention values.

When scheduled backup is disabled, the encrypted vault is retained, the effective schedule and retention are null, the backup plan/selection are absent, and workload EC2/RDS resources use `Backup=false`.

Defaults are:

```text
production  -> enabled by default, daily schedule, 30-day retention
development -> disabled
minimal     -> disabled
```

If backup is explicitly enabled for a non-production profile, retention defaults to 7 days unless overridden.

### SOC 2 Alignment

- Availability-supporting control
- Supports recoverability expectations

### Narrative

The [backup module](../../modules/backup/main.tf) can support recovery, but a
retained vault means it remains declared when scheduling is off, not that its
data and key can never be destroyed. Production defaults AWS Backup to enabled
but honors an explicit false override; that also disables profile-derived Restore
Testing. Separately, normal production retains RDS automated backups at deletion,
requires a final DB snapshot, and
keeps durable-vault/ECR force deletion disabled.

When production backups are enabled, Restore Testing is configured for the managed RDS instance using a
private Single-AZ temporary restore. Record four distinct outcomes: correct
configuration, actual restore execution, application/data validation, and
cleanup. [Backup validation](../../scripts/validation/validate-backup.sh) can
PASS with missing-job, application-validation, or cleanup warnings. The module
supplies no application-specific validation. A no-change plan and a configured
restore selection do not establish RPO/RTO or recovery from ransomware.

## Patch Management

### Baseline Control

The [patch module](../../modules/patch_management/main.tf) configures a tagged
SSM maintenance-window target and `AWS-RunPatchBaseline` Install operation with
`RebootIfNeeded`. It does not create a custom patch baseline, application health
gates, load-balancer draining, or a quarantine-exclusion filter.

### SOC 2 Alignment

- CC7.1 - Vulnerabilities are identified and addressed.
- CC7.2 - System conditions are monitored.

### Narrative

An Online SSM node, existing maintenance window, or zero reported failures alone
does not prove current patch coverage. Retain applicable baseline identity,
per-target execution and freshness, missing/failed patches, reboot status,
application recovery, and exceptions. Vulnerability triage and remediation
ownership remain organizational responsibilities.

## Production Availability and Controlled Retirement

[Baseline policy](../../baseline/locals.tf) uses three production AZs, enforces
an RDS Multi-AZ DB instance, and enables ECS AZ rebalancing. In normal operation, production deployable
services require at least two fixed tasks or an autoscaling minimum of two; this
is not a promise of one task per AZ. RDS-native 14-day backup retention is distinct
from AWS Backup. Live placement, task replacement, database failover, application
recovery, and measured recovery objectives require their own exercises.

[Production retirement](../production-retirement.md) uses a reviewed Stage-1
saved plan to quiesce ECS and relax selected deletion protections. Separate
approvals cover durable cleanup and Identity Center cleanup before final exact
workload destruction. Later rejection does not undo earlier cleanup, and durable
cleanup re-inventories rather than consuming a frozen-item manifest. The complete
workflow is `prod`-only. Preserve required data, evidence, and keys outside the
approved deletion scope; those operational decisions are not supplied by this
mapping.

---

# Evidence Examples

The following artifacts can support audit or customer due diligence discussions. Evidence should be reviewed as a package rather than treating any one validator as proof of the complete control environment.

## Generated Validation Evidence

```text
validation-results/control-plane/<timestamp>/
validation-results/security-operations/security-services/<timestamp>/
validation-results/<env>/bootstrap/<timestamp>/
validation-results/<env>/baseline/<timestamp>/
```

Useful generated artifacts include `summary.md`, `summary.json`, and the supporting validation logs. Current workload baseline evidence includes `validate-security-workload.log`; centralized-security evidence includes `validate-security-operations.log`.

Generated summaries count child-script exit results, not all assertions. Review
warnings and skipped/empty branches, including Config scope, logging delivery,
notification receipt, and Restore Testing. The baseline exporter reruns the
scripts; it does not merely package an earlier run. Its summary does not
automatically record all deployment commits, digests, input sets, or a signed
evidence chain. Add provenance and reviewer acceptance explicitly using the
[evidence guide](validation-evidence-guide.md).

## Terraform / CI/CD Evidence

```text
application image-publication metadata and authoritative ECR digest
release PR showing the selected one-field image_digest change
Terraform plans and apply logs
GitHub Actions workflow history
GitHub OIDC role and trust-policy configuration
Terraform state backend and native-locking configuration
AWS Organizations / Identity Center Terraform state
security_operations/security_services Terraform state
```

## AWS Evidence

```text
CloudTrail settings, fresh delivery, digest-verification results where performed, and actual log retention/key access
AWS Config recorder/rule state
Security Hub CSPM central configuration and policy associations
Security Hub finding aggregator
Security Hub V2 effective workload policies
GuardDuty detector, organization enrollment, exact Runtime Monitoring organization feature state, ECS cluster enrollment, live agent/coverage state, and coverage-health notification configuration
Inspector account/resource status
KMS aliases and policies
VPC endpoint placement, including guardduty-data
Backup scope/jobs, Restore Testing execution/application validation/cleanup, RDS lifecycle and failover evidence, retained key access, and per-target patch results
```

## Identity / Response Evidence

```text
IAM Identity Center groups, permission sets, and account assignments
SecOps-Administrator assignment for security-operations
AWSReservedSSO role assumptions in CloudTrail
Break-glass role events
EC2 isolation / rollback test evidence
IP enrichment evidence
Tamper alerts and SNS notifications
```

## Evidence and Responsibility Matrix

| Area | Implementation authority | Evidence still required for acceptance |
|---|---|---|
| Identity and CI/CD | [OIDC](../../modules/github_oidc/main.tf), [Identity Center](../../modules/identity_center/main.tf) | Actual grants/subjects, assignment principals and membership, approvals/removal, negative access tests, risk disposition for broad grants and bus mismatch |
| Network and transport | [Baseline](../../baseline/main.tf), [security policy](../../modules/networking/security_policy/main.tf) | Exact routing/SG state, intended ingress/egress observations, application/database TLS, cross-account and tenant boundaries |
| Logs and records | [Logging](../../modules/logging/main.tf), [storage](../../modules/storage/main.tf) | Fresh delivery and archival, performed integrity verification, retention/deletion decisions, usable key access, evidence custody |
| Detection and notification | [Monitoring](../../modules/monitoring/main.tf), [Config](../../modules/security/config_baseline/main.tf) | Actual evaluated resources and timestamps, coverage/queue-age review, correlated alert receipt, triage and response records |
| Response | [Handlers](../../modules/automation/lambda/) | Approved target and caller, independent pre-state, partial-failure handling, observed containment/recovery, notification and follow-up records |
| Recovery and maintenance | [Backup](../../modules/backup/main.tf), [patching](../../modules/patch_management/main.tf) | Restore execution, data validation, cleanup, measured objectives, per-target patches/reboots and application recovery |

A named owner must resolve discrepancies or document a risk decision within the
agreed control program. This table does not assert that such decisions or
operating evidence already exist.

---

# Control Coverage Summary

| Control Area | Baseline Support |
|-------------|------------------|
| Logical access | Identity Center and OIDC resources; broad grants and Operator authorization require explicit review |
| Network access | Private subnets, security groups, Network Firewall, VPC endpoints |
| CI/CD access | OIDC roles, plan/apply separation, GitHub environments |
| Logging | CloudTrail, Config, VPC Flow Logs, CloudWatch Logs |
| Monitoring | GuardDuty, Fargate Runtime Monitoring and coverage health, Security Hub, Config, Inspector |
| Tamper detection | EventBridge alerts for security service modification |
| Incident response | EC2 isolation, rollback workflow, SNS alerts |
| Data protection | KMS encryption, protected S3 logs, Secrets Manager |
| Change management | Terraform, GitHub workflows, Config monitoring |
| Recovery | Production RDS/ECS resilience, AWS Backup/Restore Testing configuration, and controlled retirement; behavioral and operating evidence required |

---

# Assurance Position

`tf-secure-baseline` implements infrastructure-level controls that support SOC 2 readiness by helping organizations:

- Restrict system access
- Reduce public exposure
- Protect CI/CD access
- Centralize identity
- Configure monitoring, with actual coverage and continuing operation separately evidenced
- Detect security-relevant events and monitoring-coverage degradation
- Support incident containment
- Evaluate selected configuration conditions and reviewed changes
- Protect operational data through encryption
- Support evidence collection subject to mutable-retention and key-lifecycle limits
- Support recovery readiness

These mechanisms provide candidate supporting evidence for selected SOC 2 Security criteria, especially CC6, CC7, and CC8; the associations require assessment for the actual system and examination scope.

This baseline should be considered an enabling technical foundation within a broader compliance program.

It does not guarantee SOC 2 compliance or audit success without supporting organizational controls, policies, procedures, evidence management, and operational review.
