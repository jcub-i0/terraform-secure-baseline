# v1.15.0 — M0 Architecture & Ownership

**Status:** M0 in progress — M0-A/B/C1 and consolidated C2–C4 design owner-approved; C5 and final security/cost/licensing acceptance open

**Scope:** Architecture and documentation only; no AWS deployments, state changes, or Terraform implementation

**Starting release:** `terraform-secure-baseline` v1.14.1

**Reference:** ReconoSense (private repository), `infra/terraform/BASELINE_INTEGRATION.md`

**Release roadmap:** [`ROADMAP_v1_15_0.md`](./ROADMAP_v1_15_0.md)

## 1. Objective and non-negotiable architecture rules

Deliver an approved, application-agnostic design that can satisfy all 17 ReconoSense integration contracts without embedding ReconoSense's business logic in `terraform-secure-baseline`.

- **Modular:** new ECS, job, schedule, data and release features are optional and reusable by other SaaS applications.
- **Single Terraform owner:** every deployed AWS resource has one authoritative Terraform state. Do not point the current standalone ReconoSense staging root and a baseline-derived root at the same resources.
- **Secure by default:** retain AWS-enforced least privilege, private networking, encryption, protected deployment, evidence and teardown rules.
- **Compatible:** preserve existing baseline resource addresses and single-container behavior where feasible; record any migration explicitly.
- **Application boundaries:** tenant schemas, data models, Cognito, business-specific IAM statements, documents, model selection, and job commands stay in the ReconoSense repository or a thin adopter-owned composition layer.
- **Testable without ReconoSense:** new generic capabilities need non-ReconoSense synthetic examples and negative tests before the ReconoSense integration test.

## 2. Current implementation inventory

**Baseline v1.14.1:**

- Existing modules include `ecs_cluster`, `ecs_service`, `application_load_balancer`, `storage`, `iam`, `networking`, `monitoring`, `security`, and others.
- `modules/ecs_service` currently generates one essential container per service, with digest-pinned image, per-service role ARNs, optional health checks, scaling and ALB target groups. No generic multi-container specification or standalone job interface exists.
- `modules/storage` hardcodes PostgreSQL `17.10`; it already uses ephemeral/write-only credentials. `modules/application_load_balancer` supports HTTPS and configurable target health paths, but the `baseline/` root creates an ALB only when registered ECS services require it.
- The top-level `baseline/` composition currently owns both shared infrastructure and ECS/ALB resources. Its graph must be checked for application-module dependency cycles before deciding whether adopters should call it directly.
- Baseline staging pins Terraform `1.15.8` and AWS provider `6.66.0`; re-evaluate constraints when integrating modules used by ReconoSense.

**ReconoSense, as currently documented:**

- `infra/terraform` has standalone modules for network, database, secrets, storage, identity, edge, messaging, runtime, containers, background jobs, model access, and observability.
- Its local Terraform code supports PostgreSQL 16, seven independent task definitions, multi-container API/scan tasks, a runtime-versus-owner execution-role split, write-only secrets, and `aws_rds_instance_state`-based staging pause/resume.
- Its Terraform README explicitly says **validated locally only, not yet deployed to AWS**. Its existing `deploy-staging.yml` workflow uses the older CloudFormation deployment path, not the newer Terraform integration flow.
- ReconoSense currently pins Terraform `>=1.11,<2.0` and AWS provider `~>6.69`. It has a dedicated AWS account with its own bootstrap/state/security boundaries. Whether this account can host a baseline-derived qualification without duplicating existing resources requires explicit review.
- ReconoSense PR #148 is still Draft; the eventual qualification must use an owner-accepted application SHA, not an unaccepted draft.

## 3. Contract-to-owner matrix — initial disposition

**Disposition:** **Existing** = baseline largely supports; **Enhance** = generic baseline interface needed; **App-owned** = stay in ReconoSense; **Shared** = baseline interface + app-specific configuration/qualification. The matrix is preliminary; it does not claim live acceptance.

