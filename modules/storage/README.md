# Storage Module

## Overview

The `storage` module owns the workload account's centralized S3 logging/archive
capability: the logs bucket, public-access block, encryption, versioning,
ownership controls, lifecycle configuration, and bucket policy.

[Database](../database/README.md) is a peer module that owns RDS, its security
groups, monitoring IAM, log groups, and master-secret handling. Both are composed
directly in [baseline](../../baseline/main.tf). Shared KMS keys remain in
[security](../security/README.md).

This module consumes resolved inputs; baseline owns profile defaults and
production retirement. The resource declarations below are identification
excerpts, not complete standalone HCL configurations.

## Resources Created

### Centralized Logs S3 Bucket

Creates a centralized S3 bucket for logs:

```hcl
resource "aws_s3_bucket" "centralized_logs"
```

Bucket name format:

```text
<name_prefix>-centralized-logs-<random_id>
```

This bucket is intended to store logs from services such as:

- CloudTrail
- AWS Config
- AWS Network Firewall log delivery
- Other centralized audit/logging sources integrated into the baseline

---

### S3 Public Access Block

Blocks public access to the centralized logs bucket:

```hcl
resource "aws_s3_bucket_public_access_block" "centralized_logs"
```

The module enables:

- `block_public_acls`
- `block_public_policy`
- `ignore_public_acls`
- `restrict_public_buckets`

This helps prevent accidental public exposure of audit and security logs.

---

### S3 Server-Side Encryption

Enables KMS-backed server-side encryption for the centralized logs bucket:

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "centralized_logs"
```

Encryption settings:

| Setting | Value |
|---|---|
| SSE algorithm | `aws:kms` |
| KMS key | `var.logs_cmk_arn` |
| Bucket key | Enabled |

This ensures new objects are encrypted using the logs CMK by default.

---

### S3 Versioning

Enables versioning for the centralized logs bucket:

```hcl
resource "aws_s3_bucket_versioning" "centralized_logs"
```

Versioning improves recoverability and supports log integrity by retaining object versions.

---

### S3 Ownership Controls

Enforces bucket-owner ownership for objects:

```hcl
resource "aws_s3_bucket_ownership_controls" "centralized_logs"
```

The bucket uses:

```hcl
object_ownership = "BucketOwnerEnforced"
```

This disables ACLs and ensures the bucket owner owns all objects written to the bucket.

This is especially important for service-delivered logs.

---

### S3 Lifecycle Configuration

Creates a lifecycle policy for centralized logs:

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "centralized_logs"
```

Current lifecycle configuration:

| Lifecycle action | Timing |
|---|---:|
| Transition to Glacier Instant Retrieval | 30 days |
| Transition to Deep Archive | 180 days |
| Expire current objects | 2555 days |
| Expire noncurrent versions | 2555 days |

The configured expiration period is approximately seven years. These lifecycle settings are not a guarantee of immutable retention: Object Lock is disabled, the policy can be changed by authorized administrators, and the bucket has separate destructive-lifecycle limitations documented below.

---

### S3 Bucket Policy

Creates a bucket policy for the centralized logs bucket:

```hcl
resource "aws_s3_bucket_policy" "centralized_logs"
```

The policy includes controls for:

- Denying log object deletion
- Restricting bucket policy changes
- Restricting versioning changes
- Enforcing KMS encryption on object uploads
- Allowing AWS Config delivery
- Allowing CloudTrail delivery
- Allowing firewall log delivery

---

## Bucket Policy Controls

### Deny Log Deletion

The bucket policy denies:

```text
s3:DeleteObject
s3:DeleteObjectVersion
```

This deny applies to objects and versions while the policy is present. It has no `bucket_admin_principals` exception in the deletion statement; the administrator exception is on policy/versioning changes. Do not equate this policy with Object Lock or a guarantee that logs survive workload destruction.

---

### Restrict Bucket Policy Changes

The bucket policy denies bucket policy modification unless the caller is listed in:

```text
var.bucket_admin_principals
```

Restricted actions:

```text
s3:PutBucketPolicy
s3:DeleteBucketPolicy
```

This prevents unauthorized or accidental weakening of the log bucket policy.

---

### Restrict Versioning Changes

The bucket policy denies versioning changes unless the caller is listed in:

```text
var.bucket_admin_principals
```

Restricted action:

