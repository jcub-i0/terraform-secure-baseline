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
- Centralized control plane for organization structure and identity
- Dedicated security-operations delegated administrator account
- IAM Identity Center access
- GitHub OIDC-based CI/CD
- Private-first networking
- Centralized logging
- Centrally governed Security Hub CSPM, GuardDuty, and Security Hub V2 for workload accounts
- Profile-driven GuardDuty ECS/Fargate Runtime Monitoring with workload-local enrollment, resource-scoped prerequisites, and coverage-health notification
- Workload-local AWS Config, Inspector, remediation, and supporting security controls
- Event-driven security automation
- Encrypted operational telemetry with explicit retention and destruction limits

The controls described below are infrastructure-level controls. They should be paired with organizational policies, application security controls, risk management, incident response procedures, and human review processes.

---

## Reading These Narratives

**Control Intent** describes the desired outcome. **Implementation** describes
repository behavior, not a certification or a result for a particular deployment.
**Security Impact** describes the contribution that behavior can make when it is
correctly configured, operated, and reviewed.

| Evidence level | What it establishes | What it does not establish |
|---|---|---|
| Source configuration | Resources, inputs, policies, and workflow logic declared in the repository | That they were applied or are effective in a customer account |
| Point-in-time validation | The assertions actually executed against a named account, Region, and deployment | All possible settings, skipped branches, transactions, or continuing effectiveness |
| Recorded behavioral exercise | The selected operation and observed outcome, including failures and cleanup | Every workload, failure mode, or recovery objective |
| Operating evidence | Dated records and owner review for an agreed scope and period | A certification conclusion from this repository alone |

Record deployment and validation commits separately, the effective inputs and
image digests, execution time, account/Region, warnings, exclusions, and evidence
location. Prior exercises retain their original provenance; a subsequent
configuration check does not retroactively rerun them. Use the
[evidence guide](validation-evidence-guide.md) and
[report template](validation-report-template.md) to record acceptance separately
from generated script results. The baseline runner counts successful exits of
its 16 child scripts; it does not count every assertion or convert warnings into
successful behavioral tests.

---

# Account and Environment Segmentation

## Control Intent

Separate governance, centralized security administration, and workload environments to reduce blast radius and prevent non-production activity from affecting production systems.

## Implementation

The baseline uses separate AWS accounts for:

```text
control-plane
security-operations
dev
staging
prod
```

The AWS Organizations structure separates workload and centralized-security responsibilities:

```text
Root
├── Workloads
│   ├── NonProd -> dev, staging
│   └── Prod    -> prod
└── Security    -> security-operations
```

The control-plane account owns organization structure, centralized identity, control-plane state, and organization-level prerequisites. The `security-operations` account acts as delegated administrator for centralized security services. Workload accounts host environment-specific infrastructure and workload-local controls.

## Security Impact

This supports:

- Environment isolation
- Reduced blast radius
- Separation of management and delegated security administration
- Cleaner access boundaries
- Safer experimentation in non-production
- More controlled production access
- Improved auditability of environment-specific activity

**Implementation and evidence:** Review the
[Organizations root](../../bootstrap/control_plane/organizations/main.tf) and
[control-plane validator](../../scripts/validation/validate-control-plane.sh).
Record actual account IDs, OU placement, trusted-service access, and delegated
administrators. Account and state separation do not prohibit every cross-account
role or resource-policy grant, and the repository does not supply a complete
Service Control Policy strategy.

---

# Control Plane Separation

## Control Intent

Prevent foundational organization, identity, and state resources from being accidentally modified or destroyed by workload infrastructure changes.

## Implementation

Control-plane resources are deployed separately in:

```text
bootstrap/control_plane/state
bootstrap/control_plane/account
bootstrap/control_plane/organizations
bootstrap/control_plane/identity_center
```

The control plane owns AWS Organizations topology and the management-account prerequisites required for delegated security administration. It does not own the delegated administrator's Security Hub CSPM, GuardDuty, or Security Hub V2 configuration.

## Security Impact

This separation helps prevent workload changes from affecting centralized identity, organization structure, or control-plane access and reduces the chance of CI/CD lockout or cross-stack failures.

**Boundary:** Separate Terraform roots reduce lifecycle coupling; they are not
an IAM deny boundary. The workload Destroy workflow includes separately approved
Identity Center cleanup before final workload-destroy approval. Review that
intentional cross-stack operation in the
[retirement runbook](../production-retirement.md); rejecting a later gate does
not reverse earlier authorized cleanup.

---

# Centralized Security Administration

## Control Intent

Apply consistent threat-detection and posture-governance policy across workload accounts while separating organization ownership from delegated security-service administration.

## Implementation

The dedicated `security-operations` account centrally manages:

- Security Hub CSPM administrator state and finding aggregation;
- Security Hub CSPM `CENTRAL` organization configuration;
- workload configuration policies and associations;
- GuardDuty organization enrollment and protection plans;
- GuardDuty Runtime Monitoring organization policy; and
- Security Hub V2 administrator state and the `SECURITYHUB_POLICY` attached to `Workloads`.

The managed GuardDuty Runtime Monitoring organization contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

