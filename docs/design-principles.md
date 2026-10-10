# Design Principles - tf-secure-baseline

## Purpose

This document describes the design principles behind `tf-secure-baseline`.

It explains why the platform is structured the way it is, what tradeoffs were made, and what security outcomes the baseline is intended to support.

Principles express design intent; the implementation boundaries below qualify what the code actually provides. These principles are not evidence of a completed deployment or successful live qualification.

This document is not a deployment guide. For deployment instructions, see:

```text
docs/quickstart.md
```

For system structure, see:

```text
docs/architecture-overview.md
```

---

## Target Client Type

`tf-secure-baseline` is designed for early- to mid-stage SaaS companies and engineering teams that:

- Run workloads in AWS
- Handle customer PII or other sensitive data
- Need stronger cloud security defaults
- Want a reusable AWS foundation
- Are preparing for SOC 2, ISO 27001, or similar assurance efforts
- Need security architecture that is understandable and operable by a small team

The baseline is opinionated, but it is intended to be adaptable.

It provides a secure starting point rather than a one-size-fits-all production platform.

---

## Primary Design Goals

The baseline is designed to provide:

- Secure-by-default AWS infrastructure
- Multi-account environment isolation
- Centralized identity and access management
- No long-lived CI/CD credentials
- Private-first networking
- Controlled outbound access
- Configurable deployment profiles
- Configurable egress modes
- Dedicated private subnets for Interface VPC Endpoints
- Centralized logging and monitoring
- Automated detection and response
- Explicit runtime ownership between Terraform and managed autoscaling
- Human-approved recovery workflows
- Encrypted and tamper-resistant operational evidence
- A structure that is understandable enough to be adopted by small teams

---

## Core Principles

## 1. Multi-Account Isolation

Each major environment is deployed into a dedicated AWS account.

```text
control-plane
security-operations
dev
staging
prod
```

This reduces blast radius and creates cleaner separation between:

- Development workloads
- Staging workloads
- Production workloads
- Control-plane governance resources
- Centralized security administration
- Human access management
- CI/CD execution roles

A compromise or misconfiguration in one workload account should not automatically compromise every environment.

---

## 2. Control Plane Separation

Control-plane resources are separated from workload infrastructure.

The control plane manages:

- AWS Organizations/OU structure and delegated-security prerequisites; existing member-account placement is checked rather than automatically performed
- IAM Identity Center access
- Organization-level trusted-service and delegated-administrator prerequisites
- Security Hub V2 organization-policy prerequisites
- Control-plane Terraform state
- GitHub OIDC roles for control-plane automation

The security-operations layer manages:

- its own Terraform state and GitHub OIDC roles
- delegated Security Hub CSPM administration
- delegated GuardDuty administration and organization protection plans
- Security Hub V2 administrator-side organization policy management

Environment bootstrap stacks manage:

- Environment-specific Terraform state resources
- Environment-specific GitHub OIDC roles for CI/CD

Workload baseline stacks manage:

- Networking
- Compute
- Logging
- workload-local AWS Config and Inspector
- deterministic remediation and response automation
- Storage
- Backup
- Patch management

In the centralized deployment, workload Terraform explicitly defers local Security Hub CSPM, GuardDuty, and Security Hub V2 ownership to the security-operations layer.

This separation reduces accidental lifecycle coupling; it is not a guarantee that permissions or cross-root dependencies cannot affect another layer. Workload teardown still needs Identity Center dependency cleanup. State bucket/CMK `prevent_destroy` guards and explicit backend migration provide separate protections; root separation alone cannot make self-managed infrastructure undeletable.

---

## 3. Bootstrap Before Automation

Some resources must exist before automation can safely manage the rest of the platform.

Each `state` substack follows a two-phase lifecycle:

1. It is initialized and applied locally without an active `backend.tf`.
2. After it creates the S3 state bucket and state CMK, its local state is migrated into the new S3 backend.

The repository tracks the intended post-migration configuration as:

```text
backend.tf.migrated.example
```

The active runtime file is:

```text
backend.tf
```

The active file is generated only after the backend resources exist and is ignored by Git. The guarded migration helper:

```text
scripts/bootstrap/migrate-state-stack.sh
```

checks the AWS account, validates the backend template against the state-stack output, backs up local state, refuses a destination object identified as existing, runs `terraform init -migrate-state`, and verifies the resulting remote state. Operators still need to distinguish an unused key from a failed/denied object lookup.

