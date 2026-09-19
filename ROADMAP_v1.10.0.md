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
  configuration through Terraform.
- workload Terraform continues to own ECS clusters, task execution IAM,
  networking, VPC endpoints, service configuration, deployment-profile
  decisions, and workload validation.
- Terraform owns the GuardDuty Runtime Monitoring policy and cluster enrollment
  intent; GuardDuty service-manages the resulting `aws-gd-agent` injection,
  updates, and runtime telemetry collection.
- GuardDuty must reuse Terraform-owned networking rather than introduce unmanaged
  VPC endpoint resources.
- ECS runtime security remains inside the existing workload-baseline validation
  layer. No fifth validation/evidence layer is introduced.

## Core Release Boundary

v1.10.0 should include:

1. Terraform-controlled GuardDuty Runtime Monitoring defaults derived from
   `deployment_profile`, with organization-wide Fargate agent management enabled
   and explicit workload-cluster inclusion/exclusion intent.
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
organization configuration and Runtime Monitoring enablement through Terraform.

The accepted v1.10 organization contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

This makes Fargate runtime protection a secure-by-default organization policy for
existing and future member accounts.

Workload stacks must not create or manage GuardDuty detectors or organization
configuration. They consume the organization policy by expressing whether the
Terraform-managed ECS cluster participates according to the effective
deployment-profile policy.

### Deployment-profile-driven Fargate Runtime Monitoring

GuardDuty Fargate Runtime Monitoring is a cost-sensitive security control and is
therefore derived from the existing `deployment_profile` contract rather than a
new top-level operator toggle.

Accepted defaults:

| `deployment_profile` | Fargate Runtime Monitoring |
|---|---:|
| `production` | Enabled |
| `development` | Enabled |
| `minimal` | Disabled |

The intended effective policy is conceptually:

```hcl
profile_default_guardduty_fargate_runtime_monitoring_enabled = (
  !local.is_minimal_profile
)
```

No standalone
`guardduty_fargate_runtime_monitoring_enabled` input is part of the initial
v1.10 public interface.

The Terraform-managed ECS cluster expresses the effective policy explicitly:

```text
production  -> GuardDutyManaged=true
development -> GuardDutyManaged=true
minimal     -> GuardDutyManaged=false
```

`GuardDutyManaged=true` reinforces the baseline's intended protected state even
though organization-wide Fargate automated agent management is already enabled.
`GuardDutyManaged=false` is the explicit cluster-level exclusion used by the
cost-minimized profile.

This follows the same design pattern already used for other cost-sensitive
controls: the deployment profile chooses a secure/cost posture, while Terraform
retains an explicit resource-level desired state.

### Terraform and GuardDuty ownership boundary

Terraform owns:

- GuardDuty organization Runtime Monitoring configuration;
- GuardDuty Fargate automated-agent management configuration;
- deployment-profile defaults;
- ECS cluster `GuardDutyManaged` intent;
- task execution IAM;
- workload networking and VPC endpoints;
- validation expectations.

GuardDuty service-manages the runtime artifacts produced by that Terraform-owned
policy:

- `aws-gd-agent` injection;
- GuardDuty agent updates;
- runtime telemetry collection.

Those artifacts are intentionally not separate Terraform resource addresses.
This is analogous to AWS-managed target-tracking CloudWatch alarms: Terraform
owns the policy that causes AWS to create service-managed runtime artifacts,
while AWS owns their direct lifecycle.

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

When the effective deployment profile enables GuardDuty Fargate Runtime
Monitoring, add only the additional repository scope required to pull the
AWS-hosted `aws-guardduty-agent-fargate` image.

