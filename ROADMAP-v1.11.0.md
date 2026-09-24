# Terraform Secure Baseline v1.11.0

## Proposed Release Name

`v1.11.0 - Production Resilience`

## Release Goal

Strengthen the production profile of `tf-secure-baseline` with explicit
availability, recovery, and destructive-lifecycle guarantees while preserving
the ECS runtime, centralized security, deployment, and validation architecture
established through v1.10.0.

The release should make `production` materially more resilient without becoming
a general hardening backlog.

The intended result is:

- three-AZ production application/network topology;
- production RDS Multi-AZ and safer deletion/recovery behavior;
- redundant production ECS capacity with explicit Availability Zone
  rebalancing;
- profile-aware deletion protection for critical production resources;
- real RDS recovery verification through AWS Backup Restore Testing;
- exact read-only resilience validation; and
- live qualification followed by a no-change Terraform plan.

ReconoSense-specific assumptions remain outside this release.

## Core Release Boundary

v1.11.0 should include:

1. Production resilience defaults and plan-time constraints derived from
   `deployment_profile`.
2. Three-AZ production networking and propagation of the complete subnet sets to
   Network Firewall, VPC endpoints, RDS, ECS, and ALB.
3. Stronger RDS Multi-AZ, deletion-protection, final-snapshot, and automated
   backup behavior.
4. Production ECS minimum-capacity requirements and explicit Availability Zone
   rebalancing.
5. Profile-aware production lifecycle protection for RDS, ALB, Network
   Firewall, ECR, ECS services, and the Backup vault.
6. AWS Backup Restore Testing for the Terraform-managed RDS instance.
7. Exact resilience validation inside the existing workload-baseline layer.
8. Live production-profile qualification, documentation reconciliation, and
   release.

v1.11.0 should **not** migrate the database to Aurora or an RDS Multi-AZ DB
cluster, introduce multi-region architecture, add automatic Fargate
containment, or introduce ReconoSense-specific behavior.

## Architecture Decisions to Preserve

### Three-AZ production means the application/network substrate

Production should require at least three distinct Availability Zones.

Default `us-east-1` production topology:

```text
us-east-1a
us-east-1b
us-east-1c
```

The existing subnet families remain:

```text
public
compute_private
data_private
serverless_private
endpoint_private
firewall_private
```

Networking already loops over `var.azs`. v1.11 should extend that design instead
of creating a parallel topology model.

Development and minimal should remain capable of a lower-cost two-AZ posture.

### RDS remains an `aws_db_instance`

Keep:

```text
aws_db_instance.main
```

Do not migrate v1.11 to:

- Aurora;
- RDS Multi-AZ DB clusters;
- read replicas; or
- another database resource model.

The three-AZ production VPC does not imply a three-node database. The retained
Multi-AZ DB instance continues to use a primary and synchronous standby in
separate AZs.

### Production RDS resilience becomes mandatory

Production must resolve to:

```text
multi_az                 = true
deletion_protection      = true
skip_final_snapshot      = false
delete_automated_backups = false
publicly_accessible      = false
storage_encrypted        = true
```

`rds_multi_az = false` should not be accepted for the production profile.

The current non-secret RDS consumer outputs remain unchanged.

### Production ECS services require redundant capacity

Production deployable services must not be singletons.

```text
fixed-count:
  desired_count >= 2

autoscaled:
  min_capacity >= 2
```

Existing ownership remains:

```text
fixed-count
  -> Terraform owns desired_count

autoscaled
  -> Application Auto Scaling owns live desired_count
```

### ECS Availability Zone rebalancing is Terraform-owned

Production ECS services should explicitly set:

```text
availability_zone_rebalancing = ENABLED
```

Do not depend on AWS defaults.

Validation should consume the resource-backed Terraform value and compare it to
live ECS state.

### Production deployment-health semantics remain strict

Production should require:

```text
minimum_healthy_percent = 100
maximum_percent         >= 200
```

The existing deployment circuit breaker and automatic rollback remain enabled.

### Production cannot disable core resilience

The production profile should reject effective states such as:

```text
rds_multi_az = false
backup_enabled = false
```

Development and minimal may retain the current override flexibility.

