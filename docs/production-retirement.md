# Production Retirement

## Purpose and Supported Scope

This runbook describes the implemented retirement path for `environments/prod` with `deployment_profile = "production"`. It is an operator procedure, not evidence that a new live qualification was performed.

Production retirement differs from ordinary development/minimal teardown. It separates a reviewed Terraform retirement preparation from explicitly authorized durable-data deletion, Identity Center dependency cleanup, and the final reviewed workload destroy.

**Scope limitation:** baseline resilience/lifecycle policy is selected by `deployment_profile`, not the name `prod`. However, `cleanup-retirement-durable-data.sh` explicitly accepts only `environment=prod`. Both the retirement Apply's inventory job and the production Destroy path invoke that helper. Do not represent this complete workflow as supported for a production-profile `dev` or `staging` environment. The Stage-1 plan validator and readiness validator have broader input scope, but that does not remove the cleanup helper's restriction.

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
| RDS `skip_final_snapshot` | `false` | Remains `false` |
| RDS `delete_automated_backups` | `false` | Remains `false` |
| Effective ECS desired capacity | Normal configured capacity | `0` |
| Effective ECS autoscaling bounds, when configured | Normal min/max | `0` / `0` |

Set `production_retirement_mode = true` through the retirement Apply. Do not switch `deployment_profile` to `development` or `minimal` to bypass production controls.

Retirement mode derives zero-capacity runtime inputs; it does not require editing the canonical service's ordinary `desired_count` or scaling limits. It also does not delete ECR images or AWS Backup recovery points. Those are handled by a separate approved cleanup operation.

Do not set a deployed service's `image_digest` to `null` as a quiescence mechanism. That removes it from the deployable service map and can plan resource deletions; the Stage-1 guard rejects delete/create/replacement actions. Keep the deployed service registered with its selected digest throughout retirement preparation.

## Actual Workflow and Approval Order

The implementation uses the following sequence:

```text
Terraform Apply: production_retirement_mode=true
  internal saved retirement plan
    -> Stage-1 plan validation
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
    -> create saved Identity Center cleanup plan
    -> control-plane environment approval
    -> verify and apply exact Identity Center cleanup plan
    -> workload-environment approval for final destroy
    -> verify saved destroy artifact and recheck readiness
    -> apply exact saved workload destroy plan
```

The workflows reference protected environments, but repository administrators must actually configure the required reviewer/deployment protection rules in GitHub. Declaring an `environment:` in YAML is not itself evidence that a human approval rule is configured.

**Earlier steps are not rolled back by rejecting a later approval.** Durable-data deletion happens before creation of the final destroy plan. Identity Center cleanup has its own approval and is applied before the final workload-destroy job reaches its approval. Do not document either operation as waiting for the final workload-destroy approval.

## Stage 0 — Decide Durable Asset Disposition

Before approving deletion, identify required application images, recovery points, and retention obligations. Copy/retain required assets outside the repositories/vault that will be destroyed, or stop the retirement. The workflow is not an archival/copy tool.

Production ECR repositories use `force_delete = false`, and the Backup vault uses `force_destroy = false`. Terraform therefore does not implicitly purge their contents to make deletion succeed. The explicit cleanup script inventories **all image digests in Terraform-listed ECR repositories and all recovery points in the Terraform-listed Backup vault**, not only the sample service's active image or one RDS recovery point. Treat that entire scope as the deletion authorization boundary.

The final RDS snapshot requirement and retention of RDS automated backups are separate from AWS Backup vault cleanup. `delete_automated_backups = false` is not indefinite archival retention. Decide how retained snapshots, backups, and their necessary encryption keys will be managed after workload deletion. The cleanup script does not implement that retention program.

Coordinate with image publishers, operators, and scheduled jobs. The workload Apply/Destroy concurrency group does not prevent external AWS changes, local Terraform commands, or a separately scoped image-publishing workflow from creating new data during retirement. Do not disable mandatory production backup policy merely to make a check pass.

## Stage 1 — Prepare Production for Retirement

### 1. Verify the configuration used for the deployment

Use the reviewed source revision and the same effective workload configuration that owns the live resources. Preserve the service digest and normal canonical capacity settings while enabling retirement mode.

