# v1.15.0 Roadmap — Secure SaaS Application Integration

**Release status:** Planning — M0 architecture work in progress
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

## Milestones

| Milestone | Completion status | Brief description | Requirements / acceptance criteria |
|---|---|---|---|
| **M0 — Architecture & Ownership** | **In progress** | M0-A/B/C design work merged through PR #964; [one combined D/E/F closeout](./v1_15_0_M0_D_E_F_CONSOLIDATED_CLOSEOUT.md) is proposed for IAM/security governance, priced operating scenarios, licensing and final owner decisions. No Terraform/AWS implementation is approved. | Classify all **17 ReconoSense integration contracts** as existing capability, baseline enhancement, or application-owned; assign Terraform state/IAM/CI ownership; specify reusable interfaces and compatibility decisions; assess lifecycle feasibility, costs, and licensing. Approve the architecture before coding. |
| **M1 — Multi-Container ECS** | Not started | Extend ECS services for generic sidecars and dependencies. | Configurable container images (digest-pinned), health checks, `HEALTHY` dependencies, ports, secrets, environment, and logging. Prove sidecar readiness and backward compatibility with existing single-container services. |
| **M2 — Background Tasks & Scheduling** | Not started | Add reusable, independently configured Fargate jobs. | Standalone task definitions; bounded on-demand `RunTask`; per-job task/execution roles and IAM; optional schedules **disabled by default**; encrypted scheduler DLQs; alerts for failed starts and nonzero exits. Verify allowed and denied job permissions. |
| **M3 — Data, Storage & Identity Interfaces** | Not started | Close application-integration gaps without absorbing application logic. Evaluate extracting RDS infrastructure from modules/storage into a dedicated modules/database module while preserving foundation-state ownership. Execute only with an explicitly reviewed, non-destructive Terraform migration plan; otherwise defer the refactor. | Configurable PostgreSQL version (qualify **16**, retain existing default); separate runtime/owner credentials without plaintext secrets in state; application-owned document buckets and identity provider; secure HTTPS, networking, and approved egress. Validate storage retention/teardown choices and tenant-access boundaries. |
| **M4 — Migration-Aware Releases** | Not started | Gate service promotion on successful pre-deployment work. | Enforce **worker image → migration task exits 0 → API promotion**; support first install with API count 0; block promotion on migration failure; require explicit drain/approval and a documented recovery path for incompatible migrations. Prove positive and negative release paths. |
| **M5 — Integration Qualification & Closeout** | Not started | Prove end-to-end adoption and publish reproducible evidence. | Deploy an **accepted ReconoSense commit** with synthetic data in disposable staging; test API, jobs, IAM boundaries, failure alerts, migration gating, backup recovery, and protected teardown. Record SHAs, image digests, effective inputs, negative tests, residual resources, exclusions, and actual costs. |

## Current architecture records

- [M0-A/B inventory and owner-approved state model](./v1_15_0_M0_ARCHITECTURE_OWNERSHIP.md)
- [M0-C1 accepted foundation publication design](./v1_15_0_M0_C_REUSABLE_MODULE_INTERFACES.md)
- [M0-C2–C4 owner-approved interface design (documentation only)](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md)
- [M0-C5 accepted source-based dependency and compatibility handoff (PR #964)](./v1_15_0_M0_C5_DEPENDENCY_AND_COMPATIBILITY_REVIEW.md)
- [M0-D/E/F combined closeout — pending decisions and acceptance](./v1_15_0_M0_D_E_F_CONSOLIDATED_CLOSEOUT.md)

## Release gates

`v1.15.0` is ready to tag only when:

1. M0–M5 acceptance criteria are met, with no unresolved release-blocking findings.
2. Terraform Plan, static analysis, documentation checks, and focused regression tests pass **at the intended release commit**.
3. Live positive/negative qualification demonstrates the new interfaces, and existing consumers retain expected behavior.
4. Ownership, upgrade instructions, security-control mappings, evidence limits, and outstanding operational responsibilities are documented. Historical `v1.14.x` evidence gaps are not silently treated as resolved.

**Deferred unless required to unblock adoption:** multi-Region active-active, application-specific business logic or tenant SQL, a general-purpose authentication framework, and full compliance automation.

**Status convention:** *Planning* → *In progress* → *Complete* (only after reviewed implementation and recorded acceptance evidence). *Blocked* is used when an unresolved dependency prevents progress.
