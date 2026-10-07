# terraform-secure-baseline

[![License](https://img.shields.io/badge/License-Proprietary-red.svg)](LICENSE)

Opinionated Terraform foundation for AWS infrastructure, security controls, and application hosting for SaaS workloads handling sensitive customer data.

---

## Overview

`tf-secure-baseline` is a Terraform-driven AWS security and application-hosting baseline for organizations running workloads that handle PII or other sensitive data.

The implementation combines account governance, segmented networking, EC2 and
ECS/Fargate runtimes, an RDS PostgreSQL database, security-service integrations,
backup/restore infrastructure, and controlled deployment and retirement workflows.
The production profile adds three-AZ topology, RDS Multi-AZ, redundant ECS capacity,
and selected lifecycle protections; it does not make every resource immutable or
every control an independently proven guarantee.

**Before deployment or adaptation, review [LICENSE](LICENSE) and the
[adoption guide](docs/adoption-guide.md).** Public source visibility does not grant
general deployment, modification, or consulting rights.

The platform provides:

- Five-account AWS separation across `control-plane`, `security-operations`, `dev`, `staging`, and `prod`
- AWS Organizations and IAM Identity Center governance
- Dedicated centralized security administration
- Private-first workload networking with configurable egress
- Centralized logging, monitoring, threat detection, and alerting
- Workload-local AWS Config, Inspector, remediation, and response automation
- EC2 as a supported host-based runtime
- ECS/Fargate as the preferred modern application runtime
- Optional ECS target-tracking auto scaling with explicit service-count ownership
- ECS deployment-health configuration and Terraform-owned operational alarms
- GuardDuty Fargate Runtime Monitoring for production/development with explicit minimal-profile opt-out
- GuardDuty ECS coverage-health notification through the existing SecOps path
- GitHub OIDC-based CI/CD without long-lived AWS access keys
- Exact reviewed-plan Terraform application through protected environments
- Four read-only validation layers and separate evidence exporters
- Selected SOC 2 / ISO 27001 control mappings with explicit evidence and organizational boundaries

> This baseline supports SOC 2 and ISO 27001 readiness, but it does not replace an organization’s full compliance program, ISMS, policies, risk management process, or formal audit requirements.

---

## What This Project Provides

### Governance and identity

- AWS Organizations OU separation for `Security`, `Workloads/NonProd`, and `Workloads/Prod`
- Centralized IAM Identity Center access management
- Dedicated `SecOps-Administrator` access for security operations
- Environment-specific workload access boundaries
- GitHub Actions OIDC federation for Terraform and application publication

### Networking and data protection

- Seven subnet families: ingress-public, egress-public, compute-private, data-private, serverless-private, firewall-private, and endpoint-private
- Canonical IPv4 `/16` workload VPCs with derived `/24` subnet families and profile-based AZ selection
- `network_firewall`, `nat_only`, and `vpc_endpoints_only` egress modes
- AWS Network Firewall inspection when enabled
- Terraform-managed VPC endpoints for private AWS service access
- KMS-backed encryption across state, logs, messaging, application resources, and backups
- Separately managed state storage and workload logs storage, with different deletion and retention controls
- Private RDS PostgreSQL with profile-derived Multi-AZ and deletion-time settings

### Security operations

- Centralized Security Hub CSPM and GuardDuty governance
- Centralized GuardDuty Runtime Monitoring with EC2 and ECS/Fargate automated agent management
- Security Hub V2 organization policy governance
- Workload-local AWS Config, Inspector, remediation, and supporting controls
- GuardDuty-scoped EC2 automatic isolation with configurable severity eligibility, defaulting to `CRITICAL`
- Event-driven EC2 rollback, IP enrichment, tamper detection, and break-glass monitoring, subject to the authorization and failure boundaries below
- SNS/SQS alerting and DLQs for selected delivery and processing failure paths

### Application runtimes

- EC2 hosting with dependency-safe first boot and scheduled patching
- One ECS cluster per workload environment
- Generic long-running Fargate services using digest-pinned ECR images
- Conditional shared HTTPS Application Load Balancer
- Separate task execution and application task IAM roles
- Per-service task security groups and encrypted logs
- Terraform-owned Container Insights performance logging
- Registered-but-unreleased ECS services whose ECR repositories can exist before an image digest is selected
- Optional Application Auto Scaling with CPU, memory, and ALB request-count target tracking
- Explicit Terraform-vs-autoscaler ownership of ECS `desired_count`
- Configurable ECS deployment minimum/maximum percentages and health-check grace period
- Terraform-owned task-deficit and ingress unhealthy-target operational alarms
- Deployment-profile-driven `GuardDutyManaged` ECS cluster enrollment
- GuardDuty-managed Fargate runtime agent with Terraform-owned IAM/network prerequisites and live coverage validation

---

## Target Use Case

This baseline is designed for SaaS companies handling sensitive data, teams
preparing for security reviews, cloud security/platform engineers, and authorized
consulting deployments. Adoption assumes ownership of AWS operations, access
review, application security, incident response, costs, and recovery testing.
It is not a managed SOC, an account-vending service, or a complete compliance program.

---

## High-Level Architecture

```text
AWS Organizations management account
└── control-plane
    ├── state / GitHub OIDC
    ├── Organizations + OU topology
    ├── delegated-administrator prerequisites
    └── IAM Identity Center

Security OU
└── security-operations
    ├── state / GitHub OIDC
    └── centralized security services
        ├── Security Hub CSPM
        ├── GuardDuty
        └── Security Hub V2 policy governance

Workloads OU
├── NonProd
│   ├── dev
│   └── staging
└── Prod
    └── prod
```

The platform separates three Terraform ownership domains:

| Domain | Primary responsibilities |
|---|---|
| Control plane | Organizations structure, account placement, trusted-service access, delegated-administrator registration, IAM Identity Center, and management-account prerequisites |
| Security operations | Delegated-administrator-side Security Hub CSPM, GuardDuty, and Security Hub V2 organization policy configuration |
| Workload environments | Networking, EC2, ECS/Fargate, ECR, logging, AWS Config, Inspector, remediation, automation, storage, backup, patching, and workload IAM |

Architectural ownership order:

```text
control-plane -> security-operations -> bootstrap-workloads -> workloads
```

The generic workload Apply and Destroy workflows intentionally do not operate the
centralized security layer because that layer has organization-wide blast radius.
Accounts must already exist or be prepared through a separate process. Existing
Organizations, Identity Center, and security-service resources require ownership
and import review; this is not an automatic merge into another landing zone.
The sequence is an overview, not a substitute for root-specific prerequisites in
the [quickstart](docs/quickstart.md).

---

## Core Design Principles

### Private-first infrastructure

Compute workloads are placed in private subnets by default. Internet-bound egress follows an explicitly selected Network Firewall, NAT-only, or no-default-route path, while supported AWS service traffic can remain private through VPC endpoints.

### Explicit ownership boundaries

Organization prerequisites, centralized security administration, and workload-local
resources are owned by distinct Terraform roots. Do not manage the same resource
from competing states. Changing a local-ownership flag can plan deletion; it is
not an automatic transfer of ownership to the central account.

### No long-lived CI/CD credentials

GitHub Actions authenticates to AWS using OIDC. Plan, Apply, image-publication, and repository-write responsibilities use distinct trust boundaries where required.

### Exact reviewed-plan application

The protected workload Apply workflow generates its own saved Terraform plan, readable output, metadata, and checksum before approval. The Apply job verifies and applies that exact binary plan without replanning.

### Resource-granular readiness

EC2 and ECS/Fargate launch paths use resource-level dependency chains for required
security-policy, IAM, and endpoint resources. Terraform dependency completion is
not proof of successful image pulls, OS bootstrap, agent enrollment, application
health, DNS resolution, or end-to-end connectivity.

### Single canonical ECS service interface

Operators maintain one `ecs_services` map. Baseline derives narrower ECR, IAM, ALB, security-policy, runtime, scaling, and monitoring inputs from it.

### Explicit ECS service-count ownership

A service with `scaling = null` remains fixed-count and Terraform owns `desired_count`. A service with non-null scaling configuration uses `desired_count` only as bootstrap capacity; Application Auto Scaling owns subsequent live count changes within the configured minimum and maximum.

---

## Deployment Profiles and Egress Modes

| `deployment_profile` | Default `egress_mode` | AWS Config | Scheduled Backup | Inspector | GuardDuty Fargate Runtime Monitoring | Log retention | Intended use |
|---|---|---:|---:|---:|---:|---:|---|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | Enabled | 90 days | Production resilience and inspected compute egress defaults |
| `development` | `nat_only` | Enabled | Disabled | Enabled | Enabled | 30 days | Lower-cost development/testing with production-aligned runtime detection |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | Disabled | 14 days | Reduced-service, private AWS-only testing |

Explicit egress behavior:

| `egress_mode` | Network Firewall | NAT Gateway | Compute-private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

When `egress_mode = "auto"`, the effective mode is selected from `deployment_profile`.
The table describes resolved defaults, not a guarantee that every value is fixed.
Production RDS Multi-AZ and normal-operation ECS capacity have enforced constraints;
Config, Inspector, egress, retention, and scheduled-backup settings have their own
input/override rules. A child-module input is configurable from a workload root or
workflow only when that layer actually forwards it.

GuardDuty Fargate Runtime Monitoring follows the deployment profile directly. There is no independent top-level Runtime Monitoring toggle:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

The Scheduled Backup column controls plan/selection creation, not vault creation.
The encrypted vault remains declared even when scheduling is disabled; that is not
a guarantee it survives an approved destroy. Disabled scheduling produces null
effective schedule/retention, no plan/selection, and `Backup=false` on the managed
EC2/RDS resources. Production defaults to `cron(0 5 * * ? *)` with 30-day retention;
explicitly enabled non-production backup defaults to 7 days unless overridden.
An explicit `backup_enabled=false` is accepted even for production and also disables
profile-derived Restore Testing. RDS-native automated backups are separate and
remain configured with 14-day retention.

Default networking uses three AZs for production and two for development/minimal.
`main_vpc_cidr` must be a canonical IPv4 `/16`; default subnet families are derived
as `/24`s. Additional AZs require complete explicit subnet-family input. Service
`primary_region`, state-resource `state_region`, and S3 backend `region` are distinct
settings; changing one does not migrate resources or state for the others.

The supplied composition creates standalone EC2 instances, RDS, an ECS cluster,
endpoints, keys, and other shared resources even when no ECS service has a selected
digest. Profiles are not an empty-environment or zero-cost switch.

`vpc_endpoints_only` provides no default internet route for private compute.
The supplied EC2 first-boot script still needs Ubuntu repositories; SSM endpoint
connectivity alone does not satisfy that requirement. Network Firewall inspection
applies to the configured compute path, not every Lambda or account resource.
The IP enrichment Lambda is not attached to the workload VPC.

## Security Architecture

The baseline combines centralized security governance with workload-local enforcement.

| Service / capability | Primary Terraform ownership | Purpose |
|---|---|---|
| Security Hub CSPM | `bootstrap/security_operations/security_services` | Central policy, standards, finding aggregation, workload associations |
| GuardDuty organization policy | `bootstrap/security_operations/security_services` | Organization enrollment, protection plans, Runtime Monitoring and automated agent policy |
| ECS Runtime Monitoring intent | Workload | `GuardDutyManaged` cluster participation, exact task-execution IAM, networking, validation |
| GuardDuty live Fargate agent | GuardDuty service-managed | Agent injection/upgrades and runtime telemetry |
| Security Hub V2 | Control-plane prerequisites + security-operations policy | Workload enablement through `SECURITYHUB_POLICY` |
| AWS Config / Inspector | Workload | Configuration monitoring, remediation support, vulnerability scanning |
| CloudTrail / CloudWatch | Workload | API activity, logs, metrics, and alarms |
| EventBridge / Lambda | Workload | Detection routing, coverage-health notification, and selected response automation |
| SNS / SQS | Workload | Alert delivery, retention, and failure paths |
| IAM Identity Center | Control plane | Centralized workforce access |
| AWS Backup / SSM Patch Manager | Workload | Recovery and patch-management foundations |

The centralized GuardDuty Runtime Monitoring contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

Central Security Hub CSPM and GuardDuty governance reduce account-level drift while workload Terraform retains AWS Config, Inspector, remediation, logging, and incident-response responsibilities.

The workload VPC endpoint layer pre-creates `guardduty-data`; endpoint validation requires exactly one such endpoint and exact agreement between the live VPC Endpoint ID and Terraform output. Protected Fargate tasks also use Terraform-owned `ecr.api`, `ecr.dkr`, and S3 private paths.

EC2 remains a standalone-instance pattern, not an Auto Scaling Group. The compute
module defaults `isolation_allowed` to `false`, but all three supplied workload roots
default it to `true`; inspect effective inputs and live tags before enabling response.
Ignoring security-group attachment drift preserves quarantine during ordinary
reconciliation but does not prevent replacement or destruction. Bootstrap requests
package updates and reports required reboots; execution and subsequent patching
need their own operational evidence.

Automatic EC2 isolation is intentionally narrower than the general Security Hub alert/enrichment path. EventBridge forwards only active, `NEW`, HIGH/CRITICAL GuardDuty findings for `AwsEc2Instance` resources to the isolation Lambda. The Lambda then independently revalidates GuardDuty product identity, workflow state, record state, and the configured `ec2_auto_isolation_severities` set, which defaults to `CRITICAL`, before evaluating the instance-level `IsolationAllowed` and quarantine gates.

Automatic ECS/Fargate containment is not implemented. Runtime Monitoring provides
detection and coverage visibility, not a task-level quarantine mechanism.

### Security boundaries requiring adoption review

| Area | Implemented boundary and remaining responsibility |
|---|---|
| CI/CD privileges | Plan includes broad read access plus custom state-write and selected secret permissions; Apply attaches `AdministratorAccess`. Role separation is not a universal least-privilege ceiling. Review trust, all grants, and GitHub protection settings. |
| Human recovery access | The Identity Center Operator caller constructs an unprefixed bus ARN while automation creates a prefixed bus. The bus policy also contains a wildcard-principal source-conditioned allow. A successful submission does not prove Operator-only authorization; assess identity and resource policies together. |
| Approval and partial response | Rollback approver/ticket fields are event data, not an authenticated approval check. Isolation requests snapshots without waiting, changes groups before writing recovery tags, and can return handled errors. Rollback also sets `IsolationAllowed=true`. Preserve independent pre-state and verify each outcome. |
| Logs and keys | The workload logs bucket has Object Lock disabled and permits force destruction. Workload KMS keys lack production destruction guards. Encryption, versioning, and lifecycle settings do not guarantee preservation or post-destroy recoverability. |
| Config remediation | Config's fixed recorder scope and rule families are distinct. The separate automatic S3 remediation follows Config enablement, not the S3-family flag, and is not restricted by workload-name tags. Review affected resources and actual evaluation/remediation outcomes. |
| Notifications | DLQs protect selected edges, not every SNS subscriber delivery or handled Lambda error. The module supplies no queue consumer or independent fallback alert channel. Verify receipt, retention, and response ownership. |
| Application transport and identity | ALB frontend traffic is HTTPS; task targets use HTTP. VPC endpoint connectivity does not replace IAM. Application task permissions, database users, TLS, tenant isolation, and transactions need application-specific design. |

See the [adoption guide](docs/adoption-guide.md), [IAM reference](modules/iam/README.md),
[automation reference](modules/automation/README.md), and
[control narratives](docs/assurance/control-narratives.md) for the supporting scope.
These boundaries are not marked resolved by a successful documentation or baseline
validation run. Report suspected vulnerabilities through [SECURITY.md](SECURITY.md).

## ECS/Fargate Runtime and Operations

ECS/Fargate uses a single canonical application-service model for deployment, scaling, networking, and Runtime Monitoring prerequisites.

The runtime remains composed from:

```text
modules/ecr
modules/ecs_cluster
modules/application_load_balancer
modules/ecs_service
```

A canonical service can be registered with:

```hcl
image_digest = null
```

That state is **registered but unreleased**: the required ECR repository can exist while the task definition, ECS service, per-service runtime IAM, task security group, runtime log group, scaling resources, and optional ALB attachment remain absent.

Selecting a valid digest materializes the deployable runtime from the same service
entry. A null digest withholds that service's runtime, not the shared baseline,
standalone EC2 instances, or RDS. The shared ALB is absent only when no deployable
service requires ingress. Setting an existing service's digest back to null is a
resource-removal change and requires plan review.

Deployable images use exact immutable references:

```text
<repository_url>@sha256:<digest>
```

Fargate tasks run in compute-private subnets with `awsvpc` and no public IP. Per-service logs use:

```text
/aws/ecs/<name-prefix>/<service>
```

Container Insights performance logs use:

```text
/aws/ecs/containerinsights/<cluster-name>/performance
```

Both logging paths are Terraform-owned and use the effective workload retention policy and logs CMK.

### Scaling ownership

Scaling is optional per service.

```hcl
scaling = null
```

means no platform-owned Application Auto Scaling target or scaling policy is created, and Terraform owns the exact ECS `desired_count`.

A non-null scaling object defines minimum/maximum capacity plus at least one target-tracking metric:

```hcl
desired_count = 2
scaling = {
  min_capacity               = 2
  max_capacity               = 3
  cpu_target_percent         = 50
  memory_target_percent      = 60
  alb_requests_per_target    = null
  scale_in_cooldown_seconds  = 300
  scale_out_cooldown_seconds = 300
}
```

This excerpt belongs inside an existing service object; it is not a complete
service definition. In normal production operation, fixed `desired_count` or
scaling `min_capacity` must be at least two. Three-AZ networking does not imply
one running task in every AZ; actual placement requires live evidence.

For autoscaled services, the configured `desired_count` is bootstrap capacity only. Application Auto Scaling owns subsequent live desired count changes within the configured bounds, and Terraform intentionally does not reconcile legitimate autoscaler changes back to the bootstrap count.

Supported target-tracking metrics are:

- ECS average CPU utilization
- ECS average memory utilization
- ALB request count per target

`ALBRequestCountPerTarget` requires service ingress. Its Application Auto Scaling resource label is derived from Terraform-owned ALB and target-group ARN suffixes rather than reconstructed from names.

### Deployment health

Each service supports deployment-health configuration:

```hcl
deployment = {
  minimum_healthy_percent           = 100
  maximum_percent                   = 200
  health_check_grace_period_seconds = 0
}
```

Those values apply to both fixed-count and autoscaled services, while the ECS
deployment circuit breaker and automatic rollback remain enabled. The normal
production runtime validator requires `minimum_healthy_percent=100` and
`maximum_percent>=200`; not every runtime assertion is an identical Terraform
input restriction. AZ rebalancing is explicitly `ENABLED` for production.
ALB health, container health reporting, and successful application/database
transactions remain separate checks.

### Operational signals

Terraform owns two ECS operational alarm classes:

- sustained `DesiredTaskCount - RunningTaskCount > 0` for services monitored through Container Insights; and
- sustained `UnHealthyHostCount > 0` for ingress-enabled services.

Both alarm classes notify the SecOps SNS topic on `ALARM` and `OK`.

These alarms are separate from the CloudWatch alarms that AWS creates internally
for target-tracking policies. AWS-managed target-tracking alarms remain AWS-managed.
Both operational families treat missing data as non-breaching; their configuration
or `OK` state is not an independent availability guarantee. Desired and running
counts can both be zero, and an unhealthy-target metric does not prove a minimum
number of healthy targets or successful transactions.

### GuardDuty Fargate Runtime Monitoring

The shared ECS cluster expresses profile-derived participation through the exact `GuardDutyManaged` tag:

```text
production/development -> true
minimal                -> false
```

For protected profiles, each deployable service's task execution role receives only the additional ECR pull scope for the regional AWS-hosted `aws-guardduty-agent-fargate` repository. Application image permissions remain independently resource-scoped.

Terraform's task definition remains application-only. GuardDuty injects and manages the runtime agent on protected tasks. Live ECS may report the agent as `aws-gd-agent` or an AWS-generated `aws-guardduty-agent-<suffix>` name.

For protected running tasks, `validate-ecs-runtime.sh` checks exactly one running
GuardDuty agent, the application-container contract, and GuardDuty ECS coverage of
`AUTO_MANAGED` / `HEALTHY` with no unresolved issues. Empty-service and not-yet-running
branches do not establish live instrumentation. A healthy coverage report is a
point-in-time service observation, not proof that the application is uncompromised.

Coverage-state changes are routed through the existing SecOps notification architecture. The default-bus rule matches both `GuardDuty Runtime Protection Unhealthy` and `GuardDuty Runtime Protection Healthy` for ECS resources and uses the shared EventBridge security-notification DLQ/retry policy.

See [`docs/ecs-runtime-design.md`](docs/ecs-runtime-design.md) for the full runtime and runtime-security contract.

## CI/CD and Application Releases

GitHub Actions uses OIDC to assume account-specific AWS roles without storing long-lived AWS access keys.

Core workflows include:

- `Deploy Application`
- `Terraform Plan`
- `Terraform Apply`
- `Reconcile Workload Account`
- `Terraform Destroy`
- Static analysis and documentation validation
- Workload, control-plane, and security-operations evidence export

### Terraform Plan and Apply

The standalone `Terraform Plan` workflow is informational and does not produce the artifact consumed by Apply.

The self-contained `Terraform Apply` workflow follows:

```text
internal Plan job
  -> readable plan
  -> binary saved plan
  -> metadata + checksum
  -> protected approval
  -> verify exact artifact
  -> apply exact binary plan
```

Workload Plan/Apply paths require a valid `DEPLOYMENT_PROFILE` and fail closed when it is missing or invalid.

### Application publication

Application publication is separate from Terraform infrastructure deployment:

```text
application source + Dockerfile
  -> branch-trusted GitHub OIDC image publisher
  -> build and push image to ECR
  -> resolve authoritative sha256 digest
  -> separate repository-write job
  -> update only ecs_services.<service>.image_digest
  -> release PR
  -> human review and merge
  -> protected Terraform Apply
  -> ECS convergence
  -> validation
```

The image-publisher job has AWS/ECR authority but not repository-write authority.
The release-PR job has repository-write authority but no AWS credentials or OIDC
permission. These describe the declared workflow jobs, not a security boundary
against every malicious source change.

Publication requires the Amazon ECR Docker credential helper. The push operation
uses an isolated temporary Docker configuration and disables the helper's token
file cache instead of running `docker login`. That configuration is scoped to the
push; it does not erase pre-existing Docker credentials or isolate every build step.
See [publication prerequisites](scripts/deployment/README.md).

Plan trust uses the corresponding GitHub Environment subject. Apply uses an
Environment subject or configured branch subjects, depending on its input;
Image Publisher uses configured branch subjects. Required reviewers and deployment
branch restrictions are GitHub settings, not proof supplied by role names. Saved-plan
checksums detect changed bytes; they do not authenticate an independent approver or
replace protection of the workflow, artifacts, and privileged roles.

Terraform never builds or pushes application images.

See [`scripts/deployment/README.md`](scripts/deployment/README.md) for detailed operator behavior.

---

## Deployment Overview

Before the first Apply, resolve licensing, account ownership, literal backend
coordinates, Region/CIDR selection, administrative access, response authorization,
remediation scope, preservation, and cost requirements in the
[adoption guide](docs/adoption-guide.md). The AWS provider Region must agree with
`primary_region`; administrative roots and backend configuration have separate
context requirements.

Recommended high-level sequence:

1. Bootstrap and migrate the control-plane state stack.
2. Deploy the control-plane account and Organizations stacks.
3. Bootstrap and migrate the security-operations state stack.
4. Deploy the security-operations account and centralized security-services stack.
5. Bootstrap and migrate each workload state stack and deploy its account/OIDC stack.
6. Deploy `environments/<env>` through the local or protected plan-first path.
7. Reconcile workload account-stack permissions when GitHub OIDC is enabled.
8. Deploy or re-apply IAM Identity Center assignments.
9. Run the applicable validation and evidence workflows.
10. Complete approved behavioral/recovery tests and review the applicable retirement procedure.

Use the Terraform CLI specified by the workflows and the committed per-root
`.terraform.lock.hcl` files; do not silently upgrade providers while reproducing
an accepted plan. Configure both members of each GitHub Plan/Apply Environment
pair consistently. A passing example does not authorize testing production or
removing its durable data.

Supported state migration targets:

```text
control-plane
security-operations
dev
staging
prod
```

For detailed deployment instructions, use [`docs/quickstart.md`](docs/quickstart.md).

---

## Validation and Evidence

The repository uses four read-only validation layers:

| Layer | Validator | Evidence exporter |
|---|---|---|
| Control plane | `validate-control-plane.sh` | `export-control-plane.sh` |
| Security operations | `validate-security-operations.sh` | `export-security-operations.sh` |
| Workload bootstrap | `validate-bootstrap.sh <env>` | `export-bootstrap.sh <env>` |
| Workload baseline | `validate-baseline.sh <env>` | `export-baseline.sh <env>` |

The workload baseline suite contains 16 validators covering environment identity, networking, VPC endpoints, ECR, logging, workload security, KMS, Backup, SNS, SQS, EventBridge, Lambda, SSM, EC2 compute, ECS runtime, and IAM.

The total counts successful child-script exits, not individual assertions.
Warnings, unqueried paths, and empty-runtime branches remain distinguishable from
successful behavioral tests. The baseline runner proceeds sequentially and reports
failed children; the exporter independently reruns the children rather than
packaging a preceding run.

Runtime checks cover the declared ECS service, IAM, network, scaling, logging,
ALB, alarm, and GuardDuty contracts, with live instrumentation requirements scoped
to applicable running workloads. Administrative configuration, member-account
realization, and end-user access require their respective evidence layers.

`validate-backup.sh` compares resource-backed RDS resilience and AWS Backup settings.
It is not an exhaustive database configuration, SQL, failover, or application-data
audit. Restore Testing configuration, actual execution, application validation, and
temporary-resource cleanup are separate results; some warning states can coexist
with a passing script.

Generated packages contain Markdown, JSON, and logs. Preserve the actual source
commit, effective non-secret inputs, account/Region, selected image digests,
execution time, warnings, and reviewer decisions with the evidence. The summaries
do not automatically establish every item of provenance or a signed custody chain.
Earlier qualification remains associated with its original configuration and run;
this README does not relabel it as fresh testing of the current checkout.

Detailed guidance:

- [`scripts/validation/README.md`](scripts/validation/README.md)
- [`docs/validation-checklist.md`](docs/validation-checklist.md)
- [`docs/assurance/validation-evidence-guide.md`](docs/assurance/validation-evidence-guide.md)
- [`docs/assurance/validation-report-template.md`](docs/assurance/validation-report-template.md)

Live EC2 isolation/rollback, IP enrichment, IAM Identity Center end-user login, tamper simulation, break-glass assumption, and destroy-safety testing remain separately controlled activities.

## State Management

Terraform state is separated by account and Terraform root.

State bootstrap stacks follow a two-phase lifecycle:

```text
1. Initial local apply creates the S3 state bucket and KMS CMK.
2. migrate-state-stack.sh migrates the state into that protected S3 backend.
```

Remote-backed roots use Terraform S3 native locking with:

```hcl
use_lockfile = true
```

Tracked `backend.tf.migrated.example` files document intended post-migration configuration, while active state-stack `backend.tf` files are ignored by Git.

A state stack must never destroy the bucket containing its own active state.
Intentional teardown first requires independent state and external backups; that
step alone does not remove the state module's literal destruction guards. Workload
retirement is not a state-resource teardown mechanism.

Service `primary_region`, state-resource `state_region`, and S3 backend `region`
serve different purposes. Bucket names and object keys in backend files are literal
coordinates, not rewritten by `cloud_name` or an IAM bucket-ARN input. Review
migration and access separately when any of these change.

See [`scripts/bootstrap/README.md`](scripts/bootstrap/README.md) for migration and reconciliation details.

---

## Cost Considerations

Cost drivers include AWS Network Firewall, per-AZ NAT/Interface Endpoints,
CloudWatch ingestion and retention, Config, Inspector, Security Hub/GuardDuty,
Runtime Monitoring, standalone EC2, RDS/Multi-AZ and native snapshots, Backup
storage/restore jobs, ECS/Fargate, ALB, keys, and data transfer. The shared baseline
still has a resource footprint when no application digest is selected; the
reduced-service profile is not free. Temporary restores and retained artifacts
can continue to incur costs outside the application lifecycle.

Recommended defaults:

- `production` for production or sensitive workloads
- `development` for lower-cost development/testing
- `minimal` for private AWS-only testing without general internet access

Review environment-specific usage and AWS pricing before treating the default profiles as a fixed cost model.

---

## Repository Layout

```text
bootstrap/       account, state, Organizations, Identity Center, and security-operations roots
environments/    dev, staging, and prod workload roots
modules/         reusable infrastructure modules
scripts/         bootstrap, deployment, and validation tooling
docs/            architecture, adoption, validation, assurance, and runtime design
.github/         CI/CD, static-analysis, and evidence workflows
```

---

## Documentation

| Document | Purpose |
|---|---|
| [`docs/quickstart.md`](docs/quickstart.md) | End-to-end deployment guide |
| [`docs/architecture-overview.md`](docs/architecture-overview.md) | Architecture and ownership boundaries |
| [`docs/design-principles.md`](docs/design-principles.md) | Design rationale and tradeoffs |
| [`docs/adoption-guide.md`](docs/adoption-guide.md) | Guidance for adapting the baseline |
| [`docs/ecs-runtime-design.md`](docs/ecs-runtime-design.md) | ECS/Fargate runtime and release architecture |
| [`docs/production-retirement.md`](docs/production-retirement.md) | Staged production retirement, approvals, cleanup, and preservation boundaries |
| [`SECURITY.md`](SECURITY.md) | Private vulnerability reporting and maintenance scope |
| [`CHANGELOG.md`](CHANGELOG.md) | Historical change records; not current operating instructions |
| [`docs/validation-checklist.md`](docs/validation-checklist.md) | Post-deployment validation checklist |
| [`docs/assurance/`](docs/assurance/) | Evidence guidance and SOC 2 / ISO 27001-aligned mappings |
| [`scripts/bootstrap/README.md`](scripts/bootstrap/README.md) | State migration and workload-account reconciliation |
| [`scripts/deployment/README.md`](scripts/deployment/README.md) | Application publication and digest promotion |
| [`scripts/validation/README.md`](scripts/validation/README.md) | Validation layers, usage, and safety boundaries |
| [`bootstrap/control_plane/README.md`](bootstrap/control_plane/README.md) | Control-plane responsibilities |
| [`bootstrap/security_operations/README.md`](bootstrap/security_operations/README.md) | Central-security responsibilities |

---

<a id="release-highlights"></a>

## Production Availability and Recovery

The production profile selects three standard AZs by default, with dedicated
public-ingress and public-egress subnet roles. The ALB uses ingress-public subnets;
NAT Gateways use egress-public subnets. In inspected mode, compute outbound and
return routes use the same-AZ firewall/NAT path without overriding the ALB-to-task
VPC-local path.

RDS remains a PostgreSQL **Multi-AZ DB instance**, not Aurora or a three-node DB
cluster. Production rejects `rds_multi_az=false`, enables deletion protection in
normal operation, requires a final snapshot, and retains automated backups at
deletion. RDS-native backups, scheduled AWS Backup, and isolation snapshots are
separate mechanisms with separate scopes and retention behavior.

AWS Backup Restore Testing is configured for the production profile when scheduled
backup is enabled. It selects the latest eligible snapshot within the configured
window from the workload vault for the exact managed RDS instance. The temporary
restore uses private networking and `multiAz=false`; no application-data validation
handler is supplied by the Backup module. Configuration presence is not a measured
recovery time or proof of a completed restore, successful application checks, or
cleanup. See the [Backup reference](modules/backup/README.md) and
[evidence guide](docs/assurance/validation-evidence-guide.md).

### Production retirement

`production_retirement_mode=true` is explicit retirement intent, not a request to
switch production into a development profile. The reviewed Stage-1 plan derives
zero ECS capacity and removes the necessary RDS/ALB/firewall deletion protections
while retaining the production durable-data boundaries. ECR/ECS force deletion
and Backup-vault force destruction remain disabled for the production profile.

The implemented workflow separates these stages:

```text
reviewed Stage-1 plan and Apply
  -> durable-data inventory and Destroy preflight
  -> separately approved durable-data cleanup
  -> retirement readiness validation
  -> saved workload destroy plan
  -> separately planned and approved Identity Center cleanup
  -> final workload-destroy approval
  -> artifact verification and readiness recheck
  -> exact saved-plan Apply
```

The complete durable-cleanup path is restricted to the `prod` environment, even
though profile-derived protections can apply elsewhere. Cleanup re-inventories at
execution; it does not replay a frozen item manifest. Rejecting a later approval
does not undo earlier cleanup. Required evidence, recovery artifacts, secrets, and
usable encryption keys need a preservation plan outside the deletion scope.

Follow the [retirement runbook](docs/production-retirement.md), not this overview,
for the exact inputs, approval gates, and recovery boundaries.

<a id="future-roadmap"></a>

## Extension Boundaries

The supplied runtime is for long-running ECS services and standalone EC2 hosts.
It does not provide first-class scheduled/run-to-completion ECS jobs, generic
application task-IAM permissions, multi-container application services, ECS Exec,
application database-user/migration lifecycle, WAF/DNS ownership, or cross-Region
application recovery. Automatic ECS/Fargate containment is also absent.

These are separate design and implementation decisions, not promised deliverables.
A downstream application must fit the actual service interface or provide reviewed
extensions with their own ownership, permissions, operations, and validation.
Historical changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Intended Audience

- Cloud security engineers
- DevSecOps engineers
- Platform engineers
- SaaS founders
- Security consultants
- Teams preparing for SOC 2 / ISO 27001

---

## Summary

`tf-secure-baseline` is a deployable AWS security foundation and generic application-hosting baseline for sensitive workloads.

It combines separate account/stack ownership, segmented networking, security-service
integration, EC2 and ECS/Fargate hosting, RDS resilience, backup/restore resources,
reviewable deployment and retirement, and layered validation. The implementation
and documented limitations must be assessed together for the intended application;
control presence alone is not proof of secure operation or recoverability.

The goal is to provide a secure-by-default foundation that can be adapted and extended without representing the infrastructure alone as a complete compliance program.

---

## License

Copyright © 2026 Nano Nexus Holdings LLC. All rights reserved.

Terraform Secure Baseline is proprietary software. No license or permission to use, copy, modify, distribute, sublicense, or deploy the software is granted except as expressly provided in the [LICENSE](LICENSE) file or in a separate written agreement with Nano Nexus Holdings LLC.

Revisions of the project that were previously distributed under the Apache License 2.0 remain subject to the license terms that applied when those revisions were distributed. The current proprietary license does not revoke or restrict rights previously and validly granted under Apache License 2.0.

Terraform Secure Baseline is owned and maintained by Nano Nexus Holdings LLC. See [LICENSE](LICENSE) for the complete terms.
