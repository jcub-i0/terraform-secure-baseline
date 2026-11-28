# v1.15.0 Roadmap — Secure SaaS Application Integration

**Release status:** M0 architectural direction owner-approved and independently reviewed (**ACCEPT WITH DEFERRED ITEMS** at PR #965 head `58f7886`). SG/lease enforcement, retained evidence, financial and licensing authorization remain open. M1 implementation is merged and scoped live qualification is complete: positive multi-container operation, negative `SUCCESS` prerequisite behavior, and a final 16/16 baseline-validator pass. Staging workload Destroy completed successfully. M1 was owner-accepted on November 13, 2026, for the documented qualification scope; evidence retention/sanitization remains a nonblocking follow-up. See the [M1 implementation and acceptance record](./v1_15_0_M1_IMPLEMENTATION_STATUS.md).
**Starting point:** `v1.14.1`
**Reference application:** ReconoSense

## Objective

Extend `terraform-secure-baseline` into a **modular, application-agnostic foundation** for SaaS workloads handling sensitive data. ReconoSense will validate the capabilities in a realistic deployment, but its business logic and application-specific resources must remain outside reusable baseline modules. The baseline supports SOC 2 / ISO 27001 readiness; it does not confer compliance or certification.

## Architectural requirements

- **Reusable by design:** No ReconoSense-specific workflows, SQL, IAM grants, model IDs, or resource names hardcoded in baseline modules. Application-specific choices belong in a separate composition layer.
- **Optional and compatible:** New capabilities are opt-in. Preserve existing single-container ECS behavior, defaults, and Terraform resource addresses where feasible; document unavoidable migrations.
- **Secure by default:** Prefer AWS-enforced least privilege, encryption, private networking, explicit authorization, and observable failures over redundant custom validators.
- **Single resource owner:** Every AWS resource has one authoritative Terraform state owner. Define stable inputs, outputs, and deployment responsibilities across repositories.
- **Independently testable:** Validate each reusable capability with a synthetic, non-ReconoSense configuration as well as the eventual application integration.

## Reusable baseline and adopter responsibilities

The baseline supplies infrastructure interfaces and protected execution/deployment controls. Each adopter supplies a separate application composition using version-pinned modules; the foundation does not consume application-state outputs.

| Reusable baseline requirement | Adopter-owned configuration or behavior |
| --- | --- |
| Configurable PostgreSQL version, protected foundation master identity, and interfaces for separate application credentials | Selected version, application database-owner/runtime identities, SQL grants, tenant schemas and migrations |
| Protected foundation publication, approved network connectivity, scoped deployment IAM and mandatory role boundaries | Application identities, reviewed resource grants, destinations and job catalog |
| Configurable HTTPS health matching, ALB DNS alias metadata and narrowly scoped upload-route WAF treatment | Hostnames, health endpoints, routes, identity provider and MFA policy |
| Bounded job execution, completion reporting, release gates and lifecycle fencing | Task images/commands, schedules, administrative operations, migration compatibility and recovery decisions |
| Infrastructure capable of enforcing approved encryption, retention and deletion controls | Document/quarantine storage, application-audit archive and integrity processing, retention/offboarding rules and AI processing configuration |

ReconoSense's Cognito/TOTP policy, tenant SQL, audit-event semantics, Bedrock model/geography and financial workflows remain outside baseline defaults. Reuse or extend a module only for a general infrastructure capability. Production RDS Multi-AZ is already supported; integration must configure and qualify it rather than count it as new infrastructure work.

## Milestones

| Milestone | Completion status | Brief description | Requirements / acceptance criteria |
| --- | --- | --- | --- |
| **M0 — Architecture & Ownership** | **In progress — direction owner-approved** | M0-A/B/C merged through PR #964. [One D/E/F closeout](./v1_15_0_M0_D_E_F_CONSOLIDATED_CLOSEOUT.md) records the approved identity/coordinator architecture, disposable dev (2 AZ, approx. 24–48h, application Destroy before existing foundation Destroy), and no-fee licensed-SaaS direction. **Independent cross-repository review completed with zero design merge blockers. Open:** enforceable SG/release control, retained-evidence destination and export before Destroy, cost ceiling and executed license. The original M0 approval did not authorize deployment; later implementation checkpoints are tracked below. | Classify the pinned reference-application contracts as existing capability, baseline enhancement, or application-owned; assign Terraform state/IAM/CI ownership; specify reusable interfaces and compatibility decisions; assess lifecycle feasibility, costs, and licensing. Approve the architecture before coding. |
| **M1 — Multi-Container ECS** | **Complete** | PRs #967–#969 merged implementation, initial image release, and staging qualification configuration. Positive readiness and negative `SUCCESS` evidence are recorded; legacy compatibility retains offline coverage, and optional interfaces are not all live-tested. See [qualification limits and closeout](./v1_15_0_M1_IMPLEMENTATION_STATUS.md#e-live-qualification-and-closeout). | Configurable container images (digest-pinned), health checks, `HEALTHY` dependencies, ports, secrets, environment, and logging. Prove sidecar readiness and backward compatibility with existing single-container services. |
| **M2 — Background Tasks & Scheduling** | **In progress — offline broker and disabled infrastructure implemented** | Standalone tasks, launch IAM, Scheduler-to-SQS, broker admission/dispatch/completion, foundation gates, request/completion delivery infrastructure and dedicated application backends are merged through PR #1009. Deployment/invocation protection, artifact publication/composition, gate lifecycle operations, monitoring, recovery and live qualification remain. | Bounded authorized jobs; per-job roles, durable request accounting and concurrency; schedules disabled by default; encrypted failure delivery; alerts for failed starts and nonzero exits. Qualify allowed/denied paths and lifecycle races before activation. See the [C4 record](./v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md). |
| **M3 — Data, Storage & Identity Interfaces** | Not started; database module extraction already implemented | Complete generic database, connectivity and ingress interfaces and their published fields. RDS already resides in `modules/database`; the [R3 record](./v1_15_0_R3_REFACTOR_CLOSEOUT.md) retains refactor evidence and limitations. | Configurable PostgreSQL version, retaining default `17.10` and qualifying fresh **16** instances; separate application owner/runtime credentials without plaintext secrets in state; approved network attachment/readiness; health matcher, ALB zone output and narrow upload WAF controls. Integrate adopter-owned identity, storage and audit/retention controls without importing application logic. |
| **M4 — Migration-Aware Releases** | Not started | Provide generic pre-deployment job and service-promotion gates with protected release/lifecycle coordination. | Enforce **approved task revision → intended migration container exits 0 → service promotion**; qualify first install with serving count zero, compatible upgrades, incompatible upgrades and interrupted releases. Broker acknowledgement or task termination alone is not migration success. Fence launches and prove service/job drain before disruptive operations; preserve application state authority and use schema-compatible rollback or explicit recovery. |
| **M5 — Integration Qualification & Closeout** | Not started | Qualify generic interfaces and a pinned ReconoSense integration using synthetic data; record the exact configuration and limits. | After separate deployment/budget approval and executed ReconoSense license, begin with the planned two-AZ development exercise, then qualify the intended production controls, including database Multi-AZ/failover, identity, retained storage and recovery. Test API, jobs, IAM, alerts, migrations, tenant isolation and **application-first → foundation Destroy**; independently inspect orphan tasks/schedules/ENIs and retain required evidence with usable keys. Scope and budget both phases explicitly; the **24–48h** development target is not proof of production readiness. Preserve production retirement/cleanup approvals and record SHAs, costs and residual resources. |

### Next M2 checkpoint

Implement the generic protected application deployment IAM module and account-bootstrap wiring: separate Plan/Apply identities, exact backend permissions, protected workflow trust, role boundaries and broker invocation/bypass restrictions. PR #1009 implemented backend storage, not these identities. Resolve the administrative-task integration boundary during this design; a fixed application runner consuming authorized operations is a candidate, not an approved broker-schema change. Keep the broker, delivery mappings and schedules disabled pending qualification.

### Reference-application qualification boundary

Before M5, pin the completed application revision and its runtime contract: images, tasks, administrative operations, credential classes, destinations, retained stores and release modes. For ReconoSense, verify mandatory MFA, application-audit completeness/recovery, retention/offboarding and restore safeguards, tenant isolation and manual continuity during AI outages. Hosting region, Bedrock source region and inference destinations are separate inputs/approvals. These are adopter acceptance cases, not generic product defaults. Baseline M5 evidence supports hosting adoption; ReconoSense's customer-release gates remain separate.

## Current architecture records

- [M0-A/B inventory and owner-approved state model](./v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md)
- [M0-B current state/backend ownership](./v1_15_0_M0_B_ARCHITECTURE_AND_TF_OWNERSHIP.md)
- [M0-C1 accepted foundation publication design](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md)
- [M0-C2–C4 owner-approved interface design (documentation only)](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md)
- [M0-C5 accepted source-based dependency and compatibility handoff (PR #964)](./v1_15_0_M0_C5_DEPENDENCY_AND_COMPATIBILITY_REVIEW.md)
- [M0-D/E/F combined closeout — pending decisions and acceptance](./v1_15_0_M0_D_E_F_CONSOLIDATED_CLOSEOUT.md)
- [M1 implementation, live qualification, evidence limits, and owner closeout](./v1_15_0_M1_IMPLEMENTATION_STATUS.md)
- [M2 launch authorization, implemented broker contracts and remaining controls](./v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md)

## Release gates

`v1.15.0` is ready to tag only when:

1. M0–M5 acceptance criteria are met, with no unresolved release-blocking findings.
2. Terraform Plan, static analysis, documentation checks, and focused regression tests pass **at the intended release commit**.
3. Live positive/negative qualification demonstrates the new interfaces, and existing consumers retain expected behavior.
4. Ownership, upgrade instructions, security-control mappings, evidence limits, and outstanding operational responsibilities are documented. Historical `v1.14.x` evidence gaps are not silently treated as resolved.

**Deferred unless required to unblock adoption:** multi-Region active-active, application-specific business logic or tenant SQL, a general-purpose authentication framework, and full compliance automation.

**Status convention:** *Planning* → *In progress* → *Complete* (only after reviewed implementation and recorded acceptance evidence). *Blocked* is used when an unresolved dependency prevents progress.
