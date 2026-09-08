# Workload Environment State Stack

## Overview

The `bootstrap/<env>/state` stack provisions the Terraform backend resources for one workload AWS account. The same stack pattern is used for `dev`, `staging`, and `prod`.

Each workload account owns its own state backend. The state stack creates:

- an Amazon S3 bucket for Terraform state storage; and
- a dedicated AWS KMS customer-managed key (CMK) used to encrypt that bucket.

Terraform state locking uses the S3 backend's native lockfile support:

```hcl
use_lockfile = true
```

DynamoDB state locking is not part of the current architecture.

After the initial bootstrap, the state stack itself is migrated into the S3 backend that it created. The same bucket is then used by the environment's other Terraform roots with distinct state object keys.

Conceptually:

```text
bootstrap/<env>/state
    |
    | creates
    v
S3 state bucket + state CMK
    |
    +--> state-stack state object
    +--> bootstrap/<env>/account state object
    +--> environments/<env> state object
```

The state, account, and workload roots share the environment's state bucket, but each root must use a unique backend key.

---

## Why This Stack Exists

Terraform cannot use an S3 backend before that backend exists. The state stack therefore has a deliberate two-phase lifecycle:

```text
Phase 1
local Terraform state
    |
    v
create S3 state bucket + KMS CMK

Phase 2
scripts/bootstrap/migrate-state-stack.sh <env>
    |
    v
migrate the state stack into its own S3 backend
```

This is expected behavior. Long-lived local state is not the intended steady state.

---

## Security Model

The state backend is treated as critical infrastructure because corruption, deletion, or unauthorized modification of Terraform state can prevent safe infrastructure management.

The current state architecture expects the S3 bucket to use:

- versioning;
- S3 Block Public Access;
- SSE-KMS encryption with a customer-managed KMS key; and
- S3 native state locking with `use_lockfile = true`.

The state CMK is expected to be enabled and customer-managed.

The state module also uses `bucket_admin_principals` to identify principals that are allowed to modify protected state-bucket controls. Include the administrative Terraform principal that must manage the state resources. Including the AWS account root principal is strongly recommended as an administrative recovery boundary.

A typical value is:

```hcl
bucket_admin_principals = [
  "arn:aws:iam::<account-id>:role/<terraform-admin-role>",
  "arn:aws:iam::<account-id>:root",
]
```

Use the actual administrative principal for the target account. Do not copy example ARNs unchanged.

---

## Repository Layout

Each workload state stack follows this structure:

```text
bootstrap/<env>/state/
├── backend.tf.migrated.example
├── main.tf
├── outputs.tf
├── providers.tf
├── README.md
├── terraform.tfvars.example
└── variables.tf
```

After migration, a local active backend file may also exist:

```text
bootstrap/<env>/state/backend.tf
```

The active `backend.tf` is intentionally ignored by Git. The tracked `backend.tf.migrated.example` remains the source template for the intended migrated backend configuration and for clean-runner materialization.

---

## Inputs

The workload state stack is parameterized by the environment-specific values declared in its `variables.tf`, including:

| Input | Purpose |
|---|---|
| `cloud_name` | Cloud/project name used in resource naming |
| `environment` | Workload environment name |
| `account_id` | AWS account ID that owns the state backend |
| `primary_region` | AWS Region for the state backend |
| `bucket_admin_principals` | IAM principal ARNs allowed to manage protected state-bucket controls |

Use the tracked `terraform.tfvars.example` as the starting point for local configuration:

```bash
cp bootstrap/<env>/state/terraform.tfvars.example   bootstrap/<env>/state/terraform.tfvars
```

Review every value before applying. Runtime `terraform.tfvars` files are ignored by Git and must not be committed.

---

## Outputs

The state stack exposes the backend values required by the environment's other Terraform roots:

| Output | Description |
|---|---|
| `tf_state_bucket_name` | Name of the environment's Terraform state S3 bucket |
| `tf_state_bucket_arn` | ARN of the environment's Terraform state S3 bucket |
| `tf_state_bucket_cmk_arn` | ARN of the KMS CMK used to encrypt the state bucket |

These values are consumed by the workload account/bootstrap and environment deployment configuration.

