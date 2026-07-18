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

### Plan-Only Review

Without `--apply`, the helper generates and displays a plan but does not apply
it:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev
```

That default plan is stored in a temporary directory and removed when the
script exits.

### Durable Exact-Plan Handoff

Use `--plan-file` when the reviewed plan must be retained and applied in a
later invocation:

```bash
RECONCILIATION_PLAN="/tmp/tf-secure-baseline-dev-account-reconciliation.tfplan"

AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --plan-file="${RECONCILIATION_PLAN}"
```

Apply that exact saved file with:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev \
  --apply-plan="${RECONCILIATION_PLAN}"
```

`--apply-plan` implies apply mode and does not generate a replacement plan. It
cannot be combined with `--plan-file`, `--var`, or `--var-file`, because the
saved plan already contains its resolved inputs.

### One-Step Apply

The existing one-step mode remains available:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/reconcile-workload-account.sh dev --apply
```

This mode generates a plan, displays it, asks the operator to type `apply`,
and applies that plan within the same invocation. Use `--auto-approve` only in
approved automation.

### GitHub OIDC Behavior

The `Reconcile Workload Account` workflow uses the durable plan options:

- the Plan job runs `--plan-file`;
- the protected Apply job downloads the artifact and runs `--apply-plan`;
- strict bootstrap validation runs after apply.

The workflow supports `plan-only` and `plan-and-apply`. Plan jobs use the
matching `*-plan` GitHub environment and Plan role. Apply jobs use the
protected workload environment and Apply role.

When `AWS_PROFILE` is not set, the script and post-apply validation use the
AWS default credential provider chain. This allows GitHub OIDC temporary
credentials to work without attempting to load an empty AWS CLI profile.
Local operators can continue setting `AWS_PROFILE` normally.

The reconciliation helper:

- validates the active AWS identity and backend regions;
- initializes the workload and account Terraform roots;
- resolves and validates the workload-created CMKs;
- validates the account stack's resolved Terraform inputs from the saved plan;
- requires GitHub OIDC and the GitHub Apply role to remain enabled;
- applies the plan generated in the current invocation with `--apply`;
- applies an existing exact saved plan with `--apply-plan`; and
- runs strict bootstrap validation after apply unless `--skip-validation` is used.

The script requires `jq` in addition to Terraform, the AWS CLI, Git, and the
standard shell utilities checked at runtime.

Saved Terraform plan files may contain sensitive configuration values. Store
them securely and remove them after the apply and validation complete.

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