### Production retirement is explicit

Do not document changing the deployment profile from `production` to
`development` as the way to destroy production.

Introduce explicit retirement intent, conceptually:

```text
production_retirement_mode = false
```

Normal production retains deletion protections.

Approved retirement may relax only the protections that must be removed to
perform a deliberate teardown.

Retirement should not automatically force-delete durable ECR images or Backup
recovery points.

### Recovery verification uses AWS Backup Restore Testing

v1.11 should prove that the RDS recovery path actually works.

Conceptually:

```text
Terraform-managed Backup vault
        |
        v
RDS recovery point
        |
        v
AWS Backup Restore Testing
        |
        v
private restored test resource
        |
        v
successful restore evidence
        |
        v
cleanup
```

The generic platform proves infrastructure recovery.

Application-level logical data validation remains future application/reference
deployment work.

### Existing validation architecture remains unchanged

There remain exactly four validation/evidence layers:

```text
Control plane
Security operations
Workload bootstrap
Workload baseline
```

The workload baseline remains:

```text
16 validators
```

Do not add a seventeenth validator solely for resilience.

### Existing ECS architecture remains unchanged

Preserve:

- one canonical `ecs_services` map;
- `image_digest = null` as registered-but-unreleased;
- digest-pinned runtime images;
- separate ECR, ECS cluster, ALB, and ECS service modules;
- private Fargate tasks;
- separate execution/task roles;
- fixed/autoscaled desired-count ownership;
- AWS-managed target-tracking alarms;
- Terraform-owned operational alarms;
- GuardDuty-managed runtime-agent injection; and
- Terraform-owned `guardduty-data` endpoint reuse.

### Exact reviewed-plan Apply remains unchanged

Preserve:

```text
internal Apply-workflow Plan
        |
        v
exact binary plan
        |
        v
human approval
        |
        v
checksum / metadata verification
        |
        v
apply exact reviewed plan
```

Do not re-plan after approval.

## Milestones

| Milestone | Purpose | Expected repository areas |
|---|---|---|
| ✅ **R1 - Production Resilience Contract** | Lock AZ, RDS, ECS availability, lifecycle-protection, retirement, Restore Testing, and validation semantics before resource changes | `ROADMAP-v1.11.0.md`, `baseline/variables.tf`, `baseline/locals.tf`, environment interfaces |
| ✅ **R2 - Three-AZ Production Topology** | Make production networking three-AZ and propagate the full topology to firewall, endpoints, RDS, ECS, and ALB | `modules/networking/`, `modules/firewall/`, `modules/vpc_endpoints/`, `baseline/`, environments |
| ✅ **R3 - RDS Resilience & Lifecycle** | Enforce production Multi-AZ, deletion protection, final-snapshot behavior, automated-backup retention, and exact RDS validation | `modules/storage/`, `baseline/`, workload outputs, `validate-backup.sh` |
| ✅ **R4 - ECS Production Availability** | Enforce redundant service capacity, strict deployment-health semantics, and explicit AZ rebalancing | `modules/ecs_service/`, `baseline/`, ECS runtime validators |
| ✅ **R5 - Production Lifecycle Protection** | Replace development-friendly production force-delete settings while preserving dev/minimal teardown | storage, ALB, firewall, ECR, ECS service, Backup modules |
| **R6 - Backup Restore Verification** | Add Terraform-owned AWS Backup Restore Testing for RDS and prove the recovery path | `modules/backup/`, `modules/iam/backup.tf`, storage/baseline outputs, `validate-backup.sh` |
| **R7 - Exact Resilience Validation** | Extend existing validators to prove the complete v1.11 contract without changing validation-layer count | workload validators and ECS runtime helpers |
| **R8 - Live Qualification & Release** | Exercise three-AZ topology, ECS replacement, RDS failover, RDS restore testing, dev teardown regression, evidence, docs, and final no-change plan | qualification/evidence, docs, module READMEs, README/CHANGELOG |

## R1 - Production Resilience Contract ✅

**Status:** Complete.

R1 is intentionally a contract-only milestone. It locks the production-resilience architecture before R2 begins changing live Terraform-managed infrastructure. R1 does not itself add a third AZ, modify RDS/ECS resources, enable deletion protection, or create Restore Testing resources.

