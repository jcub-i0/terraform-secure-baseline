# v1.15.0 — M0-B: Architecture and Terraform State Ownership

**Status:** D1/D2/B-3/B-5 owner-approved; M0-B final review and CI pending (no AWS authorization or implementation)
**Scope:** D1 (composition/state), D2 (baseline ECS/ALB boundaries), and B-5 (owner-approved, staging-only RDS run-state delegation); documentation only
**Baseline:** `v1.14.1`; M0-A at `v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md`
**Reference application:** ReconoSense (private repository; contract: `infra/terraform/BASELINE_INTEGRATION.md`)

## 1. Owner-approved architecture decision

**Owner-approved (2026-11-06): adopt two workload Terraform states with a one-way dependency: platform foundation -> application workload.** Reuse the modules in this repository as a version-pinned library, but let the root configuration containing each module determine who owns its AWS resources.

- **Foundation root/state:** retain the existing `environments/staging` -> `baseline/` stack and its established security, networking, database, backup, ECS cluster, logging and governance responsibilities.
- **Application root/state:** create a separate, thin ReconoSense-owned integration root for ECS services/tasks, application ingress, scoped IAM, identity, data buckets, scheduling, observability and releases. It may call generic modules from `terraform-secure-baseline`; those module-created resources are owned by the **application state**, not both states.
- **No reverse Terraform dependency:** the foundation may expose stable identifiers but must not consume application state outputs, SG IDs, roles, services or task definitions. The owner-approved, **not yet implemented** application run-state controller may invoke narrowly bounded RDS start/stop operations on a foundation-owned instance without owning its configuration or requiring a foundation Apply.
- **Do not move existing resources yet.** This is a design proposal, not authorization to migrate state, deploy, change IAM, or copy application data.

This pattern is intended for other SaaS adopters. No ReconoSense job names, models, tenant SQL or application-specific resource names belong in baseline modules.

## 2. Account, state and control boundaries

| Scope | Repository / root | Proposed state and authority | Notes |
|---|---|---|---|
| Platform account/bootstrap and security governance | Existing baseline bootstrap/control-plane/security-operations roots | **Existing independent states**, existing protected identities | Remain unchanged; application CI has no access. |
| Workload foundation | `terraform-secure-baseline/environments/staging` | **Existing:** S3 bucket `tf-secure-baseline-staging-state`, key `baseline/staging.tfstate`; baseline Plan/Apply OIDC roles | No ReconoSense-managed objects in this state. |
| ReconoSense integration workload | **Proposed new** `reconosense/infra/terraform/environments/baseline-staging` | **Proposed:** distinct key `applications/reconosense/staging.tfstate`; application-only Plan/Apply roles | Same target account/Region as baseline staging for initial synthetic qualification; backend and role authorization must be approved. |
| Existing standalone ReconoSense staging | `reconosense/infra/terraform/environments/staging`, plus its `bootstrap/` | **Existing separate account/state** | Preserve unchanged. Do not run it against baseline-owned resources or consider it an adopted baseline state. |

A shared S3 state bucket with isolated keys is an **option**, not permission to reuse the foundation's state ACLs. Verify bucket policies, encryption, KMS access, S3 Get/Put/Delete scope and `*.tflock` scope for each role. If key-level isolation cannot be enforced safely, provision an approved application-state bucket instead. State backends and accounts are environment decisions; the illustrated key is not deployed.

**Initial qualification target:** a disposable, synthetic-data application stack in the existing baseline staging account, after a separate authorized foundation deployment. A subsequent move into ReconoSense's dedicated account requires its own account/governance/bootstrap and migration design. The current standalone root is not overwritten.

## 3. Proposed AWS resource owner matrix

Each AWS resource instance (including independently managed rules, policies, grants and bindings) must belong to **exactly one** Terraform state.

