# v1.15.0 — M0-C5: Dependency Graph and Backward-Compatibility Review

**Status:** Proposed source-based architecture/verification handoff; independent review and owner acceptance pending
**Baseline examined:** `main` after PR #962, merge `21ad01122a4d88b5370ca7cd19441b843b833f18`
**Scope:** One consolidated, **documentation-only** C5 checkpoint; no implementation, state/AWS operations, or executed Terraform graph
**References:** [M0-B two-state ownership](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md), [accepted C1 contract](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md), [accepted C2–C4 interfaces](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md)
**Independent reference:** Private ReconoSense contract at `~/recon-engine/infra/terraform/BASELINE_INTEGRATION.md` (local source review must be separately performed)

## 1. Decision and evidence boundary

M0-C5 is the final **design-stage dependency and compatibility** review before the combined M0-D/E/F architecture/security/economics/licensing closeout. The design decisions under M0-B/C1/C2–C4 are accepted; this checkpoint does **not** reopen their ownership model or authorize Terraform implementation. C5 specifies exactly which present source relationships are evidenced, which proposed resource/deployment edges require implementation, and which executable regression and negative tests must accompany M1–M5.

**Do not confuse three evidence levels:**

1. **Source observed now:** existing Terraform HCL references and resource addresses inspected at the baseline commit above.
2. **Design proposed:** edges and interfaces needed in a **new, not-yet-implemented** application integration root.
3. **Not performed:** `terraform graph`/`plan` for the proposed integration, state address migration, AWS IAM simulation, deployment or live acceptance. Terraform cannot graph new modules that do not yet exist.

A read-only reviewer can assess the DAG and document required edges now. **Executable graph/plan acceptance must be performed against actual future implementation commits**; it is explicitly assigned below rather than inaccurately claimed complete in M0.

## 2. Verified existing composition (source inspection only)

| Existing source | Observed behavior | C5 non-regression constraint |
|---|---|---|
| [`baseline/locals.tf`](../baseline/locals.tf), lines 120–152 | `deployable_ecs_services` filters on non-null image digest; `ecs_required_repositories` includes **all** registered service repositories, even when images are not deployable; ALB service map includes only deployed services with ingress. | An empty deployment should not create ECS services or ALB. Removing a null-image registration can still remove its derived ECR repository unless an explicit inventory retains it. |
| [`baseline/main.tf`](../baseline/main.tf), lines 381–470 | Foundation presently instantiates ECR, one ECS cluster and the `ecs_service` module; the shared ALB module is conditional on ingress-enabled deployable services. | The new app root must consume the foundation cluster/ECR and own its **own** ALB/services; do not invoke both foundation and application roots to own identical resource instances. |
| [`modules/ecs_service/main.tf`](../modules/ecs_service/main.tf), lines 1–36, 53–129 | Existing task definitions render exactly one essential named container per service; fixed-count and autoscaled services are selected into distinct `for_each` maps. | When new container inputs are absent, retain the current one-container JSON semantics and resource keys/addresses; no implicit migration or service replacement. |
| Same file, lines 162–207 and 219–270 | Fixed services use `aws_ecs_service.services`; autoscaled use `aws_ecs_service.autoscaled_services` with `ignore_changes = [desired_count]`. Both use private networking with `assign_public_ip = false`, task SG, task definition and `terraform_data` launch-readiness inputs. | An autoscaled service cannot be parked merely by changing desired count in Terraform; preserve existing fixed/autoscaled addresses and require an explicit scale/pause control. |
| [`modules/application_load_balancer/main.tf`](../modules/application_load_balancer/main.tf), lines 61–119 | HTTPS listener and forwarding listener rules reference target groups; a target group ARN can be known without proving its forwarding listener/rule is ready. | ECS service creation must be ordered after **listener/forwarding-route readiness**, not only target-group existence; preserve an acyclic resource-level relationship. |
| [`modules/networking/security_policy/main.tf`](../modules/networking/security_policy/main.tf), lines 130–245 | Module owns ECS-to-endpoint/S3/DB and ALB ingress/egress rules, including ingress on foundation DB/endpoint SGs; platform-wide rules exist elsewhere in this same module. | Do not call this full module in application state or duplicate foundation rule addresses. Each app-facing connection must have exactly one owner and separately approved admission authority. |
| [`modules/storage/main.tf`](../modules/storage/main.tf), lines 1–170 | `aws_db_instance.main` uses PostgreSQL `17.10`, foundation subnet/DB SG, master secret and RDS monitoring. Module also owns separate centralized S3 logs. | Preserve DB configuration and deletion in foundation. C3-D3's optional future `modules/database` extraction requires same-state `moved` mappings and a non-destructive plan; do not perform it during M0. |

**Assessment:** These source relationships are consistent with a reusable application root consuming foundation identifiers, but this inspection alone **does not prove** the complete current or future Terraform graph is cycle-free. Do not describe a diagram as a successful graph run.

## 3. Required directed dependency graph