| # | Requirement | Disposition | Proposed implementation and state owner | Target |
|---|---|---|---|---|
| 1 | HTTPS API, `/ready`, 50 MiB uploads, DNS/callback | Shared | Baseline's generic ALB/target-group interface; application owns hostname, ACM/DNS policy and callback. Verify upload and WAF behavior; resolve ALB coupling to baseline service registration. | M0, M3, M5 |
| 2 | Multi-container API/scan, clamd, optional ADOT | Enhance | Baseline ECS service/task-definition interface supports digest-pinned sidecars, `HEALTHY` dependencies, per-container health/logging. ReconoSense supplies image/command definitions. | M1 |
| 3 | Seven independent jobs, manual `RunTask` | Enhance | Optional baseline standalone task definitions and bounded invocation contract; application supplies names, sizing, commands and images. | M2 |
| 4 | Per-job schedules, default disabled, authorization | Enhance | Optional Scheduler + encrypted DLQ + per-schedule state; app supplies schedules and tenant-data authorization decision. | M2 |
| 5 | Per-task IAM, worker S3/SNS restrictions, extract-only Bedrock | Shared | Generic distinct task-role/permissions-boundary interfaces; app owns resource-specific policies, model IDs, Regions and authorization decisions. Never create shared wildcard task privileges. | M2, M3 |
| 6 | Runtime vs database-owner execution credentials | Enhance | Baseline job/service interfaces accept distinct execution roles and secret grants; application defines credential classes. | M2, M3 |
| 7 | Fixed secret JSON shapes, no plaintext in state | Shared | Reuse ephemeral + write-only Secrets Manager patterns and ECS secret references; application owns schema, generation, rotation and secret consumers. | M3 |
| 8 | PostgreSQL 16, owner/runtime roles, tenant SQL | Enhance | Baseline RDS engine version configurable, default remains `17.10`; application owns SQL roles, provisioning and migrations. Fresh PG16 qualification, **no in-place downgrade**. | M3 |
| 9 | Documents/quarantine buckets, Object Lock differences | App-owned | ReconoSense owns both bucket resources and retention rules; baseline exports security integration points without asserting log-bucket retention onto app data. | M3, M5 |
| 10 | Cognito PKCE, hosted UI, admin-created users | App-owned | ReconoSense identity module owns Cognito; baseline provides compatible HTTPS ingress and network integration. | M3 |
| 11 | Relay SNS and scheduler DLQ SQS | Shared | Application owns relay topic; generic scheduling infrastructure may own its own DLQ. Keep application messaging distinct from central SecOps queues. | M2, M3 |
| 12 | Failed task alerts and application log metrics | Enhance | Generic task-state/EventBridge alerting and optional log metric filters; application defines field names and alarm thresholds. | M2, M5 |
| 13 | Worker → migration exits 0 → API promotion | Enhance | Reusable protected release orchestration with explicitly staged changes, failed-migration block, and incompatible-schema drain/approval. No single Terraform Apply that prematurely promotes API. | M4 |
| 14 | AWS/Cognito/Bedrock egress 443, no direct inbound | Shared | Prefer baseline private-subnet networking with explicit NAT/firewall/endpoints; application defines required destinations. Measure functionality and cost against ReconoSense's public-subnet reference. | M0, M3, M5 |
| 15 | us-east-1 extraction origin | Existing | Baseline already accepts a Region input; ReconoSense pins application-specific Region/model destinations. | M0, M5 |
| 16 | Declarative running/maintenance/parked state | Enhance | **M0-B owner-approved B-5 design (2026-11-07; not implemented):** foundation exclusively owns RDS configuration while application owns the dedicated staging RDS start/stop controller, with narrowly scoped AWS authorization. App supplies lifecycle intent; M0-C/D must prove staging-only eligibility, safe drain/resume and least privilege. | M0-B, M2, M3, M4 |
| 17 | Disposable teardown vs protected evidence | Shared | Baseline owns shared-resource retirement guards; application owns document/retention lifecycle; dedicated state and denial of unsafe deletion/bypass; residual inventory required. | M3, M5 |

## 4. Architecture decisions to resolve before implementation