When the effective profile disables Runtime Monitoring (`minimal`), that
additional GuardDuty-agent repository scope must be absent.

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
| ✅**R1 - Runtime Monitoring Contract** | Finalize Terraform-vs-GuardDuty ownership, organization-wide agent management, deployment-profile defaults, cluster intent, rollout behavior, IAM scope, endpoint ownership, and validation contract before changing live resources | `ROADMAP_v1.10.0.md`, `docs/ecs-runtime-design.md` |
| ✅**R2 - Agent Prerequisite Wiring** | Add profile-aware GuardDuty-agent ECR pull scope and prove existing Fargate platform/network prerequisites without changing the application service contract | `modules/iam/ecs.tf`, `baseline/locals.tf`, `baseline/main.tf`, `modules/networking/security_policy/`, `modules/vpc_endpoints/` only if implementation changes are required |
| ✅**R3 - Profile-Driven Cluster Enrollment** | Set centralized `ECS_FARGATE_AGENT_MANAGEMENT = ALL` and add exact Terraform-managed `GuardDutyManaged=true/false` cluster intent derived from `deployment_profile` | `bootstrap/security_operations/security_services/`, `modules/ecs_cluster/`, `baseline/locals.tf`, `baseline/main.tf`, environment interfaces |
| ✅**R4 - Coverage Health Signals** | Route GuardDuty Runtime Protection unhealthy coverage events to SecOps while preserving existing notification architecture | `modules/monitoring/`, `modules/automation/` or `modules/security/` as appropriate, baseline outputs/locals |
| ✅**R5 - Exact Runtime Security Validation** | Extend current validation to prove agent prerequisites, cluster enrollment, agent sidecar state, GuardDuty coverage, and Terraform-owned endpoint reuse | `scripts/validation/validate-ecs-runtime.sh`, `scripts/validation/lib/ecs-runtime/`, `validate-security-operations.sh` only where central GuardDuty state is authoritative |
| **R6 - Live Qualification** | Enable in development, redeploy a test service, prove healthy coverage and stable application behavior, exercise opt-out/rollback, run full evidence, finish with no-change plan | dev configuration/evidence only; no production rollout required |
| **R7 - Documentation & Release** | Reconcile module, architecture, validation, quickstart, assurance, README, and changelog documentation with the qualified implementation | docs, module READMEs, validation/deployment READMEs, root README/CHANGELOG |

## R1 - Runtime Monitoring Contract ✅

**Status:** Complete.

R1 is intentionally a contract-only milestone. It locks the architecture before
R2 begins implementation and does not itself change runtime Terraform resources,
IAM policies, ECS cluster tags, GuardDuty organization configuration, or
validation code.

### Locked decisions

1. `security-operations` remains the Terraform owner of centralized GuardDuty
   organization configuration.
2. Central `RUNTIME_MONITORING` remains `ALL`.
3. Central `ECS_FARGATE_AGENT_MANAGEMENT` changes from `NONE` to `ALL` in v1.10
   so Fargate Runtime Monitoring is secure-by-default across organization member
   accounts.
4. Central `EC2_AGENT_MANAGEMENT` remains `ALL` and
   `EKS_ADDON_MANAGEMENT` remains `NONE`.
5. Runtime Monitoring remains a cluster/runtime security capability and does not
   add fields to the canonical `ecs_services` application map.
6. Fargate Runtime Monitoring is derived from `deployment_profile`, not a new
   initial top-level operator toggle:
   - `production` -> enabled;
   - `development` -> enabled;
   - `minimal` -> disabled.
7. Terraform expresses the effective workload-cluster intent explicitly:
   - enabled -> `GuardDutyManaged=true`;
   - disabled -> `GuardDutyManaged=false`.
8. Terraform owns the GuardDuty policy and enrollment intent. GuardDuty
   service-manages the resulting `aws-gd-agent` injection, updates, and runtime
   telemetry collection.
9. The existing Terraform-owned `guardduty-data` Interface VPC Endpoint remains
   the authoritative Runtime Monitoring telemetry endpoint.
10. GuardDuty must reuse Terraform-owned networking and must not create a second
    GuardDuty VPC endpoint or endpoint security group.
11. Existing private Fargate networking remains unchanged: `awsvpc`,
    `assign_public_ip = false`, compute-private subnets, task security groups,
    `ecr.api`, `ecr.dkr`, S3 Gateway Endpoint, and `guardduty-data`.
12. The ECS task execution role remains least privilege. When the effective
    profile enables Runtime Monitoring, Terraform adds only the GuardDuty-agent
    image-pull scope required in addition to the existing application-repository
    permissions.
13. When the effective profile is `minimal`, the additional GuardDuty-agent
    repository scope is absent.
14. The exact cross-account/Region GuardDuty Fargate agent ECR repository ARN
    derivation is an R2 implementation decision; broad ECR administration or
    unbounded repository access is not acceptable.
15. GuardDuty owns direct lifecycle of the injected `aws-gd-agent` sidecar.
    Terraform does not add that container to the canonical ECS task definition.
16. Existing running services are not silently retrofitted. Adoption of Runtime
    Monitoring for an already-running service requires one deliberate new
    deployment after prerequisites and cluster intent converge.
17. Terraform must not permanently force a new ECS deployment on every apply
    solely to obtain GuardDuty injection.
18. Security-operations validation owns centralized GuardDuty organization
    configuration. Workload ECS runtime validation owns effective profile intent,
    prerequisite IAM/networking, injected-agent state, and workload-local
    coverage expectations.