---

## Backend Template

Before the initial apply, review:

```text
bootstrap/<env>/state/backend.tf.migrated.example
```

The template defines the intended post-migration S3 backend.

It must use:

```hcl
terraform {
  backend "s3" {
    bucket       = "<environment-state-bucket>"
    key          = "<state-stack-specific-key>"
    region       = "<primary-region>"
    encrypt      = true
    use_lockfile = true
  }
}
```

The exact bucket name and object key are environment-specific and must match the intended backend configuration.

Do not add a DynamoDB lock table or `dynamodb_table` setting. The project uses native S3 lockfiles.

---

## Initial Deployment

Run the initial state-stack deployment from the repository root.

Set the target environment and AWS identity explicitly:

```bash
export ENV_NAME="<dev|staging|prod>"
export AWS_PROFILE="<aws-cli-profile>"
export EXPECTED_ACCOUNT_ID="<12-digit-account-id>"
```

Confirm the active AWS account before running Terraform:

```bash
aws sts get-caller-identity   --profile "${AWS_PROFILE}"
```

The returned account ID must match `EXPECTED_ACCOUNT_ID`.

### 1. Review local configuration

Confirm:

```text
bootstrap/${ENV_NAME}/state/terraform.tfvars
bootstrap/${ENV_NAME}/state/backend.tf.migrated.example
```

Use a correctly scoped `bucket_admin_principals` value.

### 2. Ensure the initial backend is local

The first apply must occur before the S3 backend exists.

For a new deployment, do not create an active migrated `backend.tf` before the initial local apply.

### 3. Initialize

```bash
terraform -chdir="bootstrap/${ENV_NAME}/state" init
```

### 4. Review the plan

```bash
terraform -chdir="bootstrap/${ENV_NAME}/state" plan
```

Confirm that the plan targets the expected AWS account and creates only the intended state-backend resources.

### 5. Apply

```bash
terraform -chdir="bootstrap/${ENV_NAME}/state" apply
```

Record:

```text
tf_state_bucket_name
tf_state_bucket_arn
tf_state_bucket_cmk_arn
```

For example:

```bash
terraform -chdir="bootstrap/${ENV_NAME}/state" output
```

At this point, the backend resources exist but the state stack is still using its bootstrap/local state.

---

## Migrate the State Stack

After the initial apply, migrate the state stack into the S3 backend it created.

Use the repository helper rather than manually constructing the migration sequence:

```bash
AWS_PROFILE="${AWS_PROFILE}" EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" ./scripts/bootstrap/migrate-state-stack.sh "${ENV_NAME}"
```

The migration helper performs guarded checks around the migration, including:

- validating required local commands;
- resolving the repository and target state-stack paths;
- reading `backend.tf.migrated.example`;
- requiring `use_lockfile = true`;
- validating AWS credentials;
- validating `EXPECTED_ACCOUNT_ID` when supplied;
- validating the backend Region;
- checking the configured backend bucket against the state stack output;
- creating external state backups;
- refusing unsafe overwrite conditions;
- materializing the active `backend.tf`;
- running Terraform backend migration; and
- verifying the resulting remote state.

The migration is intentionally guarded because the state stack is moving into a backend that it owns.

Keep the external migration backups until post-migration validation succeeds.

---

## Verify an Existing Migration

An already-migrated state stack can be checked without repeating the migration:

```bash
AWS_PROFILE="${AWS_PROFILE}" EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" ./scripts/bootstrap/migrate-state-stack.sh "${ENV_NAME}" --verify-only
```

Verification should establish that the configured backend and remote state are usable before dependent stacks are treated as ready.

---

## Downstream Backend Model

After migration, the workload environment uses the same S3 state bucket for three Terraform roots:

```text
bootstrap/<env>/state
bootstrap/<env>/account
environments/<env>
```

Each root must use:

- the same environment state bucket;
- the same backend Region;
- `use_lockfile = true`; and
- a distinct state object key.

The backend relationship is conceptually:

```text
Environment S3 state bucket
├── state stack key
├── account stack key
└── workload baseline key
```

Never reuse one root's backend key for another Terraform root.

---

## Deploy Dependent Stacks