The control-plane Organizations stack owns trusted service access, delegated-administrator registration, the `SECURITYHUB_POLICY` organization prerequisite, and OU/account placement. Workload Terraform defers account-level ownership of centrally governed Security Hub CSPM, GuardDuty, and Security Hub V2 resources while continuing to manage AWS Config, Inspector, remediation, and other workload-local controls.

For ECS/Fargate, central GuardDuty policy and workload Terraform have separate responsibilities. The central stack enables automated Fargate agent management across organization members. Workload Terraform expresses whether its shared ECS cluster participates through `GuardDutyManaged=true` for `production` and `development` or `GuardDutyManaged=false` for `minimal`, and owns the supporting task-execution IAM, networking, and validation contract.

## Security Impact

This supports:

- Consistent security-service policy across dev, staging, and prod;
- Secure-by-default Fargate Runtime Monitoring for production and development;
- Reduced account-level configuration drift;
- Separation of organization governance from security operations;
- Central finding visibility and delegated administration; and
- Explicit evidence boundaries between organization, central security, and workload state.

**Implementation and evidence:** The
[central service root](../../bootstrap/security_operations/security_services/main.tf)
and its [validator](../../scripts/validation/validate-security-operations.sh)
are separate from workload validation. The CSPM aggregator uses `NO_REGIONS`;
regional finding aggregation is not cross-Region recovery. Administrator service
resources and detector discovery are not all removed by disabling organization
rollout flags. The root's `check` assertions are not blocking account safeguards;
verify caller identity independently. Local-ownership flags suppress local
resources, not prove that central policy has successfully reached each workload.

# Terraform State Protection

## Control Intent

Protect Terraform state because it contains sensitive infrastructure metadata and controls how infrastructure changes are applied.

## Implementation

The baseline uses dedicated state resources per account/environment, including:

- S3 buckets for Terraform state
- customer-managed KMS encryption
- S3 native lockfiles with `use_lockfile = true`
- restricted bucket administration
- distinct state object keys per Terraform root
- bucket versioning and public-access protections

Each `state` substack follows a two-phase lifecycle: it is applied locally first to create its state bucket and CMK, then `scripts/bootstrap/migrate-state-stack.sh` migrates that stack into the protected S3 backend it created. Strict deployment/client evidence can require the remote state object to exist, be readable, and support `terraform state pull`.

## Security Impact

This supports:

- Controlled infrastructure change management
- Reduced risk of state corruption
- Reduced blast radius between stacks
- Encrypted state storage
- Protection against unauthorized backend modification

**Implementation and evidence:** Review the
[state module](../../modules/state/main.tf), backend coordinates, the
[migration helper](../../scripts/bootstrap/migrate-state-stack.sh), and strict
bootstrap evidence. Keep service `primary_region`, state-resource `state_region`,
and backend `region` distinct. Locking coordinates Terraform operations; it does
not authorize a change or prevent a separately authorized direct S3 write.
State, local backups, saved plans, and JSON exports can contain sensitive values.
Plan-role custom permissions include state-object writes/deletes across the
configured bucket, not only lockfiles. Migrating a state root away from its own
bucket does not remove the state resources' literal destruction guards.

---

# CI/CD Access Control

## Control Intent

Use short-lived CI/CD identities, review their actual privileges, and preserve separation between planning, infrastructure application, image publication, and source-control release mutation.

## Implementation

GitHub Actions authenticates to AWS using OIDC rather than long-lived access keys. Workload accounts separate Plan and Apply roles and may also enable a dedicated branch-trusted Image Publisher role whose AWS permissions are limited to the Terraform-defined ECR publication/query contract.

Application publication further separates authority at the job level: the publisher job receives AWS OIDC authority and repository read access, while the release/PR job receives repository write permissions but no AWS credentials or OIDC token. The release job updates only the selected `ecs_services.<service>.image_digest` in tracked workload configuration; it does not change service scaling configuration.

Workload infrastructure deployment remains plan-before-approval. `terraform-apply.yml` creates its own saved binary plan, readable plan, metadata, and checksum before protected approval; the Apply job verifies and applies that exact artifact without replanning. The standalone Terraform Plan workflow is informational and is not the source of the Apply artifact.

Workload bootstrap validation can also verify the enabled Image Publisher role's exact branch-based trust, ECR action set, repository scope, and absence of unexpected state, ECS, IAM, or general administrative authority.

## Security Impact

This model reduces exposure to static credentials, limits the blast radius of any one CI job, preserves a reviewable chain from image digest to release PR to exact Terraform plan, and supports separation of duties between artifact publication and infrastructure deployment.

**Privilege and approval limits:** The
[OIDC module](../../modules/github_oidc/main.tf) attaches `ReadOnlyAccess` plus a
custom state/secret policy to Plan and `AdministratorAccess` to Apply. Apply is
not a least-privilege role, and Plan is not strictly read-only. The Image
Publisher's repository prefix is not an IAM restriction to the one service
selected in a workflow.

Plan trusts the configured GitHub Environment subject. Apply selects an
Environment subject or configured branch subjects; those are not combined as an
AND condition. Required reviewers, deployment-branch restrictions, and repository
protections need their own administrative configuration and evidence. A checksum
binds plan bytes to expected metadata; it is not an independent signature or
proof of reviewer independence. Retain actual approvals and protect the binary
plan, its readable representation, and metadata as sensitive artifacts.