19. `validate-ecs-runtime.sh` remains the single ECS workload-baseline validator
    entry point. v1.10 does not create a seventeenth workload validator or a
    fifth evidence layer.
20. Runtime Monitoring enablement remains separate from automatic ECS/Fargate
    task containment. Automatic task containment is explicitly outside the
    v1.10 contract.

### Accepted deployment-profile policy

```text
production  -> GuardDuty Fargate Runtime Monitoring enabled
development -> GuardDuty Fargate Runtime Monitoring enabled
minimal     -> GuardDuty Fargate Runtime Monitoring disabled
```

Conceptual baseline local:

```hcl
profile_default_guardduty_fargate_runtime_monitoring_enabled = (
  !local.is_minimal_profile
)
```

The first implementation does not add a separate public
`guardduty_fargate_runtime_monitoring_enabled` variable. If a future adopter
demonstrates a legitimate need for an independent override, it can be added
later using the existing nullable-override pattern used by other
deployment-profile-controlled settings.

### Accepted ownership model

```text
Terraform directly owns:
  GuardDuty organization Runtime Monitoring policy
  GuardDuty Fargate automated-agent management policy
  deployment-profile defaults
  ECS cluster GuardDutyManaged intent
  task execution IAM
  ECR/S3/guardduty-data networking
  validation expectations

GuardDuty service-manages:
  aws-gd-agent injection
  aws-gd-agent upgrades
  runtime telemetry collection
```

The service-managed artifacts are an intentional AWS lifecycle boundary, not a
loss of infrastructure control: Terraform owns the policy that determines
whether they exist and the prerequisites under which they operate.

### R1 validation ownership boundary

Security-operations validation will eventually prove:

```text
GuardDuty delegated administrator
RUNTIME_MONITORING organization feature = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT = ALL
EKS_ADDON_MANAGEMENT = NONE
```

Workload ECS runtime validation will eventually prove:

```text
effective deployment-profile Runtime Monitoring policy
GuardDutyManaged=true for production/development
GuardDutyManaged=false for minimal
compatible Fargate platform version
exact profile-aware GuardDuty-agent ECR pull authority
required ECR/S3/guardduty-data connectivity
Terraform-owned guardduty-data endpoint reuse
aws-gd-agent injected on newly deployed protected tasks
aws-gd-agent RUNNING
healthy GuardDuty ECS/Fargate coverage when enabled
absence of GuardDuty-agent requirements when minimal disables the feature
```

### R1 exit criteria

- [x] Central GuardDuty ownership remains in Terraform under
      `security-operations`.
- [x] `ECS_FARGATE_AGENT_MANAGEMENT = ALL` is selected for v1.10.
- [x] Deployment-profile defaults are locked:
      production/development enabled, minimal disabled.
- [x] No initial standalone Runtime Monitoring enable/disable variable is added.
- [x] Exact `GuardDutyManaged=true/false` workload-cluster semantics are locked.
- [x] Terraform-vs-GuardDuty lifecycle ownership is documented.
- [x] Terraform-owned `guardduty-data` endpoint reuse is locked.
- [x] Least-privilege, profile-aware task execution IAM boundary is locked.
- [x] GuardDuty-owned `aws-gd-agent` lifecycle boundary is locked.
- [x] Existing-task rollout behavior is locked.
- [x] Validation ownership and four-layer evidence boundary are locked.
- [x] Automatic ECS/Fargate containment is explicitly deferred.
- [x] `docs/ecs-runtime-design.md` records the revised Runtime Monitoring
      contract.

R2 may now implement prerequisites without reopening these architecture
decisions.

## R2 - Agent Prerequisite Wiring

### IAM

When the effective deployment profile disables Runtime Monitoring (`minimal`):

- ECS execution-role ECR scope remains unchanged;
- no GuardDuty-agent ECR repository scope is added.

When the effective deployment profile enables Runtime Monitoring
(`production` or `development`):

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

The additional monitored-vCPU cost and sidecar resource overhead are part of the
reason Runtime Monitoring is profile-driven:

- `production`: security coverage takes precedence over incremental runtime cost;
- `development`: coverage remains enabled so the normal non-production
  environment exercises the same runtime-security architecture as production;
- `minimal`: Runtime Monitoring is disabled to preserve the deliberately
  cost-minimized posture.

## R3 - Profile-Driven Cluster Enrollment

R3 implements both sides of the policy:

1. centralized GuardDuty organization configuration; and
2. workload-cluster intent derived from `deployment_profile`.

### Centralized GuardDuty configuration

Update the centralized organization feature configuration so the accepted
runtime policy is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

