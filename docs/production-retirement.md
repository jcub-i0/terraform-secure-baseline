# Production Retirement

## Purpose and Supported Scope

This runbook covers retirement of `environments/{dev,staging,prod}` when the selected workload has `deployment_profile = "production"`, including production-profile staging. It is an operator procedure, not evidence of a live retirement qualification.

Production retirement differs from ordinary development/minimal teardown. It separates a reviewed Terraform retirement preparation from explicitly authorized durable-data deletion, separately coordinated Identity Center dependencies, and the final reviewed workload destroy.

**Scope:** Retirement eligibility follows the *applied* `deployment_profile`, not the directory name. The existing workflows and cleanup helper accept `dev`, `staging`, or `prod` when the deployed profile is `production` and the retirement checks pass. The matching `<env>-plan` and `<env>` GitHub Environments must have their intended access controls and required reviewers configured; merely naming an environment in workflow YAML does not enforce approval.

Workload destruction does not destroy the account or self-managed state roots. Those are separate, later operations with their own dependencies and protection decisions.

## Safety Model

Normal production uses:

```hcl
production_retirement_mode = false
```

| Control | Normal production | Retirement preparation |
|---|---|---|
| RDS deletion protection | Enabled | Disabled |
| ALB deletion protection, when present | Enabled | Disabled |
| Network Firewall delete protection, when present | Enabled | Disabled |
| ECR `force_delete` | `false` | Remains `false` |
| ECS service `force_delete` | `false` | Remains `false` |
| Backup vault `force_destroy` | `false` | Remains `false` |
| Centralized logs S3 `force_destroy` | `false` | `true` after Stage-1 Apply |
| ALB access-log S3 `force_destroy`, when logging is enabled | `false` | `true` after Stage-1 Apply |
| RDS `skip_final_snapshot` | `false` | Remains `false` |
| RDS `delete_automated_backups` | `false` | Remains `false` |
| Effective ECS desired capacity | Normal configured capacity | `0` |
| Effective ECS autoscaling bounds, when configured | Normal min/max | `0` / `0` |

Set `production_retirement_mode = true` through the retirement Apply. Do not switch `deployment_profile` to `development` or `minimal` to bypass production controls. When an ingress ALB and its access-log bucket exist, Stage 1 keeps logging enabled and changes only the bucket's retirement posture; it does not delete the bucket.

Retirement mode derives zero-capacity runtime inputs; it does not require editing the canonical service's ordinary `desired_count` or scaling limits. It also does not delete ECR images or AWS Backup recovery points. Those are handled by a separate approved cleanup operation.

Do not set a deployed service's `image_digest` to `null` as a quiescence mechanism. That removes it from the deployable service map and can plan resource deletions; the Stage-1 guard rejects delete/create/replacement actions. Keep the deployed service registered with its selected digest throughout retirement preparation.

## Actual Workflow and Approval Order

The implementation uses the following sequence:

```text
Terraform Apply: production_retirement_mode=true
  internal saved retirement plan
    -> ALB access-logging saved-plan guard and Stage-1 plan validation
    -> workload-environment approval
    -> verify and apply exact saved plan
    -> read-only durable-data inventory

Terraform Destroy: confirm=DESTROY, delete_durable_retirement_data=true
  preflight: identity, inputs, retirement no-change plan, inventory
    -> workload-environment approval for durable cleanup
    -> inventory again and delete scoped durable data
    -> retirement-readiness validation
    -> reconfirm no change and readiness
    -> create saved workload destroy plan
    -> workload-environment approval for final destroy
    -> verify saved destroy artifact and recheck readiness
    -> apply exact saved workload destroy plan
```

The workflows reference protected environments, but repository administrators must actually configure the required reviewer/deployment protection rules in GitHub. Declaring an `environment:` in YAML is not itself evidence that a human approval rule is configured.

**Earlier steps are not rolled back by rejecting a later approval.** Durable-data deletion happens before creation of the final destroy plan. The final workload-destroy approval is distinct; declining it does not restore images or recovery points that were deleted earlier.

## Stage 0 — Decide Durable Asset Disposition

