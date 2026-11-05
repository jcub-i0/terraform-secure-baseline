# v1.14.0 Roadmap — Production Deployment Assurance & Security Hardening

**Status:** `In progress`
**Baseline:** [v1.13.0 — Recovery Assurance & Edge Protection](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.13.0) (`0ebfea2d675e1d443b2f610ff329fea2cd70363d`)
**Objective:** Strengthen the security and operational reliability of the existing AWS baseline, then demonstrate that a supported, single-container ECS/Fargate SaaS application can be deployed, monitored, and recovered under a production configuration.

This release prioritizes **correctness and evidence over new features**. It does not claim that every application or organization is production-ready simply because the baseline passes its infrastructure checks.

## Milestones

| Milestone | Scope | Acceptance target | Status |
|---|---|---|---|
| **M1 — CI/CD State Protection** | Separate GitHub Plan state-read permission from S3 lockfile mutation permissions; retain required Apply capabilities. | Plan cannot modify Terraform state; legitimate plans and locking still work; affected account roots and workflows remain compatible. | `Complete` |
| **M2 — Deployment & Backup Assurance** | Correct backup-job API error handling and establish explicit application-release acceptance after Terraform Apply. | API failures fail validation; failed ECS releases cannot be reported as accepted merely because Terraform Apply succeeded. | `Validated` — Terraform teardown verified; residual audit pending |
| **M3 — Production Operational Qualification** | Qualify a synthetic production-profile workload; close material monitoring and recovery gaps discovered by testing. | Measured deployment, availability, database recovery, notification and evidence-retention outcomes meet explicitly agreed test criteria, or are documented as gaps. | `In progress` — M3-A complete; M3-B not started |
| **M4 — Regression & Release Qualification** | Review changes, run relevant CI and live validation, document results, and publish the release. | All approved milestones are qualified, residual risks are documented, and the maintainer explicitly authorizes publication. | Planned |

## M1 — CI/CD State Protection

**Status:** Complete

