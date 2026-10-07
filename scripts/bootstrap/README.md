# Bootstrap Scripts

This directory contains helper scripts for one-time or infrequent Terraform bootstrap operations.

## Region and Version Contract

State roots use `state_region` to configure the AWS provider that provisions the state bucket and CMK. Workload/account roots and the centralized security-services root use service `primary_region`; administrative workflows also supply their own service-region context. S3 backend `region` values describe the location of existing backend storage and are configured independently.

| Operation | Meaning of `AWS_REGION` |
|---|---|
| `migrate-state-stack.sh` | State backend Region, derived from the tracked template if omitted; an explicit mismatch is rejected |
| `reconcile-workload-account.sh` | Required workload/account service Region; must match the planned account `primary_region` |
| Workload/control-plane validation | Service Region; state S3/KMS operations use separately resolved backend-region arguments |

Do not treat service `primary_region` as the state location, or changing a variable as a state migration. Keep committed provider lockfiles and the root's required Terraform/provider versions. RC1 pins Terraform `1.15.8` and AWS provider `6.66.0` in the inspected state roots.

## State-Stack Migration

Use `migrate-state-stack.sh` after a new state stack has been initialized and applied locally.

Supported command targets and directories:

| Command target | State-stack directory |
|---|---|
| `dev` | `bootstrap/dev/state` |
| `staging` | `bootstrap/staging/state` |
| `prod` | `bootstrap/prod/state` |
| `control-plane` | `bootstrap/control_plane/state` |
| `security-operations` | `bootstrap/security_operations/state` |

Example:

```bash
export AWS_PROFILE=dev
export EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>"
export STATE_REGION=us-east-1 # Match state_region and the backend template.

aws sts get-caller-identity --region "${STATE_REGION}"
# Confirm the returned account before reviewing/applying the state root.
terraform -chdir=bootstrap/dev/state init
terraform -chdir=bootstrap/dev/state plan
terraform -chdir=bootstrap/dev/state apply

AWS_REGION="${STATE_REGION}" \
./scripts/bootstrap/migrate-state-stack.sh dev
```

The script reads the tracked `backend.tf.migrated.example` from the selected state-stack directory. For example:

```text
bootstrap/dev/state/backend.tf.migrated.example
bootstrap/control_plane/state/backend.tf.migrated.example
```

It then:

- requires the default Terraform workspace and a non-empty local state
- requires `use_lockfile = true` in the template
- validates the active AWS identity
- confirms the backend bucket matches `tf_state_bucket_name`
- writes pre-migration backups outside the repository
- refuses a destination state object it can already read
- creates the ignored active `backend.tf`
- runs interactive `terraform init -migrate-state`
- verifies the S3 state object and `terraform state pull`
- compares Terraform resource addresses before and after migration

The script does **not** run the initial `terraform apply`. Before migration, review the template's bucket, key, and Region and confirm that the caller can determine whether the destination key is already occupied. An access error is not independent proof that the key is unused.

Backups default to `${HOME}/.tf-secure-baseline/state-backups/<target>/<UTC timestamp>`; `BACKUP_DIR` overrides the base directory. The helper refuses to start a new migration when active `backend.tf` already exists. If a migration fails, inspect the printed guidance and determine whether state was copied before changing that file or retrying. It never uses `-force-copy`.

## Verify an Existing Migration

For a state stack that already has an active `backend.tf`:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
```

Verification confirms that:

- `backend.tf` matches `backend.tf.migrated.example` byte-for-byte
- the workspace is `default`
- the remote S3 object exists and is readable
- `terraform state pull` succeeds
- the backend bucket matches the state stack output

`--verify-only` does not migrate state again, but it runs `terraform init` and uses temporary local files. It is not a no-local-write check.

## Workload Account Reconciliation

Use `reconcile-workload-account.sh` after applying `environments/<env>` when GitHub OIDC is enabled. The helper resolves current workload-created Lambda and Secrets Manager CMKs, validates account/region/repository context, and produces or applies a reviewable `bootstrap/<env>/account` plan.

Run from the repository root with the account root's normal Terraform inputs in place. Region and identity are explicit:

```bash
export AWS_PROFILE=dev
export AWS_REGION=us-east-1 # Workload/account service Region, not backend Region.
export EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>"

