# Security-Operations State Stack

## Overview

`bootstrap/security_operations/state` provisions the S3/KMS backend for the delegated security-operations account. It does not provision a shared backend for every workload account. `dev`, `staging`, `prod`, and the other administrative account have their own state roots.

The stack creates an S3 state bucket and a dedicated AWS KMS customer-managed key. Locking is configured by the consuming Terraform backends with:

```hcl
use_lockfile = true
```

There is no DynamoDB table in the current state module.

## Safety Model

Treat state resources as critical infrastructure. Both the S3 bucket and the state CMK have literal `prevent_destroy = true` guards in `modules/state/main.tf`. Bucket versioning, SSE-KMS, S3 Block Public Access, bucket-owner-enforced ownership, and selected bucket-policy denies provide additional controls.

Backend separation alone does not guarantee that Terraform cannot destroy its own backend. The operational rule is:

> Never destroy resources that still contain this root's active Terraform state.

Moving state to an independent backend is necessary before any state-resource retirement, but is not sufficient: the literal bucket and CMK destruction guards remain. The workload `production_retirement_mode` input does not control these guards.

State corruption or loss requires recovery from verified state copies and available object versions. Do not promise either automatic recovery or inevitable total loss; the outcome depends on the retained evidence and backups.

## Architecture

The account's backend is shared by distinct roots, each with a unique state object key:

```text
bootstrap/security_operations/state
    |
    +--> S3 state bucket + state CMK
             |
             +--> bootstrap/security_operations/state
             +--> bootstrap/security_operations/account
             +--> bootstrap/security_operations/security_services
```

The initial apply uses local state. After the bucket and key exist, `migrate-state-stack.sh security-operations` migrates this state root into the bucket it created. Long-lived local state is not the intended steady state.

## Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `cloud_name` | `string` | Required | Project name used by the root to build `name_prefix` |
| `environment` | `string` | Required | Naming identity; the normal value for this account is `security-operations` |
| `state_region` | `string` | `"us-east-1"` | Region hosting the state bucket and CMK; cannot be null |
| `bucket_admin_principals` | `list(string)` | Required | Non-empty principal list exempted from selected bucket-control denies |

The root derives the account ID from `data.aws_caller_identity.account_id` and passes it to `modules/state`. There is no root `account_id` input and no root `primary_region` input.

A principal exempted from a bucket-policy deny still needs an applicable permission grant. Use the actual administrative principals for the account; a root-principal ARN in a policy is not an instruction to use root credentials for routine deployment.

### State and service Regions

The state root's provider uses `var.state_region`. The `region` in an S3 backend is an independent, explicit backend setting; it must identify the Region containing the existing state bucket. The account/security-services stacks have a separate service-region context (`primary_region` where declared); administrative workflow Regions must also be reviewed independently.

The migration helper resolves the backend Region from `backend.tf.migrated.example`. An explicitly set `AWS_REGION` must match that Region. Do not export a different service Region into a migration invocation.

Changing `state_region` or `primary_region` does not migrate existing state. A backend migration and any resource-location changes require their own reviewed plan.

## Outputs

| Output | Description |
|---|---|
| `account_id` | AWS account ID resolved from the active provider identity |
| `tf_state_bucket_name` | State S3 bucket name |
| `tf_state_bucket_arn` | State S3 bucket ARN |
| `tf_state_bucket_cmk_arn` | State KMS key ARN |

## Files

| File | Purpose |
|---|---|
| `main.tf` | Resolves the account identity and calls `modules/state` |
| `variables.tf` | Defines this root's four inputs |
| `providers.tf` | Configures the state-region provider and required tool/provider versions |
| `.terraform.lock.hcl` | Committed provider selections and checksums |
| `outputs.tf` | Exposes account identity and backend resource values |
| `terraform.tfvars.example` | Starting point for reviewed local inputs |
| `backend.tf.migrated.example` | Tracked template for this root's migrated backend |
| `backend.tf` | Local active backend file created by migration; ignored by Git |

The frozen provider requirements are Terraform `1.15.8` and AWS provider `6.66.0`. Retain the lockfile. Do not run an incidental `init -upgrade` as part of documentation reconciliation or routine deployment.

## Deployment and Integration with Other Stacks

Run the following from the repository root with access to the intended delegated security-operations account. These commands are for an initial deployment, not for repairing an uncertain or partially migrated backend.

### 1. Set and verify the execution context

```bash
export AWS_PROFILE="security-operations" # Replace if your local profile has a different name.
export EXPECTED_ACCOUNT_ID="<12-digit-account-id>"
export STATE_REGION="us-east-1" # Must match state_region and the backend template.

aws sts get-caller-identity \
  --profile "${AWS_PROFILE}" \
  --region "${STATE_REGION}"
```

Confirm that the returned account ID equals `EXPECTED_ACCOUNT_ID`. The variable is checked by the migration helper, not automatically consumed as a Terraform provider restriction by this root.

### 2. Review local inputs and the destination template

Copy the example only when a local input file does not already exist:

```bash
test ! -e bootstrap/security_operations/state/terraform.tfvars &&
  cp bootstrap/security_operations/state/terraform.tfvars.example \
    bootstrap/security_operations/state/terraform.tfvars
```