Before approving deletion, identify required application images, recovery points, audit logs, and retention obligations. Preserve required assets outside the repositories, Backup vault, centralized logs bucket, and (when present) dedicated ALB access-log bucket that will be destroyed, or stop retirement. The workflow does not archive or copy assets. **Final approved Terraform Destroy may permanently purge objects and versions from both logging buckets after Stage 1 sets `force_destroy=true`.** Preserve needed log evidence and, for the SSE-KMS centralized logs bucket, its decrypt-key access independently before advancing. The ALB access-log bucket uses SSE-S3.

Record a human-reviewed log/key disposition decision in an externally retained ticket or evidence record. For logs that must survive, identify **each applicable logging bucket**, its object-version scope, the out-of-workload archive destination, integrity/completeness checks, and any necessary KMS key/decrypt-access plan. If approved deletion without preservation is permissible, record the applicable authority and rationale instead. The Destroy workflow's initial preflight checks the acknowledgment and non-secret record reference in its existing request-validation step; **it does not independently verify the record, archive copies, or KMS recoverability**. GitHub Environment reviewers must check the evidence before approving destructive steps.

Production ECR repositories use `force_delete = false`, and the Backup vault uses `force_destroy = false`. Terraform therefore does not implicitly purge their contents to make deletion succeed. The explicit cleanup script inventories **all image digests in Terraform-listed ECR repositories and all recovery points in the Terraform-listed Backup vault**, not only the sample service's active image or one RDS recovery point. Treat that entire scope as the deletion authorization boundary.

The scoped ECR/Backup cleanup does not enumerate, archive, or delete either S3 logging bucket. Both are subject to final Terraform Destroy when permitted by their policies and provider behavior. The `delete_durable_retirement_data=true` input and protected final-destroy approval must be understood to authorize this outcome, not merely ECR/Backup cleanup.

The final RDS snapshot requirement and retention of RDS automated backups are separate from AWS Backup vault cleanup. `delete_automated_backups = false` is not indefinite archival retention. Decide how retained snapshots, backups, and their necessary encryption keys will be managed after workload deletion. The cleanup script does not implement that retention program.

Coordinate with image publishers, operators, and scheduled jobs. The workload Apply/Destroy concurrency group does not prevent external AWS changes, local Terraform commands, or a separately scoped image-publishing workflow from creating new data during retirement. Do not disable mandatory production backup policy merely to make a check pass.

## Stage 1 — Prepare Production for Retirement

### 1. Verify the configuration used for the deployment

Use the reviewed source revision and the same effective workload configuration that owns the live resources. Preserve the service digest and normal canonical capacity settings while enabling retirement mode.

Confirm the selected `<env>-plan` and `<env>` GitHub Environment settings and required reviewer rules. Relevant inputs include `ACCOUNT_ID`, `PRIMARY_REGION`, `CLOUD_NAME`, Plan/Apply role ARNs, `DEPLOYMENT_PROFILE`, and the workload's other state and infrastructure settings. Keep `MAIN_VPC_CIDR`, `RDS_INSTANCE_CLASS`, ALB certificate/ingress settings, and optional `ALB_ACCESS_LOGS_ENABLED` / `ALB_ACCESS_LOGS_RETENTION_DAYS` overrides consistent with the deployed workload. When unset, ALB logging uses profile defaults. Local `TF_VAR_*` overrides are not automatically present in Actions.

The workflows pin Terraform `1.15.8`; use the committed provider lockfiles and root requirements. This procedure does not authorize provider upgrades or topology changes.

### 2. Start Terraform Apply with retirement enabled

Dispatch **Terraform Apply** with:

```text
environment                = <dev|staging|prod> (choose the root with applied production profile)
production_retirement_mode = true
```

The workflow creates a saved plan using `terraform-plan-artifact.sh`. It runs both `validate-alb-access-logging-plan.sh` (with the existing retirement workflow input) and `validate-production-retirement-plan.sh` against that same binary plan before the protected Apply job.

### 3. Review the Stage-1 plan and guard result