| Resource group | Foundation state | Application state or application operations |
|---|---|---|
| VPC, subnets, route tables, NAT/firewall, VPC endpoints | Owns VPC and shared egress/network infrastructure | Reads IDs only; owns narrowly scoped application ENIs/SGs and application-specific rules |
| RDS, DB subnet group, master credentials, backup/restore | **Exclusively owns instance configuration/deletion**, RDS subnet group, data SG, master secret, monitoring, backups and restore governance. Does **not** own an RDS run-state controller. | **Owner-approved B-5 design (not deployed):** owns one `aws_rds_instance_state` controller for the designated, exclusively used *synthetic staging* DB, plus application runtime/owner secrets and SQL provisioning. No second `aws_db_instance` for the same endpoint; no RDS configuration/deletion authority. |
| KMS and central security services | Owns baseline CMKs, GuardDuty/Config/Security Hub, central security logging and notification infrastructure | Owns application IAM grants/policies where authorized, application log groups and application alarms; KMS/key-policy compatibility is a gate |
| ECS cluster | Owns **one shared** ECS cluster | Consumes cluster name/ARN; does not create another cluster for this integration |
| ECR repositories and repository lifecycle policies | Proposed default: owns the per-repository ECR resources and policies **listed in the approved foundation inventory**; inventory must be finalized in M0-C before first Apply. | Publishes digest-pinned images to explicitly granted repositories; cannot create, replace or delete those repositories from the application state. |
| ECS services, task definitions, application task SGs | **No integration application service resources** | Owns API service, sidecars, standalone task definitions, service SGs and capacity/scaling configuration |
| ECS task/execution IAM roles and mandatory boundaries | Owns/authorizes the independent permission ceiling, deployment-role trust, and bootstrap administration; never delegates boundary editing to application CI. | Owns per-job/task execution roles and application-specific policy attachments **subject to** the independently enforced boundary. May not create or weaken the mandatory boundary. |
| HTTPS ALB, target groups, listeners, WAF, ALB access logs | No integration application ALB when foundation service registration is empty | Owns one ALB ingress stack through reusable baseline modules and app-specific ACM/DNS integration |
| Scheduler, queues, app SNS, app secrets, document/quarantine buckets, Cognito | No ReconoSense instances | Owns these application-specific resources, policies and lifecycle rules |
| Cross-boundary network rules | Owns existing compute, automation, quarantine, restored-DB and endpoint/DB rules. An opt-in, platform-managed connectivity grant is one **candidate**, not yet approved. | Owns app ALB/task SGs and their own egress/ingress rules. Additional rules on foundation-owned RDS/endpoint SGs require B-2 approval, independent per-rule ownership and proven IAM isolation; never re-creates foundation rules or invokes the entire foundation security-policy module. |
| Release orchestration and evidence | Owns protected foundation Plan/Apply and foundation evidence | Owns protected task/migration/API promotion and its evidence |

**Application-specific SQL objects and Cognito users are not Terraform-managed baseline resources.** Capture their operational owner separately; they must not be described as Terraform state-owned merely because they live in foundation-owned RDS.

## 4. Dependency graph — no circular edges

```text
Existing workload-account bootstrap and security governance
                         |
                         v
Foundation state: VPC -> egress/endpoints -> RDS/KMS/backup -> ECS cluster/ECR
                         |
                  explicit interface
                         v
Application state: application SGs + least-privilege roles
                  |         |
                  v         v
            ALB/WAF     job task definitions + schedules
                  \         /
                   v       v
                 ECS service / release jobs
                         |
                         v
             protected migration -> API promotion
```

Constraints:

1. The **foundation consumes no application outputs** or resources. Its published interface must not depend on application-owned objects; start/stop API calls under B-5 are a limited operational delegation, not a foundation Terraform dependency.
2. App state can consume foundation outputs *after* the foundation Apply completes, using stable, validated identifiers.
3. Application ALB routing and target groups can be declared before the ECS service; application SG rules can reference the service SG without adding a module-level `depends_on` cycle. Verify the **actual** Terraform graph in M0-C.
4. Foundation destroy is prohibited while application resources depend on it. Retire/drain the application first; then run the approved foundation retirement procedure.
5. **B-5:** application `aws_rds_instance_state` reads the published RDS identifier and controls *operational state only*. The foundation retains the `aws_db_instance` and must have **no competing `aws_rds_instance_state`**. This is not two Terraform states owning the same Terraform resource instance.
6. This graph describes the proposed dependency direction, not a successful `terraform graph`, permission simulation or live Apply.

## 5. Cross-state integration contract