State locking uses Terraform S3 native lockfiles with:

```hcl
use_lockfile = true
```

After the state stack has been migrated and the account stack has created GitHub OIDC roles, GitHub Actions can safely initialize the remote backends and manage supported stacks.

This preserves the required bootstrap sequence without leaving long-lived Terraform state only on an operator workstation.

---

## 4. No Long-Lived CI/CD Credentials

GitHub Actions uses short-lived OIDC credentials instead of static AWS access keys. Workload infrastructure separates Plan and Apply authorities, and application image publication adds a third narrow Image Publisher role.

```text
Plan role          -> Terraform planning / read paths
Apply role         -> protected exact-plan application
Image Publisher    -> ECR publication/query from approved branches
```

The publisher job intentionally has `id-token: write` and `contents: read` only. A separate release/PR job receives repository write permissions but no AWS credentials and no `id-token`. This reduces the chance that one compromised CI job can both publish an AWS artifact and rewrite the deployment declaration that selects it.

The Image Publisher role uses exact branch-based OIDC subjects. Its job must not use a GitHub Environment because that would change the subject from `ref:refs/heads/<branch>` to an environment subject.

Workload deployment follows plan-before-approval semantics. The standalone Terraform Plan workflow is informational; the Terraform Apply workflow creates its own binary plan, readable plan, metadata, and checksum, then applies that exact artifact after protected approval without replanning. `DEPLOYMENT_PROFILE` and other critical Plan inputs are validated before planning.

Static AWS keys are not part of the intended CI/CD model.

The image publisher uses the ECR Docker Credential Helper with temporary push-only configuration and helper token-file caching disabled. That removes this script's explicit `docker login` storage path, not every possible credential exposure on a runner. Likewise, an `environment:` declaration only identifies the GitHub environment; required reviewers and deployment restrictions need separate configuration and evidence.

## 5. Human Access Through IAM Identity Center

Human access is managed through IAM Identity Center instead of long-lived IAM users.

The design favors:

- Group-based access
- Permission sets
- Account assignments
- Environment-specific roles
- Least-privilege operational workflows

Required Identity Center groups include:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

Investigative, engineering, and other customer workforce access is configured by the customer outside the baseline-managed Identity Center personas.

The access model is designed so that humans receive only the access needed for their function. Workload `SecOps-Operator` access is intended for rollback-event submission, while `SecOps-Administrator` provides centralized security-operations administrative access. The workload bus policy restricts `custom.rollback` publication to matching permission-set-derived Operator role ARNs and explicitly denies other publishers. Human approval remains an operational requirement rather than an independently authenticated Lambda check.

---

## 6. Private-First Infrastructure

Workloads are placed in private subnets by default.

Compute resources should not receive public IP addresses.

Inbound exposure is minimized, and outbound traffic is controlled through explicit network paths.

The exact outbound path depends on the selected `deployment_profile` and effective `egress_mode`.

Production-style inspected egress keeps the firewall/NAT path same-AZ:

```text
Compute-private subnet
    |
    v
same-AZ AWS Network Firewall endpoint
    |
    v
Firewall-private route table
    |
    v
same-AZ NAT Gateway in egress-public
    |
    v
Internet Gateway
    |
    v
Internet
```

The internet-facing ALB uses a separate `ingress_public` subnet/route-table role. Its path to private workload targets remains VPC-local and is not redirected through the stateful Network Firewall egress path.

Lower-cost NAT-only egress:

```text
Compute-private subnet
    |
    v
same-AZ NAT Gateway in egress-public
    |
    v
Internet Gateway
    |
    v
Internet
```

Private AWS-only egress:

```text
Private Compute Subnets
    |
    v
VPC Endpoints for supported AWS services
```

This makes private networking the default and public exposure the exception.

The optional ALB has an HTTPS frontend but HTTP target groups and health checks; private placement is not end-to-end transport encryption. The fixed endpoint set and security groups supply network paths, not application authorization or custom endpoint-policy isolation.

---

## 7. Controlled Egress

Outbound access is treated as a security boundary.

The baseline uses controls such as:

- AWS Network Firewall
- NAT Gateway
- Route table segmentation, including separate ingress-public and egress-public roles
- VPC endpoints
- Security groups
- Explicit service access paths
- Egress mode selection

