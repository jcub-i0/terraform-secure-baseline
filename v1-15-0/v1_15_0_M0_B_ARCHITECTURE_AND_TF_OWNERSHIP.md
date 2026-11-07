# v1.15.0 — M0-B: Architecture and Terraform State Ownership

**Status:** Proposed for owner review; not accepted
**Scope:** D1 (composition/state) and D2 (baseline ECS/ALB boundaries), documentation only
**Baseline:** `v1.14.1`; M0-A at `v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md`
**Reference application:** ReconoSense (private repository; contract: `infra/terraform/BASELINE_INTEGRATION.md`)

## 1. Proposed decision

**Recommend two workload Terraform states with a one-way dependency: platform foundation -> application workload.** Reuse the modules in this repository as a version-pinned library, but let the root configuration containing each module determine who owns its AWS resources.

- **Foundation root/state:** retain the existing `environments/staging` -> `baseline/` stack and its established security, networking, database, backup, ECS cluster, logging and governance responsibilities.
- **Application root/state:** create a separate, thin ReconoSense-owned integration root for ECS services/tasks, application ingress, scoped IAM, identity, data buckets, scheduling, observability and releases. It may call generic modules from `terraform-secure-baseline`; those module-created resources are owned by the **application state**, not both states.
- **No reverse dependency:** the foundation may expose stable identifiers but must not reference application SGs, roles, services or task definitions. Application changes must not require foundation Terraform applies.
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
| RDS, DB subnet group, master credentials, backup/restore | Owns RDS instance, master secret, core RDS SG, backups/restore governance | Owns distinct application runtime/owner credential handling and SQL roles/schemas through authorized provisioning/migrations; never manages a second RDS instance for the same endpoint |
| KMS and central security services | Owns baseline CMKs, GuardDuty/Config/Security Hub, central security logging and notification infrastructure | Owns application IAM grants/policies where authorized, application log groups and application alarms; KMS/key-policy compatibility is a gate |
| ECS cluster | Owns **one shared** ECS cluster | Consumes cluster name/ARN; does not create another cluster for this integration |
| ECR repositories | Prefer foundation-owned repositories where provisioned | Application CI publishes digest-pinned images; does not duplicate repository resources |
| ECS services, task definitions, application task SGs | **No integration application service resources** | Owns API service, sidecars, standalone task definitions, service SGs and capacity/scaling configuration |
| ECS task/execution IAM roles | No ReconoSense task roles | Owns per-job/task execution roles, policies and permission boundaries under approved IAM controls |
| HTTPS ALB, target groups, listeners, WAF, ALB access logs | No integration application ALB when foundation service registration is empty | Owns one ALB ingress stack through reusable baseline modules and app-specific ACM/DNS integration |
| Scheduler, queues, app SNS, app secrets, document/quarantine buckets, Cognito | No ReconoSense instances | Owns these application-specific resources, policies and lifecycle rules |
| Cross-boundary network rules | Owns platform SGs and its existing rule instances | **Only distinct approved** application-to-RDS/endpoint SG rules; not the platform SG objects or existing rule IDs |
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

1. The baseline root must not consume application-state outputs. Publishing foundation references must not depend on application resources.
2. App state can consume foundation outputs *after* the foundation Apply completes, using stable, validated identifiers.
3. Application ALB routing and target groups can be declared before the ECS service; application SG rules can reference the service SG without adding a module-level `depends_on` cycle. Verify the **actual** Terraform graph in M0-C.
4. Foundation destroy is prohibited while application resources depend on it. Retire/drain the application first; then run the approved foundation retirement procedure.
5. This graph describes the **proposed dependency direction**, not a successful `terraform graph` or live Apply.

## 5. Cross-state integration contract