./scripts/bootstrap/reconcile-workload-account.sh dev \
  --plan-file /tmp/dev-account-reconciliation.tfplan
```

This invocation is plan-only. Review the saved plan and current account/workload CMK identities before applying it:

```bash
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --apply-plan /tmp/dev-account-reconciliation.tfplan
```

`--apply-plan` uses an existing saved plan rather than generating a new one. The script also supports `--apply`, `--var`, and `--var-file`; relative variable-file paths are resolved from `bootstrap/<env>/account`. Do not treat a plan generated before unrelated state/configuration changes as current authorization.

The account root must enable GitHub OIDC and the Apply role. The script derives current workload Lambda/Secrets Manager CMK ARNs and supplies those to the account plan. It checks workload/account backend consistency separately from service `AWS_REGION`.

Current workload account reconciliation must preserve the three workload GitHub OIDC authorities when enabled: Plan, Apply, and Image Publisher. The GitHub reconciliation workflow explicitly passes:

```text
TF_VAR_enable_image_publisher_role_github=true
TF_VAR_branches_image_publisher_github=<BRANCHES_IMAGE_PUBLISHER_GITHUB or ["main"]>
```

This prevents normal account-stack reconciliation from deleting the publisher role and keeps its exact branch trust synchronized with the approved branch list. The reconciled account output includes `image_publisher_role_github_arn` when the role is enabled.

The reconciliation workflow remains plan-first: its Plan job publishes a saved account-stack plan, and the protected Apply job verifies and applies that exact artifact. Local use may also retain a plan with `--plan-file` and later apply it with `--apply-plan`.

The bootstrap validator checks the GitHub OIDC provider and Plan/Apply role/state/CMK contract. When `image_publisher_role_github_arn` is present, it also checks the Image Publisher's branch trust and exact ECR publication/query policy. `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true` additionally fails when that role is absent; leaving that flag false does not skip a role that exists.

For strict remote-state evidence, run the layer explicitly:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<owner>/<repo>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

Supply the approved publisher branch expectations when they differ from the normal `main` default. Keep strict CMK checks enabled for qualification; stale workload-created CMK references should be reconciled rather than waived to obtain a pass.

Supported workload targets are `dev`, `staging`, and `prod`. See each `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md` for the role-specific inputs and outputs.

## Repository Behavior

The post-migration template is tracked:

```text
backend.tf.migrated.example
```

For state roots only, the active runtime file is ignored by Git:

```text
backend.tf
```

GitHub evidence workflows materialize the active state backend from the tracked template before initialization. The workload-account reconciliation workflow materializes the state-stack backend using its configured bucket/key/CMK and the state Region read from the tracked template, not `PRIMARY_REGION`. Keep these values consistent with the intended migrated backend.

This ignore rule does not mean every `backend.tf` in the repository is untracked: account, Organizations, Identity Center, security-services, and workload backend files are tracked.

## Safety Notes

Always set `EXPECTED_ACCOUNT_ID` for first-time migrations.

Retain the generated backup directory until the deployment and validation workflows have been independently verified. Do not use this script to move state onto a destination key that already contains unrelated Terraform state.

The state module's bucket and CMK retain literal `prevent_destroy = true` guards. Neither of these bootstrap scripts removes them, and workload retirement does not retire state resources. Moving active state away from a bucket is a prerequisite, not a complete state-destruction procedure.

## Implementation References

- [Migration implementation](migrate-state-stack.sh)
- [Account reconciliation implementation](reconcile-workload-account.sh)
- [Workload bootstrap validator](../validation/validate-bootstrap.sh)
- [Reconciliation workflow](../../.github/workflows/reconcile-workload-account.yml)
- [State module](../../modules/state/README.md)
