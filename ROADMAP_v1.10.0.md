# Terraform Secure Baseline v1.10.0

## Proposed Release Name

`v1.10.0 - ECS Runtime Security`

## Release Goal

Extend the production-oriented ECS/Fargate runtime delivered in v1.8.0 and
operationalized in v1.9.0 with GuardDuty Runtime Monitoring coverage for the
Terraform-managed Fargate cluster.

The release should add runtime threat-detection coverage without weakening the
existing ownership model:

- `security-operations` continues to own centralized GuardDuty organization
  configuration.
- workload Terraform continues to own ECS clusters, task execution IAM,
  networking, VPC endpoints, service configuration, and workload validation.
- GuardDuty may manage the Fargate security agent, but it must reuse
  Terraform-owned networking rather than introduce unmanaged VPC endpoint
  resources.
- ECS runtime security remains inside the existing workload-baseline validation
  layer. No fifth validation/evidence layer is introduced.

## Core Release Boundary

v1.10.0 should include:

1. Explicit Terraform-controlled GuardDuty Runtime Monitoring enrollment for the
   workload ECS cluster.
2. Exact task execution-role permissions required for the GuardDuty Fargate
   security agent image.
3. Reuse and validation of the Terraform-owned `guardduty-data`, ECR, and S3
   connectivity paths.
4. Runtime coverage health monitoring and SecOps notification.
5. Exact validation of cluster enrollment, agent injection, runtime coverage,
   IAM scope, and endpoint ownership.
6. Live development qualification and final no-change Terraform plan.
7. Documentation and release reconciliation.

v1.10.0 should **not** implement automatic Fargate task containment unless a
separate design proves a safe, fail-closed mechanism that does not rely on
modifying a running Fargate task ENI.

## Architecture Decisions to Preserve

### One canonical application service map

`ecs_services` remains the single operator-maintained application service
inventory.

GuardDuty Runtime Monitoring is a cluster/runtime security capability and should
not create a second per-service inventory.

### Centralized GuardDuty ownership

The delegated `security-operations` account remains the owner of GuardDuty
organization configuration and Runtime Monitoring enablement.

Workload stacks must not create or manage GuardDuty detectors or organization
configuration.

### Selective cluster enrollment

Prefer explicit ECS cluster enrollment over globally enabling Fargate agent
management for every ECS cluster in every workload account.

Proposed workload control:

```hcl
guardduty_fargate_runtime_monitoring_enabled = false
```

When enabled, the Terraform-managed ECS cluster should carry:

```text
GuardDutyManaged=true
```

When disabled, Terraform should express the non-enrolled state deliberately,
preferably through `GuardDutyManaged=false` unless live qualification proves
that tag absence provides a cleaner stable contract.

This preserves an explicit opt-in model and avoids silently enrolling unrelated
future ECS clusters.

### Terraform-owned GuardDuty VPC endpoint

The existing Terraform-owned Interface VPC Endpoint:

```text
com.amazonaws.<region>.guardduty-data
```

remains the authoritative Runtime Monitoring telemetry endpoint.

GuardDuty automated agent management must reuse the existing endpoint rather
than creating a second unmanaged endpoint/security group.

### Existing private Fargate networking

Preserve:

- `awsvpc`
- `assign_public_ip = false`
- compute-private subnets
- Terraform-managed task security groups
- `ecr.api` Interface Endpoint
- `ecr.dkr` Interface Endpoint
- S3 Gateway Endpoint
- `guardduty-data` Interface Endpoint

### Fargate platform requirement

The current module default of Fargate platform `1.4.0` already satisfies the
minimum platform requirement for GuardDuty Runtime Monitoring.

v1.10 validation should make this relationship explicit rather than relying on
an undocumented assumption.

### Task execution IAM remains least privilege

The current execution role already grants the application image-pull actions:

```text
ecr:GetAuthorizationToken
ecr:BatchCheckLayerAvailability
ecr:GetDownloadUrlForLayer
ecr:BatchGetImage
```

Application image-pull permissions remain scoped to application ECR
repositories.

When GuardDuty Fargate Runtime Monitoring is enabled, add only the additional
repository scope required to pull the AWS-hosted
`aws-guardduty-agent-fargate` image.

Do not replace the existing resource-scoped policy with broad
`AmazonECSTaskExecutionRolePolicy` attachment.