**Prefer an explicit, versioned, non-sensitive published contract** (candidate: SSM Parameter Store JSON read by the application Plan identity), not `terraform_remote_state`. Reading remote-state outputs also requires access to the complete state snapshot, which is inappropriate for the application deployment identity. [HashiCorp's remote-state guidance](https://developer.hashicorp.com/terraform/language/state/remote-state-data) recommends explicitly publishing shared data.

Proposed v1 contract fields, all **non-secret**:

| Field group | Candidates | Current baseline availability |
|---|---|---|
| Identity | schema version, foundation release/commit, AWS account, Region, environment | Add/assemble a reviewed contract |
| Networking | VPC ID, compute-private subnet IDs, S3 prefix list ID, endpoint SG ID | Existing outputs cover most; endpoint SG ID is available in the VPC endpoints submodule but not exposed by baseline root |
| Database | RDS endpoint/port/database name, RDS SG ID | Existing root outputs |
| Runtime | ECS cluster name/ARN, approved ECR repositories | Existing root outputs |
| Cryptography/alerts | application-usable logs/secrets CMK ARNs, optional SecOps notification endpoint | Existing root outputs; consumption requires separately approved IAM/KMS policies |

Never publish RDS master password/secret contents, app credentials, or full Terraform state into this contract. The existing root exposes `rds_master_secret_arn`, but the application manifest **must not** include it. Pin expected account and Region, validate contract version, and refuse stale/incomplete contracts before app Plan/Apply. Publication and consumption mechanics are an M0-C/D design item, not an implemented resource.

## 6. D1/D2 compatibility findings and implementation implications

**Finding A — currently safe separation candidate:** `baseline/locals.tf` filters deployable ECS services by non-null image digest; `baseline/main.tf` creates an ALB only when a deployable service has ingress. Keeping `ecs_services = {}` (or a reviewed registration with no deployed image) allows the foundation to own its cluster without an integration application service or ALB. The current staging sample registers `test` with `image_digest = null` and still derives an ECR repository; explicitly review this configuration before qualification.

**Finding B — module reuse is feasible without state co-ownership:** `modules/ecs_service` accepts an existing cluster ARN/name, VPC, subnets and task/execution-role ARNs. `modules/application_load_balancer` accepts VPC, public subnet IDs, ACM certificate and a service route map. These can be called by the application root after their interfaces have been extended/qualified for M1–M3. Existing consumers of `baseline/` should retain their current resource addresses and behavior.

**Finding C — cross-boundary SG rules require deliberate governance:** the foundation uses standalone `aws_security_group_rule` resources, not inline SG ingress on its RDS SG. An additional distinct app-to-RDS ingress rule could be owned by the application root without claiming the foundation SG, but its deployer must not gain uncontrolled authority over foundation SG rules. Confirm an AWS-enforced least-privilege arrangement before implementing. If it cannot be proven, use a separately approved platform-owned connection-grant process/state; do **not** silently widen the app Apply role.

**Finding D — release independence must be protected:** neither a baseline Apply nor a combined app Terraform Apply may roll the serving API image before migrations exit successfully. The application state owns the runtime resource, but M4 must stage configuration changes and promotion through that authoritative state without unmanaged `aws ecs update-service` drift.

**Finding E — database role bootstrap is unresolved:** the baseline RDS master secret stays with the foundation. ReconoSense requires separate database-owner and runtime logins. Define the privileged first-install provisioning step, owner credential lifecycle, SQL grants and negative-access tests in M3; do not grant the app's normal runtime or CI blanket access to the baseline master secret.

## 7. Adoption, migration and rollback boundaries

- **No destructive migration for M0-B.** Branch changes are documents only. Continue using the baseline staging root and existing ReconoSense standalone root as distinct configurations.
- **First integration:** provision foundation through its protected workflow; validate/publish non-secret outputs; prepare and Plan an empty application integration root; then add synthetic-data application resources in separate, reviewed stages. Do not import or duplicate existing RDS/VPC/ECS cluster resources.
- **Existing ReconoSense deployment cutover (future):** inventory real resources and existing state, classify reusable vs replaceable, choose explicit import/state-move or clean-deploy migration with backups and ownership handoff. A `moved` block alone is not a cross-state migration procedure. Require owner approval of the exact plan, downtime/data handling and rollback.
- **Destroy ordering:** application tasks/schedules/ALB and disposable data resources first, then baseline retirement. Never force-destroy protected evidence or bypass S3 Object Lock/legal holds. Keep state and security evidence until policy permits retirement.
- **Rollback:** application image rollback only when schema compatibility allows. Database rollback/restore is a separately approved, evidence-backed operation, not a consequence of Terraform rollback.

## 8. Decisions for owner acceptance

| ID | Proposed decision | Status |
|---|---|---|
| D1 | Separate foundation and application states, same target account for first synthetic qualification; one-way dependency; app root consumes pinned generic modules | **Proposed — owner approval required** |
| D2 | Preserve existing `baseline/` composition and resource addresses; keep integration app ECS/ALB out of foundation state; app-owned root calls generic modules | **Proposed — owner approval required** |
| B-1 | Publish a non-secret, versioned output contract rather than giving app CI remote-state access | **Proposed — M0-C detail pending** |
| B-2 | Narrowly scoped application SG connectivity to foundation-owned data/endpoints without broad SG mutation authority | **Open security gate (M0-D)** |
| B-3 | Use baseline staging account for first qualification; leave dedicated ReconoSense account/bootstrap untouched | **Proposed — owner approval required** |
| B-4 | Application state/backend key and IAM trust, encryption and lockfile restrictions | **Open implementation gate (M0-C/D)** |

## 9. M0-B acceptance and handoff

**M0-B can close after owner review confirms D1/D2 and B-3, resolves or explicitly assigns B-1/B-2/B-4, and the reviewer verifies:**

- [ ] A single authoritative owner is identified for every proposed AWS resource **and individual SG rule**; no overlapping Terraform states.
- [ ] No foundation -> application dependency, no application Plan/Apply authority over foundation state, and no secret-bearing state reads.
- [ ] Existing `baseline/` paths and single-container consumers remain stable; app ECS/ALB ownership is isolated.
- [ ] The initial deployment account/state paths, qualification boundary, lifecycle sequencing and migration/rollback rules are recorded.
- [ ] M0-C owns module/output and Terraform graph verification; M0-D owns OIDC/IAM/KMS and network grant enforcement.

**Not yet claimed:** Terraform graph pass, Plans, CI results, AWS deployment or production readiness. Do not mark M0-B accepted until its architectural decisions are approved.

## Source inventory

- Baseline (public, same repository): [`baseline/main.tf`](../baseline/main.tf), [`baseline/locals.tf`](../baseline/locals.tf), [`baseline/outputs.tf`](../baseline/outputs.tf), [`modules/ecs_service`](../modules/ecs_service/README.md), [`modules/application_load_balancer`](../modules/application_load_balancer/README.md), [`modules/networking/security_policy`](../modules/networking/security_policy/main.tf), [`environments/staging/backend.tf`](../environments/staging/backend.tf).
- ReconoSense (private; paths for authorized reviewers only): `infra/terraform/BASELINE_INTEGRATION.md`, `infra/terraform/README.md`, `infra/terraform/environments/staging/main.tf`, `infra/terraform/modules/service_runtime/main.tf`, `infra/terraform/modules/background_jobs/main.tf`, `infra/terraform/bootstrap/outputs.tf`.