The approved two-workload-state model is strictly **foundation → application**. The application never owns or imports foundation resources, and foundation HCL cannot read application outputs or rely on application-created SGs.

```text
Existing protected bootstrap and account/governance states
                      |
                      v
Foundation state: VPC -> endpoints/SGs -> RDS and CMKs -> ECS cluster/ECR
                      |
           Terraform-owned SSM non-secret contract
                      |
       protected post-Apply validation + eligibility epoch
                      |
               approved application Plan
                      |
               application-owned resources:
                +------------------------+
                | IAM policy/attachment  |
                | app SG / grant access  |
                | logs + task definition |
                | ACM -> ALB -> listener |
                |        -> route/target |
                +------------------------+
                      |
         resource-level launch readiness
          (IAM + SG + listener/route)
                      |
             application ECS service
                      |
        worker/job availability -> migration exits 0
                      |
           protected API promotion
```

The arrows between **foundation and application** represent published values and a protected release gate, not a cross-state Terraform resource-level `depends_on`. Worker → migration → API promotion is an **application release orchestration gate**, not something proven by a single Terraform graph or one unconstrained Apply.

### 3.1 Required resource-level edges in the application state

| Dependency | Mechanism to design/verify | Unsafe shortcut |
|---|---|---|
| Cluster/subnets/ECR/RDS/KMS identity → application configuration | Exact C1 SSM publication identity, version/digest, approved eligibility epoch, expected account/Region and protected manifest | Application `terraform_remote_state` or whole foundation-state reads |
| App ALB target groups/HTTPS listener → forwarding listener rules → ECS service readiness | Output a narrow route/listener readiness **token** or reference from app-owned ingress composition, consumed by task/service readiness without a reverse dependency | Service depends only on target-group ARN; unqualified whole-module `depends_on` that creates ALB/SG/service cycles |
| Execution-policy, task-role attachment, KMS secrets grants → task launch | Retain the existing `execution_policy_ids` / `task_role_policy_attachment_ids` readiness model and inspect whether generated IDs actually form dependencies | Claiming that role/policy **names** or static strings prove applied attachment/secret permission |
| Task/ALB SG + approved endpoint/DB connectivity → service/task launch | App-owned rules or separately governed foundation connector grant, per-rule owner, authorized task SG attachments; prove admission before launch | Reusing platform `security_policy` module in app state, broad application mutation of DB/endpoint SGs, or permissive alternate SG attachments |
| Sidecar readiness → primary serving container | ECS `containerDependencies` with supported condition and health check, deterministic names, optional per-container start/stop timeouts | Assuming `HEALTHY` means perpetual readiness; dependency on missing/essential-completion container |
| Per-job roles, logs, SGs, task definition → bounded RunTask/Scheduler | Separate task definitions and optional default-disabled Scheduler, guarded PassRole and target scope, encrypted DLQ and failure alerts | Adding permanent ECS services for jobs or copying standalone broad IAM |
| DB available → migration task exits successfully → serving API promotion | Protected, full-release coordinator with explicit migration exit-code barrier, authoritative application-state API promotion, rollback/recovery | Single unguarded Terraform Apply or direct unmanaged `aws ecs update-service` drift |
| No new launches → schedules disabled/retries fenced → app-specific jobs/tasks drained → RDS Stop | Shared environment lease, app-specific discovery, autoscaled service target reconciliation, exact B-5 resource scope | Existing standalone check-before-disable pause order or stopping shared foundation DB |
| App drain/teardown → optional foundation retirement | Protected coordination, data/evidence-retention policy and separate foundation authority | App Destroy deleting RDS, central logs, baseline state or protected evidence |

**C5-D1 (proposed design conclusion):** Use **resource-level** readiness outputs for HTTPS listener and forwarding route association, rather than a blanket application module dependency. The output must remain independent of service-created task SGs or other references that would form a cycle. Implementation is deferred to M1/M3, with actual graphs required.

## 4. Backward-compatibility and executable evidence matrix