The exact cross-account GuardDuty-agent ECR resource-scoping strategy must be
finalized before implementation. Prefer a portable least-privilege ARN pattern
or another exact Terraform-derived contract over an unbounded ECR wildcard.

### Existing tasks are not silently recycled

GuardDuty injects the Fargate security agent only into new tasks/new service
deployments.

Enabling the feature must not cause Terraform to permanently force deployments
on every apply.

The rollout procedure should explicitly perform one controlled service
redeployment during qualification/adoption after all prerequisites are in
place.

## Milestones

| Milestone | Purpose | Expected repository areas |
|---|---|---|
| **R1 - Runtime Monitoring Contract** | Finalize ownership, opt-in semantics, rollout behavior, IAM scope, endpoint ownership, and validation contract before changing live resources | `ROADMAP_v1.10.0`, `docs/ecs-runtime-design.md`, `baseline/variables.tf`, `modules/ecs_cluster/`, `bootstrap/security_operations/security_services/` |
| **R2 - Agent Prerequisite Wiring** | Add conditional GuardDuty-agent ECR pull scope and prove existing Fargate platform/network prerequisites | `modules/iam/ecs.tf`, `baseline/locals.tf`, `baseline/main.tf`, `modules/networking/security_policy/`, `modules/vpc_endpoints/` |
| **R3 - Cluster Enrollment** | Add explicit Terraform-managed `GuardDutyManaged` cluster intent without globally enrolling unrelated ECS clusters | `modules/ecs_cluster/variables.tf`, `modules/ecs_cluster/main.tf`, `baseline/main.tf`, environment variable interfaces |
| **R4 - Coverage Health Signals** | Route GuardDuty Runtime Protection unhealthy coverage events to SecOps while preserving existing notification architecture | `modules/monitoring/`, `modules/automation/` or `modules/security/` as appropriate, baseline outputs/locals |
| **R5 - Exact Runtime Security Validation** | Extend current validation to prove agent prerequisites, cluster enrollment, agent sidecar state, GuardDuty coverage, and Terraform-owned endpoint reuse | `scripts/validation/validate-ecs-runtime.sh`, `scripts/validation/lib/ecs-runtime/`, `validate-security-operations.sh` only where central GuardDuty state is authoritative |
| **R6 - Live Qualification** | Enable in development, redeploy a test service, prove healthy coverage and stable application behavior, exercise opt-out/rollback, run full evidence, finish with no-change plan | dev configuration/evidence only; no production rollout required |
| **R7 - Documentation & Release** | Reconcile module, architecture, validation, quickstart, assurance, README, and changelog documentation with the qualified implementation | docs, module READMEs, validation/deployment READMEs, root README/CHANGELOG |

## R1 - Runtime Monitoring Contract

Before implementation, lock these decisions:

1. `security-operations` remains the GuardDuty organization owner.
2. Workload Terraform owns ECS cluster inclusion/exclusion intent.
3. Runtime Monitoring is cluster-scoped, not configured independently for each
   canonical `ecs_services` entry.
4. `guardduty-data` remains Terraform-owned.
5. GuardDuty must not create duplicate VPC endpoint/security-group resources.
6. Runtime Monitoring enablement is separate from automatic task containment.
7. Existing running services require an explicit one-time redeployment for agent
   injection after enablement.
8. Validation must fail if a cluster is expected to be protected but GuardDuty
   reports unhealthy coverage after the normal convergence window.

Recommended input:

```hcl
variable "guardduty_fargate_runtime_monitoring_enabled" {
  description = "Whether the Terraform-managed ECS/Fargate cluster is enrolled in GuardDuty Runtime Monitoring."
  type        = bool
  default     = false
}
```

Do not make the first implementation implicitly environment-specific. Keep the
module/baseline reusable; environment policy can decide whether dev, staging,
and prod enable it.

## R2 - Agent Prerequisite Wiring

### IAM

When runtime monitoring is disabled:

- ECS execution-role ECR scope remains unchanged.

When runtime monitoring is enabled:

- preserve registry-wide `ecr:GetAuthorizationToken`;
- preserve existing exact application repository pull permissions;
- add only the GuardDuty agent repository scope required for:
  - `ecr:BatchCheckLayerAvailability`
  - `ecr:GetDownloadUrlForLayer`
  - `ecr:BatchGetImage`