It should lock effective production policy before R2 begins making live
infrastructure changes.

### Locked decisions

1. `deployment_profile = "production"` is the policy boundary for v1.11 resilience guarantees; do not key generic behavior directly from `environment == "prod"`.
2. Production requires at least three distinct Availability Zones; development/minimal may remain two-AZ.
3. Workload roots will expose and forward the existing `azs` and `subnet_cidrs` topology interfaces before R2 expands production networking.
4. The existing PostgreSQL `aws_db_instance.main` remains the database resource model. v1.11 does not migrate to Aurora or an RDS Multi-AZ DB cluster.
5. Production RDS must be Multi-AZ. An explicit `rds_multi_az = false` override is invalid under the production profile.
6. Production scheduled AWS Backup is mandatory. An explicit `backup_enabled = false` override is invalid under the production profile.
7. Production fixed-count ECS services require `desired_count >= 2`.
8. Production autoscaled ECS services require `min_capacity >= 2`; Application Auto Scaling continues to own live desired count after bootstrap.
9. Production ECS deployment settings require `minimum_healthy_percent = 100` and `maximum_percent >= 200`.
10. Production ECS Availability Zone rebalancing is explicitly Terraform-owned and enabled; do not rely on AWS defaults.
11. Production deletion/lifecycle behavior is profile-derived rather than exposed as independent per-resource operator toggles.
12. Normal production uses RDS deletion protection, ALB deletion protection, Network Firewall delete protection, `ECR force_delete = false`, `ECS force_delete = false`, and `Backup vault force_destroy = false`.
13. Intentional production retirement uses one explicit retirement signal rather than changing the deployment profile. The accepted public name is `production_retirement_mode`, default `false`.
14. `production_retirement_mode = true` may relax only native deletion protections required for deliberate retirement; it must not automatically force-delete ECR images or Backup recovery points.
15. Production RDS retirement still requires a final snapshot and retains automated backups regardless of retirement mode.
16. AWS Backup Restore Testing is the accepted generic RDS recovery-verification mechanism for v1.11.
17. Restore Testing proves infrastructure restorability only; application/business-data validation is outside the generic baseline contract.
18. Existing Backup IAM should be reused for Restore Testing if its current backup/restore authority is sufficient; do not create a broader second role without a demonstrated need.
19. New resilience expectations remain inside the existing four evidence layers and 16-validator workload baseline.
20. Validators consume Terraform-owned effective/resource-backed expectations rather than recreating production-profile policy in Bash.
21. Existing ECS architecture remains intact: one `ecs_services` map, nullable `image_digest`, digest-pinned runtime, fixed/autoscaled ownership split, private Fargate networking, and GuardDuty-managed agent injection.
22. The exact reviewed-plan Terraform Apply workflow remains unchanged.
23. KMS `lifecycle.prevent_destroy` redesign, Vault Lock compliance mode, multi-region resilience, and ReconoSense-specific behavior remain outside v1.11.

### Effective production contract

Production should require:

```text
Availability Zones             >= 3

RDS Multi-AZ                   enabled
scheduled AWS Backup           enabled
RDS deletion protection        enabled
RDS final snapshot             required
RDS automated backups          preserved on deletion

fixed ECS desired_count        >= 2
autoscaled ECS min_capacity    >= 2
minimumHealthyPercent          100
maximumPercent                 >= 200
ECS AZ rebalancing             enabled

ALB deletion protection        enabled
Network Firewall protection    enabled
ECR force_delete               disabled
ECS force_delete               disabled
Backup vault force_destroy     disabled

RDS Restore Testing            enabled
```

### Environment interfaces

The environment roots should explicitly pass AZ/subnet topology into `baseline`
instead of relying only on the current two-AZ baseline defaults.

Follow the existing effective-value pattern:

```text
input / nullable override
        |
        v
baseline local resolves effective value
        |
        v
resource consumes effective value
        |
        v
Terraform output
        |
        v
validator compares expected vs live
```

### Plan-time safeguards

Production should fail before Apply for states such as:

```text
fewer than 3 AZs
duplicate AZs
subnet CIDR count < AZ count
rds_multi_az = false
backup_enabled = false
fixed desired_count < 2
autoscaled min_capacity < 2
minimum_healthy_percent < 100
maximum_percent < 200
```

### R1 exit criteria

- [x] Three-AZ production semantics are locked.
- [x] Existing RDS DB-instance architecture is retained.
- [x] Production Multi-AZ and scheduled-Backup requirements are locked.
- [x] Production ECS minimum-capacity semantics are locked.
- [x] Production deployment-health and AZ-rebalancing semantics are locked.
- [x] Profile-derived production lifecycle protections are locked.
- [x] `production_retirement_mode` ownership and boundaries are locked.
- [x] AWS Backup Restore Testing is selected for RDS recovery verification.
- [x] Application-level restore validation is explicitly excluded.
- [x] Four-layer / 16-validator evidence architecture is preserved.
- [x] Existing ECS and exact-plan deployment invariants are preserved.
- [x] KMS lifecycle redesign and unrelated backlog are explicitly deferred.

R2 may now introduce the three-AZ topology and its workload interfaces without reopening these architecture decisions.

## R2 - Three-AZ Production Topology

R2 extends the current AZ-looping networking model to three production
Availability Zones.

### Subnet topology

Production should create one subnet per configured AZ for each existing family:

```text
public
compute_private
data_private
serverless_private
endpoint_private
firewall_private
```

### Network Firewall and NAT

Production `network_firewall` routing remains AZ-local:

```text
compute-private subnet
        |
        v
same-AZ Network Firewall endpoint
        |
        v
same-AZ firewall-private route table
        |
        v
same-AZ NAT Gateway
        |
        v
Internet Gateway
```

Do not introduce cross-AZ NAT routing as part of the third-AZ change.

### Downstream consumers

The complete production topology must flow into:

```text
RDS DB subnet group       -> all data-private subnets
ECS services              -> all compute-private subnets
ALB                       -> all public subnets
Interface VPC endpoints   -> all endpoint-private subnets
Network Firewall          -> all firewall-private subnets
```

### CIDR migration safety

Existing first/second-AZ CIDRs must remain unchanged.

Append the third CIDR rather than reorder the current list.

This should preserve existing AZ-keyed resources and create only the new
third-AZ instances.

### R2 validation

Networking validation should prove:

- exact effective AZ set;
- one subnet of each expected family per AZ;
- expected NAT inventory;
- expected Network Firewall endpoints;
- AZ-local routes; and
- exact route-table associations.

VPC endpoint validation should prove exact endpoint-private subnet placement.

### R2 exit criteria

- Production spans at least three distinct AZs.
- Existing first/second-AZ resources remain stable.
- Third-AZ networking converges cleanly.
- Firewall/NAT routing remains AZ-local.
- Dev/minimal two-AZ deployment remains supported.

## R3 - RDS Resilience & Lifecycle

R3 hardens the current RDS DB instance without changing the database resource
model.

### Production RDS configuration

Production should use:

```text
multi_az                 = true
deletion_protection      = true
skip_final_snapshot      = false
delete_automated_backups = false
publicly_accessible      = false
storage_encrypted        = true
```

The DB subnet group should receive the full production data-private subnet set.

### Final snapshot behavior

Production retirement must generate a final RDS snapshot.

The identifier should be deterministic enough for operators/evidence while
remaining unique enough to avoid reuse collisions.

Do not put secrets in the snapshot identifier.

### Validator-facing outputs

Expose only the resource-backed metadata required by validation, likely:

```text
identifier
ARN
Multi-AZ state
DB subnet group
deletion protection
backup retention
public accessibility
storage encryption
```

The existing application-consumer output contract remains unchanged.

### R3 validation

Existing workload validation should prove:

```text
expected RDS instance exists
MultiAZ == Terraform expectation
publicly accessible == false
storage encrypted == true
deletion protection == Terraform expectation
DB subnet group == Terraform expectation
Backup tag == Terraform expectation
```

Provider-only deletion-time behavior should be checked from Terraform
configuration/state where AWS exposes no live equivalent.

### R3 live qualification

Perform a controlled Multi-AZ RDS failover.

Record:

```text
DB available before test
MultiAZ = true
failover requested
RDS failover event observed
DB returns to available
managed endpoint remains authoritative
primary AZ change observed where available
observed recovery duration
```

The observed duration is qualification evidence, not an advertised RTO.

### R3 exit criteria

- Production cannot resolve to Single-AZ RDS.
- Deletion protection is enabled.
- Final-snapshot behavior is explicit.
- Automated backups are preserved during intentional retirement.
- Controlled failover succeeds.

## R4 - ECS Production Availability

R4 turns the current multi-AZ-capable ECS runtime into an explicitly redundant
production runtime.

### Fixed-count services

Production:

```text
desired_count >= 2
```

Terraform continues to own exact live desired count.

### Autoscaled services

Production:

```text
min_capacity >= 2
```

Application Auto Scaling continues to own live desired count after bootstrap.

The existing fixed/autoscaled resource split must remain intact.

### Availability Zone rebalancing

Production should explicitly configure:

```text
availability_zone_rebalancing = ENABLED
```

Expose the actual configured value through ECS service outputs.

### Deployment health

Production should require:

```text
minimum_healthy_percent = 100
maximum_percent         >= 200
```

Circuit breaker behavior remains:

```text
enabled = true
rollback = true
```

### ECS subnet placement

Each deployable production service must use the exact compute-private subnet set.

After R2, that should be the three production compute-private subnets.

### R4 validation

Extend ECS runtime validation to prove:

```text
exact compute-private subnet set
AZ rebalancing enabled
deployment-health settings exact
circuit breaker enabled
rollback enabled

fixed:
  desired_count >= 2
  live desired_count == Terraform

autoscaled:
  min_capacity >= 2
  live desired count within configured bounds
```

Existing GuardDuty agent/coverage validation must continue passing.

### R4 live qualification

Use the existing minimal HTTP test fixture.

For qualification, run three tasks so placement can be observed across all three
AZs.

Then deliberately stop one application task.

Prove:

```text
replacement task starts
service returns to desired capacity
pendingCount returns to zero
ALB targets remain/return healthy
GuardDuty instrumentation remains healthy
```

This proves task replacement, not a simulated AZ outage.

### R4 exit criteria

- Production singleton services are rejected.
- Autoscaled production minimum capacity is at least two.
- AZ rebalancing is Terraform-owned.
- Three-AZ task placement is observed during qualification.
- Task replacement returns the service to steady state.

## R5 - Production Lifecycle Protection

R5 replaces the remaining development-friendly delete behavior in normal
production.

### Target production behavior

```text
RDS deletion protection             true
ALB deletion protection             true
Network Firewall delete protection  true

ECR force_delete                    false
ECS service force_delete            false
Backup vault force_destroy          false
```

### Development/minimal behavior

Development and minimal must remain practical to destroy.

Do not impose production retirement controls on ordinary dev teardown.

### Production retirement

Introduce an explicit retirement path.

Conceptually:

```text
production_retirement_mode = true
```

may allow Terraform to remove the native protections that must be disabled
before deliberate retirement.

It should not automatically:

```text
force-delete ECR image history
force-delete Backup recovery points
turn every durable production resource into disposable state
```

### Network Firewall scope

Production delete protection belongs in v1.11.

The separate settings:

```text
firewall_policy_change_protection
subnet_change_protection
```

remain outside the release unless implementation proves they are required and
can be introduced without creating a larger maintenance/unlock lifecycle.

### KMS scope

The current KMS `prevent_destroy = false` TODOs are not part of R5.

They require a different Terraform lifecycle/state design and should not expand
this release.

### R5 validation

Use live AWS values for AWS-native deletion protection.

Use Terraform configuration/state evidence for provider-only `force_delete` /
`force_destroy` semantics.

### R5 exit criteria

- Normal production cannot casually delete critical resources.
- Production retirement requires deliberate intent.
- Dev/minimal teardown remains practical.
- No broad production force-delete escape hatch is introduced.

## R6 - Backup Restore Verification

R6 moves the recovery contract from backup presence to actual RDS
restorability.

### Restore Testing

Production should create Terraform-owned AWS Backup Restore Testing resources for
RDS.

