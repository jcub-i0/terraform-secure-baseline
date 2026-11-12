# v1.15.0 M1 — Implementation and Acceptance Status

**Status: In progress — implementation complete, acceptance pending.** N1/N2, N3, N4, N5A, N5B, N5C-A, and N5C-A1 are implemented. This N5C-B record closes documentation discrepancies only. Final independent review, live AWS qualification, owner acceptance, and merge remain outstanding; M1 is not fully accepted.

**Implementation:** [PR #967](https://github.com/jcub-i0/terraform-secure-baseline/pull/967), branch `feat/v1.15.0-m1-sidecars`, verified HEAD `89436e6b4f455fad5dd71a5190e52f41dd77837b`. The PR remains open and draft. Evidence below applies to that implementation, not a future acceptance commit.

## A. Scope delivered

- One essential primary application container plus up to nine optional Terraform-configured sidecars, with digest-pinned images, optional native health checks, validated startup dependencies, environment variables, Secrets Manager/SSM references, and per-container CloudWatch logging.
- Sidecar resource settings, command/entry-point overrides, ports, and root-filesystem mode; shared task-local volumes and container mount points; optional task ephemeral storage and container startup/shutdown timeouts. Primary and sidecar interfaces are intentionally different; consult the [module usage and limits](../modules/ecs_service/README.md#container-and-validation-limits).
- Per-service execution IAM derived from all configured containers, deduplicated repository/secret/parameter resources, Secrets Manager selector normalization, explicit KMS key grants, and direct IAM-input wildcard-resource rejection. Application task-role permissions remain separate from execution permissions.
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

- [ECS native suites](../modules/ecs_service/tests/): multi-container behavior, invalid configurations, legacy compatibility, platform compatibility, and secret selectors.
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

The static-analysis workflow uses Checkov `--soft-fail` and validates report integrity; a green workflow does not mean zero Checkov findings. This checkpoint neither rescans nor suppresses/remediates them. Final review must assess the acceptance-commit evidence and retain any unresolved M1-relevant findings. No additional implementation defect was established by this focused documentation review; it does not replace the full independent review.

## E. Outstanding acceptance gates

All gates below remain outstanding:

1. Final independent Codex review against the complete PR at the intended acceptance commit, including disposition of unresolved findings.
2. Explicitly approved synthetic AWS deployment testing with bounded scope and cost.
3. Positive sidecar-readiness evidence, including observed `HEALTHY` dependency behavior before primary startup.
4. Negative sidecar health/dependency behavior demonstrating the expected failure or blocked startup.
5. Continued single-container compatibility evidence in the live qualification, alongside existing offline regressions.
6. Live runtime-validator, IAM, secret retrieval, and logging verification for the configured containers.
7. Final Terraform Plan and all required CI checks at the acceptance commit.
8. Evidence review and retention, cleanup/rollback documentation, final owner approval, and PR merge.

The original [M1 roadmap acceptance criteria](./ROADMAP_v1_15_0.md#milestones) remain unchanged. Documentation closeout does not authorize deployment, acceptance, or merge.