Do not grant ECR push permissions.

Do not grant general ECR administrative permissions.

### Networking

The current workload already supplies the required private image/telemetry paths:

```text
task SG
  -> ecr.api / ecr.dkr Interface Endpoints
  -> S3 Gateway Endpoint
  -> guardduty-data Interface Endpoint
```

Qualification must prove those paths are sufficient for agent injection in
`vpc_endpoints_only`, not only in NAT-backed development networking.

### Task sizing

GuardDuty injects a security-agent sidecar and consumes task resources.

The release should document this cost and validate supported Fargate CPU/memory
combinations, but should not automatically inflate user-selected application
task sizes.

Container Insights should be used during live qualification to observe agent
overhead.

## R3 - Cluster Enrollment

Extend `modules/ecs_cluster` with explicit Runtime Monitoring intent.

Expected behavior:

```text
enabled  -> GuardDutyManaged=true
disabled -> explicit non-enrolled state
```

The setting must not change:

- ECS cluster identity;
- Container Insights behavior;
- application service definitions;
- image digest release ownership;
- autoscaling ownership;
- task security-group ownership.

Enrollment must be visible through Terraform outputs so validation does not
reconstruct intent from names or environment assumptions.

Suggested output:

```text
guardduty_fargate_runtime_monitoring_enabled
```

or an equivalent cluster-security metadata output.

## R4 - Coverage Health Signals

Add an operational signal for GuardDuty Runtime Protection coverage failures.

Preferred event source:

```text
source      = aws.guardduty
detail-type = GuardDuty Runtime Protection Unhealthy
resource    = ECS
```

Route the event through the existing SecOps notification architecture.

The signal should identify at least:

- workload account;
- Region;
- ECS cluster;
- current/previous coverage state;
- GuardDuty-reported issue;
- update time.

Do not create a parallel notification system for this feature.

Healthy recovery events may optionally be routed as recovery/OK evidence if that
fits the existing notification contract cleanly.

## R5 - Exact Runtime Security Validation

Keep one ECS runtime validator entry point.

Extend the existing modular validator rather than adding a seventeenth
workload-baseline validator solely for GuardDuty Fargate.

Validation should prove, when enabled:

### Terraform contract

- expected Runtime Monitoring setting is present;
- cluster has exact expected `GuardDutyManaged` intent;
- Fargate platform version is compatible;
- exact GuardDuty-agent ECR permission scope exists;
- required task execution actions are present;
- application ECR permissions remain unchanged and least-privilege;
- required VPC endpoints exist;
- exactly one `guardduty-data` endpoint exists for the workload VPC;
- the endpoint is Terraform-owned according to the baseline contract;
- task SG relationships permit ECR, S3, and GuardDuty telemetry paths.

### Live ECS state

For deployable services after rollout:

- service is steady;
- expected running tasks are present;
- GuardDuty sidecar container is present on newly deployed tasks;
- GuardDuty sidecar is `RUNNING`;
- application container remains healthy;
- runtime agent injection does not alter the task definition's canonical
  application container contract.

### GuardDuty coverage

Use GuardDuty coverage APIs from the appropriate authorized validation layer to
prove:

- resource type is ECS;
- target cluster is the expected cluster;
- management type is auto-managed when enrolled;
- coverage status is healthy;
- no unresolved Fargate coverage issues are reported.

Centralized GuardDuty organization configuration remains a
security-operations-validation responsibility. Workload validation should not
pretend to own delegated-administrator configuration.

### Disabled state

When runtime monitoring is disabled:

- no GuardDuty agent repository permission should be added;
- cluster enrollment must match disabled intent;
- absence of injected GuardDuty sidecars is valid;
- validation must not require healthy GuardDuty ECS coverage.

## R6 - Live Qualification

Use development first.

### Qualification sequence

1. Confirm current v1.9.0 development plan is clean before v1.10 changes.
2. Apply IAM/network prerequisite changes while Runtime Monitoring remains
   disabled.
3. Confirm the ECS application continues to converge normally.
4. Enable Runtime Monitoring enrollment for the development ECS cluster.
5. Apply and verify the cluster enrollment state.
6. Trigger one controlled new ECS service deployment so new tasks are eligible
   for GuardDuty sidecar injection.