Conceptually:

```text
Backup vault
   |
   v
valid RDS recovery point
   |
   v
Restore Testing
   |
   v
private restored RDS test resource
   |
   v
successful restore evidence
   |
   v
cleanup
```

### IAM

The current Backup role already has backup and restore service policies.

Prefer reusing it if the authority is sufficient.

Do not create another broad restore role without a concrete requirement.

### Restore metadata

Do not rely on a default VPC.

Use Terraform-owned restore metadata such as:

```text
DB subnet group
data security group
restore IAM role
private networking
```

### Application-validation boundary

R6 proves that the infrastructure recovery path works.

It does not prove:

- application migration correctness;
- business-data semantic integrity;
- ReconoSense startup against the restored DB; or
- application-specific RTO/RPO.

### R6 validation

Extend `validate-backup.sh` to prove:

```text
Restore Testing plan exists
schedule matches Terraform
RDS selection exists
restore role matches Terraform
private restore metadata is configured
latest restore-test state can be reported
```

Strict release evidence may require a recent successful Restore Testing
execution.

A fresh deployment may validate configuration before its first scheduled run.

### R6 live qualification

At least one real RDS restore test must complete successfully.

Capture:

```text
recovery point
restore job ID
start/completion time
status
restored resource identity
private networking
cleanup state
```

A lingering test resource after cleanup should fail qualification.

### R6 exit criteria

- Restore Testing is Terraform-owned.
- A real RDS recovery point restores successfully.
- The restored resource remains private.
- Cleanup succeeds.
- Validation reports both configured and qualified recovery state.

## R7 - Exact Resilience Validation

R7 turns the R1-R6 behavior into exact read-only workload evidence.

### Validation architecture

Keep:

```text
4 evidence layers
16 workload baseline validators
```

Do not add a separate top-level resilience validator.

### `validate-networking.sh`

Add:

```text
production AZ set/count
subnet inventory
NAT inventory
Network Firewall endpoint inventory
AZ-local routing
Network Firewall delete protection
```

### `validate-vpc-endpoints.sh`

Add/strengthen:

```text
Interface Endpoint subnet set == Terraform expectation
```

Existing ECR and `guardduty-data` checks remain unchanged.

### `validate-ecs-runtime.sh`

Add:

```text
AZ rebalancing
production minimum capacity
production deployment-health contract
three-AZ compute subnet use
ALB public-subnet coverage
ALB deletion protection
```

Continue extending the existing helper library.

### `validate-backup.sh`

Add:

```text
production Backup cannot be disabled
RDS Multi-AZ
RDS deletion protection
RDS recovery/lifecycle intent
Backup vault destruction posture
Restore Testing plan
Restore Testing selection
Restore Testing role
latest Restore Testing execution
```

### `validate-ecr.sh`

Preserve the existing live repository contract.

Add Terraform/state evidence that production repositories do not use
`force_delete = true`.

### `validate-iam.sh`

If R6 changes restore IAM, validate the exact accepted authority.

Do not broaden Backup/restore IAM for validator convenience.

### Terraform expectation rule

Validators should consume Terraform-owned effective/resource-backed outputs.

Do not duplicate production-profile policy logic in Bash when Terraform can
export the resolved expected value.

### Exporter safety

Exporters remain read-only.

They must not:

```text
trigger RDS failover
stop ECS tasks
start restore tests
change deletion protection
terraform apply
terraform destroy
```

### R7 exit criteria

- Every v1.11 resilience guarantee has validation coverage.
- Validation remains read-only.
- Terraform remains the source of expected state.
- Recursive ShellCheck passes.
- Full workload baseline remains `16/16 PASS`.

## R8 - Live Qualification & Release

Use a non-customer workload account with:

```text
DEPLOYMENT_PROFILE=production
```

The production profile itself should be qualified rather than approximated
through development settings.

### Qualification sequence