Review every value. Ensure `state_region` matches the intended state-resource location. Review `bucket_admin_principals` and any environment-supplied Terraform variables.

The tracked backend template currently uses:

```hcl
terraform {
  backend "s3" {
    bucket       = "tf-secure-baseline-security-operations-state"
    key          = "security-operations/state.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
```

For a different deployment, adapt the template to the actual bucket and Region before migration. The bucket must match `tf_state_bucket_name` after apply, and the key must be unique to this root. Do not reuse the state key for an account or service root.

### 3. Bootstrap with local state

For a new state stack, do not create the active `backend.tf` before the S3 backend exists. Do not remove an existing backend file merely to make this initial-deployment example applicable.

```bash
terraform -chdir=bootstrap/security_operations/state init
terraform -chdir=bootstrap/security_operations/state validate
terraform -chdir=bootstrap/security_operations/state plan
```

Review the account, naming, Region, and the planned state resources. Then apply:

```bash
terraform -chdir=bootstrap/security_operations/state apply
terraform -chdir=bootstrap/security_operations/state output
```

This initial apply creates backend resources; it does not deploy the dependent roots or migrate this root's state.

### 4. Migrate this root into S3

```bash
AWS_PROFILE="${AWS_PROFILE}" \
AWS_REGION="${STATE_REGION}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" \
./scripts/bootstrap/migrate-state-stack.sh security-operations
```

The helper requires the default workspace, an existing non-empty local state, and no active `backend.tf`. It reads the tracked template, checks the identity and bucket output, saves external pre-migration state copies and resource addresses, refuses a destination object it can already read, creates `backend.tf`, and runs interactive `terraform init -migrate-state` without `-force-copy`.

Review the migration destination before answering the Terraform prompt. Ensure the caller can determine whether the destination key already exists; an access error must not be treated as independent proof that a key is unused.

After migration, the helper verifies the remote object and pulled state, checks the bucket output, compares resource addresses, and retains a post-migration state copy. The default backup directory is `${HOME}/.tf-secure-baseline/state-backups`; `BACKUP_DIR` can override it. Keep these copies outside the repository and restrict access to them.

### 5. Verify an existing migration

```bash
AWS_PROFILE="${AWS_PROFILE}" \
AWS_REGION="${STATE_REGION}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" \
./scripts/bootstrap/migrate-state-stack.sh security-operations --verify-only
```

This does not perform a second migration. It does run `terraform init`, checks the default workspace, and uses temporary local files. The active `backend.tf` must match the tracked template byte-for-byte.

If migration fails, do not blindly rerun it or force-copy state. The helper leaves `backend.tf` in place and prints the recovery guidance and backup location. Determine whether state was actually copied before altering backend configuration.

### 6. Configure dependent roots

Use the backend outputs in the actual roots listed under Architecture. Review each tracked backend file for the correct bucket, state Region, native lockfile setting, and distinct object key before initializing it.

Do not run the reusable `baseline/` directory as a standalone workload root. Workloads are rooted at `environments/<env>`, and their backends belong to their respective workload accounts.

## Security-Operations Validation Boundary

Use the migration helper's `--verify-only` mode for this state root. Review state/account plans using their own effective inputs and the intended identity.

The separate service validator targets centralized security governance:

```bash
AWS_PROFILE="${AWS_PROFILE}" \
AWS_REGION="<security-operations-service-region>" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" \
./scripts/validation/validate-security-operations.sh
```

Run it after the centralized security-services root is ready. A successful security-services validation must not be presented as an exhaustive validation of this state stack. Likewise, state migration success does not prove GuardDuty or Security Hub organization configuration.

## Operational Guidelines

Keep the state bucket's versioning, encryption, public-access protection, and destruction guards intact. Retain the committed lockfile and use the root's required versions. Keep active state-stack `backend.tf`, local input files, state files, plan files, and state backups out of source control.

Do not edit a template or active backend to redirect an established stack without reviewing its current state location. Never point two roots at the same state key. The migration helper performs the initial local-to-S3 migration; it is not a general-purpose cross-account/Region migration or state-retirement tool.

## Teardown and Recovery

State resources are not part of ordinary workload retirement. Before even planning their retirement, inventory all dependent roots, preserve external state backups, and move this root's active state to an independent backend or local state. Verify that independent state before proceeding.

The literal `prevent_destroy = true` guards on the bucket and CMK still block normal destruction after that move. This state root provides no input that removes those guards. Any approved exception needs a separate, reviewed change and retained-object disposition plan. Do not remove resource definitions, force-delete bucket contents, or disable key protections simply to get past an error.

A successful workload destroy does not authorize deletion of this account's state bucket. For the management and security accounts, separately assess the organization-wide responsibilities of the dependent roots before retiring anything.

## Related Documentation

This page describes implementation, not a new live test.

- [Root inputs](variables.tf), [provider](providers.tf), [module call](main.tf), and [outputs](outputs.tf)
- [State module](../../../modules/state/README.md)
- [Migration and reconciliation tooling](../../../scripts/bootstrap/README.md)
- [Account architecture](../README.md)