| Scenario / fixture | Acceptance expectation | Timing / evidence owner |
|---|---|---|
| Empty foundation registration (`ecs_services = {}`) | Shared cluster may exist; no ECS services, no integration ALB or implicit app resources. ECR ownership remains explicit. | C5 source/design; actual `plan` + module output checks at M1/M2 |
| Null-digest staging test registration | No running service/ALB, but ECR repository may still be derived by registration; explicit inventory must protect intended repository lifecycle. | C5 source/design; actual plan and remove-registration diff at M2 |
| Legacy fixed-count, single-container service | Same resource addresses (including `aws_ecs_task_definition.task_definitions[key]` and `aws_ecs_service.services[key]`), container JSON semantics, ALB port/logs and no default drift. | M1 baseline plan/diff and regression fixtures |
| Legacy autoscaled service | Same `aws_ecs_service.autoscaled_services[key]` and scaling ownership; `desired_count` remains ignored after bootstrap, no implicit recreation, explicit park procedure. | M1–M3 plan and lifecycle tests |
| Opt-in multi-container API | Stable digest-pinned primary/sidecars; health dependency validation, optional absent containers, per-container start/stop timeouts, log groups/volumes and ALB container mapping. | M1 tests and graph/plan |
| Standalone jobs and disabled schedules | No new cluster or always-on ECS job service; task/execution roles separated; bounded `RunTask`/PassRole and SG; encrypted DLQ/alerts. | M2 graph/plan and positive/negative tests |
| New PostgreSQL 16 instance vs existing 17.10 | 17.10 remains default. PostgreSQL 16 only on newly approved instance; never silently change engine version or replace an existing DB. | M3 independent plans, database startup/migration acceptance |
| Optional future database-module extraction | Same **foundation** state, complete `moved` address map and no destruction/replacement (DB, subnet, SG, credentials, logs, monitoring). Defer if any unsafe migration. | M3 owner-approved plan; not mandated for release |
| ALB + SG + IAM launch readiness | Graph acyclic and service creation gated by listener/route, relevant IAM attachments, KMS grants and SG rules; no apparent target-group/SG/service cycle. | M1/M3 actual graph + apply sequence |
| Foundation publication/coordination | Changed values, changed epoch, prior saved-plan, failed/partial Apply, expired/labeled SSM history, coordinator crash or lock expiry must all fail closed. | C1 protocol implementation M0-D/M4; negative tests M4/M5 |
| Dedicated synthetic staging B-5 run-state | No app RDS configuration ownership; correct instance scope, drain-before-stop, resume-before-migrate, no unrelated tasks affected, no assumed permanent stop. | M3/M4/M5 protected lifecycle tests |
| Protected application teardown | No foundation resource, baseline S3 state, RDS master secret or retained evidence deleted; inspect residual resources and approved retirement sequence. | M5 security/destroy tests |

**Pass/fail rule:** Any unexpected RDS replacement/deletion, baseline resource-address churn, duplicate state ownership, new cross-state dependency, unsafe API promotion, or privilege widening is a **release-blocking implementation finding**. Do not downgrade an unsafe future plan because this design PR was accepted.

## 5. Six prior Codex findings carried forward

The local cross-repository review of PR #962 returned **ACCEPT WITH DEFERRED ITEMS**, with six nonblocking findings. They must remain visible until their assigned tests are complete:

| Finding | C5 disposition | Future owner |
|---|---|---|
| **N1** — Attached security groups grant a union of permissions | No approval of connector-grant design without independently enforced SG-attachment admission for ECS create/update, direct RunTask and Scheduler; deny alternate SG/rule bypass. | M0-D (authority), M3–M5 (negative tests) |
| **N2** — Container start/stop and dependency semantics | Keep optional primary/sidecar timeouts and dependency validation in interface; assert graceful stop and ongoing readiness. | M1/M2 |
| **N3** — Reference pause/resume race | Prevent launches before disabling/draining; do not copy standalone task discovery/order unchanged; bind entire lifecycle to lease. | M3/M4/M5 |
| **N4** — App DB owner is currently RDS master | Require protected bootstrap, separate SQL rights/extensions/rotation and denied master secret access. | M0-D/M3–M5 |
| **N5** — Shared-cluster alerts and CMK gaps | Scope alert identities by application task family; validate container attribution and encryption-compatible publisher/decrypt policies. | M2/M3/M5 |
| **N6** — Listener/route readiness not in existing ECS module | Specify app ingress readiness edge before service creation; test graph and startup order without module cycles. | C5 design; M1–M3 executable tests |

## 6. C5 acceptance and handoff

- [x] Inspect authoritative baseline source and identify existing task, ALB, network, database, ECR and fixed/autoscaled dependencies. **Source inspection does not equal a `terraform graph` pass.**
- [x] Define required application resource-level edges, no-reverse-dependency invariant and explicit future graph/plan scenarios.
- [x] Preserve original single-container resource addresses/defaults, RDS foundation ownership and C3-D3 optional same-state module extraction.
- [x] Carry N1–N6 into M0-D and M1–M5 without inventing extra architecture checkpoints.
- [ ] Independent focused source/cross-repository review of **this C5 design and coverage**, including representative ReconoSense implementation constraints; report real architectural blockers.
- [ ] Owner accepts C5 **as a design/verification handoff**, recognizing actual new-module Terraform graphs/plans and AWS security tests remain outstanding until implementation exists.
- [ ] Docs Validation and Static Analysis green on final C5 PR head; no Terraform or AWS operation claimed.

**When accepted:** M0-C design work may close, **not** M0-D/E/F or the v1.15.0 release. The next and final M0 work package combines IAM and deployment authority, connector-SG admission decisions, SSM coordinator ownership, budget/operating-cost scenarios, Nano Nexus–ReconoSense license authorization and final architecture approval. M1–M5 execute the technical work only after separate owner authorization.

**No Terraform files, provider configuration, workflows, state, IAM, AWS resources, applications or credentials were changed or accessed to create this document.**