Confirm the `prod-plan` and `prod` GitHub Environment settings. Relevant inputs include `ACCOUNT_ID`, `PRIMARY_REGION`, `CLOUD_NAME`, the Plan/Apply role ARNs, `DEPLOYMENT_PROFILE`, state bucket/key information required by the roots, and the workload's other inputs. Keep `MAIN_VPC_CIDR`, `RDS_INSTANCE_CLASS`, and ALB certificate/ingress settings consistent with the deployment. A local-only `TF_VAR_*` override is not automatically available in Actions.

The workflows pin Terraform `1.15.8`; use the committed provider lockfiles and root requirements. This procedure does not authorize provider upgrades or topology changes.

### 2. Start Terraform Apply with retirement enabled

Dispatch **Terraform Apply** with:

```text
environment                = prod
production_retirement_mode = true
```

The workflow creates a saved plan using `terraform-plan-artifact.sh`. It runs `validate-production-retirement-plan.sh` against that same binary plan before the protected Apply job.

### 3. Review the Stage-1 plan and guard result

The guard permits only resource actions `read`, `no-op`, and `update`. It rejects create/delete/replacement or unsupported actions and requires planned outputs showing production profile, retirement mode, the specified deletion-protection/force-delete posture, and zero effective ECS capacity (including zero min/max for autoscaled services).

This is not a whitelist of every allowed in-place attribute change. Review the full readable plan for unrelated updates, credential changes, or security-policy changes; a passing action-type check does not authorize them. Verify that the RDS final-snapshot and automated-backup behavior remains intact.

For a separately generated saved Stage-1 plan, the guard's actual invocation is:

```bash
bash scripts/deployment/validate-production-retirement-plan.sh \
  --working-directory environments/prod \
  --plan-file /absolute/path/to/reviewed-stage1.tfplan
```

That validator reads the plan and never applies it. Do not fabricate a placeholder plan file or substitute a new plan after approval.

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
environment                   = prod
confirm                       = DESTROY
delete_durable_retirement_data = true
```

`delete_durable_retirement_data=true` is mandatory for a production-profile destroy **even when the repositories and vault are already empty**. Its workflow input defaults to false, so set it deliberately. Non-production-profile destruction requires this flag to remain false.

The Destroy workflow evaluates retirement mode as true for production and checks that the prior retirement Apply has already converged. It does not apply Stage-1 changes on the operator's behalf.

### 2. Review the read-only preflight inventory

`terraform-destroy-preflight` uses the workload Plan environment. It validates identity/input context, initializes and validates Terraform, requires a no-change retirement plan, and calls the cleanup helper in `--mode plan`.

Review all listed repositories, image digests, vault recovery points, and active backup jobs against the approved disposition decision. The inventory is not a saved Terraform plan.

### 3. Approve durable-data cleanup

`production-durable-cleanup` uses the workload Apply environment and its Apply role. After the environment gate, it runs:

```text
cleanup-retirement-durable-data.sh
  --environment prod
  --mode apply
  --confirm DELETE-DURABLE-DATA
  --region <workload-service-region>
  --expected-account-id <workload-account-id>