The [publication script](../../scripts/deployment/deploy-application.sh) uses an
ECR credential helper with temporary push configuration and token-file caching
disabled. This narrows local persistence, not all credential exposure on a
compromised runner. See the [deployment reference](../../scripts/deployment/README.md).

# Human Access Management

## Control Intent

Provide centralized, role-based human access to AWS accounts.

## Implementation

The [Identity Center caller](../../bootstrap/control_plane/identity_center/main.tf)
uses the [persona module](../../modules/identity_center/main.tf) to discover an
existing Identity Center instance and create configured groups, permission sets,
policy attachments, and account assignments. It does not create human users,
manage group membership, or configure the upstream identity provider's MFA.

Example workload **group names** are:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
```

Permission-set names are distinct, for example `SecOps-Operator-dev` and
`SecOps-Administrator-secops`. The central security account requires
the administrative persona and disables Operator. Analyst and Engineer are
optional; Engineer includes wildcard-resource response actions, and Administrator
attaches `AdministratorAccess`.

Operator's inline policy omits direct EC2 mutation and Lambda invocation, but the
caller constructs an unprefixed `event-bus/secops-bus` ARN while automation creates
`event-bus/<name_prefix>-secops-bus`. The bus's rollback resource-policy statement
also uses a wildcard principal and a source condition, not an Operator allowlist.
These are unresolved authorization boundaries, not evidence of enforced
Operator-only recovery. Review identity and resource policies together.

The control-plane validator checks groups, output-backed permission sets, and
assignment presence. It does not compare each assignment principal to the created
group or inspect full policies and group membership. Retain actual grants,
assignment principals, membership, access reviews, and approved positive/negative
access tests before accepting the access-control claim.

## Security Impact

This supports:

- Centralized human access management
- Environment-specific access boundaries
- Reviewable persona-specific grants, including explicitly privileged personas
- Reduced reliance on IAM users
- Better auditability of human access

---

# Break-Glass Access Monitoring

## Control Intent

Provide emergency administrative access while ensuring that use of that access is visible.

## Implementation

The [break-glass role](../../modules/iam/break_glass.tf) trusts the supplied
principals with an MFA condition and attaches `AdministratorAccess`. The deploying
organization supplies and secures the emergency identity; the module does not
create that identity, authenticate a ticket, or technically limit use to emergencies.

The [monitoring rule](../../modules/monitoring/main.tf) matches CloudTrail
`AssumeRole` requests for the role ARN and targets SecOps SNS. It does not require
a successful assumption. Inspect the original API outcome, not only the alert's
wording. Capture an authorized exercise, caller identity, MFA/trust configuration,
notification receipt, and subsequent access review. Event routing is not a
guarantee that a person receives or acts on an alert.

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

The [baseline](../../baseline/main.tf) derives a seven-family VPC topology from
its canonical `/16` CIDR and selected standard Availability Zones. Production
defaults to three AZs; other profiles default to two. The families are
`ingress_public`, `egress_public`, `compute_private`, `data_private`,
`serverless_private`, `endpoint_private`, and `firewall_private`.

The public ingress family hosts the optional internet-facing ALB; the public
egress family hosts NAT Gateways. Their route-table roles remain separate so
inspected compute egress can use AZ-local firewall/NAT paths without redirecting
the ALB's VPC-local path to tasks.

ECS tasks use private compute subnets without public task IPs. The RDS DB instance
is private. Standalone EC2 instances are created per compute-subnet map entry;
they are not an Auto Scaling Group. IP enrichment is deliberately not attached
to this VPC, so private-workload statements do not apply to every Lambda.

Review [network resources](../../modules/networking/main.tf),
[traffic rules](../../modules/networking/security_policy/main.tf), and exact
[topology validation](../../scripts/validation/validate-networking.sh).
Separate subnet names alone do not establish the complete allowed-traffic set.

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

Outbound traffic from private workloads follows one of three explicit egress modes:

| Effective mode | Internet path |
|---|---|
| `network_firewall` | Private compute -> AWS Network Firewall -> NAT Gateway -> Internet Gateway |
| `nat_only` | Private compute -> NAT Gateway -> Internet Gateway |
| `vpc_endpoints_only` | No default internet route; supported AWS service access uses VPC endpoints |

When `egress_mode = "auto"`, the deployment profile selects the effective mode. Network Firewall therefore represents the strongest inspected path, not an unconditional dependency for every workload environment.

AWS service access uses VPC endpoints where available, reducing dependence on public internet routes.

## Security Impact

This supports:

- Centralized outbound traffic inspection
- Reduced unmonitored internet access
- Better control over external communication
- Improved security posture for workloads handling sensitive data

**Scope and evidence:** The [firewall module](../../modules/firewall/main.tf)
implements the configured domain allowlist on the inspected compute path. The
resolved list combines platform-required domains with the caller's additions;
it is not an arbitrary-content DLP system or end-to-end TLS inspection. Verify
actual same-AZ routes and allowed/denied destinations in the selected mode.
`nat_only` has no Network Firewall inspection. IP enrichment runs outside the
workload VPC and does not use its NAT or firewall. Neither endpoint presence nor
an egress mode proves every sensitive data flow is restricted.

---

# Private AWS Service Access

## Control Intent

Reduce reliance on public internet paths for AWS service communication.

## Implementation

The baseline deploys VPC endpoints for AWS services used by workloads and automation.

The current endpoint set includes private connectivity for services such as:

- STS
- Systems Manager and SSM Messages
- SQS and SNS
- CloudWatch Logs
- KMS
- Secrets Manager
- EC2
- AWS Config
- EventBridge
- Security Hub
- Lambda
- Amazon ECR API (`ecr.api`)
- Amazon ECR Docker Registry (`ecr.dkr`)
- GuardDuty data (`guardduty-data`) for Runtime Monitoring
- S3 through a Gateway Endpoint

The `guardduty-data` Interface Endpoint is Terraform-owned and is reused by eligible Runtime Monitoring workloads rather than being left for GuardDuty to create opportunistically. Workload validation requires exactly one live `guardduty-data` endpoint and requires its VPC Endpoint ID to match Terraform output.

For ECS/Fargate, task security groups reach the shared Interface Endpoint security group over TCP/443 and use the Terraform-owned S3 Gateway Endpoint for the S3/ECR layer path. Application image pulls use `ecr.api`, `ecr.dkr`, and S3; GuardDuty Runtime Monitoring telemetry uses `guardduty-data`.

## Security Impact

This supports:

- Private connectivity to AWS services;
- Reduced public internet dependency;
- Improved management access for private workloads;
- Deterministic ownership of Runtime Monitoring networking; and
- Better alignment with private-by-default architecture.

**Authorization boundary:** The [endpoint resources](../../modules/vpc_endpoints/main.tf)
do not supply custom endpoint policy documents. Security-group connectivity,
endpoint/service policies, IAM authority, and KMS permissions must be assessed
separately. Quarantine retains TCP/443 to the shared Interface Endpoint SG; it
is neither complete network disconnection nor an SSM-only destination set.

# Secure ECS/Fargate Runtime and Runtime Security

## Control Intent

Provide a private, digest-selected, observable application runtime while preserving explicit ownership of service capacity, deployment health, runtime-detection prerequisites, and operational alerting.

## Implementation

ECS/Fargate is the preferred modern application runtime and uses one canonical `ecs_services` map. A service may remain registered with `image_digest = null`; its required ECR repository can exist while per-service ECS runtime resources remain absent until an immutable digest is selected.

Deployable services use:

- digest-pinned ECR images;
- Fargate with `awsvpc` networking in compute-private subnets;
- no public task IP;
- separate task execution and application task IAM roles;
- per-service task security groups;
- Terraform-owned KMS-encrypted application log groups;
- deployment circuit breaking with rollback; and
- optional shared HTTPS ALB ingress.

Service-capacity ownership is explicit. When `scaling = null`, Terraform owns the ECS service `desired_count`. When scaling is configured, the configured `desired_count` is bootstrap capacity and Application Auto Scaling owns subsequent live desired count within the Terraform-defined minimum and maximum bounds. The current scaling policies use target tracking for CPU, memory, and optional `ALBRequestCountPerTarget`; ALB request scaling requires ingress and uses resource labels derived from Terraform-owned ALB and target-group identities.

Deployment-health configuration is explicit through minimum healthy percentage,
maximum percentage, and health-check grace period. Normal production deployable
services require at least two fixed tasks or an autoscaling minimum of two, and
explicit AZ rebalancing. A three-AZ VPC does not prove three running tasks or one
task per AZ. Capture live placement and ALB target health separately. Runtime
validation's normal production deployment-health requirement is 100 minimum
healthy percent and at least 200 maximum percent.

The ALB terminates HTTPS; its task target groups and health checks use HTTP.
Digest pinning selects exact image content but does not establish signature
verification, absence of vulnerabilities, read-only container filesystems, or
application transaction correctness. Application task roles start without
application policies; task-startup secret access belongs to the execution role.

Terraform-owned operational alarms are separate from AWS-managed target-tracking alarms. The monitoring module creates:

- an ECS task-deficit alarm based on `DesiredTaskCount - RunningTaskCount` when Container Insights is enabled; and
- an unhealthy-target alarm for ingress-enabled ECS services.

Both operational alarm families route alarm and recovery notifications to the SecOps SNS topic.

### GuardDuty Fargate Runtime Monitoring

Deployment-profile-driven GuardDuty Runtime Monitoring uses the same ECS runtime without a second application-service inventory.

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

For protected profiles, the ECS task execution role receives only the additional image-pull scope required for the regional AWS-hosted repository:

```text
repository/aws-guardduty-agent-fargate
```

The permitted actions are limited to `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchGetImage`; registry authorization remains the existing `ecr:GetAuthorizationToken` grant.

Terraform intentionally keeps the canonical task definition application-only. GuardDuty service-manages runtime-agent injection, upgrades, and telemetry. Live tasks may report the agent as `aws-gd-agent` or an AWS-generated `aws-guardduty-agent-<suffix>` container.

For protected running tasks, workload validation requires exactly one injected GuardDuty agent in `RUNNING` state while the application container remains valid. GuardDuty coverage must identify the expected ECS cluster and report:

```text
ManagementType = AUTO_MANAGED
CoverageStatus = HEALTHY
Issues         = none
```

For `minimal`, healthy coverage and an injected agent are not required; if a coverage record exists, its Fargate management type must be `DISABLED`.

The monitoring module also routes both `GuardDuty Runtime Protection Unhealthy` and `GuardDuty Runtime Protection Healthy` ECS coverage-state events to the existing SecOps SNS topic through the default EventBridge bus. The target uses the shared EventBridge security-notification DLQ, three retry attempts, and a 3600-second maximum event age.

Automatic ECS/Fargate task containment is **not implemented**. Runtime Monitoring provides detection and coverage visibility; the existing automatic containment implementation remains EC2-specific.

## Security Impact

This supports:

- private workload placement and reduced public exposure;
- immutable application release selection;
- separate task-startup and application identity authority;
- deterministic scaling ownership without Terraform fighting legitimate autoscaling;
- controlled deployment-health behavior;
- timely detection of sustained task deficits and unhealthy ingress targets;
- runtime threat-detection coverage for protected Fargate tasks;
- visibility when GuardDuty runtime coverage degrades or recovers; and
- auditable runtime validation through resource-backed Terraform outputs and live AWS state.

**Evidence boundary:** Inspect the [ECS resources](../../modules/ecs_service/main.tf)
and [runtime validator](../../scripts/validation/validate-ecs-runtime.sh).
An empty deployable-service map or an unexercised branch does not prove live agent
injection, ALB health, application/database access, or replacement behavior.
`UNKNOWN` application-container health is distinct from a healthy ALB target.
The operational alarms use nonbreaching missing-data treatment; no alarm is not
proof of running capacity or continuing telemetry. Preserve task/cluster identity,
image digest, timestamps, warning branches, and application acceptance evidence.

# Logging Integrity

## Control Intent

Ensure that security-relevant activity is captured and protected from tampering.

## Implementation

The [logging module](../../modules/logging/main.tf) configures an account-level
multi-Region CloudTrail for read/write management events, CloudWatch delivery,
S3 delivery, Insights, and log-file validation. It does not configure an
organization trail or data-resource selectors. VPC Flow Logs record flow
metadata, not packet payloads, and use a CloudWatch-to-Firehose-to-S3 path.

Other modules create Config records, Lambda logs, RDS exports, ECS service logs,
and Container Insights logs. They do not all share one automatic archival path.
The workload's centralized logs bucket is local to that workload account, not
an independently administered organization-wide log archive.

[Storage](../../modules/storage/main.tf) configures KMS encryption, public-access
blocks, versioning, and lifecycle transitions, but **Object Lock is disabled**,
`force_destroy=true`, and `prevent_destroy=false`. Lifecycle expiration is not
immutable retention or a legal hold. Workload KMS keys also lack production
destruction guards; retained ciphertext alone is not recoverability.

The [logging validator](../../scripts/validation/validate-logging.sh) permits
selected delivery/retention warnings and does not verify Firehose archival or a
CloudTrail digest chain. ECS runtime validation compares the exact logs CMK and
effective retention for its own managed log groups. Retain fresh delivery samples,
selected object/key metadata, integrity-verification results where required,
reader/deletion permissions, and an independently approved preservation plan.

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

Detect suspicious activity, vulnerabilities, configuration problems, and runtime-monitoring coverage degradation across workload accounts while preserving a centralized governance boundary.

## Implementation

The baseline combines centrally governed and workload-local services:

- GuardDuty is organization-enrolled and centrally configured from `security-operations`.
- GuardDuty Runtime Monitoring is centrally enabled with EC2 and ECS/Fargate automated agent management, while EKS add-on management remains disabled.
- Workload ECS cluster participation follows `deployment_profile` through `GuardDutyManaged=true|false`.
- Security Hub CSPM uses centralized configuration policies and finding aggregation.
- Security Hub V2 workload enablement is governed through an Organizations policy attached to `Workloads`.
- AWS Config remains workload-local and provides configuration recording/rule evaluation where enabled.
- Inspector remains workload-local and provides vulnerability detection for configured resource types.
- CloudTrail, EventBridge, CloudWatch, and SNS provide activity capture, routing, and alerting.
- GuardDuty ECS Runtime coverage unhealthy/healthy events route to the existing SecOps notification path.
- Terraform-owned ECS task-deficit and ingress unhealthy-target alarms provide operational runtime signals, while AWS-managed target-tracking alarms remain owned by Application Auto Scaling.

The security-operations validator compares the Terraform-managed GuardDuty organization feature subset exactly with live AWS. AWS may return supported features outside Terraform management; those are acceptable only while they remain disabled.

## Security Impact

This supports:

- Centralized visibility into workload security findings;
- Consistent threat-detection and posture policy;
- Runtime threat-detection coverage for protected Fargate workloads;
- Detection of runtime-coverage degradation;
- Workload-specific configuration and vulnerability evidence;
- Event-driven response and alerting; and
- Reduced drift between workload accounts.

**Coverage and evidence:** Account-level service enablement is not per-resource
coverage. The [workload security validator](../../scripts/validation/validate-security-workload.sh)
checks selected active services and relationships; its Config checks do not
compare the full recorder scope, rule catalog, or compliance outcomes. Disabled
Inspector/Config branches are skipped, not proof of live absence. Record the
applied ownership flags, central associations, resource coverage, finding ages,
exceptions, and human disposition.

[Security Hub insights](../../modules/security_dashboard/main.tf) are saved views.
Their environment suffix labels the insight, not a finding filter. An empty view
may reflect missing ingestion or filter scope rather than a clean environment.

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
- Selected CloudTrail and Config delivery-setting APIs

Tamper events are detected through CloudTrail/EventBridge and routed to SNS.

## Security Impact

This can surface selected administrative changes if the source telemetry and
notification path remain available. It does not ensure that monitoring cannot
be silently degraded.

It supports:

- Monitoring continuity
- Alerting on suspicious administrative activity
- Detection of defense evasion behavior
- Increased confidence in security telemetry

**Implementation and evidence:** The [tamper pattern](../../modules/security/tamper_detection/main.tf)
lists selected CloudTrail, GuardDuty, Security Hub, KMS, and Config actions on the
regional default bus. It does not prove success, intent, approval, or complete
coverage of every way to alter monitoring. A non-publishing pattern test proves
only matching; inspect original outcomes and independently test delivery.
The same SNS topic and logs key support ordinary alerts and DLQ alarms, so their
failure is not covered by an independent notification channel.

---

# Automated EC2 Isolation

## Control Intent

Contain potentially compromised EC2 instances quickly when high-severity findings occur.

## Implementation

The EC2 Isolation EventBridge rule is intentionally narrower than the baseline's general Security Hub notification/enrichment path. It accepts imported Security Hub findings only when the finding is from the GuardDuty product, severity is `HIGH` or `CRITICAL`, the resource type is `AwsEc2Instance`, workflow status is `NEW`, and record state is `ACTIVE`.

The Lambda independently revalidates the GuardDuty product ARN, workflow status, record state, resource type, and configured automatic-isolation severity. `ec2_auto_isolation_severities` defaults to `CRITICAL` and is limited by the baseline contract to `HIGH` and/or `CRITICAL`. Missing `ProductArn`, missing `RecordState`, unsupported severity, or other ineligible finding state fails closed.

Before quarantine, the Lambda also requires a valid running or stopped EC2 instance with `IsolationAllowed=true`, skips duplicate or already-isolated instances, and requests tagged snapshots for attached EBS volumes. Any snapshot API failure prevents the security-group change.

When an eligible finding is processed successfully, the Lambda:

- retains the original security group IDs in memory;
- replaces the current security groups with the quarantine security group;
- then persists the original IDs in the `OriginalSecurityGroups` tag;
- applies isolation evidence tags while leaving `IsolationAllowed` Terraform-managed;
- records the finding and isolation time; and
- publishes an SNS notification when the SecOps topic is configured.

A notification failure is logged after isolation and does not roll back an already successful quarantine.

## Security Impact

Successful, reviewed containment can reduce:

- Lateral movement
- Continued network communication
- Potential data exposure
- Blast radius during security events

It supports containment, but successful recovery requires independently verified metadata and authorization.

**Implementation and evidence:** The [handler](../../modules/automation/lambda/ec2_isolation.py)
requests snapshots without waiting for completion and replaces security groups
before writing recovery tags. Partial failure can leave quarantine applied without
usable rollback metadata. Its caught exceptions normally return an error count,
not an invocation failure that necessarily reaches a DLQ. Its
[IAM EC2 permissions](../../modules/iam/lambda.tf) use `Resource="*"` without the
Python eligibility conditions.

The reusable compute default is `isolation_allowed=false`, but the supplied
workload roots default to `true`. Confirm the effective tag and approved policy
rather than inferring safety from an environment name. Preserve independent
pre-isolation groups, requested/completed snapshots, handler counters, final
tags/groups, and notification receipt using the [test guide](../lambda_tests/ec2_isolation.md).
Routine Terraform attachment drift is ignored, but replacement/destruction is
not prevented. Quarantine still reaches shared Interface Endpoints.

---

# Controlled EC2 Rollback

## Control Intent

Allow recovery from quarantine only after human review and approval.

## Implementation

The [automation bus/rule](../../modules/automation/main.tf) routes
`source=custom.rollback` events to the [rollback handler](../../modules/automation/lambda/ec2_rollback.py).
The rule does not filter detail type. The handler requires nonempty `instance_id`,
`approved_by`, and `ticket_id`, an `Isolated=true` tag, and saved original groups.
The approval fields are caller-supplied metadata; no approval system is consulted.

Intended recovery flow:

```text
Independent review and authorization
    -> authorized event submission to <name_prefix>-secops-bus
    -> Lambda reads saved groups
    -> restore groups
    -> write release tags
    -> publish notification