**Prefer an explicit, versioned, non-sensitive published contract** (candidate: SSM Parameter Store JSON read by the application Plan identity), not `terraform_remote_state`. Reading remote-state outputs also requires access to the complete state snapshot, which is inappropriate for the application deployment identity. [HashiCorp's remote-state guidance](https://developer.hashicorp.com/terraform/language/state/remote-state-data) recommends explicitly publishing shared data.

Proposed v1 contract fields, all **non-secret**:

| Field group | Candidates | Current baseline availability |
|---|---|---|
| Identity | schema version, foundation release/commit, AWS account, Region, environment | Add/assemble a reviewed contract |
| Networking | VPC ID, compute-private and **ALB ingress-public** subnet IDs, S3 prefix list ID, endpoint SG ID, and approved connectivity grant identifiers | Existing `network_topology` includes both subnet families; endpoint SG ID is available in the VPC endpoints submodule but not the baseline root; grant design pending B-2 |
| Database | RDS endpoint/port/name, RDS SG ID, **identifier and ARN**, explicit staging lifecycle eligibility and dedicated-use flag | Identifier/ARN exist in `modules/storage/outputs.tf` `rds_configuration` but need a reviewed, purpose-built foundation publication; eligibility is not currently expressed |
| Runtime | ECS cluster name/ARN; explicit owner and image-publish grant for every ECR repository; GuardDuty Fargate agent repository information where applicable | Cluster/ECR outputs exist; role/policy coverage is built by baseline composition and cannot be assumed by direct module reuse |
| Cryptography/alerts | Application-usable logs/secrets CMK ARNs, platform-owned mandatory permissions-boundary ARN, effective egress policy and GuardDuty execution-role requirements; optional SecOps notification endpoint | Some root outputs exist; actual KMS decrypt, boundary, trust and runtime permissions need M0-C/D design and negative tests |

Never publish RDS master password/secret contents, app credentials, or full Terraform state into this contract. The existing root exposes `rds_master_secret_arn`, but the application manifest **must not** include it. Pin expected account and Region, validate contract version, and refuse stale/incomplete contracts before app Plan/Apply. Publication and consumption mechanics are an M0-C/D design item, not an implemented resource.

## 6. D1/D2 compatibility findings and implementation implications

**Finding A — currently safe separation candidate:** `baseline/locals.tf` filters deployable ECS services by non-null image digest; `baseline/main.tf` creates an ALB only when a deployable service has ingress. Keeping `ecs_services = {}` (or a reviewed registration with no deployed image) allows the foundation to own its cluster without an integration application service or ALB. The current staging sample registers `test` with `image_digest = null` and still derives an ECR repository; explicitly review this configuration before qualification.

**Finding B — module reuse is feasible without state co-ownership:** `modules/ecs_service` accepts an existing cluster ARN/name, VPC, subnets and task/execution-role ARNs. `modules/application_load_balancer` accepts VPC, public subnet IDs, ACM certificate and a service route map. These can be called by the application root after their interfaces have been extended/qualified for M1–M3. Existing consumers of `baseline/` should retain their current resource addresses and behavior.

**Finding C — cross-boundary SG rules require deliberate governance (N1/B-2):** the foundation's `modules/networking/security_policy` unconditionally creates existing platform rules and **must not** be called from application state. Application owns ALB/task SGs, ALB-to-task rules, task egress, and app-owned service rules. Foundation owns its existing SG rules. A new DB/endpoint SG ingress grant must have an explicit single owner. Prefer examining a **platform-owned, opt-in connectivity grant configured within the existing foundation state** (e.g., a foundation-owned approved connector SG and ingress rules) so application CI does not need broad mutation of foundation SGs. If the design instead delegates individual rule creation to application, prove IAM can prevent changes to *all unrelated* rules in the foundation SG. No third workload state is authorized under D1; any additional-state alternative requires a new owner decision.

**Finding D — release independence must be protected:** neither a baseline Apply nor a combined app Terraform Apply may roll the serving API image before migrations exit successfully. The application state owns the runtime resource, but M4 must stage configuration changes and promotion through that authoritative state without unmanaged `aws ecs update-service` drift.

**Finding E — database role bootstrap is unresolved:** the baseline RDS master secret stays with the foundation. ReconoSense requires separate database-owner and runtime logins. Define the privileged first-install provisioning step, owner credential lifecycle, SQL grants and negative-access tests in M3; do not grant app runtime or CI blanket access to the foundation master secret.

**Finding F — RDS run-state delegation (Codex B1; B-5 design approved):** the proposed application lifecycle controller is distinct from foundation-owned RDS configuration. It may control only a **dedicated, eligible, synthetic-data staging instance**, with exact ARN- and Region-bound `rds:StartDBInstance`/`rds:StopDBInstance` rights on a protected application Apply role plus necessary read-only descriptions. The foundation must retain exclusive configuration, backup, restore and deletion control. **The owner explicitly approved B-5 in chat (2026-11-07), subject to dedicated synthetic-staging use, exact-resource/Region scope, independent IAM controls, and safe lifecycle sequencing. This is design approval only, not permission to deploy.** M0-C defines lifecycle inputs, published database identifier/ARN, resume-before-migration, drain-before-stop, autoscaling and Scheduler interaction. M0-D defines independent permission boundaries, negative IAM tests, state/backend lock isolation and concurrent-operation protection. Stop is forbidden unless other users of the foundation DB are absent or a specific exclusive-use designation is established. An app-state destroy leaves the DB state unchanged (provider no-op); RDS can auto-restart a stopped DB after seven days. Application teardown must not trigger foundation deletion or assume the DB becomes available on lifecycle-resource destroy. The foundation's RDS version must be qualified as PostgreSQL 16 for ReconoSense on a **fresh** database; do not downgrade an existing PostgreSQL 17 instance.

## 7. Adoption, migration and rollback boundaries

- **No destructive migration for M0-B.** Branch changes are documents only. Continue using the baseline staging root and existing ReconoSense standalone root as distinct configurations.
- **First integration:** provision foundation through its protected workflow; validate/publish non-secret outputs; prepare and Plan an empty application integration root; then add synthetic-data application resources in separate, reviewed stages. Do not import or duplicate existing RDS/VPC/ECS cluster resources.
- **Existing ReconoSense deployment cutover (future):** inventory real resources and existing state, classify reusable vs replaceable, choose explicit import/state-move or clean-deploy migration with backups and ownership handoff. A `moved` block alone is not a cross-state migration procedure. Require owner approval of the exact plan, downtime/data handling and rollback.
- **Destroy ordering:** disable schedules, drain tasks, release the application lifecycle controller and application resources first, then retire the foundation through its protected process. Deleting `aws_rds_instance_state` is a no-op for the instance's current run state, so any desired start must happen before lifecycle-controller destroy. Never force-destroy protected evidence or bypass S3 Object Lock/legal holds. Keep state and security evidence until policy permits retirement.
- **Rollback:** application image rollback only when schema compatibility allows. Database rollback/restore is a separately approved, evidence-backed operation, not a consequence of Terraform rollback.

## 8. Decisions for owner acceptance

| ID | Decision | Status |
|---|---|---|
| D1 | Separate foundation and application states, same target account for first synthetic qualification; one-way dependency; app root consumes pinned generic modules | **Owner-approved (2026-11-06)** |
| D2 | Preserve existing `baseline/` composition and resource addresses; keep integration app ECS/ALB out of foundation state; app-owned root calls generic modules | **Owner-approved (2026-11-06)** |
| B-1 | Publish a non-secret, versioned output contract rather than giving app CI remote-state access | **Proposed — M0-C detail pending** |
| B-2 | Narrowly scoped application SG connectivity to foundation-owned data/endpoints without broad SG mutation authority | **Open security gate (M0-D)** |
| B-3 | Use baseline staging account for first qualification; leave dedicated ReconoSense account/bootstrap untouched | **Owner-approved (2026-11-06)** |
| B-4 | Application state/backend key and IAM trust, encryption and lockfile restrictions | **Open implementation gate (M0-C/D)** |
| B-5 (Codex B1) | App state exclusively owns one RDS operational run-state controller for a designated, exclusively used synthetic staging DB; foundation exclusively owns RDS configuration/deletion. Application Apply may be granted resource/Region-scoped Start/Stop rights only under independent platform-administered IAM enforcement and safe transition gates. | **Owner-approved design (2026-11-07); no IAM grant or Terraform implementation authorized; M0-C/D must implement and validate safeguards** |

## 9. M0-B acceptance and handoff

**Owner approval for D1, D2, B-3 and B-5 has been recorded. Codex's independent cross-repository review of the prior PR head reported B1 BLOCKING, N1–N4 NONBLOCKING and F1 FUTURE.** The owner-approved B-5 design resolves the B1 resource-ownership ambiguity on paper; the lifecycle and IAM enforcement remain required M0-C/D implementation gates. Independent review must verify the revised documented disposition before closing M0-B. The reviewer must also verify that B-1 is assigned to M0-C, B-2 to M0-D, and B-4 to M0-C/D. None of these controls has been implemented or validated in AWS.

- [x] B-5 RDS instance/run-state split and staging-only, exact-resource Start/Stop delegation **approved as a design** by the owner (2026-11-07). No competing controller may be introduced; exclusive DB use and denied permissions remain mandatory pre-deployment tests.
- [ ] A single authoritative owner is identified for every proposed AWS resource and individual SG rule **or the unresolved per-rule choices are explicitly assigned to M0-C/D without implying deployer permission**; no overlapping Terraform states.
- [ ] The foundation consumes **no application outputs**; application roles cannot read foundation state snapshots, alter foundation RDS configuration or access foundation master secrets. B-5's permitted start/stop operations are explicitly bounded.
- [ ] Existing `baseline/` paths and single-container consumers remain stable; app ECS/ALB ownership is isolated.
- [ ] The initial deployment account/state paths, qualification boundary, lifecycle sequencing and migration/rollback rules are recorded.
- [ ] M0-C owns exact module/output contracts, RDS lifecycle orchestration and Terraform graph verification; M0-D owns OIDC/IAM/KMS and network-grant enforcement and negative tests.

**Not yet claimed:** Reviewer acceptance of the final head, Terraform graph pass, Plans, AWS IAM simulations, AWS changes or production readiness. D1/D2/B-3/B-5 have design approval; **the application has not been granted RDS start/stop permission**. Do not mark M0-B complete until final review and CI pass; M0-C/D must implement the actual controls under separate authorization.

## 10. Cross-repository Codex review disposition (against prior head `fd63e47`)

| Finding | Disposition | Required downstream proof |
|---|---|---|
| **B1 — BLOCKING at prior head** | **Architecture correction accepted as B-5 (owner-approved design; not implemented):** instance configuration remains foundation-owned; state controller belongs to application for an approved exclusive staging DB. | M0-C contract/lifecycle/drain; M0-D IAM simulations, authorization boundaries and exclusive-use safeguards. |
| **N1 — NONBLOCKING** | Keep foundation's broad `security_policy` module out of app state; ownership by individual new SG rule, not SG identity alone. No third state. | M0-C app-specific connectivity interfaces; M0-D grant enforcement/negative tests. |
| **N2 — NONBLOCKING** | New application Plan/Apply/release identities, not baseline admin or standalone ReconoSense PowerUser. Mandatory permissions boundary remains independently platform-owned. | M0-D OIDC trust, PassRole, S3 state/lock access, KMS and boundary-enforcement tests. |
| **N3 — NONBLOCKING** | Add ingress-public subnet IDs, RDS identifier/ARN/eligibility, endpoint SG, ALB canonical hosted-zone ID or authorized lookup, ECR inventory, GuardDuty execution contract and boundary reference. | M0-C versioned, non-secret published interface; no `terraform_remote_state` access to foundation. |
| **N4 — NONBLOCKING** | Preserve GuardDuty agent pull/coverage permissions, encrypted secrets access, ALB logs/WAF/deletion protection, private task networking and credential separation. Size-restriction WAF controls must accommodate approved 50 MiB uploads without disabling the entire rule group. | M0-C interfaces; M0-D security acceptance; M5 large-upload and negative tests. |
| **F1 — FUTURE** | Dedicated ReconoSense account cutover and data migration deferred; a **new** PG16 baseline staging instance must be separately planned and approved. | Future cutover plan, inventory and data migration approval; no in-place PG17 downgrade. |

Private-source verification was performed by local Codex against `~/recon-engine/infra/terraform/`; no local ReconoSense files or AWS resources were modified by that review. The present revisions themselves still require targeted independent re-review.

## Source inventory

- Baseline (public, same repository): [`baseline/main.tf`](../baseline/main.tf), [`baseline/locals.tf`](../baseline/locals.tf), [`baseline/outputs.tf`](../baseline/outputs.tf), [`modules/ecs_service`](../modules/ecs_service/README.md), [`modules/application_load_balancer`](../modules/application_load_balancer/README.md), [`modules/networking/security_policy`](../modules/networking/security_policy/main.tf), [`environments/staging/backend.tf`](../environments/staging/backend.tf).
- ReconoSense (private; paths for authorized reviewers only): `infra/terraform/BASELINE_INTEGRATION.md`, `infra/terraform/README.md`, `infra/terraform/environments/staging/main.tf`, `infra/terraform/modules/service_runtime/main.tf`, `infra/terraform/modules/background_jobs/main.tf`, `infra/terraform/bootstrap/outputs.tf`.