7. Confirm the application service reaches steady state.
8. Confirm the GuardDuty sidecar is present and running.
9. Confirm GuardDuty reports healthy ECS/Fargate runtime coverage.
10. Confirm the existing Terraform-owned `guardduty-data` endpoint is reused and
    no duplicate unmanaged endpoint/security group appears.
11. Observe Container Insights during the qualification window for CPU/memory
    impact.
12. Exercise the Runtime Protection unhealthy notification path with a safe test
    event/pattern validation or another non-destructive method.
13. Run `validate-ecs-runtime.sh`.
14. Run the full workload baseline suite.
15. Run the applicable security-operations validation/evidence.
16. Run strict workload bootstrap validation if IAM bootstrap state is affected.
17. Confirm a final Terraform plan reports no changes.
18. Exercise the documented disable/rollback path and confirm the resulting
    ownership behavior is understood before production adoption.

### Release gate

| Test | Required result |
|---|---|
| GuardDuty Fargate prerequisites | PASS |
| Cluster enrollment intent | PASS |
| Exact agent ECR IAM scope | PASS |
| Existing application ECR IAM scope preserved | PASS |
| Terraform-owned `guardduty-data` endpoint reused | PASS |
| No duplicate unmanaged GuardDuty endpoint/SG | PASS |
| GuardDuty sidecar injected on new tasks | PASS |
| GuardDuty sidecar running | PASS |
| Application steady state with sidecar | PASS |
| GuardDuty ECS coverage | HEALTHY |
| Runtime coverage unhealthy notification path | PASS |
| `validate-ecs-runtime.sh` | PASS |
| Full workload baseline | PASS |
| Security-operations validation | PASS |
| Final Terraform plan | No changes |

## Automatic ECS Task Containment - Explicitly Deferred

GuardDuty Runtime Monitoring findings can identify a compromised ECS/Fargate
task, but automatic containment needs a different design from EC2 isolation.

Do **not** copy the EC2 model of replacing the live resource's security groups.

Fargate task ENIs are AWS-managed and cannot be manually modified while the task
is running.

Potential future containment models require a separate design exercise, for
example:

- immediately stopping the affected task;
- service-wide emergency containment;
- controlled service network-configuration replacement and redeployment;
- application-level kill switches;
- image-revocation workflows;
- combinations of load-balancer deregistration, service scaling, and deployment
  controls.

Any future automatic response must define:

- exact GuardDuty finding/resource matching;
- task-to-service identity resolution;
- behavior for fixed-count versus autoscaled services;
- behavior when multiple tasks use the same compromised image;
- preservation of forensic evidence;
- rollback/recovery;
- prevention of Terraform/autoscaler conflict;
- fail-closed behavior;
- notification/evidence;
- live qualification.

Until that contract is proven, v1.10.0 should provide detection, coverage, and
operational visibility rather than unsafe automatic containment.

## Deferred Beyond v1.10.0

Keep these out of the v1.10.0 release unless the scope is deliberately changed:

- automatic ECS/Fargate task containment;
- ReconoSense reference deployment;
- scheduled/run-to-completion ECS task abstractions;
- audited ECS Exec;
- advanced WAF/DNS ownership;
- multi-container application abstractions;
- application database-user lifecycle;
- more sophisticated historical ECR retention;
- third-AZ/RDS resilience work;
- broad RDS validation expansion;
- architectural diagram program;
- general script normalization/technical-debt refactors.

## Suggested Follow-On Release Themes

### v1.11.0 - Platform Resilience

Candidate scope:

- third Availability Zone support;
- RDS subnet/AZ resilience;
- stronger RDS validation;
- related networking validation and migration safety.

### v1.12.0 - Application Lifecycle

Candidate scope:

- scheduled/run-to-completion ECS tasks;
- migration tasks;
- application database-user lifecycle;
- ReconoSense reference deployment.

The exact follow-on order can change, but keeping these themes separate prevents
v1.10.0 from mixing runtime threat detection with unrelated database/network
resilience and application-platform expansion.

## Final v1.10.0 Definition

v1.10.0 is complete when a Terraform-managed workload ECS/Fargate cluster can be
explicitly enrolled in GuardDuty Runtime Monitoring, newly deployed tasks receive
the GuardDuty security agent, private networking and least-privilege IAM remain
under Terraform ownership, unhealthy coverage reaches SecOps, exact validation
proves the intended state, live development qualification passes, and Terraform
converges with no changes.