```

The helper re-reads Terraform outputs, checks the production retirement posture and AWS identity, and re-inventories the scoped repositories/vault. It refuses mutation while active Backup jobs are present, deletes the inventoried image digests and recovery points, verifies emptiness, and checks again for active Backup jobs.

**The apply-mode inventory is fresh.** The cleanup helper does not accept and replay a checksummed saved inventory from preflight. Approval authorizes the scoped cleanup operation, not an immutable item list equivalent to the Terraform saved-plan contract. Coordinate writers and inspect the cleanup job's actual inventory. Do not claim stronger approval binding than the implementation provides.

The workflow then runs `validate-retirement-readiness.sh`.

### 4. Reconfirm readiness and generate the workload destroy plan

`terraform-destroy-plan` depends on preflight and cleanup. For production, it reruns the no-change convergence check and readiness validation before creating the saved destroy artifact.

Readiness checks include:

- Terraform's production retirement posture and disabled force-delete controls;
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
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
bash scripts/deployment/validate-retirement-readiness.sh \
  --environment prod
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

### 5. Review and approve Identity Center cleanup

After the workload destroy plan exists, `identity-center-cleanup-plan` runs in `control-plane-plan`. It takes the configured `IDENTITY_CENTER_WORKLOADS` map and sets only the target workload's `enable_secops_analyst` and `enable_secops_engineer` inputs to false. It also requires the configured `IDENTITY_CENTER_SECOPS` input.

It generates a separate saved plan for `bootstrap/control_plane/identity_center`. Review the complete plan: a narrowly changed input is not a guarantee that unrelated pre-existing drift cannot appear in that root's plan. Do not approve unexpected changes to other workloads or central administration.

`identity-center-cleanup-apply` then uses the `control-plane` environment gate, verifies that cleanup artifact, and applies the exact saved plan. This removes the applicable dependencies before workload-created IAM policies are deleted; it is not a destroy of the whole Identity Center stack.

The workflow changes the effective input for that run; it does not persistently rewrite the GitHub `IDENTITY_CENTER_WORKLOADS` variable or commit a configuration change. Reconcile the authoritative map with the intended post-retirement state through the normal reviewed configuration process so a later unrelated apply does not attempt to restore retired assignments.

### 6. Approve and apply the workload destroy plan

Only after successful Identity Center cleanup does `terraform-destroy-apply` become eligible. It has its own workload-environment gate. It downloads the existing destroy artifact, verifies checksums and exact context, rechecks production readiness, and applies the saved `.tfplan` without generating a new plan.

Do not replace this step with `terraform destroy -auto-approve` or a newly generated unreviewed plan. If state or resources change and the saved plan becomes unusable, investigate and obtain a new reviewed plan; do not bypass verification.

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

Record the workflow run, source commit, plan artifacts, readiness result, deletion result, and disposition of retained recovery assets. A successful workload root destroy is not evidence that all account resources, historical snapshots, or state backends are gone.

Only consider removing `bootstrap/prod/account` after its roles and access are no longer required. The state root is handled last and only from independent state with retained external backups. Its bucket and CMK remain guarded by literal `prevent_destroy = true`; workload retirement does not remove these guards or supply a turnkey state teardown.

See the [workload state procedure](../bootstrap/prod/state/README.md) and [state module](../modules/state/README.md) for those boundaries.

## Abort / Recovery

If only Stage 1 has been applied, cancel retirement through a reviewed Apply with `production_retirement_mode=false`. The canonical normal service configuration is the source for capacity; verify actual live capacity, especially for autoscaled services, and restore normal protection/validation before treating the environment as operational.

After durable cleanup has executed, changing retirement mode back does not recreate deleted images or recovery points. Confirm that the required image and recovery assets still exist in an approved location before attempting service recovery. If Identity Center cleanup already applied, separately restore intended assignments through a reviewed Identity Center plan where appropriate.

If final destruction fails part-way, inspect the failed resource and Terraform state, preserve evidence, and generate/review a new plan for the remaining work. Do not enable force-delete flags or manually remove unrelated resources simply to turn the workflow green. Previously applied cleanup is not rolled back by a failed or rejected final destroy.

## Production Retirement Exit Criteria

Stage 1 is complete when the reviewed saved plan passes its guard and applies, the retirement inputs converge to no change, and actual ECS/scaling capacity is quiescent. Remaining durable data is inventoried but has not been implicitly deleted.

Final retirement is complete when scoped durable deletion has been explicitly approved and verified, readiness has passed, the separately reviewed Identity Center cleanup has applied, the exact reviewed workload destroy plan has applied, and retained assets/state/account responsibilities are recorded. Account/state deletion is not a prerequisite to calling the workload root destroyed.

## Implementation References

- [Baseline lifecycle and capacity derivation](../baseline/locals.tf)
- [Terraform Apply](../.github/workflows/terraform-apply.yml)
- [Terraform Destroy](../.github/workflows/terraform-destroy.yml)
- [Saved-plan artifact helper](../scripts/deployment/terraform-plan-artifact.sh)
- [Stage-1 plan validator](../scripts/deployment/validate-production-retirement-plan.sh)
- [Durable-data cleanup](../scripts/deployment/cleanup-retirement-durable-data.sh)
- [Retirement readiness](../scripts/deployment/validate-retirement-readiness.sh)
- [Deployment script reference](../scripts/deployment/README.md)
