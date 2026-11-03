# v1.14.0 Roadmap — Production Deployment Assurance & Security Hardening

**Status:** `In progress`
**Baseline:** [v1.13.0 — Recovery Assurance & Edge Protection](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.13.0) (`0ebfea2d675e1d443b2f610ff329fea2cd70363d`)
**Objective:** Strengthen the security and operational reliability of the existing AWS baseline, then demonstrate that a supported, single-container ECS/Fargate SaaS application can be deployed, monitored, and recovered under a production configuration.

This release prioritizes **correctness and evidence over new features**. It does not claim that every application or organization is production-ready simply because the baseline passes its infrastructure checks.

## Milestones

| Milestone | Scope | Acceptance target | Status |
|---|---|---|---|
| **M1 — CI/CD State Protection** | Separate GitHub Plan state-read permission from S3 lockfile mutation permissions; retain required Apply capabilities. | Plan cannot modify Terraform state; legitimate plans and locking still work; affected account roots and workflows remain compatible. | `Complete` |
| **M2 — Deployment & Backup Assurance** | Correct backup-job API error handling and establish explicit application-release acceptance after Terraform Apply. | API failures fail validation; failed ECS releases cannot be reported as accepted merely because Terraform Apply succeeded. | Planned |
| **M3 — Production Operational Qualification** | Qualify a synthetic production-profile workload; close material monitoring and recovery gaps discovered by testing. | Measured deployment, availability, database recovery, notification and evidence-retention outcomes meet explicitly agreed test criteria, or are documented as gaps. | Planned |
| **M4 — Regression & Release Qualification** | Review changes, run relevant CI and live validation, document results, and publish the release. | All approved milestones are qualified, residual risks are documented, and the maintainer explicitly authorizes publication. | Planned |

## M1 — CI/CD State Protection

**Purpose:** Remove unnecessary production-state modification authority from the GitHub Plan role without breaking native S3 state locking.

**Approved design direction - `Complete`:**

- Permit Plan to **read** state objects (`s3:GetObject`), while granting `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` only to S3 `*.tflock` objects in the configured state bucket.
- Preserve required bucket listing and state-KMS access. Keep the Apply role's existing state permissions and OIDC trust behavior unchanged for this milestone.
- Account for all relevant committed backends and migrated state-stack layouts across the five account buckets; do not assume there is only one state key per bucket.
- Extend existing IAM regression coverage to check actual rendered policy actions/resources, including negative state-write cases and alternative effective grants. Reuse the existing Static Analysis workflow; avoid a new workflow.
- Qualify with disposable, synthetic, versioned state before any approved account-root rollout. **Never attempt destructive permission tests against real state.**

**Exit gate:** Offline positive/negative tests pass; disposable Plan and Apply operations succeed as expected; prohibited Plan state mutations are denied; affected roots are reviewed and the approved IAM rollout is verified. Record residual bucket-wide lockfile access and broad state-read permissions explicitly.

## M2 — Deployment & Backup Assurance

**Purpose:** Make a successful infrastructure Apply distinguishable from a successful application release, and prevent backup API errors from being misreported as empty job history.

- Fix `scripts/validation/validate-backup.sh` so failure of `aws backup list-backup-jobs` causes validation failure. A **successful** but empty response may retain its documented no-history warning. Add regression tests for both cases.
- Define a bounded post-Apply acceptance check for **deployable** ECS services: intended task-definition revision, completed primary rollout, desired/running counts, relevant task and target health, and a clear failure result when ECS rolls back an unhealthy release.
- Preserve existing behavior for `ecs_services = {}`, null image digests, services without ingress, and approved retirement paths. Do not treat a generic ECS health check as proof that an application's business endpoints or SQL operations work.
- Exercise both a healthy release and an intentionally unhealthy release in disposable AWS infrastructure. Determine whether the acceptance step belongs in the existing Apply workflow or an explicitly required release gate before implementation.