```text
s3:PutBucketVersioning
```

This helps prevent accidental or malicious disabling of log versioning.

---

### Enforce KMS Encryption

The bucket policy denies object uploads that are not encrypted with KMS.

It denies uploads when:

- `s3:x-amz-server-side-encryption` is not `aws:kms`
- The encryption header is missing

These conditions require the SSE-KMS header but do not constrain every upload to one exact KMS key ARN. The bucket’s default encryption separately selects `logs_cmk_arn`.

---

### Allow AWS Config Delivery

The bucket policy allows AWS Config to:

- Check the bucket ACL
- Check bucket existence
- Write objects under the `Config/` prefix

AWS Config writes are expected under:

```text
Config/*
```

---

### Allow CloudTrail Delivery

The bucket policy allows CloudTrail to:

- Check the bucket ACL
- Write objects under the `CloudTrail/` prefix

CloudTrail writes are expected under:

```text
CloudTrail/*
```

CloudTrail access is scoped with the source account condition:

```text
aws:SourceAccount = <workload account ID>
```

---

### Allow Firewall Log Delivery

The bucket policy allows AWS log delivery to write firewall logs under:

```text
<cloud_name>/firewall/flow/AWSLogs/<account_id>/*
```

The policy allows the log delivery service principal:

```text
delivery.logs.amazonaws.com
```

The write statement requires the workload source account and bucket-owner-full-control ACL and restricts `aws:SourceArn` to `arn:<partition>:logs:<primary_region>:<account_id>:*`, with `<partition>` derived from `data.aws_partition.current`. The [firewall module](../firewall/README.md) supplies the matching `<cloud_name>/firewall/flow` destination prefix. This is workload-local log storage, not a separate cross-account archive.

---

## Important Production Notes

The centralized logs bucket force-destroy posture is supplied by baseline
composition. Object Lock and Terraform's static `prevent_destroy` setting remain
independent limitations.

### Centralized Logs Bucket Object Lock

The module explicitly sets `object_lock_enabled = false` and exposes no input for enabling it. This module does not provide an Object Lock retention policy, legal hold, or WORM guarantee. An organization needing those controls needs a separate reviewed design; this documentation does not assert they are supplied by the production profile.

### Centralized Logs Bucket Force Destroy

Baseline resolves the required `centralized_logs_force_destroy` input as follows:

| Posture | S3 `force_destroy` |
|---|---:|
| Development/minimal | `true` |
| Normal production | `false` |
| Production retirement (after reviewed Stage-1 Apply) | `true` |

A nonempty production bucket is not implicitly purged under the normal-production
posture. The reviewed retirement Apply must successfully write `true` into
Terraform state **before** the final destroy; setting the input only in a
single destroy plan is insufficient to update provider deletion behavior.
The Stage-1 and retirement-readiness gates check the planned and applied
postures respectively.

**Important:** The final approved production destroy can delete the contents
of this log bucket. Unlike ECR and Backup, the scoped durable-data cleanup
script does **not** inventory/archive/delete these logs in its earlier
approved cleanup job. Operators must independently assess, copy, and verify
retained audit evidence and the required encryption keys before retirement.
S3 Object Lock remains disabled. The existing log-deletion bucket policy is
a separate permission boundary; `force_destroy` does not override its deny,
and neither that deny nor the false flag guarantees immutable retention.

### Centralized Logs Bucket Prevent Destroy

The module continues to set `prevent_destroy = false` because Terraform
lifecycle meta-arguments cannot be parameterized by the deployment profile.
Normal production's `force_destroy = false` protects a **nonempty** bucket
against Terraform's automatic object purge, but does not stop destruction of
an already empty bucket, administrative policy changes, or direct AWS deletion.
Do not describe this as WORM or a universal production destruction guard.

---

## Inputs

| Name | Type | Required / default | Purpose |
|---|---|---|---|
| `cloud_name` | `string` | Required | Prefix in the firewall log-delivery S3 path |
| `primary_region` | `string` | Required | Workload region in firewall log-delivery source ARNs; does not configure the provider or state backend |
| `name_prefix` | `string` | Required | Resource naming prefix |
| `environment` | `string` | Required | Resource tags |
| `logs_cmk_arn` | `string` | Required | Centralized logs-bucket key |
| `account_id` | `string` | Required | Workload account in policy conditions and log paths |
| `random_id` | `string` | Required | Centralized logs-bucket naming suffix |
| `bucket_admin_principals` | `list(string)` | Required | Principals exempted from protected policy/versioning-change denies |
| `centralized_logs_force_destroy` | `bool` | Required | S3 force-destroy behavior; baseline derives it from deployment profile and retirement mode |