The central configuration remains Terraform-owned from
`security-operations`.

### Workload profile default

Add a baseline effective setting derived from `deployment_profile`:

```text
production  -> enabled
development -> enabled
minimal     -> disabled
```

Do not add a standalone public Runtime Monitoring variable in the first
implementation.

### ECS cluster intent

Extend `modules/ecs_cluster` so the Terraform-managed cluster expresses the
effective setting exactly:

```text
enabled  -> GuardDutyManaged=true
disabled -> GuardDutyManaged=false
```

The tag must not change:

- ECS cluster identity;
- Container Insights behavior;
- application service definitions;
- image digest release ownership;
- autoscaling ownership;
- task security-group ownership.

Enrollment/effective policy must be visible through resource-backed Terraform
outputs so validation does not reconstruct intent from names or reimplement
deployment-profile logic in Bash.

Suggested cluster-security output fields include:

```text
guardduty_fargate_runtime_monitoring_enabled
guardduty_managed_tag_value
```

or equivalent resource-backed metadata.

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

- effective Runtime Monitoring policy matches `deployment_profile`;
- cluster has exact expected `GuardDutyManaged` intent (`true` for
  production/development, `false` for minimal);
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

### Minimal-profile disabled state

When `deployment_profile = "minimal"`:

- effective Fargate Runtime Monitoring must be disabled;
- `GuardDutyManaged=false` must be present;
- no GuardDuty agent repository permission should be added;
- absence of injected GuardDuty sidecars is valid;
- validation must not require healthy GuardDuty ECS coverage.

## R6 - Live Qualification

Use development first. Because there are no production workloads to preserve and
the current test infrastructure can be recreated from zero, qualification should
exercise the secure-by-default path from initial creation rather than simulate a
brownfield migration.

### Qualification sequence

1. Confirm centralized GuardDuty organization configuration plans
   `ECS_FARGATE_AGENT_MANAGEMENT = ALL`.
2. Confirm `development` resolves to Runtime Monitoring enabled.
3. Apply the centralized `security-operations` change and validate organization
   GuardDuty configuration.
4. Deploy the development workload prerequisites, including Terraform-owned
   ECR/S3/`guardduty-data` connectivity and exact task execution IAM.
5. Create the development ECS cluster with `GuardDutyManaged=true`.
6. Publish/select the test application digest and create the ECS service.
7. Confirm the first deployment receives `aws-gd-agent`; no retrofit deployment
   should be necessary for a freshly created service.
8. Confirm the application service reaches steady state.
9. Confirm the GuardDuty sidecar is present and `RUNNING`.
10. Confirm GuardDuty reports healthy ECS/Fargate runtime coverage.
11. Confirm the existing Terraform-owned `guardduty-data` endpoint is reused and
    no duplicate unmanaged endpoint/security group appears.
12. Observe Container Insights during the qualification window for CPU/memory
    impact.
13. Exercise the Runtime Protection unhealthy notification path with a safe,
    non-destructive event/pattern validation method.
14. Run `validate-ecs-runtime.sh`.
15. Run the full workload baseline suite.
16. Run security-operations validation/evidence.
17. Confirm a final Terraform plan reports no changes.
18. Separately exercise `deployment_profile = "minimal"` in plan/test state and
    prove `GuardDutyManaged=false`, absence of GuardDuty-agent ECR authority, and
    disabled-state validation semantics without weakening production/development
    defaults.

### Release gate

| Test | Required result |
|---|---|
| GuardDuty Fargate prerequisites | PASS |
| Central `ECS_FARGATE_AGENT_MANAGEMENT = ALL` | PASS |
| Production/development profile Runtime Monitoring default | ENABLED |
| Minimal profile Runtime Monitoring default | DISABLED |
| Cluster `GuardDutyManaged` intent | PASS |
| Exact agent ECR IAM scope | PASS |
| Existing application ECR IAM scope preserved | PASS |
| Minimal profile has no GuardDuty-agent ECR scope | PASS |
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

v1.10.0 is complete when Terraform centrally enables GuardDuty Runtime Monitoring
and Fargate automated agent management across the organization, the workload
`deployment_profile` produces secure-by-default Runtime Monitoring for
`production` and `development` while preserving a deliberate cost-minimized
`minimal` exclusion, ECS clusters express exact `GuardDutyManaged` intent,
least-privilege IAM and private networking remain Terraform-controlled,
GuardDuty service-manages healthy `aws-gd-agent` runtime instrumentation,
unhealthy coverage reaches SecOps, exact validation proves both enabled and
disabled states, live development qualification passes, and Terraform converges
with no changes.