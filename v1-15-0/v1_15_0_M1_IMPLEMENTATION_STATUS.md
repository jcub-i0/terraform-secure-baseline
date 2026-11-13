# v1.15.0 M1 — Implementation and Acceptance Status

**Status: Implementation merged; scoped live qualification complete; final owner acceptance pending.** N1/N2 through N5D and the validation/testing simplification are delivered. Positive multi-container operation and a negative `SUCCESS` prerequisite were qualified in staging; the final baseline export passed **16/16 validators with zero failures**. Staging workload destruction completed successfully; final owner acceptance remains pending. Section E records the final evidence, limits, and remaining closeout decisions; M1 is not yet owner-accepted.

**Implementation:** [PR #967](https://github.com/jcub-i0/terraform-secure-baseline/pull/967) merged at `9c6de5646efc190bfb7124026f1ae63b7f1cfec7`, including cleanup `05a4c69e` and fixture correction `2dc329e3`. [PR #968](https://github.com/jcub-i0/terraform-secure-baseline/pull/968) merged the initial image release; [PR #969](https://github.com/jcub-i0/terraform-secure-baseline/pull/969) merged the staging qualification configuration. [PR #970](https://github.com/jcub-i0/terraform-secure-baseline/pull/970), branch `chore/m1-closeout`, remains the draft documentation closeout. Sections B, F, and G retain historical engineering evidence, including the independent **ACCEPT WITH DEFERRED ITEMS** review at `afdbda0edf314c135d0c24a82750756ed560a0a7`; that review is not final owner acceptance.

## A. Scope delivered

- One essential primary application container plus up to nine optional Terraform-configured sidecars, with digest-pinned images, optional native health checks, validated startup dependencies, environment variables, Secrets Manager/SSM references, and per-container CloudWatch logging.
- Sidecar resource settings, command/entry-point overrides, ports, and root-filesystem mode; shared task-local volumes and container mount points; optional task ephemeral storage and container startup/shutdown timeouts. Primary and sidecar interfaces are intentionally different; consult the [module usage and limits](../modules/ecs_service/README.md#container-and-validation-limits).
- Per-service execution IAM derived from all configured containers, deduplicated repository/secret/parameter resources, Secrets Manager selector normalization, explicit KMS key grants, and exact direct-IAM resource validation for Secrets Manager, SSM, KMS keys, and (in N5D) application/GuardDuty ECR repositories. ECR authorization intentionally retains `Resource = "*"`; CloudWatch log-stream grants retain their scoped suffix wildcard. Application task-role permissions remain separate from execution permissions.
- Canonical environment-root propagation, complete expected task-definition inventory and runtime comparison, Terraform native positive/negative regressions, offline validator regressions, and CI enforcement. Empty sidecar configuration retains the existing single-container service and resource-address model.

The [runtime design](../docs/ecs-runtime-design.md) and [Terraform variable contract](../modules/ecs_service/variables.tf) define the interfaces and validation boundaries; this record does not expand them.

## B. Historical implementation verification

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

Implementation checkpoints were reported locally validated in the owner handoff. The available N5C-A local `validation-summary.json` and logs corroborate passing native suites for ECS, IAM, baseline, and dev/staging/prod propagation, plus offline IAM, runtime inventory, native health, and release-acceptance regressions. The summary records a pre-commit working tree based on `ead8dce6`; all eight recorded changed-file hashes match committed `76ed2105`. It does not independently certify the later N5C-A1 changes. These local reports are separate from GitHub CI and were inspected, not rerun, at the historical N5C-B documentation checkpoint.

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

Passing offline tests and CI do not prove zero live drift, sidecar readiness in AWS, or owner acceptance. These historical checkpoints precede the live evidence in section E.

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

## E. Live qualification and closeout

### Provenance and final evidence

Qualification used the `staging` environment with effective `deployment_profile = production`, Linux/X86_64 Fargate platform `1.4.0`, three fixed-count service tasks, and the shared image digest selected by PR #968. All three configured containers used that same repository and digest; see the [captured task definition](./evidence/m1-live/task-definition.json).

The [source marker](./evidence/m1-live/validation-commit.txt) records `a6ee164caacd56398b3be5a9aef1175a644beb3e`, PR #969's feature commit. The deployed `main` merge commit was **`5cbf78e8d64eb64150af3b9d49d0bda13fb3a79f`**. The final validation workflow also checked out that merge commit; `a6ee164c` is neither its workflow SHA nor the deployed commit. The source and merge commits have identical staging qualification configuration. Evidence was subsequently committed on the closeout branch at `3b4cedb9`; that is not a deployment or validation SHA.

| Operation (attempt 1) | Verified result | Evidence |
|---|---|---|
| Multi-container Plan / Apply | Successful saved plan, Apply, and ECS release acceptance at `5cbf78e8` | [Run 43499646691](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43499646691) |
| Final baseline export | Successful; **16/16 PASS, 0 failures**, including ECS runtime and IAM | [Run 43512991768](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43512991768), [summary](./evidence/m1-live/validation/2026-11-13T214233/summary.md), [JSON](./evidence/m1-live/validation/2026-11-13T214233/summary.json) |
| Staging retirement Plan / Apply | Successful, including retirement Stage 1 plan validation and durable-data inventory | [Run 43514377171](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43514377171) |
| Staging workload Destroy | **Success:** all four jobs passed; Terraform reported 0 added, 0 changed, **341 destroyed** at `5cbf78e8` | [Run 43515303509](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43515303509) |

Both committed summaries are byte-identical to the final run's [artifact 14079886315](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43512991768), `baseline-validation-staging-43512991768-1`. The downloaded ZIP matches GitHub's SHA-256 `f88617498ee4ef6da01eec03795d83a838c3d3d55f969ed2c2607a73611873bf`. The report time is `2026-11-13T21:42:33+00:00`; validation used GitHub OIDC credentials. The repository contains only the two summaries, not the 16 per-validator logs listed by the generated report; those logs are in the artifact. Its recorded expiry is **2026-12-13**, so it is not durable retention by itself.

### Qualification results and limits

- **Positive:** the owner's live observation recorded three running Fargate service tasks, all `HEALTHY`; primary `test` and essential `readiness` were running and healthy, and nonessential `init` had stopped with exit code `0`. The task definition declares `readiness` → `init` with `SUCCESS` and `test` → `readiness` with `HEALTHY`. The final artifact's `validate-ecs-runtime.log` independently confirms three healthy primary containers, exact task-definition inventory and health-check configuration, steady-state service health, and three running GuardDuty agents. The positive `DescribeTasks` snapshot is not among the five committed evidence files; the detailed sidecar observations are owner-supplied, not reconstructed from the summary.
- **Negative:** the [standalone task capture](./evidence/m1-live/negative-task.json) uses the same task-definition revision with `init` overridden to `exit 1`. It records `init` stopped with exit code `1`, dependent `readiness` and `test` stopped without reported exit codes, and `TaskFailedToStart` / `Task failed to start`. This supports a successful negative **`SUCCESS` prerequisite** test; it is not a negative `HEALTHY` prerequisite test or qualification of an M2 standalone-task abstraction.
- **Security and logging:** ECS runtime and IAM validators passed; task-definition `awslogs` configuration and log-group settings were validated. The earlier owner-reported GuardDuty coverage issue had recovered: the final runtime log records `HEALTHY`, `AUTO_MANAGED`, zero unresolved issues, and coverage updated at `2026-11-13T21:40:46+00:00`. This does not establish continuous coverage throughout the earlier interval or independently verify every container's emitted log messages.
- **Not live-tested in this multi-container qualification:** separate per-container ECR repositories, Secrets Manager/SSM retrieval and optional startup-secret KMS grants, shared volumes/mounts, explicit expanded ephemeral storage, custom start/stop timeouts, alternate architectures, and the full range of optional ports/environment/entry-point settings. `START`/`COMPLETE` behavior and legacy single-container compatibility retain offline regression evidence; this run does not establish a separate live single-container regression. Startup timestamps did not independently prove container ordering. Passing checks do not prove zero live drift or qualify every optional interface.

### Teardown, evidence hygiene, and remaining owner decisions

Staging workload foundation destruction completed successfully, as expected for closeout. After the owner reported completion, GitHub run `43515303509` was verified as `completed` / `success`, with all four jobs passing. The [final Apply job](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/43515303509/job/132197854602) logged `Apply complete! Resources: 0 added, 0 changed, 341 destroyed.` at `2026-11-13T22:38:52Z`. The completed evidence was retrieved once without polling. This verifies the workflow outcome, not zero residual AWS resources: no independent post-destroy residual-resource inspection was performed. The separately managed bootstrap and state stacks are outside this workload Destroy; their destruction is not claimed. The completed pre-retirement qualification remains valid.

The five evidence files in PR #970 were reviewed without alteration. `negative-task.json` exposes private IP addresses, internal DNS, a MAC address, subnet/ENI IDs, task/container/runtime/attachment identifiers, and infrastructure ARNs. `task-definition.json` exposes account, ECR, task-definition, IAM-role, log-group, and registering-session identifiers; both summaries expose account IDs and the infrastructure name prefix. No plaintext credentials or secret values were identified in these five files. These identifiers are unnecessary for a public behavioral record.

**Recommendation: replace the public raw AWS metadata with explicitly labeled sanitized evidence after privately retaining the originals.** No evidence files were changed during this closeout. Retain byte-for-byte originals and the full export in an access-controlled durable location, with SHA-256 hashes and run/commit provenance; then replace the two raw JSON captures and both summaries with sanitized derivatives using consistent placeholders for account/resource/network identities. The source-commit marker can remain unchanged. Keep full validator logs private unless separately sanitized; locally present ignored logs are not part of the five committed files. Preserve container names, image digests, dependency/health settings, statuses, exit codes (including absent values), timestamps, and workflow/commit links. Keep any identity mapping private. Removing values from a later commit does not remove them from existing public Git history; any history cleanup requires a separate owner decision.

Remaining closeout work is owner review of the scoped evidence and untested interfaces, a public-evidence sanitization/private-retention decision (including retention of the positive task observation if available), and final acceptance/closeout PR review with its required checks. The original [M1 criteria](./ROADMAP_v1_15_0.md#milestones) remain unchanged; unexercised interfaces are not silently marked qualified. No authoritative final owner acceptance was found in the reviewed PR records. This documentation update authorizes no deployment, new qualification, or merge.

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

Evidence is in the temporary local directory `/tmp/m1-n5d-ofii8387/` (`validation-summary.json`, native JUnit/logs, and before/after probe logs). Mutated copies were restored; production resource definitions were never edited. Retain required evidence with acceptance. The final N5D recheck confirmed module, static-analysis, and documentation CI passed for `26d180d6`; Terraform Plan was skipped for the draft PR. That historical evidence does not cover the later cleanup; section E records the subsequent live qualification and remaining closeout work.

## G. Historical validation and testing simplification — merged

This owner-authorized cleanup started from committed `26d180d6` on temporary branch `cleanup/v1.15.0-m1-validation`, in `/tmp/terraform-secure-baseline-m1-simplify`. At that checkpoint, the original checkout and its four uncommitted R02/documentation files were preserved. The cleanup was subsequently committed at [05a4c69e](https://github.com/jcub-i0/terraform-secure-baseline/commit/05a4c69e84584d8dc92ef70150c3f21104105fa3), followed by the fixture correction at `2dc329e3`; both are included in merged PR #967. The stricter repository-name length follow-up was not incorporated: AWS name limits are not a least-privilege control. The IAM module still rejects wildcard ECR, secret, parameter, and KMS resources.

The governing standard is [validation ownership](../docs/ecs-runtime-design.md#validation-ownership): Terraform enforces security and composition; providers/AWS own routine parameter validation. The cleanup deletes CPU/memory and platform matrices, routine numeric/name/health checks, repeated baseline IAM checks, and redundant primary/sidecar checks. Secret normalization, production/retirement policies, renderers, interfaces, provider locks, CI, and runtime validators are unchanged.

| Metric | Before cleanup | Cleanup checkpoint |
|---|---:|---:|
| Native test files | 11 | 9 |
| Native test lines | 4,984 | 2,501 |
| Native runs | 185 | 42 |
| ECS `services` lines / validation blocks | 709 / 27 | 306 / 8 |
| Baseline `ecs_services` lines / validation blocks | 472 / 23 | 228 / 7 |

The suite retains legacy fixed/autoscaled rendering, multi-container health and all dependency conditions, exact secret propagation and normalization, per-service IAM isolation and full policy statement comparisons, runtime-inventory output, and all three typed environment-root fixtures. Equivalent malformed-input permutations and AWS capability/boundary tests were removed. Four focused tests cover existing collision and managed-policy restrictions at the boundaries retained by this refactor; no new validation policy was introduced.

Local validation passed: ECS 19, IAM 8, baseline 6, and dev/staging/prod 3 native runs each; 19 offline IAM tests; 115 runtime-inventory, 18 native-health, 17 release-acceptance, and 13 task-role scenarios. Backend-disabled initialization and Terraform validation passed for all six roots using existing lockfiles. Twelve before/after positive fixtures produced identical planned address inventories, seven task definitions (complete direct-module values and baseline rendering fields), and two execution policies. Input types/defaults and all resource definitions remain unchanged.

Historical evidence was retained temporarily in `/tmp/m1-simplify-evidence-c7ecrg7h/`. These results describe the isolated local checkpoint, during which no remote workflow, authenticated AWS plan, deployment, state operation, or commit was performed. They do not independently certify subsequent changes. The cleanup is now merged, and section E supersedes the former outstanding live-qualification status.