The baseline resolves these values before calling the module. Most inputs have no module default; a resource example that omits them is not a complete call.

---

## Outputs

| Name | Description |
|---|---|
| `centralized_logs_bucket_name` | Name of the centralized logs S3 bucket |
| `centralized_logs_bucket_arn` | ARN of the centralized logs S3 bucket |
| `centralized_logs_bucket_id` | ID of the centralized logs S3 bucket |

---

## Usage Example

This is the complete module call from baseline composition. Its referenced
variables, locals, and security module must exist in the caller:

```hcl
module "storage" {
  source = "../modules/storage"

  cloud_name                     = var.cloud_name
  name_prefix                    = local.name_prefix
  environment                    = var.environment
  primary_region                 = var.primary_region
  account_id                     = var.account_id
  random_id                      = var.random_id
  logs_cmk_arn                   = module.security.logs_cmk_arn
  bucket_admin_principals        = var.bucket_admin_principals
  centralized_logs_force_destroy = local.effective_centralized_logs_force_destroy
}
```

---

## Validation

[Logging validation](../../scripts/validation/validate-logging.sh) and the
supplemental manual inspections below concern centralized log storage. Database
validation is documented in the [database module](../database/README.md).
These inspections require a separately authorized, deployed workload; source and
offline checks alone do not establish live delivery or retention.

Run from the repository root against an initialized, deployed workload. Substitute the profile, environment, and account ID; resolve region and identifiers from that root rather than account-wide discovery:

```bash
export ENV_NAME="prod"
export AWS_PROFILE="prod"
export EXPECTED_ACCOUNT_ID="<12-digit-workload-account-id>"
ENV_DIR="environments/${ENV_NAME}"
export AWS_REGION="$(terraform -chdir="$ENV_DIR" output -raw primary_region)"
export AWS_DEFAULT_REGION="$AWS_REGION"
test "$(aws sts get-caller-identity --query Account --output text)" = "$EXPECTED_ACCOUNT_ID" || exit 1
CENTRALIZED_LOGS_BUCKET_NAME="$(terraform -chdir="$ENV_DIR" output -raw centralized_logs_bucket_name)"
```

### Confirm Centralized Logs Bucket Exists

Check the exact bucket name obtained from the workload output:

```bash
aws s3api head-bucket \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

A successful request establishes that the named bucket is accessible to this caller. It does not independently prove its encryption, retention, or ownership policy. The Terraform state bucket is owned by the separate state stack and is not provisioned by this storage module.

---

### Confirm Centralized Logs Bucket Encryption

```bash
aws s3api get-bucket-encryption \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- SSE algorithm is `aws:kms`
- KMS key is the logs CMK
- Bucket key is enabled

---

### Confirm Centralized Logs Bucket Versioning

```bash
aws s3api get-bucket-versioning \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"
```

Expected:

```json
{
  "Status": "Enabled"
}
```

---

### Confirm Public Access Block

```bash
aws s3api get-public-access-block \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- `BlockPublicAcls` is `true`
- `IgnorePublicAcls` is `true`
- `BlockPublicPolicy` is `true`
- `RestrictPublicBuckets` is `true`

---

### Confirm Lifecycle Policy

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Lifecycle rule is enabled
- Transition to `GLACIER_IR` after 30 days
- Transition to `DEEP_ARCHIVE` after 180 days
- Expiration after 2555 days

---

### Confirm Bucket Policy

```bash
aws s3api get-bucket-policy \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}" \
  --query Policy \
  --output text
