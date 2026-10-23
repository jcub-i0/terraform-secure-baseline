# v1.13.0 Roadmap — Recovery Assurance & Edge Protection

**Status:** In progress · **Baseline:** [v1.12.0](https://github.com/jcub-i0/terraform-secure-baseline/releases/tag/v1.12.0)

**Objective:** Prove that protected RDS data can be recovered, make public application traffic observable, and introduce controlled HTTP threat protection for SaaS workloads handling sensitive data. Build on existing Terraform modules and validation workflows without introducing application-specific assumptions or unnecessary default costs.

**Tracking:** Update each row from `Planned` → `In progress` → `Validated` → `Complete`. Record PRs, CI runs, and privately retained evidence at each milestone's closeout. *Expected results below are acceptance targets, not completed claims.*

## M1 — Verified RDS Recovery

The baseline already provisions AWS Backup RDS Restore Testing when enabled. v1.13.0 must qualify recoverability—not implement a parallel backup system.

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Private restore | Extend existing Restore Testing with isolated networking, least-privilege validation access, and synthetic PostgreSQL data. Prefer a dedicated restore-test security group. | A recovery point restores to a private, temporary RDS instance without modifying the source database. | In progress |
| Data integrity | Provide an application-agnostic validation hook, with a reference synthetic-data query/checksum test; report its result to AWS Backup. | Actual SQL connectivity and known record/integrity assertions succeed; a corrupted or inaccessible restore fails qualification. | Planned |
| Outcome and cleanup | Distinguish configuration checks, pending jobs, completed validation, failed jobs, and cleanup failures. Capture duration and resource identifiers. | The completed restore and validation pass, temporary resources are removed, and observed recovery time is recorded (not advertised as a guaranteed RTO/RPO). | Planned |

**M1 closeout:** PR/commit — TBD · CI — TBD · Controlled restore/cleanup evidence (private) — TBD

## M2 — Protected ALB Access Logging

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Delivery architecture | Choose a supported path: dedicated S3 for legacy ALB logs or CloudWatch Logs delivery, based on encryption compatibility, least privilege, querying, and cost. Do not assume the existing SSE-KMS-enforced logs bucket supports legacy ALB delivery. | An approved destination and documented encryption/permissions design are selected. | Planned |
| Terraform integration | Add configurable, opt-in logging only when a real ingress ALB exists; manage destination protection, retention, and ownership. | Existing environments remain unchanged when disabled; enabled logging has no unnecessary public exposure or persistent resources without an ALB. | Planned |
| Validation | Check exact ALB delivery configuration, storage protections, and a controlled HTTPS request's resulting log record. | An actual request is recorded and retrievable; log sensitivity, best-effort delivery limits, and costs are documented. | Planned |

**M2 closeout:** Destination decision — TBD · PR/commit — TBD · CI — TBD · Delivery evidence (private) — TBD

## M3 — Optional AWS WAF Protection

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Web ACL | Attach an opt-in regional Web ACL to the existing shared ALB; begin with a small, approved AWS Managed Rules set and optional rate limiting. | Exact Terraform-owned ALB association and rule inventory; no WAF resources or charges when disabled. | Planned |
| Safe rollout | Start with rule-level **Count** overrides and CloudWatch metrics; enable **Block** only through explicit reviewed configuration. | Operators can observe matches and assess false positives before traffic is blocked. | Planned |
| Verification | Validate rule priorities, actions, logging/metric settings, and allowed versus controlled test requests. | Legitimate traffic remains available; expected rule matches are counted and, when expressly enabled, blocked. | Planned |

**M3 closeout:** Rule/enforcement decision — TBD · PR/commit — TBD · CI — TBD · Count/Block evidence (private) — TBD

## M4 — Integration Regression & Release Qualification

| Work item | Intended design | Expected result / acceptance | Status |
|---|---|---|---|
| Regression coverage | Add focused positive/negative offline checks for restore validation, ALB logging, and WAF; retain v1.12.0 checks and default behavior. | Static Analysis passes; disabled options introduce no unexpected permissions, resources, costs, or replacements in reviewed configurations. | Planned |
| Targeted live qualification | Reuse M1's controlled synthetic restore, verify one real ALB log delivery, and test WAF Count behavior plus approved Block behavior. | New behaviors have traceable test outcomes, configuration identity, and privately retained evidence—without repeating unrelated deployments. | Planned |
| Release closeout | Update usage/migration/security documentation; review cost, teardown, compatibility, limitations, and final CI on the release commit. | Maintainer approves verified scope; release tag and GitHub Release accurately describe what was completed and what remains untested. | Planned |

**M4 closeout:** Regression CI — TBD · Review/sign-off — TBD · Release commit/tag — TBD

## Global guardrails and non-goals

- **Application agnostic:** The baseline provides infrastructure contracts; each adopter owns tenant isolation, policy content, business-level validation, and application recovery requirements.
- **Opt-in and cost aware:** Preserve v1.12.0 defaults. Conditional ALB/WAF resources must not materialize for `image_digest = null` registrations. Review all new recurring costs and destructive operations.
- **Evidence over assumptions:** Distinguish Terraform configuration, mocked checks, live behavior, operator reports, and formal acceptance. Retain operational evidence privately, not in the public repository.
- **Out of scope:** Cross-Region DR, general-purpose WAF policy authoring, broad Checkov remediation, new ECS orchestration patterns, and application-specific database schemas or authorization.

**Release exit gate:** M1–M4 are marked `Complete` only after their stated acceptance results are verified, documented, and explicitly approved. Defer or narrow any unmet criterion visibly; do not mark an unperformed test as passed.