The goal is to reduce unmonitored outbound communication and create a central location for inspection and restriction.

This is especially important for workloads that process sensitive data.

The supported egress modes are:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route | Intended use |
|---|---:|---:|---|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint | Production / sensitive workloads |
| `nat_only` | No | Yes | NAT Gateway | Lower-cost dev/staging |
| `vpc_endpoints_only` | No | No | No default route | Private AWS-only / minimal testing |

When `egress_mode = "auto"`, the effective egress mode is selected from the `deployment_profile`.

---

## 8. Deployment Profiles Should Provide Safe Defaults

Deployment profiles provide a practical way to balance security, cost, and operational needs across environments.

The baseline supports profiles such as:

| `deployment_profile` | Default `egress_mode` | AWS Config | Backup | Inspector | CloudWatch retention | Intended use |
|---|---|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | 90 days | Full security baseline for sensitive workloads |
| `development` | `nat_only` | Enabled | Disabled | Enabled | 30 days | Lower-cost development and testing |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | 14 days | Lowest-cost/private AWS-only testing |

Profiles combine defaults with policy. Supported inputs can override egress, Config, Backup, Inspector, and retention where exposed by the caller. Production RDS Multi-AZ, minimum production availability, profile-derived force-deletion behavior, and the retirement boundary are not unrestricted cost toggles. GuardDuty Fargate enrollment follows the profile without an independent public override.

For example, a development environment can still use Network Firewall by setting:

```hcl
deployment_profile = "development"
egress_mode        = "network_firewall"
```

This keeps the baseline adaptable while preserving clear default behavior.

---

## 9. Prefer Private AWS Service Access

Where practical, AWS service access should use VPC endpoints instead of public internet paths.

This improves:

- Network privacy
- Egress control
- Reliability
- Auditability
- Dependency reduction on public internet routes

The current endpoint set supports private access to services including:

- S3 through a Gateway Endpoint
- STS
- SQS
- CloudWatch Logs
- Systems Manager and SSM Messages
- Secrets Manager
- KMS
- AWS Config
- SNS
- EC2
- Amazon ECR API (`ecr.api`)
- Amazon ECR Docker Registry (`ecr.dkr`)
- EventBridge
- Security Hub
- Lambda
- GuardDuty Runtime Monitoring (`guardduty-data`)

Interface VPC Endpoints are deployed into dedicated private endpoint subnets.

This keeps endpoint ENIs separate from compute, data, serverless, firewall, ingress-public, and egress-public subnet families. The Terraform-managed `guardduty-data` endpoint is also created before workload EC2 so GuardDuty Runtime Monitoring can use the existing endpoint instead of introducing an endpoint outside the Terraform dependency graph.

The S3 Gateway Endpoint is associated with the private route tables that need S3 access.

Private ECR image pulls for the implemented Fargate runtime use the `ecr.api` and `ecr.dkr` Interface Endpoints, while ECR image layers use the existing S3 Gateway Endpoint.

---

## 10. Endpoint Subnets Should Be Dedicated

Interface Endpoint ENIs should not compete with workload ENIs in compute subnets when the architecture can avoid it.

The baseline uses dedicated private subnets for Interface VPC Endpoints.

This provides:

- Cleaner subnet segmentation
- Reduced private IP pressure in compute subnets
- Easier endpoint inventory and troubleshooting
- Clearer route table ownership
- Better separation between workload placement and AWS service access infrastructure

Endpoint private subnets do not require a default internet route.

Workloads reach Interface Endpoints through normal VPC-local routing and security group rules.

---

## 11. Centralized Security Governance, Logging, and Evidence Preservation

Organization-wide security controls should have explicit ownership rather than being independently configured in every workload account.

The control plane owns AWS Organizations prerequisites such as trusted service access, delegated-administrator registration, and Security Hub V2 policy enablement. The dedicated security-operations account owns centralized Security Hub CSPM configuration, GuardDuty organization governance and Runtime Monitoring, and Security Hub V2 workload policy management. Workload accounts retain local Config, Inspector, logging, remediation, and response responsibilities.

This split reduces per-account drift while keeping management-account privileges separate from delegated security administration.

Security and operational logs should also be centralized, encrypted, and protected from tampering.

The baseline captures data from services such as:

- CloudTrail
- AWS Config
- VPC Flow Logs
- CloudWatch Logs
- Lambda logs
- Network Firewall logs, when Network Firewall is deployed

The logging design emphasizes:

- KMS encryption
- Versioning
- Restricted bucket policies
- Explicitly documented Object Lock limitations: the workload logs bucket does not enable it
- Lifecycle retention
- Profile-aware CloudWatch retention
- Long-term forensic usefulness

Logs are treated as security evidence, not just operational telemetry.

In the implementation, each workload owns its logs bucket. Its `object_lock_enabled=false`, `force_destroy=true`, and `prevent_destroy=false` values are not changed by the production profile. Administrative policy changes and workload destruction remain material retention risks; the 2555-day lifecycle policy is not immutable retention. Required external evidence preservation is an operator responsibility, not an implemented archive-copy workflow.

---

## 12. Detection Integrity

Detection systems must be protected from tampering.

The baseline monitors for attempts to disable or modify security services such as:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS
- Logging destinations

Tamper-related events are routed through EventBridge and surfaced through SNS notifications.

A security platform should detect attempts to weaken the security platform itself.

---

## 13. Event-Driven Security Automation

The baseline uses EventBridge and Lambda for security automation.

Security events are routed into controlled workflows that can:

- Isolate and snapshot EC2 instances
- Restore EC2 security groups after approval
- Enrich IP addresses from findings
- Alert on tampering
- Alert on break-glass role usage

This enables rapid response without requiring humans to manually execute every action.

---

## 14. Automated Containment, Human-Approved Recovery

Containment can happen automatically when a high-confidence security condition is detected, but authorization fails closed. The EC2 isolation EventBridge path is limited to `HIGH`/`CRITICAL`, `NEW`, `ACTIVE` GuardDuty findings for `AwsEc2Instance`. The Lambda independently revalidates the GuardDuty product and the canonical `ec2_auto_isolation_severities` set, which defaults to `CRITICAL`, and still requires the instance to have `IsolationAllowed=true`.

The reusable baseline default is `false`, but root and CI settings must be inspected independently: the production root declares `isolation_allowed=true` as its default. Do not assume an environment name guarantees opt-out. Align explicit local and GitHub inputs with the approved response policy. Attached EBS snapshots are requested before quarantine; a request is not evidence that snapshot creation completed. Recovery requires an authorized human to review the restoration decision and submit a rollback request. This is an operational requirement; `approved_by` and `ticket_id` are supplied metadata, not approval evidence independently verified by the handler.

For example:

```text
GuardDuty EC2 finding
(imported through Security Hub)
    |
    v
EC2 Isolation Lambda
    |
    v
Instance quarantine
    |
    v
Human review
    |
    v
SecOps-Operator rollback event
    |
    v
EC2 Rollback Lambda
```

The diagram illustrates the intended procedure: EventBridge invokes Lambda, which performs the EC2 mutation using its execution role. Separating event submission from those permissions does not independently enforce separation between the approver and submitter or guarantee prevention of uncontrolled restoration.

---

## 15. Least Privilege by Workflow

Permissions are designed around workflows rather than broad job titles.

Examples:

- CI/CD roles can manage Terraform resources for a specific environment.
- Lambda execution roles receive only the permissions needed by their automation.
- The SecOps Operator persona separates event submission from direct EC2 mutation, with a bus-policy restriction for `custom.rollback` publication. An accepted event is not proof of authenticated approval or successful recovery.
- Analysts can be granted visibility without response permissions.
- Engineers can be granted limited response actions where required.

This reduces the chance that one compromised credential can perform every action.

Least privilege is a design goal, not a uniform property of every role. The baseline's Terraform Apply role attaches `AdministratorAccess`, and its Plan role can write state objects and use relevant KMS/secret permissions. Reviewer protection, role trust, account scope, and actual permissions must all be assessed. A read-only validation operation does not prove a read-only credential.

---

## 16. Environment-Specific Permissions

Many resources are environment-specific, including:

- KMS keys
- Cloudwatch and CloudTrail Logs
- S3 buckets
- RDS instances
- IAM policies
- EventBridge buses
- Lambda functions
- SNS topics

The design avoids assuming that one environment's policies or keys apply to another environment.

Identity Center can assign access centrally, but the actual resource permissions are created in the target workload accounts.