```

Expected policy controls include:

- `DenyDeleteLogs`
- `DenyBucketPolicyChanges`
- `DenyVersioningChanges`
- `DenyUnencryptedObjectUploads`
- `DenyMissingEncryptionHeader`
- `AWSConfigAclCheck`
- `AWSConfigWrite`
- `AWSConfigBucketExistenceCheck`
- `AWSCloudTrailAclCheck`
- `AWSCloudTrailWrite`
- `AWSLogDeliveryAclCheck`
- `AWSLogDeliveryWrite`

---

## Operational Considerations

### Centralized Logs Bucket Protection

The centralized logs bucket contains security and audit data.

Treat it as sensitive infrastructure.

Be careful when changing:

- Bucket policy
- Versioning
- Encryption
- Lifecycle rules
- Force destroy
- Prevent destroy
- Object Lock settings

A broken bucket policy can prevent CloudTrail, AWS Config, or firewall logs from being delivered.

An overly restrictive explicit deny can also block Terraform or GitHub Actions from managing the bucket unless the correct admin principals are included.

---

### Bucket Admin Principals

The `bucket_admin_principals` variable controls which IAM principals are exempt from some bucket policy deny statements.

These principals are exempted from the listed policy denies, but still need independent IAM authorization to make changes. Relevant protected settings are:

- Bucket policy
- Versioning configuration

Include only trusted administrative principals in the `bucket_admin_principals` variable before applying.

Common examples may include:

- Account admin principal (role or user)
- Break-glass principal (role or user)
- GitHub Apply role, if CI/CD manages this bucket
- Account root, if intentionally used as an administrative fallback

---

### Log Retention and Cost

The lifecycle policy transitions logs to colder storage classes over time.

Current policy:

```text
30 days  -> GLACIER_IR
180 days -> DEEP_ARCHIVE
2555 days -> expiration
```

This supports long-term evidence retention while reducing storage cost.

For production, confirm retention requirements against:

- SOC 2 evidence expectations
- ISO 27001 evidence expectations
- Customer contracts
- Legal requirements
- Internal security policy

---

## Troubleshooting

### CloudTrail Cannot Write to the Logs Bucket

Check:

- Bucket policy includes CloudTrail write permissions
- CloudTrail is writing to the expected prefix
- `aws:SourceAccount` matches the workload account ID
- Object uploads include KMS encryption
- Logs CMK policy allows CloudTrail to use the key
- Bucket ownership controls do not conflict with service delivery

---

### AWS Config Cannot Write to the Logs Bucket

Check:

- Bucket policy includes AWS Config write permissions
- AWS Config is writing to the `Config/` prefix
- Required ACL and encryption conditions match the delivery behavior
- Logs CMK policy allows AWS Config to use the key
- The Config delivery channel points to the correct bucket

---

### Firewall Logs Cannot Write to the Logs Bucket

Check:

- Bucket policy allows `delivery.logs.amazonaws.com`
- Firewall logs are targeting the expected S3 prefix
- Prefix matches `<cloud_name>/firewall/flow/AWSLogs/<account_id>/*`
- Source account condition matches the workload account ID
- Uploads include required ACL and KMS encryption headers
- Logs CMK policy allows AWS log delivery usage

---

### Terraform Cannot Modify the Logs Bucket Policy

This is usually caused by the explicit deny statements in the bucket policy.

Check:

- The caller ARN is included in `bucket_admin_principals`
- GitHub Apply role ARN is included if CI/CD manages the bucket
- Admin role ARN is included if local admin workflows manage the bucket
- You are using the expected AWS profile or assumed role

This is a common failure mode when a bucket policy protects itself from modification.

---

## Security Notes

- The centralized logs bucket blocks public access.
- The centralized logs bucket uses KMS encryption.
- The centralized logs bucket has versioning enabled.
- The centralized logs bucket denies object deletion.
- The centralized logs bucket denies unencrypted uploads.
- Bucket policy and versioning changes are restricted to approved admin principals.
- CloudTrail, AWS Config, and firewall log delivery are explicitly allowed by bucket policy.

---

## Design Principles

This module follows:

- KMS-backed encryption
- Centralized audit log storage
- Least privilege service delivery
- Long-term log retention
- Operational recoverability

---

## Notes

- The logs CMK remains owned by the security module; references preserve resource ordering.
- The centralized logs bucket depends on the logs CMK.
- The logs bucket is intentionally protected by explicit deny statements.

## Implementation Sources

- [Resource definitions](main.tf), [input declarations](variables.tf), and [outputs](outputs.tf)
- [Baseline module call](../../baseline/main.tf) and [profile/lifecycle resolution](../../baseline/locals.tf)
- [Logging validation](../../scripts/validation/validate-logging.sh)
- [Production retirement](../../docs/production-retirement.md)
