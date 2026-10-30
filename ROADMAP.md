# v1.13.0 Roadmap — Recovery Assurance & Edge Protection

**Status:** In progress · **Baseline:** [v1.12.0](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.12.0)

**Objective:** Prove that protected RDS data can be recovered, make public application traffic observable, and introduce controlled HTTP threat protection for SaaS workloads handling sensitive data. Build on existing Terraform modules and validation workflows without introducing application-specific assumptions or unnecessary default costs.

**Tracking:** Update each row from `Planned` → `In progress` → `Validated` → `Complete`. Record PRs, CI runs, and privately retained evidence at each milestone's closeout. *Expected results below are acceptance targets, not completed claims.*

## M1 — Verified RDS Recovery

**Status: Complete (2026-10-25).** AWS Backup Restore Testing and opt-in SQL Restore Validation were qualified in the disposable `dev` workload account (`us-east-1`). This milestone proves the configured synthetic-data recovery contract, not end-to-end application recovery.

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Private restore | Extend existing Restore Testing with isolated networking, least-privilege validation access, and synthetic PostgreSQL data. Prefer a dedicated restore-test security group. | A recovery point restores to a private, temporary RDS instance without modifying the source database. | Complete |
| Data integrity | Provide an application-agnostic validation hook, with a reference synthetic-data query/checksum test; report its result to AWS Backup. | Actual SQL connectivity and known record/integrity assertions succeed; a corrupted or inaccessible restore fails qualification. | Complete |
| Outcome and cleanup | Distinguish configuration checks, pending jobs, completed validation, failed jobs, and cleanup failures. Capture duration and resource identifiers. | The completed restore and validation pass, temporary resources are removed, and observed recovery time is recorded (not advertised as a guaranteed RTO/RPO). | Complete |

**Live acceptance evidence (2026-10-24–25, `dev`):**

