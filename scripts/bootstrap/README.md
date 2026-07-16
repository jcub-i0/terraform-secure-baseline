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

Use `reconcile-workload-account.sh` after applying `environments/<env>` when
GitHub OIDC and the workload GitHub Apply role are enabled. The helper reads
the current workload-created Lambda and Secrets Manager CMK outputs and
reconciles those permissions into `bootstrap/<env>/account`.

Supported targets:

```text
dev
staging
prod
```

The script uses Terraform's normal variable-loading behavior for the account
stack, including `terraform.tfvars`, `*.auto.tfvars`, exported `TF_VAR_*`
variables, defaults, and optional `--var` or `--var-file` arguments. It
automatically supplies the current `lambda_cmk_arn` and
`secrets_manager_cmk_arn` values from `environments/<env>`.

Generate and review a plan:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev
```

Apply the saved plan and run strict workload bootstrap validation:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev --apply
```

The reconciliation helper:

- validates the active AWS identity and backend regions
- initializes the workload and account Terraform roots
- resolves and validates the workload-created CMKs
- validates the account stack's resolved Terraform inputs from the saved plan
- requires GitHub OIDC and the GitHub Apply role to remain enabled
- applies the exact reviewed saved plan when `--apply` is used
- runs strict bootstrap validation after apply unless `--skip-validation` is used

The script requires `jq` in addition to Terraform, the AWS CLI, Git, and the
standard shell utilities checked at runtime.

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