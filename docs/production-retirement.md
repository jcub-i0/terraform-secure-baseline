# Production Retirement

## Purpose

This runbook defines the approved procedure for intentionally retiring a `tf-secure-baseline` workload that uses:

```text
deployment_profile = "production"
```

Production retirement is deliberately different from ordinary development or minimal teardown.

The goals are to:

- make destructive intent explicit
- preserve the exact reviewed-plan Terraform workflow
- disable only the AWS-native deletion protections required for retirement
- gracefully quiesce ECS workloads
- preserve the production RDS final-snapshot and automated-backup contract
- prevent implicit deletion of ECR images or AWS Backup recovery points
- ensure final destruction applies the exact plan that received protected approval

This runbook applies to `environments/<env>` when its effective deployment profile is `production`.

Workload account and self-managed state-stack destruction happen only after the workload environment has been removed and remain documented in `docs/quickstart.md`.

---

## Safety Model

Normal production uses:

```text
production_retirement_mode = false
```

Normal production keeps:

```text
RDS deletion protection             enabled
ALB deletion protection             enabled
Network Firewall delete protection  enabled

ECR force_delete                    disabled
ECS service force_delete            disabled
Backup vault force_destroy          disabled

RDS final snapshot                  required
RDS automated backups on deletion   retained
```

Intentional retirement sets:

```text
production_retirement_mode = true
```

Terraform may then disable only the AWS-native deletion protections required for retirement:

```text
RDS deletion protection             disabled
ALB deletion protection             disabled
Network Firewall delete protection  disabled
```

These protections remain:

```text
ECR force_delete                    false
ECS service force_delete            false
Backup vault force_destroy          false

RDS final snapshot requirement      preserved
RDS automated-backup retention      preserved
```

Do not change `deployment_profile` to `development` or `minimal` to bypass production safeguards.

---

## Two Reviewed Terraform Stages

Production retirement uses two separately reviewed operations:

```text
Stage 1
retirement preparation plan
  -> protected approval
  -> apply exact saved plan
  -> prove retirement state converged

Stage 2
saved destroy plan
  -> protected approval
  -> Identity Center dependency cleanup
  -> apply exact saved destroy plan
```

Do not combine these into one unreviewed destroy action.

---

# Stage 0 - Decide Durable Asset Disposition

Before production is destroyed, decide what should happen to durable data Terraform intentionally refuses to purge automatically.

## ECR images

Production ECR repositories use:

```text
force_delete = false
```

A repository containing images can block destruction.

Before Stage 2, explicitly decide whether required images should be:

- retained elsewhere
- copied/promoted to an archival or successor repository
- deliberately deleted from the Terraform-managed repository

The Destroy workflow must not automatically purge images.

## AWS Backup recovery points

The production Backup vault uses:

```text
force_destroy = false
```

Recovery points can block deletion of the vault.

Before Stage 2, explicitly decide whether recovery points should be:

- retained/copied according to the organization's recovery-retention policy
- deliberately deleted after the retention decision is approved

The Destroy workflow must not automatically delete recovery points.

## RDS final recovery point

Production retirement retains:

```text
skip_final_snapshot       = false
delete_automated_backups  = false
```

Retirement mode must not weaken these controls.

---

# Stage 1 - Prepare Production for Retirement

## 1. Quiesce application services

Production ECS services must reach zero capacity before normal `force_delete = false` service deletion.

For fixed-count services, retirement configuration should resolve to:

```text
desired_count = 0
```

For autoscaled services, retirement configuration must prevent Application Auto Scaling from restoring capacity and resolve the service to zero.

Use Terraform-owned configuration. Do not stop tasks manually in AWS as a substitute for converged retirement state.

## 2. Enable retirement intent

Run the normal `Terraform Apply` workflow with:

```text
environment                = <production-profile environment>
production_retirement_mode = true
```

The workflow must continue to use:

```text
internal Plan
  -> readable plan
  -> saved binary plan
  -> metadata + checksum
  -> protected approval
  -> apply exact saved plan
```

## 3. Review the Stage-1 plan

Expected changes can include:

```text
RDS deletion protection
  true -> false

ALB deletion protection
  true -> false

Network Firewall delete protection
  true -> false

ECS desired/minimum capacity
  running production capacity -> zero
```

The plan must not enable production force deletion for:

```text
ECR
ECS services
AWS Backup vault
```

The plan must preserve:

```text
RDS final snapshot required
RDS automated backups retained
```

Stop and investigate any unrelated replacement or broad security-posture change.

## 4. Approve and apply the exact Stage-1 plan

Approve only after review.

The Apply job must verify and apply the exact saved artifact.

Do not re-plan after approval.

## 5. Prove Stage-1 convergence

Before Stage 2, a normal plan using:

```text
production_retirement_mode = true
```

must report no changes.

The Destroy workflow should enforce this with `terraform plan -detailed-exitcode`:

```text
0 -> retirement configuration converged
2 -> retirement preparation incomplete; stop
1 -> Terraform error; stop
```

---

# Stage 1 Readiness Checks

Before the production destroy plan is generated, read-only checks should prove:

```text
RDS deletion protection
  false

ALB deletion protection, when ALB exists
  false

Network Firewall delete protection, when firewall exists
  false

ECS services
  desiredCount == 0

Application Auto Scaling
  cannot restore service capacity

ECR repositories
  contain no images that would block repository deletion

AWS Backup vault
  contains no recovery points that would block vault deletion
```

The recommended implementation is:

```text
scripts/deployment/validate-retirement-readiness.sh
```

The Destroy workflow should call a repository script rather than embed a large set of AWS CLI checks directly in workflow YAML.

Any failed readiness check stops the workflow before the saved destroy plan is produced.

---

# Stage 2 - Reviewed Production Destroy

## 1. Start the Terraform Destroy workflow

Supply:

```text
environment = <target environment>
confirm     = DESTROY
```

For production, Terraform must evaluate with:

```text
deployment_profile         = production
production_retirement_mode = true
```

The workflow must never silently change the deployment profile.

## 2. Validate identity and inputs

Before planning, verify:

- expected AWS account ID
- active caller account ID
- Plan role ARN account
- Apply role ARN account
- deployment profile
- Terraform version
- state backend configuration
- retirement-mode requirements

Use the same fail-closed identity model as Terraform Apply.

## 3. Reconfirm Stage-1 convergence

Run a normal plan first.

Production may continue only when it reports:

```text
No changes
```

Do not rely on a destroy plan to first turn deletion protection off.

## 4. Run retirement-readiness validation

Confirm all Stage-1 readiness conditions still hold.

Do not generate a production destroy plan while ECS, ECR, Backup, or AWS-native deletion protection remains blocking.

## 5. Generate the saved destroy plan

Generate:

```bash
terraform plan \
  -destroy \
  -input=false \
  -no-color \
  -lock-timeout=5m \
  -out=baseline-destroy.tfplan
```

Produce alongside it:

```text
readable destroy-plan text
plan metadata JSON
SHA-256 checksum
```

Metadata should identify at least:

```text
environment
repository
commit SHA
workflow run ID / attempt
Terraform version
expected AWS account ID
deployment profile
production retirement mode
```

Upload the files as a short-lived artifact.

Saved plans can contain sensitive configuration; keep retention short and restrict workflow-run access.

## 6. Review the destroy plan

Review the complete destroy plan before protected approval.

The plan must not depend on force-deleting ECR images, ECS services, or Backup recovery points.

## 7. Protected approval

The Destroy Apply job must pause on the protected workload environment.

Do not modify external dependencies merely because an unapproved destroy plan was generated.

---

# Identity Center Cleanup After Approval

Some Identity Center assignments can reference IAM policies created by the workload baseline.

Those attachments must be removed before Terraform attempts to delete the workload-created policies.