After the state-stack migration is verified, continue with:

```text
bootstrap/<env>/account
    |
    v
environments/<env>
```

The account stack creates the workload GitHub OIDC roles when that integration is enabled.

The workload environment root deploys the actual environment infrastructure.

For the full deployment sequence, see:

```text
docs/quickstart.md
scripts/bootstrap/README.md
```

---

## Validation

Workload bootstrap validation covers the state backend as part of the broader account/bootstrap validation layer.

Run:

```bash
AWS_PROFILE="${AWS_PROFILE}" AWS_REGION="<primary-region>" EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID}" REQUIRE_STATE_STACK_REMOTE=true ./scripts/validation/validate-bootstrap.sh "${ENV_NAME}"
```

Relevant state checks include:

- migrated state-stack backend configuration;
- S3 native locking with `use_lockfile = true`;
- distinct backend keys across state/account/workload roots;
- remote state object existence and readability;
- successful `terraform state pull`;
- state bucket identity;
- S3 versioning;
- S3 public-access-block configuration;
- SSE-KMS encryption;
- customer-managed state CMK status; and
- consistency between backend configuration and Terraform state outputs.

For client-facing or release evidence, strict remote-state validation should remain enabled.

---

## Operational Safety

### Do

- Verify the active AWS account before every state-stack operation.
- Keep `bucket_admin_principals` deliberately scoped and recoverable.
- Keep S3 versioning and SSE-KMS protection enabled.
- Use `use_lockfile = true` on every remote-backed Terraform root.
- Keep distinct backend keys for the state, account, and workload roots.
- Use `migrate-state-stack.sh` for the supported migration and verification flow.
- Keep external state backups during migration and teardown operations.
- Treat state changes as high-impact infrastructure changes.

### Do not

- Reintroduce DynamoDB state locking.
- Point multiple Terraform roots at the same S3 object key.
- Manually overwrite an existing remote state object during migration.
- Commit active `backend.tf`, runtime `terraform.tfvars`, local state, or backup files.
- Modify state-bucket encryption, versioning, or access controls casually outside Terraform.
- Destroy the state stack while it is still storing its own active Terraform state.
- Destroy the state stack before its dependent account/workload roots have been handled.

---

## Teardown and Destroy Safety

The state stack is not an ordinary workload stack and must be destroyed last.

A safe intentional teardown requires this order:

```text
1. Destroy dependent workload/account roots as appropriate.
2. Retain an external backup of the state-stack state.
3. Migrate the state stack away from the S3 bucket it manages.
4. Verify the state from the independent backend or local state.
5. Destroy the state stack last.
6. Handle retained S3 object versions deliberately.
```

The key rule is:

> A Terraform stack must not destroy the bucket that contains its own active state.

Do not use a routine `terraform destroy` against the state stack while its backend still points at the bucket being destroyed.

---

## Recovery Considerations

S3 versioning provides recovery options for state objects, but it is not a substitute for external backups or careful backend management.

If state or backend configuration appears inconsistent:

1. stop before applying;
2. identify the intended S3 bucket and object key;
3. inspect available state versions/backups;
4. confirm the active AWS account;
5. use `terraform state pull` against the intended backend; and
6. repair backend configuration before making infrastructure changes.

Do not solve an apparent state mismatch by blindly running `terraform apply`.

---

## Environment-Neutral Usage

This README is intentionally environment-neutral and can be used unchanged in:

```text
bootstrap/dev/state/README.md
bootstrap/staging/state/README.md
bootstrap/prod/state/README.md
```

Examples use:

```text
<env>
ENV_NAME
AWS_PROFILE
EXPECTED_ACCOUNT_ID
```

so the same lifecycle and safety guidance applies consistently to every workload environment.

---

## Summary

The workload environment state stack creates and protects the S3/KMS backend used by the environment's Terraform roots.

Its expected lifecycle is:

```text
initial local apply
    -> create state bucket + CMK
    -> guarded migration into S3
    -> native S3 lockfiles
    -> verify remote state
    -> deploy account/workload roots
```

The state backend is critical infrastructure, but it is not permanently undeletable. It can be retired safely only through a deliberate teardown that moves its active state away from the resources it manages before destroying them.