The Stage-1 guard permits only resource actions `read`, `no-op`, and `update`. It rejects create/delete/replacement actions and requires production profile, retirement mode, centralized **and ALB** logging `force_destroy=true` lifecycle outputs, other deletion-protection/force-delete safeguards, and zero effective ECS capacity. The ALB saved-plan guard additionally checks prior state for protected production logging and rejects bucket deletion/replacement, retention shortening, disabling logging, and weakened bucket protections. Stage 1 must persist the enabled ALB bucket's `force_destroy=true` in Terraform state before final Destroy.

This is not a whitelist of every allowed in-place attribute change. Review the full readable plan for unrelated updates, credential changes, or security-policy changes; a passing action-type check does not authorize them. Verify that the RDS final-snapshot and automated-backup behavior remains intact.

For a separately generated saved Stage-1 plan, the guard's actual invocation is:

```bash
bash scripts/deployment/validate-production-retirement-plan.sh \
  --working-directory environments/<env> \
  --plan-file /absolute/path/to/reviewed-stage1.tfplan
```

Replace `<env>` with the selected workload root. Both validators read the plan and never apply it. Do not fabricate a placeholder plan file or substitute a new plan after approval.

### 4. Approve and apply that exact plan

Review before approving the workload environment. The Apply job verifies artifact checksums, metadata, workflow context, and Terraform version, then applies the saved binary plan without replanning.

The retirement Apply's subsequent inventory job is read-only. It does not empty ECR repositories or the Backup vault.

### 5. Establish retirement convergence

A normal plan with the same inputs and `production_retirement_mode=true` must report no changes. The Destroy workflow enforces this using `-detailed-exitcode`:

```text
0 -> no changes; retirement configuration is converged
2 -> pending changes; stop and complete/review Stage 1
other nonzero -> Terraform failure; stop
```

Also require actual ECS service quiescence, not only zero planned capacity. For every deployed service, readiness requires an active service whose live `desiredCount`, `runningCount`, and `pendingCount` are all zero. Autoscaling target membership must match Terraform, live and Terraform min/max must be zero, and scheduled scaling actions must not be present for those targets.

A readiness failure caused only by remaining ECR images or recovery points is expected before approved cleanup. Do not make a successful full readiness result a prerequisite to the very cleanup that empties those assets.

## Stage 2 — Reviewed Production Destroy

### 1. Supply explicit destroy and cleanup authorization

Dispatch **Terraform Destroy** with:

```text
environment                   = <dev|staging|prod> (same production-profile workload)
confirm                       = DESTROY
delete_durable_retirement_data = true
confirm_audit_log_disposition  = true
audit_log_disposition_reference = CHG-123456
```

`delete_durable_retirement_data=true` is mandatory for a production-profile destroy **even when the repositories and vault are already empty**. Its workflow input defaults to false, so set it deliberately. Non-production-profile destruction requires this flag to remain false. Production also requires `confirm_audit_log_disposition=true` and a non-placeholder, non-secret `audit_log_disposition_reference` (4-200 characters; letters/digits and `._:/#-`). Development/minimal destroys must leave both new inputs false/empty. The reference is an approval/evidence pointer, not a verification of S3 archival.

The Destroy workflow evaluates retirement mode as true for production and checks that the prior retirement Apply has already converged. It does not apply Stage-1 changes on the operator's behalf.

### 2. Review the read-only preflight inventory

`terraform-destroy-preflight` uses the workload Plan environment. It validates identity/input context, **fails closed on missing audit-log disposition acknowledgment/reference**, initializes and validates Terraform, requires a no-change retirement plan, and calls the cleanup helper in `--mode plan`.

Review all listed repositories, image digests, vault recovery points, and active backup jobs against the approved disposition decision. The inventory is not a saved Terraform plan.

### 3. Approve durable-data cleanup

`production-durable-cleanup` uses the selected workload Apply environment and its Apply role. Before any ECR/Backup deletions, the cleanup helper verifies the current assumed-role caller and checks the live `DenyBucketPolicyChanges` Apply-role exception and `DenyDeleteLogs` on **the centralized logs bucket and the ALB access-log bucket when present**. This also guards direct script invocations. The exception must use `ArnNotEquals`, not the obsolete `ForAnyValue:ArnNotEquals` form.