1. Confirm production resolves to at least three AZs.
2. Apply the three-AZ topology.
3. Confirm all expected subnet families span the three AZs.
4. Confirm NAT/Network Firewall routing remains AZ-local.
5. Confirm Interface Endpoints span the expected endpoint-private subnets.
6. Confirm the RDS DB subnet group includes all production data subnets.
7. Confirm production RDS is Multi-AZ and deletion-protected.
8. Deploy the minimal HTTP ECS service with three tasks.
9. Confirm tasks are distributed across the three production AZs.
10. Confirm ECS AZ rebalancing is enabled.
11. Confirm the ALB spans all production public subnets and targets are healthy.
12. Stop one ECS application task and confirm replacement/steady state.
13. Confirm GuardDuty Runtime Monitoring remains healthy.
14. Perform a controlled RDS Multi-AZ failover.
15. Confirm RDS returns to `available`.
16. Execute an RDS AWS Backup Restore Testing job.
17. Confirm restore success and cleanup.
18. Validate production lifecycle-protection state.
19. Run `validate-ecs-runtime.sh`.
20. Run `validate-backup.sh`.
21. Run the full workload baseline.
22. Export workload evidence.
23. Run a development destroy regression.
24. Confirm the final production Terraform plan reports no changes.
25. Reconcile documentation and release notes.

### Release gate

| Test | Required result |
|---|---|
| Production Availability Zones | >= 3 |
| Three-AZ subnet topology | PASS |
| AZ-local NAT/Firewall routing | PASS |
| Production RDS Multi-AZ | ENABLED |
| RDS deletion protection | ENABLED |
| Production fixed ECS minimum | >= 2 |
| Production autoscaled minimum | >= 2 |
| ECS AZ rebalancing | ENABLED |
| ECS three-AZ placement | PASS |
| ECS task replacement | PASS |
| ALB health after replacement | PASS |
| GuardDuty Runtime Monitoring | HEALTHY |
| Controlled RDS failover | PASS |
| RDS Restore Testing | PASS |
| Restore cleanup | PASS |
| Production lifecycle protection | PASS |
| Development destroy regression | PASS |
| `validate-ecs-runtime.sh` | PASS |
| `validate-backup.sh` | PASS |
| Full workload baseline | 16/16 PASS |
| Workload evidence export | PASS |
| Final Terraform plan | No changes |

## Deferred Beyond v1.11.0

Keep these outside v1.11 unless scope is deliberately changed:

- RDS Multi-AZ DB cluster migration;
- Aurora;
- RDS read replicas;
- multi-region workload architecture;
- cross-region database replication;
- cross-region Backup architecture;
- automatic ECS/Fargate containment;
- scheduled/run-to-completion ECS tasks;
- audited ECS Exec;
- WAF ownership;
- Route53/DNS ownership;
- multi-container application abstractions;
- application database-user lifecycle;
- ReconoSense reference deployment;
- application-level restore/data validation;
- foundation/runtime Terraform state split;
- advanced ECR history/retention;
- AWS Backup Vault Lock compliance mode;
- profile-aware KMS `prevent_destroy` redesign;
- architectural diagram program; and
- unrelated technical-debt/script-normalization work.

## Suggested Follow-On Work

### Architecture Diagram / Documentation Sprint

After v1.11, perform the planned dedicated architecture-diagram/documentation
sprint against the now-qualified security, ECS runtime, and resilience
architecture.

Keep that work separate from the v1.11 implementation boundary.

### Likely v1.12.0 - ReconoSense Reference Deployment

Candidate scope:

- deploy ReconoSense through the generic ECS/Fargate contracts;
- consume the existing RDS/ECS/ECR/ALB interfaces;
- prove a realistic application against the resilient production platform;
- add application permissions only where explicitly required; and
- keep ReconoSense-specific assumptions out of reusable baseline modules.

The reference deployment should prove the platform rather than redefine it.

## Final v1.11.0 Definition

v1.11.0 is complete when the production profile requires a three-AZ
application/network substrate, production ECS services have redundant capacity
with explicit Availability Zone rebalancing, the existing RDS DB instance is
Multi-AZ and protected against casual deletion, production ALB/Network
Firewall/ECR/ECS/Backup lifecycle behavior is explicitly hardened, AWS Backup
successfully restores the RDS workload through Restore Testing, exact read-only
validation proves the configured and live resilience contract, development
teardown remains practical, the full workload baseline reports `16/16 PASS`,
and the final Terraform plan reports no changes.