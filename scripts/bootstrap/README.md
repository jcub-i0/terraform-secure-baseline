# Bootstrap Scripts

This directory contains helper scripts for one-time or infrequent Terraform bootstrap operations.

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
terraform -chdir=bootstrap/dev/state init
terraform -chdir=bootstrap/dev/state apply

AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev
```

The script reads the tracked `backend.tf.migrated.example` from the selected state-stack directory. For example:

```text
bootstrap/dev/state/backend.tf.migrated.example
bootstrap/control_plane/state/backend.tf.migrated.example
```

It then:

- validates the active AWS identity
- confirms the backend bucket matches `tf_state_bucket_name`
- writes pre-migration backups outside the repository
- refuses to overwrite an existing remote state object
- creates the ignored active `backend.tf`
- runs interactive `terraform init -migrate-state`
- verifies the S3 state object and `terraform state pull`
- compares Terraform resource addresses before and after migration

The script does **not** run the initial `terraform apply`.

## Verify an Existing Migration

For a state stack that already has an active `backend.tf`:

```bash
AWS_PROFILE=dev \
./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
```

Verification confirms that:

- `backend.tf` matches `backend.tf.migrated.example`
- the remote S3 object exists and is readable
- `terraform state pull` succeeds
- the backend bucket matches the state stack output

## Workload Account Reconciliation

Use `reconcile-workload-account.sh` after applying `environments/<env>` when GitHub OIDC is enabled. The helper resolves current workload-created Lambda and Secrets Manager CMKs, validates account/region/repository context, and produces or applies a reviewable `bootstrap/<env>/account` plan.

Current workload account reconciliation must preserve the three workload GitHub OIDC authorities when enabled: Plan, Apply, and Image Publisher. The GitHub reconciliation workflow explicitly passes:

```text
TF_VAR_enable_image_publisher_role_github=true
TF_VAR_branches_image_publisher_github=<BRANCHES_IMAGE_PUBLISHER_GITHUB or ["main"]>
```

This prevents normal account-stack reconciliation from deleting the publisher role and keeps its exact branch trust synchronized with the approved branch list. The reconciled account output includes `image_publisher_role_github_arn` when the role is enabled.

The reconciliation workflow remains plan-first: its Plan job publishes a saved account-stack plan, and the protected Apply job verifies and applies that exact artifact. Local use may also retain a plan with `--plan-file` and later apply it with `--apply-plan`.

The strict post-apply bootstrap validator currently validates the GitHub OIDC provider and Plan/Apply role/state/CMK contract. It does **not** yet perform equivalent automated verification of the Image Publisher role's branch trust and ECR policy, so those publisher properties remain part of manual release/client review.

Supported workload targets are `dev`, `staging`, and `prod`. See each `bootstrap/<env>/account/README.md` and `modules/github_oidc/README.md` for the role-specific inputs and outputs.

## Repository Behavior

The post-migration template is tracked:

```text
backend.tf.migrated.example
```

The active runtime file is ignored by Git:

```text
backend.tf
```

GitHub evidence workflows materialize the active file from the tracked template before running `terraform init` and validation.

## Safety Notes

Always set `EXPECTED_ACCOUNT_ID` for first-time migrations.

Retain the generated backup directory until the deployment and validation workflows have been independently verified. Do not use this script to move state onto a destination key that already contains unrelated Terraform state.