**Implementation:** [PR #924](https://github.com/jcub-i0/terraform-secure-baseline/pull/924) separated the GitHub Plan role's bucket-wide state read (`s3:GetObject`) from `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on `*.tflock` keys. Bucket listing, required state-KMS permissions, Apply-role permissions, and OIDC trust were unchanged. The existing Static Analysis workflow runs `scripts/tests/test-github-plan-state-permissions.py`, a lightweight source-level policy guard rather than a rendered/effective-IAM test.

**Qualification evidence:**

- The source regression test and independent PR review passed; the operator reported applying the updated account-root IAM stacks in all five AWS accounts.
- Read-only IAM simulations across the five accounts, including actual control-plane and security-operations backend keys, showed state reads allowed, state writes/deletions denied, and native lockfile Get/Put/Delete allowed. `s3:DeleteObjectVersion` was denied in both cases.
- The [post-rollout Terraform Plan matrix](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41381370052/attempts/2) passed all six jobs.
- A dev Plan-role attachment/inline-policy review and state-bucket policy inspection found the expected custom policy and AWS-managed `ReadOnlyAccess`, with no unexpected object-write grant.
- The [one-time dev GitHub OIDC test](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41564136709) denied synthetic state Put/Delete, permitted lockfile Get/Put/Delete, and passed Terraform Plan. The operator reported cleanup of the versioned synthetic test artifacts. No real state object was modified.

**Qualification deviations and residual scope:** The disposable authorization test followed, rather than preceded, the IAM rollout. A separate disposable Apply-role test was not performed; Apply permissions were unchanged. Permanent CI validates HCL policy source, with deployed IAM simulation across accounts and actual S3 authorization tested in dev. Plan retains bucket-wide state-read and `*.tflock` mutation access. GitHub Environment/branch-access clarity is tracked separately in [issue #925](https://github.com/jcub-i0/terraform-secure-baseline/issues/925).

## M2 — Deployment & Backup Assurance

**Status:** `Validated` — the M2 exit gate was exercised in disposable `staging` with `deployment_profile=development`, and the protected Terraform Destroy workflow subsequently succeeded. The Terraform-managed staging workload was destroyed (296 resources). Independent AWS residual-resource and durable-data disposition checks remain pending; do not mark M2 `Complete` until those results are recorded.

**Purpose:** Distinguish a successful infrastructure Apply from an accepted application release, and prevent AWS Backup API errors from appearing as an empty backup-job history.

**Implementation and source-level qualification:**

- **M2A — Backup fail-closed:** [PR #927](https://github.com/jcub-i0/terraform-secure-baseline/pull/927) updated `scripts/validation/validate-backup.sh` so a failed `aws backup list-backup-jobs` request or invalid response fails validation instead of silently substituting `{"BackupJobs":[]}`. A valid but empty history retains the documented warning. Five offline regression cases were added to the existing Static Analysis workflow. No live AWS Backup API fault injection is claimed.
- **M2B — ECS post-Apply acceptance:** [PR #928](https://github.com/jcub-i0/terraform-secure-baseline/pull/928) added `scripts/deployment/validate-ecs-release.sh` to the existing protected `Terraform Apply` workflow, **after** applying the verified saved plan. It checks the intended task-definition revision, completed primary deployment, Terraform-owned fixed capacity or autoscaling bounds, running application tasks, configured container health, and applicable ALB target health. It polls with a bounded deadline, rejects a failed rollout, and reports nonacceptance on persistent rollback or nonconvergence. It preserves empty/null-image and approved retirement paths; legitimate zero-capacity services receive an explicit runtime-health skip, not a healthy-task attestation.
- **Independent review and offline regression:** After remediation of capacity-ownership and ECS eventual-consistency findings, Codex issued a read-only `READY TO MERGE` verdict at `b25e4f7b5e9d0d220bce64b0df4d57365ed97ec0`: 0 blocking and 0 nonblocking findings, 17 repository regression scenarios and 23 independent mock cases passed. This review did not execute AWS operations.

**Live AWS qualification — synthetic `staging` workload (November 3, 2026, US Eastern; November 4 UTC):**

| Exercise | Evidence | Observed outcome |
|---|---|---|
| Bootstrap with no deployable ECS application | [Initial staging Apply #41759248089](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41759248089) | Apply succeeded with `image_digest = null`; post-Apply gate explicitly skipped disabled ECS runtime. |
| Publish healthy image and deploy | [Image publication #41761558253](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41761558253), [release PR #929](https://github.com/jcub-i0/terraform-secure-baseline/pull/929), [Apply #41762965690](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41762965690) | Apply succeeded; post-Apply gate accepted intended task revision `:5`, including its running tasks and ALB health. |
| Publish intentionally unhealthy image and deploy | [Fixture PR #930](https://github.com/jcub-i0/terraform-secure-baseline/pull/930), [release PR #931](https://github.com/jcub-i0/terraform-secure-baseline/pull/931), [Apply #41766021594](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41766021594) | Terraform reported `Apply complete` (1 add, 1 change, 1 destroy), but post-Apply acceptance **failed** after its 10-minute deadline while waiting for intended revision `:6`. The protected Apply job therefore reported failure, as required. |
| Independent ECS rollback observation after negative test | Operator-provided `ecs describe-services` event capture (raw JSON not committed; SHA-256 `b863f3a46566e326dd87599cb8d6eb6e92915bf94b59c89f16343af682767030`) | ECS events show ALB health checks receiving HTTP `404`, the unhealthy deployment failing, and ECS explicitly rolling back to previous revision `:5`. Its subsequent completed primary deployment reached steady state with desired/running/pending counts `2/2/0`. The rollback events were observed **after** the acceptance gate's timeout; do not misreport this as immediate fail-fast detection by the validator. |
| Restore the healthy digest and reapply | [Recovery PR #934](https://github.com/jcub-i0/terraform-secure-baseline/pull/934), [Apply #41768896931](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41768896931) | Apply succeeded (1 add, 1 change, 1 destroy); the gate accepted newly registered intended revision `:7` using the previously validated healthy image digest. |
| Destroy the synthetic staging workload | [Terraform Destroy #41769873364](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41769873364) | Preflight, saved destroy-plan, and exact-plan Apply jobs succeeded. Terraform reported `Apply complete! Resources: 0 added, 0 changed, 296 destroyed.` This verifies Terraform-managed workload teardown, not independent removal of all durable or unmanaged AWS assets. |

**M2 exit gate:** Source-level backup API failures fail closed, a successful Terraform Apply with an unhealthy ECS release is not reported as an accepted application release, and healthy intended revisions pass live ECS/task/ALB acceptance. Both the rejection and ECS automatic rollback are corroborated; the latter is evidenced by the separately captured ECS events, not just GitHub Actions status.

**Outstanding disposition / limits:**

- **Terraform teardown confirmed:** [Staging Terraform Destroy #41769873364](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41769873364) completed successfully, reporting 296 destroyed resources and no additions or changes. This is the confirmed outcome of the saved Terraform destroy plan, not proof that every retained or unmanaged AWS asset was removed.
- **Post-destroy Plan qualification:** The [Terraform Plan matrix #41770746676 (attempt 2)](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41770746676/attempts/2) succeeded in all six jobs, including staging. On attempt 1, staging Plan failed to acquire the native S3 state lock while Destroy was still running; the successful retry confirms that the transient lock conflict cleared. A successful Plan does **not** assert that the next staging deployment would be a no-op.
- **Residual-resource audit still required for M2 `Complete`:** Record an AWS-side inventory and disposition for any ECR artifacts, AWS Backup recovery points, RDS manual/final snapshots, independently retained S3 logs/evidence and KMS keys, plus associated residual charges. None of these independent checks is claimed by the successful Terraform Destroy workflow. Keep M2 `Validated` until the inventory and disposition are documented.
- Keep the raw ECS event capture in an operator-controlled private evidence store; the public roadmap contains only sanitized findings and its integrity hash. Do not commit account-specific infrastructure identifiers or sensitive service details.
- This exercised the `development` deployment profile and generic synthetic HTTP health behavior. It does **not** qualify the `production` profile, SQL transactions, business readiness, all app-level endpoints, M3 recovery tests, or a production go-live.

## M3 — Production Operational Qualification

**Status:** `In progress` — **M3-A lightweight readiness complete (November 4, 2026); M3-B deployment not started.** The sole maintainer reports that GitHub Environment `staging-plan` has `DEPLOYMENT_PROFILE=production` and that no workload infrastructure is currently deployed. This is an operator-reported configuration check, not an independent GitHub Environment audit or live AWS observation. The [M3 execution plan](docs/qualification/v1.14.0-m3-execution-plan.md) tracks the staged qualification; all live M3 tests remain `Not Run`.

**Purpose:** Verify that the current platform can support a representative PostgreSQL-backed HTTPS application with realistic failures, and implement only narrowly justified hardening.

**M3-A closeout:** As a solo-maintained disposable test, no organization-style change tickets, extra approvers, or formal spending authorizations are required. The production profile is confirmed in `staging-plan` by the maintainer; the synthetic test scope and the protected production-profile retirement procedure are documented. In M3-B, verify the effective saved Plan and necessary TLS/ingress/credentials/notification inputs before Apply, and decide acceptable test cost and cleanup. Production-profile retirement protections are not optional.

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