Approved order:

```text
saved destroy plan generated
        |
        v
human / protected approval
        |
        v
environment-specific Identity Center cleanup
        |
        v
verify saved destroy artifact
        |
        v
apply exact saved destroy plan
```

Do not move Identity Center cleanup after workload deletion; IAM policy attachments may block destruction.

Do not perform the cleanup before approval; otherwise workforce access changes even if the operator rejects the destroy.

The cleanup remains environment-specific. Do not destroy the entire Identity Center stack when retiring one workload.

---

# Apply the Exact Destroy Plan

After approval and required Identity Center cleanup:

1. download the saved destroy artifact
2. verify the checksum
3. verify plan metadata
4. verify commit/environment/account/Terraform-version identity
5. assume the protected Apply role
6. verify active AWS identity
7. apply the exact saved plan

```bash
terraform apply \
  -input=false \
  -no-color \
  baseline-destroy.tfplan
```

Do not run:

```bash
terraform destroy -auto-approve
```

at this stage.

Do not generate another plan after approval.

---

# Workflow Concurrency

Terraform Apply and Terraform Destroy for the same workload must not run concurrently.

Both workflows should use one shared environment-scoped concurrency key:

```yaml
concurrency:
  group: terraform-workload-${{ inputs.environment }}
  cancel-in-progress: false
```

Avoid separate keys such as:

```text
terraform-apply-prod
terraform-destroy-prod
```

because they do not block each other.

---

# Post-Destroy Steps

After the workload root has been successfully destroyed:

1. destroy `bootstrap/<env>/account` only when GitHub OIDC access is no longer required
2. retain an external workload-state backup
3. migrate `bootstrap/<env>/state` away from the backend it manages
4. destroy the state stack only after it no longer uses its own bucket as the active backend

See:

```text
docs/quickstart.md
```

for the account/state teardown sequence.

---

# Abort / Recovery

If Stage 1 is applied but Stage 2 is cancelled:

- decide whether retirement is still intended
- do not leave the environment indefinitely in retirement mode by accident
- if retirement is cancelled, restore canonical application capacity
- run `Terraform Apply` with:

```text
production_retirement_mode = false
```

Review and apply that rollback through the normal saved-plan path.

The environment is not back in normal production posture until the rollback has converged and validation/evidence passes.

If Stage 2 fails part-way:

- do not immediately rerun with force-deletion controls
- inspect the failed resource and Terraform state
- resolve the specific blocker
- generate a new destroy plan
- review and approve the new exact plan

Never apply a stale saved destroy plan after infrastructure or state has changed.

---

# Production Retirement Exit Criteria

Stage 1 is complete when:

- [ ] `production_retirement_mode = true` is active
- [ ] RDS deletion protection is disabled
- [ ] ALB deletion protection is disabled when an ALB exists
- [ ] Network Firewall delete protection is disabled when a firewall exists
- [ ] ECS production services are quiesced to zero
- [ ] Application Auto Scaling cannot restore ECS capacity
- [ ] ECR image disposition is complete
- [ ] Backup recovery-point disposition is complete
- [ ] RDS final-snapshot behavior remains enabled
- [ ] RDS automated-backup retention remains enabled
- [ ] a normal Terraform plan reports no changes
- [ ] retirement-readiness validation passes

Stage 2 is complete when:

- [ ] a saved destroy plan has been generated
- [ ] human/protected approval has been granted
- [ ] environment-specific Identity Center dependencies have been removed
- [ ] destroy-plan metadata and checksum have been verified
- [ ] the exact reviewed destroy plan has been applied
- [ ] the workload root no longer manages live environment resources
- [ ] account/state-stack teardown follows the documented dependency order

---

## Related Documentation

```text
docs/quickstart.md
ROADMAP-v1.11.0.md
.github/workflows/terraform-apply.yml
.github/workflows/terraform-destroy.yml
scripts/deployment/README.md
```