| ID | Decision / concern | Initial recommendation | Acceptance evidence |
|---|---|---|---|
| **D1** | **Composition and Terraform ownership** | Prefer a **thin, ReconoSense-owned integration root**, consuming pinned reusable baseline modules, initially in a fresh isolated synthetic-data environment. Do **not** replace existing baseline or ReconoSense staging in place. Evaluate **single composition state** versus **separate foundation/workload states** based on the actual dependency graph. Whichever is selected, no resource belongs to both. | Diagram, ownership inventory at AWS resource level, state/back-end map, dependency graph with no cycles, approved adoption/cutover path. |
| **D2** | Top-level `baseline/` ECS/ALB coupling | Preserve existing `baseline/` consumer behavior. Expose generic extension points or direct lower-level module composition; avoid implicit duplicate ECS clusters, services, target groups or security groups. | Interface/API contract, backward-compatible example, resource-address impact review. |
| **D3** | GitHub OIDC and release responsibilities | Distinguish baseline-foundation Plan/Apply authority, application image-publisher authority, and protected application release authority. ReconoSense's CloudFormation-era workflow is not assumed to perform Terraform promotion. | Trust/permissions table, GitHub environment approvals, state-read/write boundaries, promotion sequence. |
| **D4** | PostgreSQL engine and credentials | Keep default baseline `17.10`, add validated configurable version for *new* instances, qualify PG16 separately. Preserve write-only secrets; application owns runtime SQL roles, owner role access and migration logic. | Plan compatibility test, secret-state test, role-access negative tests. |
| **D5** | Release sequencing and state convergence | Use explicit, approved stages: publish worker/task definition → run migration and verify exit zero → promote API through the **authoritative Terraform owner**. No uncontrolled `aws ecs update-service` drift. | Positive and failed migration traces, incompatible-migration drain and approval records. |
| **D6** | Network topology and cost | Favor baseline private subnet+egress strategy, not an automatic public-task conversion. Compare NAT, endpoints, and firewall costs for disposable and production-like profiles and verify Cognito JWKS, Bedrock and ClamAV update paths. | Documented network flows and **priced** monthly scenario comparison (not estimated here). |
| **D7** | 50 MiB uploads with WAF | Prove full upload via HTTPS ALB with WAF. **AWS WAF on ALB inspects only the first 8 KiB of a body**; document oversized-body rule handling and downstream file scanning. | Positive/negative large-request and WAF tests; no claim of full-body WAF inspection. |
| **D8** | Staging RDS pause/resume | `aws_rds_instance_state` is provider-supported; make lifecycle management opt-in and controlled by the correct Terraform state. AWS may restart a stopped RDS instance after seven days; document that and the resource's no-op destroy behavior. | Provider compatibility review; staged pause/resume plan, safety guard and follow-up behavior. |
| **D9** | Data retention and destruction | Keep application documents and evidence bucket destruction rules application-owned; ensure neither retirement workflows nor deployer roles can bypass legal holds or protected object retention. | Positive/negative bucket deletion and IAM tests, residual inventory. |
| **D10** | Proprietary software rights | Baseline `LICENSE` prohibits use/deployment without separate authorization. Confirm the legal entity and written rights permitting ReconoSense to consume Nano Nexus's work before deployment; counsel/owners decide the mechanism. | Recorded license disposition, without changing the license merely for this release. |

## 5. M0 execution order (docs/design only)

- [x] **M0-A — Inventory:** Inspect both repositories, record 17 contracts, classify preliminary baseline gaps and application-owned resources.
- [x] **M0-B — Ownership (architecture accepted):** [Terraform composition and state ownership record](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md) documents the approved two-state model, staging integration, limited RDS run-state delegation, independent review findings and M0-C/D handoff. D1/D2/B-3/B-5 are owner-approved; no AWS permissions or infrastructure were changed.
- [ ] **M0-C — Interfaces (C1 and consolidated C2–C4 designs accepted):** [Accepted C1 publication design](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md) merged in PR #961; the [single C2–C4 interface package](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md) was owner-approved as a **design only** (2026-11-07). C5 graph/compatibility review and independent cross-repository verification remain open. No `.tf`, CI, IAM, SSM, state or AWS changes are authorized.
- [ ] **M0-D/E/F — Consolidated final architecture closeout:** In one final work package, resolve protected IAM/OIDC/CI coordination and SG security authority, realistic cost scenarios, licensing authorization and independent acceptance; keep any actual deployment/testing in M1–M5. M0-D/E/F remain distinct requirements, not three separate review cycles.
**M0 acceptance:** Every one of the 17 requirements has an implementation owner and specific validation target; one Terraform state owns each AWS resource; no unapproved destructive migration or cross-state overlap is proposed; modular interfaces and backwards compatibility are recorded; deployment order, realistic operating costs and authorization/licensing are resolved.

## References and technical notes

- Baseline: [`modules/ecs_service`](https://github.com/jcub-i0/terraform-secure-baseline/tree/main/modules/ecs_service), [`baseline/main.tf`](https://github.com/jcub-i0/terraform-secure-baseline/blob/main/baseline/main.tf), [`modules/storage/main.tf`](https://github.com/jcub-i0/terraform-secure-baseline/blob/main/modules/storage/main.tf), [`modules/application_load_balancer`](https://github.com/jcub-i0/terraform-secure-baseline/tree/main/modules/application_load_balancer).
- ReconoSense (private repository; paths for authorized readers): `infra/terraform/README.md`, `infra/terraform/environments/staging/main.tf`, `infra/terraform/BASELINE_INTEGRATION.md`.
- AWS WAF ALB body inspection limit: [AWS documentation](https://docs.aws.amazon.com/waf/latest/developerguide/web-acl-setting-body-inspection-limit.html).
- RDS stop behavior: [AWS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_StopInstance.html).
- AWS provider `aws_rds_instance_state`: [Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/rds_instance_state).
- HashiCorp provider `aws_secretsmanager_secret_version` write-only: [Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version).