Terraform normally schedules bucket-policy removal before its owning S3 bucket, but the preflight **does not prove** effective `s3:DeleteBucketPolicy` permission (IAM/SCP/boundary denies can still apply), nor deletion ordering or success for every object version in either bucket. Review the saved Destroy plan and qualify ordering against a disposable versioned bucket; the offline tests are not a live regression.

The cleanup job runs the following command; the helper performs its policy check before deleting durable data:

```text
cleanup-retirement-durable-data.sh
  --environment <dev|staging|prod>
  --mode apply
  --confirm DELETE-DURABLE-DATA
  --region <workload-service-region>
  --expected-account-id <workload-account-id>
  --expected-apply-role-arn <workload-apply-iam-role-arn>
```

The helper re-reads Terraform outputs, checks the production retirement posture and AWS identity, and re-inventories the scoped repositories/vault. It refuses mutation while active Backup jobs are present, deletes the inventoried image digests and recovery points, verifies emptiness, and checks again for active Backup jobs.

**The apply-mode inventory is fresh.** The cleanup helper does not accept and replay a checksummed saved inventory from preflight. Approval authorizes the scoped cleanup operation, not an immutable item list equivalent to the Terraform saved-plan contract. Coordinate writers and inspect the cleanup job's actual inventory. Do not claim stronger approval binding than the implementation provides.

The workflow then runs `validate-retirement-readiness.sh`.

### 4. Reconfirm readiness and generate the workload destroy plan

`terraform-destroy-plan` depends on preflight and cleanup. For production, it reruns the no-change convergence check and readiness validation before creating the saved destroy artifact.

Readiness checks include:

- Terraform's production retirement posture, including both logging lifecycle flags, and disabled force-delete controls;
- applied ALB access-log bucket/policy state and `force_destroy=true` when logging is enabled (or no leftover bucket resources when absent), plus live ALB logging attributes;
- resource-backed RDS final-snapshot/automated-backup intent;
- live RDS, ALB, and Network Firewall deletion protection, as applicable;
- availability of the selected final RDS snapshot identifier;
- zero live ECS desired/running/pending capacity and zero scaling bounds;
- exact scalable-target membership and absence of scheduled scaling actions;
- empty Terraform-owned ECR repositories and Backup vault; and
- absence of active Backup jobs.

It is read-only with respect to AWS infrastructure, but reads Terraform state and uses temporary local files. It does not perform cleanup.

For an operator check after cleanup:

```bash
AWS_PROFILE="<workload-aws-profile>" \
AWS_REGION="<workload-service-region>" \
EXPECTED_ACCOUNT_ID="<workload-account-id>" \
bash scripts/deployment/validate-retirement-readiness.sh \
  --environment <dev|staging|prod>
```

Use the actual service Region. A supplied Region that disagrees with Terraform's `primary_region` output is rejected.

The artifact helper creates:

```text
baseline-destroy.tfplan
baseline-destroy-plan.txt
baseline-destroy-plan-metadata.json
baseline-destroy-plan.sha256
```

Destroy-mode validation permits only delete/no-op/read resource actions and requires at least one deletion. The workflow retains this artifact for one day. Treat the binary and readable plans as sensitive; checksums do not encrypt them.

### 5. Approve and apply the workload destroy plan

When `terraform-destroy-plan` succeeds, `terraform-destroy-apply` becomes eligible for its own protected workload-environment approval. It downloads the reviewed destroy artifact, verifies checksums and exact context, rechecks the live centralized/conditional ALB bucket-policy Apply-role exceptions, rechecks production readiness, and applies the saved `.tfplan` without generating a new plan. The initial destroy preflight already validated the workflow-dispatch disposition inputs; the final protected-environment reviewer must independently review the referenced evidence. The pre-destroy role check cannot guarantee the eventual S3 API operations succeed.

There is no additional Identity Center cleanup stage in this workflow. The baseline no longer creates optional customer Analyst/Engineer permission sets or policy attachments, so workload teardown no longer needs to detach those personas from workload-created IAM policies. If upgrading an older deployed Identity Center state with those personas enabled, review and apply their removal separately **before** destroying the workload that owns any referenced IAM policies. Plan and perform any additional customer-owned identity cleanup under its own governance.

