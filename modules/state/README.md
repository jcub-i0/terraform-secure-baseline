# State Module

## Overview

The `state` module provisions the S3/KMS resources used by a Terraform remote-state backend in one AWS account. The repository calls it from five separate state roots: control-plane, security-operations, dev, staging, and prod. It does not create one bucket containing all five accounts' state.

The module owns the state bucket, its dedicated customer-managed KMS key and alias, and the bucket's access, encryption, versioning, ownership, and policy resources. It does not create a DynamoDB lock table or configure a caller's Terraform backend.

Each consuming root enables native S3 locking in its own backend:

```hcl
use_lockfile = true
```

## Critical State Safety

The bucket and CMK each have a literal Terraform `prevent_destroy = true` guard. Treat these resources as critical infrastructure, not ordinary disposable workload resources.

Never destroy a bucket containing a root's active state. A state root that has migrated into its own bucket must move to an independent backend or local state before any approved state-resource retirement. That move does not remove the literal destruction guards. The state module exposes no retirement toggle, and workload `production_retirement_mode` does not alter this module.

Retain external state backups. Bucket versioning can support recovery, but neither versioning nor a separate bootstrap directory guarantees recovery from every deletion, corruption, or key-loss scenario.

## Resources Created

| Resource | Responsibility |
|---|---|
| `aws_kms_key.state` | Dedicated state CMK; rotation enabled, 30-day deletion window, `prevent_destroy = true` |
| `aws_kms_alias.state` | `alias/<name_prefix>/state-cmk` |
| `aws_s3_bucket.state` | `<name_prefix>-state`; `prevent_destroy = true` |
| `aws_s3_bucket_public_access_block.state` | Enables all four public-access-block settings |
| `aws_s3_bucket_server_side_encryption_configuration.state` | Default SSE-KMS using the state CMK, with bucket keys enabled |
| `aws_s3_bucket_versioning.state` | Enables bucket versioning |
| `aws_s3_bucket_ownership_controls.state` | Sets `BucketOwnerEnforced` |
| `aws_s3_bucket_policy.state` | Applies the generated state-bucket policy |

The module also reads `data.aws_region.current` and builds `data.aws_iam_policy_document.state_bucket`. There is no module-managed lock table.

### KMS key policy

The key policy grants the configured account-root principal `kms:*` and includes an S3 service statement constrained by the caller account and the provider-derived regional `kms:ViaService` value. The Region is read from the supplied AWS provider, not from a module `primary_region` or `state_region` input.

An account-root principal in a key policy is not a recommendation to run routine operations using root credentials.

### Bucket policy controls

The policy denies selected operations unless the request principal is in `bucket_admin_principals`:

| Statement | Operations covered |
|---|---|
| `DenyBucketPolicyChanges` | `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy` |
| `DenyVersioningChanges` | `s3:PutBucketVersioning` |
| `DenyEncryptionConfigChanges` | `s3:PutEncryptionConfiguration` |

This list exempts principals from those denies; it does not itself grant state read/write access or all S3 administration rights. Consumer IAM roles require their own appropriate permissions. Do not describe this policy as an exhaustive state-access policy or a guarantee that no authorized operator can weaken protections.

## Inputs

| Input | Type | Default | Purpose |
|---|---|---|---|
| `name_prefix` | Not explicitly constrained in `variables.tf` | Required | Used directly in resource names and aliases; roots construct `<cloud_name>-<environment>` |
| `cloud_name` | `string` | `"tf-secure-baseline"` | Declared interface input; resource naming uses the supplied `name_prefix` |
| `environment` | `string` | `"dev"` | Environment tag |
| `account_id` | `string` | Required | Account ID used by the key policy |
| `bucket_admin_principals` | `list(string)` | Required | Principals exempted from the selected bucket-control denies |

The reusable module does not accept `primary_region` or `state_region`. The five state roots accept `state_region` and configure their provider with it. They derive `account_id` from `aws_caller_identity` instead of exposing it as a root input. Those root-level behaviors are distinct from this module's inputs.

## Outputs

| Output | Description |
|---|---|
| `tf_state_bucket_name` | S3 state bucket name |
| `tf_state_bucket_arn` | S3 state bucket ARN |
| `tf_state_bucket_cmk_arn` | KMS key ARN used for default state-bucket encryption |

The state roots additionally expose their resolved `account_id`; that is not an output of this reusable module.

## Usage Example

This excerpt follows the calling pattern in `bootstrap/dev/state/main.tf`; it is not a separate standalone root:

```hcl
locals {
  name_prefix = "${var.cloud_name}-${var.environment}"
}

data "aws_caller_identity" "account_id" {}

module "state" {
  source = "../../../modules/state"

  name_prefix             = local.name_prefix
  cloud_name              = var.cloud_name
  environment             = var.environment
  account_id              = data.aws_caller_identity.account_id.account_id
  bucket_admin_principals = var.bucket_admin_principals
}
```

The calling state root supplies its provider separately:

```hcl
provider "aws" {
  region = var.state_region
}
```

Changing this provider input does not rewrite an existing S3 backend configuration or migrate state to a new location.

## Bootstrap and Backend Ownership

Create the state bucket and key with an initial local-state apply, then migrate the state root using `scripts/bootstrap/migrate-state-stack.sh`. The helper reads the root's tracked `backend.tf.migrated.example`, creates the ignored active `backend.tf`, and verifies the remote state.

Each dependent root must use the correct account's backend resources, its actual state Region, a distinct object key, and `use_lockfile = true`. The backend is configured in those roots, not in this module.

The migration helper's `AWS_REGION` is the state-backend Region. Workload/control-plane validators use `AWS_REGION` for their service Region and resolve state operations separately. Do not interchange those execution contexts.

## Validation and Operational Boundaries

The migration helper's `--verify-only` mode verifies the existing migration without migrating again; it still initializes Terraform locally. Workload bootstrap validation and control-plane validation provide their respective additional backend, bucket, CMK, identity, and role checks when the surrounding roots are ready.

Do not describe a successful migration verification as a complete platform or least-privilege validation. Do not add DynamoDB settings to a backend to match obsolete documentation.

The module does not implement cross-Region state replication, a general recovery orchestrator, or an automated state-retirement path. Any approved retirement must separately address dependent roots, independent state/backups, retained object versions, key retention, and the literal destruction guards.

## Implementation References

- [Resources and policies](main.tf), [inputs](variables.tf), and [outputs](outputs.tf)
- [Workload state-root procedure](../../bootstrap/dev/state/README.md)
- [Control-plane state-root procedure](../../bootstrap/control_plane/state/README.md)
- [Security-operations state-root procedure](../../bootstrap/security_operations/state/README.md)
- [Bootstrap scripts](../../scripts/bootstrap/README.md)