**Exit gate:** Backup API errors fail closed; an unsuccessful application rollout cannot be silently accepted; successful deployments prove the intended revision is healthy. Existing empty/disabled-state workflows remain compatible.

## M3 — Production Operational Qualification

**Purpose:** Verify that the current platform can support a representative PostgreSQL-backed HTTPS application with realistic failures, and implement only narrowly justified hardening.

**Pre-deployment gate:** Agree on synthetic data, permitted fault injections, success thresholds, cost ceiling, retention requirements, incident-response owner, and teardown/disposition procedure. Obtain separate authorization for AWS spending and disruptive tests.

**Qualification targets in a disposable `staging` workload using `deployment_profile=production`:**

- **Application availability:** Verify actual multi-AZ ECS placement, intended capacity, application/database transactions, task replacement, and a failed deployment's observable outcome. Test any selected scaling policy under controlled load.
- **Database and recovery:** Perform a controlled RDS Multi-AZ failover while observing connection recovery and data integrity; complete an approved backup restore and application reconnection check. Record observed duration and data-loss results without claiming a universal RTO/RPO.
- **Operational visibility:** Assess actionable ALB/application failure signals, RDS capacity indicators, backup/restore freshness and failure detection, and real SecOps notification receipt. Assign application-specific SQL and transaction monitoring to the adopter rather than making it an unconditional platform feature.
- **Evidence survival:** Identify which audit and recovery records must survive workload retirement; confirm any chosen independent archive remains readable and decryptable with retained key material. Do not equate S3 lifecycle retention with immutability.
- **Safe retirement:** Run existing protection and authorization gates, then verify residual resources, backups, logs, state, and expected costs after cleanup.

**Exit gate:** Publish the tested configuration and image digest, pass/fail outcomes, observed timings, retained evidence references, and any open limitations. Remediate only material baseline defects demonstrated by review or testing; document application/operator-owned requirements separately.

## M4 — Regression & Release Qualification

- Complete applicable Terraform Plan, Static Analysis, documentation validation, and focused regression tests. Preserve the existing **16 workload-baseline validators**; extend relevant checks instead of adding a new top-level validator without justification.
- Confirm no unintended infrastructure changes, recurring charges, public exposure, IAM broadening, or default behavior regressions. Review production retirement and disabled-resource paths.
- Obtain independent read-only review of security-sensitive changes and record any exceptions or accepted limitations.
- Update `CHANGELOG.md`, relevant usage/validation documentation, and release notes only after implementation and evidence are verified. Preserve sensitive evidence privately; public documents should contain sanitized outcomes and durable identifiers.
- Publish `v1.14.0` only after final maintainer approval. Do not describe planned or historical tests as freshly completed.

## Boundaries and decisions

- **Application-agnostic:** No private application integration, tenant business logic, database schema migrations, or application-specific authorization in the public baseline.
- **Deferred:** Generic ECS sidecars, scheduled/on-demand ECS jobs, cross-Region disaster recovery, broad refactoring of the Apply administrator role, and universal WAF/SIEM designs. Reconsider only if a concrete production-readiness defect requires it.
- **Cost-conscious:** Prefer existing modules, workflows, and validators. Do not deploy a synthetic production profile or alter live IAM until its plan, impact, cost, and rollback path are approved.
- **Evidence discipline:** Distinguish configured controls, offline tests, deployed behavior, operator reports, and explicit acceptance. A passing Terraform Apply or 16/16 baseline validation is not, alone, a production go-live authorization.

**Tracking convention:** `Planned` → `In progress` → `Validated` → `Complete`. Add PRs, test runs, observed outcomes, and review decisions as each milestone closes; do not pre-populate successes.

**Historical roadmap:** The completed v1.13.0 plan remains preserved in the [v1.13.0-tagged `ROADMAP.md`](https://github.com/jcub-i0/terraform-secure-baseline/blob/v1.13.0/ROADMAP.md), with release outcomes recorded in the [v1.13.0 release notes](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.13.0).