# Bootstrap Scripts

This directory contains helper scripts for one-time or infrequent Terraform bootstrap operations.

## State-Stack Migration

Use `migrate-state-stack.sh` after a new `bootstrap/<target>/state` stack has been initialized and applied locally.

Supported targets:

```text
dev
staging
prod
control-plane
```

Example:

```bash
terraform -chdir=bootstrap/dev/state init
terraform -chdir=bootstrap/dev/state apply

AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev
```

The script reads the tracked:

```text
bootstrap/<target>/state/backend.tf.migrated.example
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