This avoids circular dependencies and preserves environment isolation.

---

## 17. Immutable and Encrypted State

The heading describes the integrity objective, not a WORM implementation. Terraform state is necessarily updated; the baseline uses encryption, versioning, locking, and restricted administration rather than S3 Object Lock. Do not treat version history as an undeletable or independent backup.

Terraform state is sensitive because it can contain resource identifiers, outputs, and sometimes secrets or references to sensitive infrastructure.

The baseline treats Terraform state as a protected asset.

State resources use:

- S3 storage
- KMS encryption
- S3 native lockfiles
- Versioning
- Restricted administrative access
- Separate state object keys per Terraform root

The state stacks are a controlled bootstrap exception: they initially use local state only long enough to create their backend resources, then migrate their own state into those protected S3 backends.

A tracked `backend.tf.migrated.example` documents the intended remote configuration, while the active `backend.tf` is created only after the backend exists and is ignored by Git.

Migration is not considered complete merely because `backend.tf` exists. Validation also confirms that:

- The remote S3 state object exists and is readable.
- `terraform state pull` succeeds through the configured backend.
- The backend bucket matches the state stack's `tf_state_bucket_name` output.
- State, account, and workload roots use distinct state object keys.

---

## 18. Modular but Opinionated

The repository is modular but intentionally opinionated. Modules have resource-ownership boundaries rather than being generalized merely for abstraction.

EC2 and ECS/Fargate are sibling workload patterns. `modules/compute` remains EC2-only; the preferred modern application runtime is split across `modules/ecr`, `modules/ecs_cluster`, `modules/application_load_balancer`, and `modules/ecs_service` according to resource lifecycle and ownership.

Operators maintain one canonical `ecs_services` map. A service can be registered with `image_digest = null`; baseline still derives its repository requirement while filtering per-service runtime resources until an immutable digest is selected. This avoids a second service inventory and avoids splitting Terraform state merely to bootstrap ECR.

The same canonical map defines ECS capacity ownership. `scaling = null` means Terraform owns `desired_count`. A non-null scaling object means the configured count is bootstrap capacity and Application Auto Scaling owns subsequent runtime count within explicit bounds. The module keeps fixed and autoscaled ECS resources separate so Terraform lifecycle behavior cannot accidentally undo a legitimate scale event. The runtime retains the target-tracking-only model: CPU, memory, and conditional ALB requests per target.

Deployment health is likewise explicit in the canonical contract through minimum healthy percentage, maximum percentage, and task-startup health-check grace period. AWS-managed target-tracking alarms remain AWS-managed; Terraform-owned task-deficit and ingress unhealthy-target alarms are separate operational notification controls.

Terraform owns runtime infrastructure, not application artifacts. Builds, tests, image publication, and digest selection happen outside Terraform. A deployable task uses the resource-backed ECR repository URL plus the reviewed immutable `sha256` digest.

The application release pipeline also preserves authority separation: image publication uses the AWS Image Publisher role, while the release/PR job changes only the selected service digest with GitHub repository authority and no AWS credentials.

When a validator needs to compare what Terraform actually configured, prefer resource-backed outputs over reconstructing names/policy in Bash. Examples include ECR CMK identity, ECS service platform version, Container Insights/log-group metadata, ALB listener and ARN-suffix metadata, Application Auto Scaling targets/policies, operational alarm identities, S3 prefix-list ID, and the workload logs CMK.

## 19. Secure Defaults Over Maximum Flexibility

The baseline favors secure defaults even if they require more setup.

Examples include:

- Private subnets for compute
- KMS encryption
- Centralized logging
- Centralized Security Hub CSPM and GuardDuty governance
- Security Hub V2 workload policy governance
- Event-driven alerting
- Identity Center access
- GitHub OIDC instead of static credentials
- Profile defaults that keep production security controls enabled
- Egress defaults that route production workloads through Network Firewall
- An explicit EC2 isolation authorization tag and severity policy; root defaults and CI overrides must be reviewed rather than inferred from environment names
- Strict first-boot failure when package metadata cannot be refreshed safely

The platform can be customized, but defaults should guide users toward safer outcomes.

---

## 20. Cost Controls Should Be Explicit

Security controls have cost implications.

The baseline makes major cost/security tradeoffs explicit through deployment profiles and egress modes rather than hiding them inside ad hoc environment differences.

Examples:

- `production` keeps the full baseline enabled by default.
- `development` lowers cost by using NAT-only egress and disabling backup by default.
- `minimal` removes Network Firewall and NAT Gateway by default and relies on VPC endpoints for supported AWS services.

This helps teams understand why an environment costs what it costs and what security tradeoffs are being made.

---

## 21. Operational Recoverability

Security architecture must support recovery, not just prevention.

The baseline includes controls such as:

- AWS Backup
- Backup vault encryption
- Retention policies
- EC2 rollback workflow
- Patch management support
- Centralized logs for investigation

Backup defaults are profile-aware.

Production enables backup by default, while lower-cost profiles can disable backup unless explicitly overridden.

This supports operational resilience after incidents, mistakes, or misconfigurations while keeping development costs manageable.

The baseline makes resilience and intentional retirement explicit. Production defaults to three AZs, enforces Multi-AZ on the single RDS DB instance, enables ECS AZ rebalancing, and requires at least two fixed tasks or an autoscaling minimum of two for deployable services outside retirement. The production example chooses three; actual per-AZ placement still needs live evidence.

RDS-native 14-day automated backups, the AWS Backup plan, and scheduled RDS Restore Testing are separate controls. Restore Testing is enabled when the profile is production and AWS Backup is enabled; the temporary test restore is private and Single-AZ. Configuration equality does not prove application data recovery or cleanup. No cross-Region/cross-account recovery or achieved recovery objective is implied.

---

## 22. Audit and Assurance Readiness

The baseline is designed to support security assurance efforts, but it does not guarantee certification.

It can help produce evidence for areas such as:

- Least privilege access control
- Logging and monitoring
- Change management
- Encryption
- Incident response
- Vulnerability management
- Backup and recovery
- Network segmentation
- Controlled egress

However, SOC 2 and ISO 27001 also require business processes, policies, risk management, vendor management, and human operational controls.

Infrastructure alone is not a certification.

---

## 23. Dependency-Safe and Deterministic First Boot

New instances should not enter service with stale package metadata, before required security-group policy exists, or before required Interface VPC Endpoints have been created.

The standalone `security_policy` module exports the rule IDs required by compute. Those IDs feed a `terraform_data` readiness checkpoint. A second readiness checkpoint consumes the Terraform-managed Interface Endpoint IDs. EC2 depends on both checkpoints, which delays instance creation without introducing a module cycle.

This ordering is especially important for GuardDuty Runtime Monitoring: Terraform creates `guardduty-data` in the dedicated endpoint subnets before eligible EC2 instances appear, keeping the endpoint and its security-group relationships inside the Terraform graph.

These dependencies do not prove route, NAT Gateway, firewall, DNS, or repository health. The Ubuntu bootstrap separately forces APT over IPv4, retries transient failures, treats any repository-refresh error as fatal, performs a distribution upgrade, and records package and reboot state. Changes to user data replace the instance so the revised bootstrap runs from first boot.

---

## 24. One Authority for Region and Topology

Service/provider `primary_region`, state-resource `state_region`, and explicit S3 backend `region` are distinct responsibilities. Workload validation reads the deployed service Region and rejects a conflicting `AWS_REGION`; administrative-layer entry points require their service Region explicitly. The backend-centric migration helper instead checks the backend Region. Changing an input is not a migration of state or data.

The baseline accepts a canonical IPv4 `/16` and derives the seven `/24` subnet families from it. Eligible AZs are discovered in the provider Region; production defaults to three and lower-cost profiles to two. Explicit larger AZ sets require matching explicit subnet maps. This eliminates hard-coded default-address assumptions without promising a disruption-free topology change or multi-Region disaster recovery.

## 25. Retirement Is a Separate Authorization Boundary

Normal production protects RDS, ALB, and Network Firewall deletion and keeps ECR/ECS force deletion and Backup-vault force destruction disabled. Retirement mode derives zero runtime capacity and relaxes the necessary native deletion protections without weakening RDS final-snapshot or automated-backup intent.

The workflow separately reviews Stage-1 preparation, durable ECR/Backup deletion, Identity Center dependency cleanup, and the exact workload destroy plan. The durable-cleanup helper is limited to `prod`, re-inventories during apply, and does not replay a frozen item manifest. Earlier cleanup is not rolled back by rejecting final destruction. The Stage-1 guard rejects create/delete/replacement actions but is not an attribute-level whitelist of every permitted in-place change.