Do not replace the approved saved-plan step with `terraform destroy -auto-approve` or a newly generated unreviewed plan. If state or resources change and the saved plan becomes unusable, investigate and obtain a new reviewed plan; do not bypass verification.

## Artifact and Approval Boundaries

`terraform-plan-artifact.sh` handles saved-plan files, readable text, metadata, and checksums. It requires GitHub Actions context including commit, repository, run ID/attempt, ref, actor, and workflow ref. It verifies the context object supplied by its calling workflow and the Terraform CLI version. It never applies Terraform and does not itself enforce AWS identity or configure GitHub approval rules.

Do not describe the checksums as cryptographic approval signatures or immutable approval of the durable cleanup inventory. Those are different mechanisms.

## Workflow Concurrency

Workload Apply and Destroy use the shared key:

```yaml
concurrency:
  group: terraform-workload-${{ inputs.environment }}
  cancel-in-progress: false
```

Do not change them to independent Apply/Destroy keys. This key does not lock out other workflows or local operators working on the same state or on Identity Center. Coordinate those operations as well.

## Post-Destroy Steps

Record the workflow run, source commit, plan artifacts, readiness result, deletion result, and disposition of retained recovery assets and audit logs. A successful workload root destroy is not evidence that all account resources, historical snapshots, or state backends are gone.

Only consider removing `bootstrap/<env>/account` for the selected workload after its roles and access are no longer required. Its state root (`bootstrap/<env>/state`) is handled last and only from independent state with retained external backups. Its bucket and CMK remain guarded by literal `prevent_destroy = true`; workload retirement does not remove these guards or supply a turnkey state teardown.

See the matching workload state procedure (for example, [prod state](../bootstrap/prod/state/README.md)) and the [state module](../modules/state/README.md) for those boundaries.

## Abort / Recovery

If only Stage 1 has been applied, cancel retirement through a reviewed Apply with `production_retirement_mode=false`. The canonical normal service configuration is the source for capacity; verify actual live capacity, especially for autoscaled services, and restore normal protection/validation before treating the environment as operational.

After durable cleanup has executed, changing retirement mode back does not recreate deleted images or recovery points. Confirm that the required image and recovery assets still exist in an approved location before attempting service recovery. Customer-managed access assignments and any earlier Identity Center migration remain separate administrative responsibilities.

If final destruction fails part-way, inspect the failed resource and Terraform state, preserve evidence, and generate/review a new plan for the remaining work. Do not enable force-delete flags or manually remove unrelated resources simply to turn the workflow green. Previously applied cleanup is not rolled back by a failed or rejected final destroy.

## Production Retirement Exit Criteria

Stage 1 is complete when the reviewed saved plan passes both retirement/ALB guards and applies, the retirement inputs converge to no change, applied log-bucket state reflects the retirement posture, and actual ECS/scaling capacity is quiescent. Remaining durable data is inventoried but has not been implicitly deleted.

Final retirement is complete when scoped durable deletion has been explicitly approved and verified, audit-log/key preservation or disposal has an independently reviewed disposition record, readiness has passed, the exact reviewed workload destroy plan has applied, and retained assets/state/account responsibilities are recorded. Account/state deletion is not a prerequisite to calling the workload root destroyed.

## Implementation References

- [Baseline lifecycle and capacity derivation](../baseline/locals.tf)
- [Terraform Apply](../.github/workflows/terraform-apply.yml)
- [Terraform Destroy](../.github/workflows/terraform-destroy.yml)
- [Saved-plan artifact helper](../scripts/deployment/terraform-plan-artifact.sh)
- [Stage-1 plan validator](../scripts/deployment/validate-production-retirement-plan.sh)
- [ALB saved-plan guard](../scripts/deployment/validate-alb-access-logging-plan.sh)
- [Durable-data cleanup](../scripts/deployment/cleanup-retirement-durable-data.sh)
- [Read-only log-bucket policy/role guard](../scripts/deployment/validate-log-bucket-destroy-principal.sh)
- [Retirement readiness](../scripts/deployment/validate-retirement-readiness.sh)
- [Deployment script reference](../scripts/deployment/README.md)