- **Positive restore:** Restore job `9de920f6-fdab-4066-9723-b15bdd0111f1` completed against a private, isolated temporary RDS instance. The restricted, read-only SQL worker verified all three synthetic canary records; AWS Backup recorded `ValidationStatus=SUCCESSFUL` and `DeletionStatus=SUCCESSFUL`. The opt-in strict qualifier accepted this latest job.
- **Controlled negative restore:** On-demand Backup job `53824ac5-b041-48e1-b3ce-2b828dd60917` captured an intentionally altered `alpha` canary; the live source canary was repaired before testing the snapshot. Restore job `a959c843-80ed-45bd-945c-e39c1510dfed` completed, but the SQL worker detected `WORKER_SYNTHETIC_CANARY_MISMATCH`. AWS Backup recorded `ValidationStatus=FAILED` with `DeletionStatus=SUCCESSFUL`; strict qualification correctly exited nonzero instead of accepting corrupted data.
- **Events and monitoring:** The negative restore produced one matching EventBridge event and coordinator invocation, with no observed EventBridge delivery failures. The failed-validation CloudWatch alarm successfully invoked the existing SecOps SNS topic at `2026-10-25 00:28:20 EDT`. An earlier controlled alarm test confirmed subscriber email receipt; recipient delivery of the *actual* failed-validation notification was not separately confirmed.
- **Observed recovery timing:** Positive restoration finished at `2026-10-24 21:47:01 EDT`; the operator observed restore activity beginning around `21:38 EDT` (approximately nine minutes to resource completion). The precise API-derived start timestamp was not retained, so this is an estimate, **not an RTO measurement or guarantee**. Negative restoration completed at `2026-10-25 00:17:30 EDT`; no negative-run elapsed duration is asserted.
- **Lifecycle:** The source database and disposable `dev` workload were intentionally destroyed after both tests via the protected [Terraform Destroy run #40163291473](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40163291473) (`success`). Teardown does not preserve workload-local logs, secrets, or recovery points.

**M1 closeout references:** Implementation and CI integration [#880](https://github.com/jcub-i0/terraform-secure-baseline/pull/880), [#882](https://github.com/jcub-i0/terraform-secure-baseline/pull/882), [#884](https://github.com/jcub-i0/terraform-secure-baseline/pull/884); [#886](https://github.com/jcub-i0/terraform-secure-baseline/pull/886) added SecOps alarms; [#887](https://github.com/jcub-i0/terraform-secure-baseline/pull/887) added strict recovery acceptance. Final merged implementation CI passed [Static Analysis #40156297158](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40156297158), [Terraform Plan #40156297157](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40156297157), and [Docs Validation #40156297149](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40156297149). The [positive-path baseline evidence export #40153194720](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40153194720) passed **16/16 validators**; its GitHub artifact `baseline-validation-dev-40153194720-1` is scheduled to expire **2026-11-24** and should be retained privately before expiry. Negative-path job, alarm, and strict-validator outputs were inspected through the AWS CLI; durable off-platform retention of that evidence was not independently verified.

**Scope and limits:** This is an opt-in technical assurance check of private RDS restoration, a specific synthetic canary, failure reporting, and AWS-managed cleanup. It does not establish full application recovery, arbitrary business-data integrity, guaranteed RTO/RPO, or certification against SOC 2 / ISO 27001. Missing scheduled tests and AWS-managed cleanup failures are not all covered by standalone alarms; operators must review actual recovery outcomes.

## M2 — Protected ALB Access Logging

**Status: Complete (2026-10-28).** Enabled ALB logging was qualified in the `staging` workload account (`us-east-1`) under `deployment_profile=production`. The dedicated, Terraform-managed SSE-S3 bucket received actual HTTPS request records. This is live delivery evidence for the tested requests, not a completeness guarantee.

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Delivery architecture | Choose a supported path: dedicated S3 for legacy ALB logs or CloudWatch Logs delivery, based on encryption compatibility, least privilege, querying, and cost. Do not assume the existing SSE-KMS-enforced logs bucket supports legacy ALB delivery. | An approved destination and documented encryption/permissions design are selected. | Complete |
| Terraform integration | Add configurable, opt-in logging only when a real ingress ALB exists; manage destination protection, retention, and ownership. | Existing environments remain unchanged when disabled; enabled logging has no unnecessary public exposure or persistent resources without an ALB. | Complete |
| Validation | Check exact ALB delivery configuration, storage protections, and a controlled HTTPS request's resulting log record. | An actual request is recorded and retrievable; log sensitivity, best-effort delivery limits, and costs are documented. | Complete |

**Live acceptance evidence (2026-10-28 EDT, `staging`):**

- **Configuration and protection:** The deployed ALB used `alb` as its S3 prefix. Runtime validation verified the dedicated bucket's SSE-S3 (`AES256`), BucketOwnerEnforced ownership, versioning, public access blocks, IAM bucket-policy protections, and configured 90-day current-object/one-day noncurrent-version lifecycle expiration. AWS-enforced configuration changes allow designated bucket administrators, including the GitHub Apply role.
- **Observed HTTPS delivery:** A controlled HTTPS request with a unique correlation token produced two matching HTTP/2, TLS 1.3 ALB log entries at `2026-10-29T01:07:19Z` and `01:07:44Z`. Both reached private ECS targets and returned HTTP `404`, acceptable for the test route. The operator retrieved a genuine `.log.gz` object under `alb/AWSLogs/027326805885/elasticloadbalancing/us-east-1/` and matched the request token inside its decompressed contents. The object was last modified `2026-10-29T01:10:09Z`, measured 558 bytes, and reported `AES256` encryption. Full request records, client addresses, and the unique token are deliberately excluded from this public roadmap.
- **Baseline regression:** [Export Baseline Evidence run #40796511254](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40796511254) on `main` passed **16/16** staging validators, including SNS, SQS, ECS runtime, and logging checks.

**M2 implementation references:** [#890](https://github.com/jcub-i0/terraform-secure-baseline/pull/890) introduced protected ALB access logging; [#895](https://github.com/jcub-i0/terraform-secure-baseline/pull/895), [#896](https://github.com/jcub-i0/terraform-secure-baseline/pull/896), [#897](https://github.com/jcub-i0/terraform-secure-baseline/pull/897), and [#898](https://github.com/jcub-i0/terraform-secure-baseline/pull/898) corrected the S3 integration and policy validation; [#900](https://github.com/jcub-i0/terraform-secure-baseline/pull/900) and [#901](https://github.com/jcub-i0/terraform-secure-baseline/pull/901) corrected SNS/SQS evidence validation. The live delivery test was conducted separately from the 16/16 automated baseline export.

**Staging teardown (2026-10-28 EDT):** Following M2 acceptance, the approved [Terraform Destroy run #40805111463](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/40805111463) passed retirement preflight, authorized durable-data cleanup, readiness checks, and exact saved-plan verification. The final Apply reported **0 added, 0 changed, 342 destroyed**, including the ALB and centralized S3 log buckets, VPC, and RDS instance. The cleanup deleted one ECR image digest; the AWS Backup vault had no recovery points. The operator subsequently verified the `environments/staging` Terraform state was empty and reported successful deletion of the retained manual RDS final snapshot (`tf-secure-baseline-staging-saas-db-final-4efac425`). Snapshot deletion was operator-reported, not independently rechecked. Workload bootstrap, remote state infrastructure, and the AWS account were outside this destroy scope.

**Scope and limits:** ALB logs are best-effort and may contain sensitive request details (client addresses, paths, and user agents); restrict access and avoid committing raw records to this public repository. S3 storage, request, and retrieval costs apply. The configured 90-day lifecycle is **not** Object Lock or immutable retention. The workload-local log buckets and their contents were deleted during teardown; durable off-platform preservation of the live log object/CLI proof has not been independently verified. Retain the separate GitHub validation evidence privately before artifact expiration.

## M3 — Optional AWS WAF Protection

**Status: Validated (2026-10-30); staging teardown pending.** The optional regional AWS WAF integration was merged in [PR #906](https://github.com/jcub-i0/terraform-secure-baseline/pull/906) and qualified against the shared HTTPS ALB in the disposable `staging` workload account (`us-east-1`, `deployment_profile=development`). Mark M3 `Complete` only after protected teardown and empty workload-state verification.

| Work item | Intended design | Observed acceptance | Status |
|---|---|---|---|
| Web ACL and association | Create an opt-in regional Web ACL on the existing shared ALB with the Common Rule Set and Known Bad Inputs Rule Set; omit the optional rate rule unless configured. | AWS readback confirmed one Web ACL, its ALB association, default `Allow`, group priorities 10/20, and CloudWatch metrics. Enabling WAF added exactly two resources without replacing the ALB. | Validated |
| Count observation | Start with group-level Count overrides; opt into sampled requests only for controlled synthetic testing. | Benign and synthetic missing-User-Agent requests both returned HTTP `200`; AWS sampled the latter as `COUNT` by `NoUserAgent_HEADER`. | Validated |
| Reviewed enforcement | Apply the managed groups' actions only after review; allow ordinary requests and block known rule matches. | Both group overrides changed to `None`; benign traffic returned HTTP `200`, the matching synthetic request returned HTTP `403`, and AWS sampled it as `BLOCK`. | Validated |
| Teardown | Retire the disposable workload via the protected Destroy workflow, then inspect remaining state and durable-data disposition. | Destroy outcome, state verification, and final private evidence retention remain to be confirmed. | Pending |

**Live acceptance evidence (2026-10-30 EDT):**

- **Preparation and deployment:** The controlled test image was published in [Deploy Application #41135487951](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41135487951) and selected through [PR #909](https://github.com/jcub-i0/terraform-secure-baseline/pull/909). The `test` ECS service reached **2/2 running tasks** and **2/2 healthy ALB targets**. [Staging Apply #41136434991](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41136434991) created the WAF Web ACL and association (**2 added, 0 changed, 0 destroyed**); independent AWS readback confirmed both managed groups in Count mode and request sampling enabled.
- **Count evidence:** A benign `/health` request and a synthetic request without a User-Agent both returned HTTP `200`. WAF sampled `AWS#AWSManagedRulesCommonRuleSet#NoUserAgent_HEADER` as `COUNT` at **18:21:17 EDT**.
- **Enforcement evidence:** [Staging Apply #41137783510](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41137783510) changed the Web ACL in place (**0 added, 1 changed, 0 destroyed**). AWS showed `OverrideAction=None` for both managed groups. The benign request remained HTTP `200`, whereas the same type of synthetic request returned HTTP `403`; WAF sampled `NoUserAgent_HEADER` as `BLOCK` at **18:25:44 EDT**.
- **Post-test posture:** [Staging Apply #41138454229](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41138454229) restored Count mode (**0 added, 1 changed, 0 destroyed**). A subsequent [saved-plan run #41138718148](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/41138718148) reported **no changes**; its protected Apply step was awaiting approval at review time. Request sampling was still enabled in that plan and must not remain enabled if the test environment is retained.

**Scope and limitations:** These tests prove the exercised Common Rule Set rule's Count and Block behavior, not exhaustive managed-rule coverage. `AWSManagedRulesKnownBadInputsRuleSet` was configured and observed in the ACL, but no separate matching request was tested. The optional rate rule remained disabled and was not tested. Group-level Count overrides do not force every nested managed rule to be non-terminating. WAF sampled requests can contain sensitive data; only controlled synthetic traffic was used, raw samples are omitted here, and durable off-platform retention of CLI evidence has not been independently verified. The ALB-DNS `curl -k` checks do not establish TLS hostname verification.

**M3 closeout:** Implementation and live Count/enforcement validated; **protected staging Destroy, workload-state confirmation, and evidence disposition pending**.

## M4 — Integration Regression & Release Qualification

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Regression coverage | Add focused positive/negative offline checks for restore validation, ALB logging, and WAF; retain v1.12.0 checks and default behavior. | Static Analysis passes; disabled options introduce no unexpected permissions, resources, costs, or replacements in reviewed configurations. | Planned |
| Targeted live qualification | Reuse M1's controlled synthetic restore, verify one real ALB log delivery, and test WAF Count behavior plus approved Block behavior. | New behaviors have traceable test outcomes, configuration identity, and privately retained evidence—without repeating unrelated deployments. | Planned |
| Release closeout | Update usage/migration/security documentation; review cost, teardown, compatibility, limitations, and final CI for the release candidate. | Maintainer approves verified scope; release tag and GitHub Release accurately describe what was completed and what remains untested. | Planned |

**M4 closeout:** Regression CI — TBD · Review/sign-off — TBD · Release tag — TBD

## Global guardrails and non-goals

- **Application agnostic:** The baseline provides infrastructure contracts; each adopter owns tenant isolation, policy content, business-level validation, and application recovery requirements.
- **Opt-in and cost aware:** Preserve v1.12.0 defaults. Conditional ALB/WAF resources must not materialize for `image_digest = null` registrations. Review all new recurring costs and destructive operations.
- **Evidence over assumptions:** Distinguish Terraform configuration, mocked checks, live behavior, operator reports, and formal acceptance. Retain operational evidence privately, not in the public repository.
- **Out of scope:** Cross-Region DR, general-purpose WAF policy authoring, broad Checkov remediation, new ECS orchestration patterns, and application-specific database schemas or authorization.

**Release exit gate:** M1–M4 are marked `Complete` only after their stated acceptance results are verified, documented, and explicitly approved. Defer or narrow any unmet criterion visibly; do not mark an unperformed test as passed.