Autoscaled services retain `ignore_changes=[desired_count]`; only live readiness proves they reached zero desired/running/pending tasks and zero scaling bounds. State-resource teardown remains outside workload retirement, and moving active state does not remove literal `prevent_destroy` guards. Follow the [retirement runbook](production-retirement.md), not a generic force-destroy recipe.

## 26. Evidence Must Match the Claim

Use resource-backed outputs and exact live checks where implemented, but retain their limits. `16/16` counts successful top-level workload scripts, not universal control coverage, zero warnings, proven application behavior, or a fresh recovery exercise. An empty registered runtime can pass without testing task instrumentation. RDS lifecycle flags stored in Terraform are deletion-time intent, not proof a final snapshot already exists.

Record the source commit, effective inputs, selected image digests, target account/Region, caller identity, and each run's artifacts. Keep historical behavioral qualification distinct from later configuration regressions. A tag does not retroactively move evidence to its commit. The [evidence guide](assurance/validation-evidence-guide.md) and [report template](assurance/validation-report-template.md) provide the recording boundary.

The repository pins Terraform `1.15.8`, the AWS provider `6.66.0`, and per-root provider lockfiles. These improve repeatability without freezing every dependency or proving a run used the pinned configuration. Retain the actual version and lockfile evidence with the run.

## Threat Model Assumptions

The baseline is designed to reduce risk from common cloud security threats.

### Primary Threats

- Unauthorized access to customer PII
- Credential compromise
- Over-permissive IAM access
- Misconfigured public exposure
- Data exfiltration from workloads
- Disabling or weakening logging
- Disabling or weakening detection services
- Compromise of EC2 workloads
- Lack of visibility into malicious activity
- Accidental data loss
- Operator mistakes
- Weak CI/CD credential handling
- Unrestricted outbound internet access from private workloads
- Excessive cloud security cost causing teams to disable controls informally

---

## Key Security Controls

### Data Protection

The baseline supports data protection through:

- S3 encryption
- S3 versioning
- Explicit log-retention policy, with S3 Object Lock absent
- KMS-backed encryption
- Restricted bucket policies
- Backup vault encryption
- Secrets Manager encryption

---

### Detection and Visibility

Detection and visibility are provided through:

- CloudTrail
- centrally governed GuardDuty and Runtime Monitoring
- centrally governed Security Hub CSPM
- Security Hub V2 workload organization policy
- workload-local AWS Config
- workload-local Inspector
- CloudWatch
- EventBridge
- VPC Flow Logs
- Lambda automation logs
- Network Firewall logs, when deployed

---

### Access Control

Access control is implemented through:

- IAM Identity Center
- Workload-specific groups and a dedicated security-operations administrator group
- Permission sets
- GitHub OIDC roles
- Least-privilege IAM policies
- Break-glass monitoring
- No long-lived CI/CD credentials

---

### Network Control

Network control is implemented through:

- Private subnet placement
- Ingress-public and egress-public subnet public IP auto-assignment disabled
- Configurable egress modes
- AWS Network Firewall, when enabled
- NAT Gateway, when required
- Dedicated endpoint private subnets
- Terraform-managed Interface VPC Endpoints, including `guardduty-data`
- S3 Gateway Endpoint
- Security group-to-security group rules

---

### Response Automation

Response automation includes:

- EC2 isolation
- EC2 rollback
- IP enrichment
- Tamper detection alerts
- Break-glass role usage alerts
- Config Auto-Remediation
- SNS notifications

---

### Recovery and Resilience

Recovery and resilience are supported through:

- AWS Backup, when enabled
- Backup vaults
- Retention policies
- Pre-EC2 isolation snapshots
- EC2 rollback
- Patch management
- Encrypted/versioned logs with known deletion and administrative limits
- Terraform state separation

---

## Security Priorities

The platform balances:

- Data security
- Identity security
- Detection and response
- CI/CD hardening
- Operational manageability
- Cost awareness
- Audit readiness

The design intentionally prioritizes security and visibility over lowest possible cost for production environments, while still allowing lower-cost development and minimal profiles.

---

## Cost Tradeoffs

Some controls increase cost, especially when deployed across multiple environments.

Notable cost drivers include:

- AWS Network Firewall
- NAT Gateway
- VPC endpoints
- CloudWatch Logs
- VPC Flow Logs
- Security services
- KMS requests
- Backup storage
- ECS/Fargate runtime capacity and Application Load Balancers when enabled

The default production design favors stronger security.

Deployment profiles and egress modes allow teams to choose different cost/security tradeoffs for dev, staging, and production environments.

| `deployment_profile` | Cost/security intent |
|---|---|
| `production` | Full baseline for sensitive workloads |
| `development` | Lower-cost development baseline with NAT-only egress |
| `minimal` | Lowest-cost AWS-private testing profile |

| `egress_mode` | Cost/security intent |
|---|---|
| `network_firewall` | Highest egress control, highest network inspection cost |
| `nat_only` | Lower-cost internet egress without Network Firewall |
| `vpc_endpoints_only` | Lowest egress cost, no general internet route |

These profiles do not replace environment-specific review.

Production deployments should still review deletion protection, retention periods, Object Lock, KMS lifecycle protections, backup requirements, and access controls before use.

---

## Non-Goals

### Not a Compliance Certification Guarantee

This baseline supports alignment with frameworks such as SOC 2 and ISO 27001.

It does not guarantee audit success or certification by itself.

Certification also requires organizational controls, policies, risk management, human procedures, and evidence collection.

---

### Not a Complete Landing Zone Replacement

This project provides a secure Terraform baseline, but it is not a full enterprise landing zone product.

Some organizations may still need:

- Account vending
- Centralized billing automation
- Organization-wide SCP strategy
- Enterprise network connectivity
- Centralized SIEM integration
- broader multi-Region security governance
- Custom compliance guardrails

---

### Not a 24/7 SOC

The baseline provides automated detection, response, enrichment, and alerting.

It does not provide continuous human monitoring, managed detection and response, or incident response retainers.

---

### Not a Zero-Trust Application Platform

The baseline provides strong cloud infrastructure controls.

It does not implement application-layer zero trust by default, such as:

- Service mesh
- mTLS between all services
- Fine-grained application identity
- Runtime authorization between services

---

### Not a Substitute for Secure Application Development

Infrastructure security does not replace secure application engineering.

Clients still need:

- Secure SDLC
- Code review
- Dependency scanning
- Application logging
- Secrets management practices
- Authentication and authorization controls
- Secure API design

---

### Not Designed for Hyperscale by Default

The baseline is intended for small and mid-sized SaaS environments.

It is not optimized out of the box for:

- Millions of requests per second
- Global active-active architectures
- High-throughput streaming systems
- Extremely large data lake environments
- Complex multi-region failover

Those patterns can be added later, but they are not default assumptions.

---

### Not Risk Elimination

The baseline reduces risk and improves visibility.

It does not prevent every possible breach, misconfiguration, or operational mistake.

Security still requires people, process, monitoring, review, and continuous improvement.

---

## Intended Outcomes

The intended outcomes of this baseline are:

- Faster deployment of secure AWS environments
- Reduced risk of public exposure
- Stronger centralized detection and posture governance
- Safer CI/CD authentication
- More consistent access control
- Faster containment of EC2-related incidents
- Better security evidence collection
- Clearer cost/security tradeoffs by environment
- A reusable foundation for client or internal SaaS environments

---

## Summary

`tf-secure-baseline` is designed to be a secure, modular, multi-account AWS baseline for sensitive SaaS workloads.

Its design favors:

- Separation of duties
- Private infrastructure
- Centralized identity
- Delegated security administration
- Encrypted/versioned logging without an implied WORM guarantee
- Event-driven detection and response
- Configurable egress control
- Dedicated private endpoint access
- Secure CI/CD
- Practical audit readiness

The goal is to provide a strong security foundation that can be understood, operated, and extended by small technical teams without requiring them to design every control from scratch.

## Implementation references

At the commit being reviewed, see the [baseline inputs](../baseline/variables.tf), [profile/topology/lifecycle derivation](../baseline/locals.tf), [GitHub OIDC policies](../modules/github_oidc/main.tf), [state safeguards](../modules/state/main.tf), [storage limitations](../modules/storage/main.tf), [production root inputs](../environments/prod/variables.tf), and [Destroy workflow](../.github/workflows/terraform-destroy.yml). These qualify the design goals; they do not establish completed operating-effectiveness tests.