```

The Identity Center caller's unprefixed bus ARN differs from this resource, and
the bus policy contains a wildcard-principal rollback allow with an event-source
condition. The repository therefore does not establish an Operator-only approval
boundary. Successful submission cannot resolve that policy discrepancy.

The handler writes `IsolationAllowed=true`, not the prior authorization value.
Security-group restoration, tagging, and notification are not transactional;
later failure does not undo earlier mutations. Use the [rollback tests](../lambda_tests/ec2_rollback.md)
to separate intended submitter access, independent observer access, per-entry event
acceptance, exact pre/post group comparison, tag review, and notification receipt.

## Security Impact

This provides a mechanism for restoring security groups. Human approval,
authorization correctness, incident closure, and safe re-enablement require
independent controls and evidence. The unresolved bus-policy and ARN relationship
must not be described as a completed separation-of-duties control.

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

**Implementation and evidence:** The [handler](../../modules/automation/lambda/ip_enrichment.py)
queries AbuseIPDB outside the workload VPC, caches the secret across warm
invocations without a TTL, and can return success-shaped payloads after handled
lookup/notification/writeback errors. It does not inspect `UnprocessedFindings`
before logging writeback success. Its incoming-note deduplication is not a fresh
read of current finding state. Secret rotation, external indicator disclosure,
provider usage limits, note replacement, and result freshness require review.

Follow the [enrichment tests](../lambda_tests/ip_enrichment.md): use synthetic
identifiers by default, approve real-finding writeback separately, and retain
before/after notes, payloads, handler results, and actual notification evidence.
Disabling runtime writeback does not remove its IAM permission.

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
- Detection of exposure and encryption-policy deviations
- Selected configuration evaluation
- Faster identification of misconfigurations

**Implementation and evidence:** The [Config recorder](../../modules/security/config_baseline/main.tf)
uses a fixed inclusion list. IAM types are included even with IAM rules disabled;
KMS keys are not listed despite enabled KMS rules. Review actual applicability,
evaluation results, and freshness rather than treating rule existence as coverage.
Disabling Config leaves its recorder and delivery channel declared, with recording
stopped and rules/remediation omitted.

The [automatic S3 remediation](../../modules/security/config_baseline/remediations.tf)
follows `enable_config` independently of the S3 catalog-family toggle. Its prefix
does not limit target buckets by name, tag, or environment, and the mutation may
disrupt deliberately public use. The [rule catalog](../../modules/security/config_baseline/rules.tf)
is primarily detective; no general guarantee of encryption enforcement or safe
remediation follows from its presence. Record evaluations, exceptions, intended
resource scope, and approved remediation outcomes.

---

# Encryption and Data Protection

## Control Intent

Protect sensitive infrastructure data, operational logs, secrets, and backups.

## Implementation

The [security module](../../modules/security/main.tf) supplies purpose-specific
KMS keys for logs/notifications, EBS, Lambda environment variables, Secrets
Manager, ECR, and the backup vault. Terraform state has a separately owned key.
RDS storage encryption is enabled without an explicit database `kms_key_id`;
do not identify that key as the logs or secrets key. The workload key policies
include differing service/account/context conditions, not one uniform
least-privilege policy.

[Storage](../../modules/storage/main.tf) uses an ephemeral generated RDS password
with write-only arguments, whereas [automation](../../modules/automation/main.tf)
stores the AbuseIPDB key through a normal secret-version value. Do not claim
all secret values are absent from Terraform state and plan artifacts.

The logs bucket uses versioning and lifecycle rules but not Object Lock. The
six workload keys have rotation and a deletion window without effective
production destruction guards. A pending-deletion key is unavailable for KMS
cryptographic operations; retaining encrypted records without usable key access
is not sufficient. [AWS KMS deletion guidance](https://docs.aws.amazon.com/kms/latest/developerguide/deleting-keys.html)
explains that service behavior.

Transport is a separate control: the optional ALB uses HTTPS on its frontend
and HTTP to task target groups. Database/application transport and tenant access
need their own configuration and evidence. Validate actual keys, grants,
permissions, secret exposure, data paths, and retention/exit requirements.

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

Support recovery from accidental deletion, misconfiguration, or destructive events while making scheduled-backup behavior explicit by deployment profile.

## Implementation

The baseline includes AWS Backup support with a retained, KMS-encrypted backup vault in each workload environment.

Scheduled backup behavior is profile-aware:

```text
production  -> enabled by default
development -> disabled by default
minimal     -> disabled by default
```

When scheduled backup is enabled:

- a backup plan and selection are created;
- the default schedule is `cron(0 5 * * ? *)`;
- production retention defaults to 30 days;
- explicitly enabled non-production retention defaults to 7 days unless overridden; and
- workload EC2 and RDS resources use `Backup=true`.

When scheduled backup is disabled:

- the encrypted backup vault remains present;
- the effective schedule and retention resolve to `null`;
- the backup plan and selection are absent; and
- workload EC2 and RDS resources use `Backup=false`.

This design avoids treating a cost-control decision as authorization to delete the environment backup vault while omitting AWS Backup plan-based scheduling when disabled. RDS-native automated backups are configured independently.

The EC2 isolation workflow separately requests tagged snapshots of attached EBS volumes after all eligibility checks pass and before quarantine is applied. Snapshot-request failure stops isolation rather than quarantining without that recovery evidence.

Patch management support is provided through SSM Patch Manager.

The baseline provides recovery infrastructure, not proof that backups meet an organization's recovery objectives. Production users must define backup scope, retention requirements, restore testing, RPO/RTO expectations, and destructive-resource protections appropriate to their environment.

## Security Impact

This supports:

- Recovery readiness;
- Operational resilience;
- Reduced impact from data loss;
- Improved patch hygiene; and
- Support for audit expectations around recoverability.

### Availability and recovery boundaries

[Profile resolution](../../baseline/locals.tf) and [input constraints](../../baseline/variables.tf)
enforce production RDS Multi-AZ. Scheduled AWS Backup defaults to enabled, but an
explicit `backup_enabled=false` overrides that default and also disables the
profile-derived Restore Testing resources. Do not present backup enablement as a
hard production-only input prohibition. The database remains a
PostgreSQL Multi-AZ **DB instance**, not a three-node cluster or Aurora. Its native
14-day automated-backup retention is separate from AWS Backup. Normal production
also enables ALB, RDS, and Network Firewall deletion protection; ECR, ECS service,
and backup-vault force deletion remain disabled even in retirement.

Three-AZ networking and redundant ECS capacity reduce single-resource exposure;
they do not establish application availability, successful failover, cross-Region
recovery, or measured recovery time/point objectives. Capture live placement,
replacement/failover observations, application recovery, and a no-change plan
for the exact tested configuration.

### Restore Testing and destructive lifecycle

The [backup module](../../modules/backup/main.tf) configures Restore
Testing when the production profile and effective backup enablement are both true, for the managed RDS source using a temporary private Single-AZ restore.
Record separately: plan/selection correctness, an actual restore job, application
and data-validation results, and cleanup of temporary resources. A
[backup-validator](../../scripts/validation/validate-backup.sh) PASS can coexist
with warnings for absent jobs, application validation, or cleanup; it is not
complete recovery acceptance. The module does not supply application-specific
restore validation.

The [retirement runbook](../production-retirement.md) describes Stage-1 protected
planning and zero ECS capacity, separately authorized durable-data cleanup,
readiness checks, Identity Center cleanup, and exact saved workload-destroy
application. Cleanup re-inventories at execution; it is not a frozen-item
manifest. Later rejection does not undo earlier cleanup. This complete workflow
is `prod`-only even though resilience policy is profile-driven. Preserve required
records, snapshots, images, and usable keys outside approved destruction scope.

# Alerting and Notification

## Control Intent

Ensure security-relevant events and monitoring-health changes reach the appropriate operational contacts.

## Implementation

SNS topics are used to notify SecOps or compliance contacts.

Alerts may include:

- broad HIGH/CRITICAL Security Hub findings routed through the general notification path;
- GuardDuty-driven EC2 isolation events;
- GuardDuty ECS Runtime Monitoring coverage unhealthy and healthy status changes;
- EC2 rollback events;
- IP enrichment results;
- tamper detection;
- break-glass role usage;
- AWS Config compliance events;
- ECS task-deficit alarms; and
- ECS ingress unhealthy-target alarms.

The GuardDuty ECS Runtime coverage target uses the existing security-notification SNS topic, shared EventBridge delivery DLQ, three retry attempts, and a one-hour maximum event age. Its transformed message preserves the workload account, Region, ECS cluster, current/previous status, GuardDuty issue, GuardDuty update time, and EventBridge event time.

The general Security Hub HIGH/CRITICAL notification and IP-enrichment rule remains broader than the separate GuardDuty-only EC2 isolation rule.

## Security Impact

This supports:

- Timely awareness;
- Operational escalation;
- Centralized notification patterns;
- Visibility into loss or recovery of Runtime Monitoring coverage; and
- Improved incident response readiness.

**Implementation and evidence:** [Monitoring](../../modules/monitoring/main.tf)
has separate EventBridge-to-SNS and SQS receive-count failure paths. The latter
cannot recognize application processing success, and neither SNS subscription
has subscriber-delivery redrive. There is no supplied SQS consumer or independent
fallback alarm channel. Confirm recipients, review queue age/retention and missing
signals, and retain actual correlated receipts and response records. Reading an
SQS message changes receive/visibility state and is not a passive observation.

GuardDuty coverage events are regional/account-scoped rather than a baseline-only
cluster filter. A transformed first-finding Security Hub notification is not a
complete event archive. Empty DLQs, an `OK` alarm, or an SNS-validator PASS do not
establish end-to-end delivery or human acknowledgement.

# Operational Impact

Together, these mechanisms are intended to support the following outcomes, subject to the limits and operating evidence above:

- Infrastructure exposure is minimized
- Human and CI/CD access is controlled
- Security-relevant activity is visible
- Selected changes to monitoring can be surfaced for investigation
- Qualifying EC2 incidents can be contained automatically, while ECS/Fargate Runtime Monitoring remains detection/visibility only
- Recovery actions can follow independently authorized procedures
- Configuration integrity is monitored
- Operational logs have configured access and encryption controls, not immutable retention
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
- Application-specific restore validation, RPO/RTO definition, or proof of recoverability
- Automatic ECS/Fargate containment or remediation
- Compliance evidence management
- Security awareness training
- Continuous SOC monitoring

Organizations should treat this baseline as a technical foundation that supports, but does not replace, a broader security program.

Unresolved implementation limitations require a named owner and a documented
remediation or risk decision; describing them here does not resolve them. The
most consequential include Operator bus authorization, broad administrative and
response grants, mutable log retention, key preservation during destruction,
partial response failures, Config recording/remediation scope, and shared
notification dependencies. This document does not assert that any customer
has accepted those risks or that behavioral tests have been rerun.

---

# Summary

`tf-secure-baseline` implements an AWS infrastructure baseline with controls for identity, networking, logging, centralized threat detection, profile-driven ECS/Fargate Runtime Monitoring, response, encryption, backup, and operational resilience.

The control narratives in this document explain how those controls function and what security outcomes they are intended to support.
