# v1.15.0 M1 — Implementation and Acceptance Status

**Status: In progress — implementation complete, acceptance pending.** N1/N2, N3, N4, N5A, N5B, N5C-A, and N5C-A1 are implemented. The complete PR received independent review at `afdbda0edf314c135d0c24a82750756ed560a0a7` with disposition **ACCEPT WITH DEFERRED ITEMS** and no code blockers. N5D corrections were committed at `26d180d6`. The subsequent validation/testing simplification in section G is locally validated in an isolated worktree and pending owner review; live AWS qualification, owner acceptance, and merge remain outstanding. M1 is not fully accepted.

**Implementation:** [PR #967](https://github.com/jcub-i0/terraform-secure-baseline/pull/967), branch `feat/v1.15.0-m1-sidecars`, N5C-B implementation evidence at `89436e6b4f455fad5dd71a5190e52f41dd77837b`; full review and N5D starting HEAD `afdbda0edf314c135d0c24a82750756ed560a0a7`. The PR remains open and draft. Sections B and F retain historical evidence for committed implementation. Section G records the separate uncommitted simplification; it does not incorporate the owner checkout's R02 length-check follow-up.

## A. Scope delivered

- One essential primary application container plus up to nine optional Terraform-configured sidecars, with digest-pinned images, optional native health checks, validated startup dependencies, environment variables, Secrets Manager/SSM references, and per-container CloudWatch logging.
- Sidecar resource settings, command/entry-point overrides, ports, and root-filesystem mode; shared task-local volumes and container mount points; optional task ephemeral storage and container startup/shutdown timeouts. Primary and sidecar interfaces are intentionally different; consult the [module usage and limits](../modules/ecs_service/README.md#container-and-validation-limits).
- Per-service execution IAM derived from all configured containers, deduplicated repository/secret/parameter resources, Secrets Manager selector normalization, explicit KMS key grants, and exact direct-IAM resource validation for Secrets Manager, SSM, KMS keys, and (in N5D) application/GuardDuty ECR repositories. ECR authorization intentionally retains `Resource = "*"`; CloudWatch log-stream grants retain their scoped suffix wildcard. Application task-role permissions remain separate from execution permissions.
- Canonical environment-root propagation, complete expected task-definition inventory and runtime comparison, Terraform native positive/negative regressions, offline validator regressions, and CI enforcement. Empty sidecar configuration retains the existing single-container service and resource-address model.

The [runtime design](../docs/ecs-runtime-design.md) and [Terraform variable contract](../modules/ecs_service/variables.tf) define the interfaces and validation boundaries; this record does not expand them.

## B. Verification evidence

### Implementation history

Representative commits in PR #967 (not an exhaustive changelog):

| Checkpoint | Repository evidence |
|---|---|
| N1/N2 — multi-container runtime | [Initial sidecar rendering and validation `63377fff`](https://github.com/jcub-i0/terraform-secure-baseline/commit/63377fff5a56e0de32d56e6646e343c00ff0d239), followed by health, dependency, volume, resource, and override changes in the PR |
| N3 — execution IAM | [Sidecar ECR, secret, and IAM integration `0e1e7b45`](https://github.com/jcub-i0/terraform-secure-baseline/commit/0e1e7b45bbf0892222279daf935d0ca231a5c1df), with subsequent selector normalization and regression coverage |
| N4 — regression enforcement | [Native suite workflow `8e7823b5`](https://github.com/jcub-i0/terraform-secure-baseline/commit/8e7823b5c4e7320ad100b5fbe70b781126eb96d5) |
| N5A — environment propagation | [Environment inputs `5540defb`](https://github.com/jcub-i0/terraform-secure-baseline/commit/5540defb2cce3da1c4f53f98a93afd0a8175acd5) and [CI coverage `e4c5ec41`](https://github.com/jcub-i0/terraform-secure-baseline/commit/e4c5ec4144d0c7e1d5c1626d6f2d453dd0012a9f) |
| N5B — runtime compatibility | [Complete container inventory validation `1933ab93`](https://github.com/jcub-i0/terraform-secure-baseline/commit/1933ab93efc7a762ed868c77609974170a607c4d) |
| N5C-A — validation hardening | [Container count, image, mount, and IAM scope validation `76ed2105`](https://github.com/jcub-i0/terraform-secure-baseline/commit/76ed2105e02980bbf1dd20c9b78e5b7cd4315b5d) |
| N5C-A1 — direct IAM secret scope | [Exact secret ARN validation `4b30b7cc`](https://github.com/jcub-i0/terraform-secure-baseline/commit/4b30b7cc126277ffa23b8d989dd411f7c2da19be) and [additional tests `89436e6b`](https://github.com/jcub-i0/terraform-secure-baseline/commit/89436e6b4f455fad5dd71a5190e52f41dd77837b) |

### Local reports and repository coverage

Implementation checkpoints were reported locally validated in the owner handoff. The available N5C-A local `validation-summary.json` and logs corroborate passing native suites for ECS, IAM, baseline, and dev/staging/prod propagation, plus offline IAM, runtime inventory, native health, and release-acceptance regressions. The summary records a pre-commit working tree based on `ead8dce6`; all eight recorded changed-file hashes match committed `76ed2105`. It does not independently certify the later N5C-A1 changes. These local reports are separate from GitHub CI and were inspected, not rerun, for this documentation checkpoint.

Local evidence location: `/tmp/m1-n5ca-evidence/validation-summary.json`, SHA-256 `b33d3ed537a33d4ab49fe3525cd86a4d97faccb991b9e8356e509928df829d27`. This temporary report is not a durable repository artifact; retain any required historical evidence with final acceptance.

Repository-verifiable coverage includes:

- [ECS native suites](../modules/ecs_service/tests/): generated multi-container behavior and secret propagation, legacy compatibility, and representative architectural/security rejection cases.
- [IAM execution-policy suite](../modules/iam/tests/ecs_execution_policy.tftest.hcl), [baseline IAM derivation](../baseline/tests/ecs_iam_derivation.tftest.hcl), and [runtime inventory](../baseline/tests/ecs_runtime_inventory.tftest.hcl).
- Environment input propagation in [dev](../environments/dev/tests/ecs_input_propagation.tftest.hcl), [staging](../environments/staging/tests/ecs_input_propagation.tftest.hcl), and [prod](../environments/prod/tests/ecs_input_propagation.tftest.hcl).
- Offline [runtime container checks](../scripts/tests/test-ecs-runtime-containers.sh), [execution-policy checks](../scripts/tests/test-ecs-execution-policy.py), [native health checks](../scripts/tests/test-ecs-native-health.sh), and [release-acceptance checks](../scripts/tests/test-ecs-release-acceptance.sh). These fixtures establish validator behavior, not live deployments.

### Independently retrieved GitHub CI

GitHub reported these completed PR runs for implementation HEAD `89436e6b4f455fad5dd71a5190e52f41dd77837b` during N5C-B evidence inspection:

| Workflow | Result | Evidence |
|---|---|---|
| [Terraform Module Tests](../.github/workflows/terraform-module-tests.yml) | Passed; native suites and IAM validator regression steps succeeded | [Run 43153174785](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43153174785) |
| [Terraform Static Analysis](../.github/workflows/tf-scans.yml) | Passed; includes offline ECS health, container-inventory, release, and IAM checks | [Run 43153174678](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43153174678) |
| [Docs Validation](../.github/workflows/docs-validation.yml) | Passed for the implementation HEAD, before these documentation edits | [Run 43153174764](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43153174764) |
| [Terraform Plan](../.github/workflows/terraform-plan.yml) | Skipped; the workflow excludes draft PRs | [Run 43153174800](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43153174800) |

Passing offline tests and CI do not prove zero live drift, sidecar readiness in AWS, or owner acceptance. No deployment or final acceptance is claimed here.

## C. Accepted design limitations

These are implemented scope boundaries, not a declaration of final M1 acceptance:

- The primary may depend on configured sidecars. A sidecar may depend only on sidecars with a strictly lower `dependency_rank`; it cannot depend on the primary. `HEALTHY` requires a target health check; `COMPLETE`/`SUCCESS` require a nonessential target. General dependency graphs are not exposed.
- All configured containers share task-level execution/task roles and `awsvpc` networking. There is no per-container IAM or network isolation; the execution role aggregates launch requirements while the task role governs runtime AWS access.
- The [runtime validator](../scripts/validation/lib/ecs-runtime/services.sh) compares configured sidecar health-check definitions and dependencies but introduces no independent sidecar lifecycle/health polling. Existing primary native-health polling, ECS rollout checks, ALB checks, and GuardDuty checks remain distinct evidence.
- GuardDuty manages its injected agent separately from Terraform-configured sidecars. The agent is not declared in the configured container inventory or used as a configured dependency target; protected live tasks are checked separately.
- Generic scheduled/background job abstractions and migration-aware release orchestration remain outside M1 (M2/M4). A nonessential initialization sidecar with `COMPLETE`/`SUCCESS` dependencies does not provide those broader capabilities.

## D. Deferred findings

The earlier independent review reported **31 nonblocking Checkov Terraform findings in unchanged infrastructure files**. The available historical local artifact `/tmp/pr967-independent-8mn973kr/checkov.json` corroborates 31 Terraform failures (SHA-256 `67eaec3177cf65a68d9817135023ec645709114103be518db51877214e4853ed`). Its 11 affected file paths are unchanged between PR base `573f5da090bf65b1534b68641ea3ab3904c7a9c3` and implementation HEAD `89436e6b`; this source comparison does **not** establish that the current finding count or disposition is unchanged. The historical artifact is not a durable repository acceptance record.

The static-analysis workflow uses Checkov `--soft-fail` and validates report integrity; a green workflow does not mean zero Checkov findings. Neither N5C-B nor N5D rescans, suppresses, or remediates those historical findings. Acceptance must assess the current evidence and retain any unresolved M1-relevant findings. The later full-review dispositions are recorded in section F.

## E. Outstanding acceptance gates

All gates below remain outstanding:

1. Review the validation/testing simplification and any subsequent changes at the intended acceptance commit; historical reviews do not certify this uncommitted cleanup.
2. Explicitly approved synthetic AWS deployment testing with bounded scope and cost.
3. Positive sidecar-readiness evidence, including observed `HEALTHY` dependency behavior before primary startup.
4. Negative sidecar health/dependency behavior demonstrating the expected failure or blocked startup.
5. Continued single-container compatibility evidence in the live qualification, alongside existing offline regressions.
6. Live runtime-validator, IAM, secret retrieval, and logging verification for the configured containers.
7. Final Terraform Plan and all required CI checks at the acceptance commit.
8. Evidence review and retention, cleanup/rollback documentation, final owner approval, and PR merge.

The original [M1 roadmap acceptance criteria](./ROADMAP_v1_15_0.md#milestones) remain unchanged. Documentation closeout does not authorize deployment, acceptance, or merge.

## F. N5D — Historical targeted review corrections

These corrections followed the independent review at `afdbda0edf314c135d0c24a82750756ed560a0a7` and were committed at `26d180d6ca7c572742fcab7654c79733f899cf4b`. The table and precommit evidence below describe that checkpoint. Section G supersedes the custom AWS capability checks and repetitive testing approach; this history does not prescribe retaining them.

| Finding | Disposition |
|---|---|
| R01 — Fargate sizing | Implemented: the existing matrix now also accepts 32 vCPUs with exactly 61440, 122880, or 249856 MiB. The previous 16-vCPU ceiling is superseded; existing combinations and platform restrictions are preserved. |
| R02 — direct IAM ECR scope | Implemented: both application and GuardDuty pull inputs require exact repository ARNs in `aws`, `aws-us-gov`, or `aws-cn`; cross-account repositories remain valid. ECR authorization is unchanged. |
| R03 — generated policy assertions | Implemented: existing policy tests compare complete statement identities, effects, action sets, and resource sets, including optional GuardDuty grants. |
| R04 — integration fixtures | Implemented: existing root fixtures preserve nonempty nested dependencies, nondefault ranks and health timings; the existing rendering fixture checks positive `COMPLETE`/`SUCCESS` prerequisites alongside `START`/`HEALTHY`. |
| R05 — optional simplification | Deferred at the N5D checkpoint; the owner subsequently authorized the isolated cleanup recorded in section G. |
| R06 — diff whitespace | Corrected the two added trailing-whitespace lines; runtime behavior is unchanged. |

Historical local validation passed before N5D was committed: **185 native runs** (ECS 103, IAM 32, baseline 41, dev/staging/prod 3 each) and **19 offline IAM unittest methods**. Terraform formatting, Markdown lint, local links/fragments, the new AWS sizing link, shell syntax, and the effective cumulative diff from PR merge base to working tree passed. The fixes are included in `26d180d6`; its cumulative committed PR diff is whitespace-clean.

Isolated before/after checks established defect detection:

- The three supported 32-vCPU sizes failed the old matrix and pass the correction; an unsupported size is rejected, and a temporary 1.3.0 platform probe confirms the existing platform guard.
- All four invalid ECR cases passed the old IAM boundary and fail the new ECR validation specifically. Positive fixtures preserve exact repository scopes across all three supported partitions, including cross-account GuardDuty repositories.
- Adding `ecr:DeleteRepository` to a temporary policy generator passed all 28 old IAM runs but failed three strengthened assertions in the updated suite.
- Temporarily dropping the root's optional sidecar health timeout passed the old propagation fixture and failed the updated fixture. Replacing sidecar completion conditions with `START` passed the old rendering fixture and failed the updated fixture. Removing a required nested dependency attribute is rejected by both versions, preserving existing N5A protection.

Evidence is in the temporary local directory `/tmp/m1-n5d-ofii8387/` (`validation-summary.json`, native JUnit/logs, and before/after probe logs). Mutated copies were restored; production resource definitions were never edited. Retain required evidence with acceptance. The final N5D recheck confirmed module, static-analysis, and documentation CI passed for `26d180d6`; Terraform Plan was skipped for the draft PR. That evidence does not cover the later cleanup; section E remains outstanding.

## G. Validation and testing simplification — pending owner review

This owner-authorized cleanup starts from committed `26d180d6` on temporary branch `cleanup/v1.15.0-m1-validation`, in `/tmp/terraform-secure-baseline-m1-simplify`. The original checkout and its four uncommitted R02/documentation files are preserved. The stricter repository-name length follow-up was not incorporated: AWS name limits are not a least-privilege control. The IAM module still rejects wildcard ECR, secret, parameter, and KMS resources.

The governing standard is [validation ownership](../docs/ecs-runtime-design.md#validation-ownership): Terraform enforces security and composition; providers/AWS own routine parameter validation. The cleanup deletes CPU/memory and platform matrices, routine numeric/name/health checks, repeated baseline IAM checks, and redundant primary/sidecar checks. Secret normalization, production/retirement policies, renderers, interfaces, provider locks, CI, and runtime validators are unchanged.

| Metric | Committed M1 | Cleanup |
|---|---:|---:|
| Native test files | 11 | 9 |
| Native test lines | 4,984 | 2,501 |
| Native runs | 185 | 42 |
| ECS `services` lines / validation blocks | 709 / 27 | 306 / 8 |
| Baseline `ecs_services` lines / validation blocks | 472 / 23 | 228 / 7 |

The suite retains legacy fixed/autoscaled rendering, multi-container health and all dependency conditions, exact secret propagation and normalization, per-service IAM isolation and full policy statement comparisons, runtime-inventory output, and all three typed environment-root fixtures. Equivalent malformed-input permutations and AWS capability/boundary tests were removed. Four focused tests cover existing collision and managed-policy restrictions at the boundaries retained by this refactor; no new validation policy was introduced.

Local validation passed: ECS 19, IAM 8, baseline 6, and dev/staging/prod 3 native runs each; 19 offline IAM tests; 115 runtime-inventory, 18 native-health, 17 release-acceptance, and 13 task-role scenarios. Backend-disabled initialization and Terraform validation passed for all six roots using existing lockfiles. Twelve before/after positive fixtures produced identical planned address inventories, seven task definitions (complete direct-module values and baseline rendering fields), and two execution policies. Input types/defaults and all resource definitions remain unchanged.

Evidence is retained temporarily in `/tmp/m1-simplify-evidence-c7ecrg7h/`. This is local evidence, not a live-drift or AWS-readiness claim. No remote workflow, authenticated AWS plan, deployment, state operation, or commit was performed. The isolated patch awaits owner review and subsequent commit-level CI; final Terraform Plan and live qualification remain outstanding.
