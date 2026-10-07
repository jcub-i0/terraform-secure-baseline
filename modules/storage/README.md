# Storage Module

## Overview

The `storage` module provisions the baseline data storage resources for the environment.

This includes:

- A private PostgreSQL RDS instance
- A dedicated RDS/data security group
- A DB subnet group using private data subnets
- CloudWatch Log Groups for RDS logs
- Secrets Manager storage for the RDS master password
- A centralized S3 logs bucket
- S3 bucket encryption, versioning, lifecycle, ownership, and public access controls
- S3 bucket policy controls for CloudTrail, AWS Config, and firewall log delivery

This module supports the baseline’s data protection, logging, auditability, and private-by-default architecture.

The module consumes resolved inputs; [baseline composition](../../baseline/main.tf) owns profile defaults and production retirement. The resource declarations below are identification excerpts, not complete standalone HCL configurations.

---

## Purpose

The purpose of this module is to provide secure storage primitives for the workload environment.

It supports:

- Private database deployment
- Encrypted database storage
- RDS log export to CloudWatch Logs
- Secure RDS credential generation and storage
- Centralized log storage in S3
- Long-term log retention
- KMS-backed encryption
- S3 public access prevention
- Controlled service writes from CloudTrail, AWS Config, and AWS log delivery services

This module is not only an application storage layer. It also provides part of the audit and evidence storage foundation used by the broader baseline.

---

## Resources Created

### Data Security Group

Creates a dedicated security group for the RDS database:

```hcl
resource "aws_security_group" "data"
```

The security group is created in the target VPC and is used by the RDS instance.

The security-group object is created here with `revoke_rules_on_delete = true`; this module creates no traffic rules on it. [Networking security policy](../networking/security_policy/README.md) owns the compute-to-data and conditional ECS-to-data rules. A declared `compute_sg_id` input does not itself create a rule in this module.

---

### DB Subnet Group

Creates a DB subnet group using private data subnets:

```hcl
resource "aws_db_subnet_group" "data"
```

The DB subnet group places the RDS instance into the private data subnet layer.

This supports the baseline’s private-by-default architecture by keeping the database away from public subnets.

---

### RDS PostgreSQL Instance

Creates the main PostgreSQL RDS instance:

```hcl
resource "aws_db_instance" "main"
```

Configuration in the frozen resource definition (not a report of live AWS state):

| Setting | Value |
|---|---|
| Engine | PostgreSQL |
| Engine version | Configured as `17.10` |
| Instance class | Required `var.rds_instance_class` |
| Allocated storage | `50 GiB` |
| Maximum allocated storage | `200 GiB` |
| Storage type | `gp3` |
| Storage encryption | Enabled |
| Multi-AZ | Required `var.rds_multi_az`; production baseline resolves to `true` |
| Publicly accessible | Disabled |
| Database name | `appdb` |
| Backup retention | `14 days` |
| Backup window | `03:00-04:00` |
| Maintenance window | `sun:05:00-sun:06:00` |
| CloudWatch log exports | `postgresql`, `upgrade` |
| Performance Insights | `performance_insights_enabled = true` |
| Enhanced Monitoring | Not configured; the `monitoring_interval` line is commented out |
| Auto minor version upgrade | Enabled |

This remains a PostgreSQL **Multi-AZ DB instance** when enabled, not Aurora or an RDS Multi-AZ DB cluster. A three-AZ DB subnet group is not a declaration of three database instances or read replicas.

The resource does not specify `kms_key_id` for database storage. Do not identify the database storage key as `logs_cmk_arn` or `secrets_manager_cmk_arn`; those inputs encrypt the log groups/bucket and secret respectively. Likewise, RC1 does not wire `db_port` into an RDS `port` argument. Baseline security-group rules use the configured port, while `rds_port` reports the database's actual endpoint port. Changing only `db_port` is not a supported database-port migration.

The configured engine version and enabled automatic minor-version upgrades are separate settings. Inspect live `EngineVersion` when establishing release evidence; do not infer it solely from this table.

The instance's tag is:

```hcl
Backup = tostring(var.backup_enabled)
```

Baseline supplies the effective AWS Backup enablement value. This tag controls tag-based AWS Backup selection; it does not disable RDS-native automated backups, whose retention remains 14 days in this resource.

---

### RDS CloudWatch Log Groups

Creates CloudWatch Log Groups for RDS PostgreSQL logs:

```hcl
resource "aws_cloudwatch_log_group" "rds_postgresql"
resource "aws_cloudwatch_log_group" "rds_upgrade"
```

The log groups are:

```text
/aws/rds/instance/<rds_identifier>/postgresql
/aws/rds/instance/<rds_identifier>/upgrade
```

Each log group uses:

- Caller-supplied `cloudwatch_retention_days`; baseline defaults are 90 days for production, 30 for development, and 14 for minimal, unless overridden
- KMS encryption using the logs CMK
- Environment and Terraform tags

The RDS instance depends on these log groups so log exports have a destination ready before the database is created.

---

### RDS Master Secret

Creates a Secrets Manager secret for the RDS master password:

```hcl
resource "aws_secretsmanager_secret" "rds_master"
```

The secret uses the Secrets Manager CMK:

```hcl
kms_key_id = var.secrets_manager_cmk_arn
```

The secret name uses a generated suffix through the `name_prefix` variable.

---

### RDS Password Generation

Generates the RDS master password using an ephemeral random password resource:

```hcl
ephemeral "aws_secretsmanager_random_password" "rds_master"
```

Current password generation settings:

| Setting | Value |
|---|---|
| Length | `20` |
| Exclude punctuation | `true` |
| Require each included type | `true` |

The generated password is written to Secrets Manager using write-only secret string arguments.

This pattern is intended to avoid persisting the plaintext database password in Terraform state.

---

### RDS Secret Version

Stores the generated password in Secrets Manager:

```hcl
resource "aws_secretsmanager_secret_version" "rds_master"
```

The secret value is stored as JSON:

```json
{
  "password": "<generated-password>"
}
```

The RDS instance uses the generated value through `password_wo`, with `password_wo_version` bound to the secret version’s `secret_string_wo_version`. RC1 sets that version counter to `1` and also declares an ephemeral secret-version read. This does not implement a scheduled secret-rotation workflow or application database-user lifecycle. Secret references and non-secret metadata remain visible in state; the write-only pattern is specific to the password value.

---

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

The write statement requires the workload source account and bucket-owner-full-control ACL and restricts `aws:SourceArn` to `arn:aws:logs:<primary_region>:<account_id>:*`. The [firewall module](../firewall/README.md) supplies the matching `<cloud_name>/firewall/flow` destination prefix. This is workload-local log storage, not a separate cross-account archive.

---

## Important Production Notes

RDS lifecycle behavior is now input-driven. The centralized logs bucket's literal settings are **not** covered by the same production lifecycle policy.

### RDS Deletion Protection

Baseline derives `rds_deletion_protection` as follows:

| Posture | Deletion protection | Multi-AZ |
|---|---:|---:|
| Normal production | `true` | `true` |
| Production retirement | `false` | `true` |
| Development/minimal | `false` | Defaults to `false`; supported non-production override applies |

The storage module simply applies its supplied booleans. Do not modify resource literals or change the deployment profile to bypass production protections.

### RDS Final Snapshot

Production, including retirement, supplies:

```text
rds_skip_final_snapshot       = false
rds_delete_automated_backups  = false
```

The baseline derives the final snapshot identifier as `<name_prefix>-saas-db-final-<random_id>`. Non-production skips the final snapshot and deletes automated backups on instance deletion by default. When snapshots are skipped the final snapshot identifier resolves to `null`.

Final-snapshot creation and automated-backup retention are deletion-time intent, not live `DescribeDBInstances` flags proving recovery has happened. Preserve the relevant encryption keys and access when planning retention. See [production retirement](../../docs/production-retirement.md) and [Backup/Restore Testing](../backup/README.md).

### Centralized Logs Bucket Object Lock

RC1 explicitly sets `object_lock_enabled = false` and exposes no input for enabling it. This module does not provide an Object Lock retention policy, legal hold, or WORM guarantee. An organization needing those controls needs a separate reviewed design; this documentation does not assert they are supplied by the production profile.

### Centralized Logs Bucket Force Destroy

RC1 explicitly sets `force_destroy = true` for this bucket in **every profile**. This is distinct from production ECR `force_delete=false` and Backup vault `force_destroy=false`.

The existing log-deletion bucket policy is a separate permission boundary. The force-destroy flag does not override an AWS policy deny, nor does that deny turn this bucket into an independently retained archive. Decide log retention/disposition before workload deletion.

### Centralized Logs Bucket Prevent Destroy

RC1 explicitly sets `prevent_destroy = false` on the logs bucket. Neither selecting production nor leaving `production_retirement_mode=false` changes it. The `# CHANGE THIS IN PROD` comments are unresolved implementation limitations, not automatic profile switches.

Do not describe the entire storage module as protected against production destruction. Changes to these S3 controls belong in a separately reviewed implementation change, not a documentation-only release update.

---

## Inputs

| Name | Type | Required / default | Purpose |
|---|---|---|---|
| `cloud_name` | `string` | Required | Prefix in the firewall log-delivery S3 path |
| `primary_region` | `string` | Required | Workload region in firewall log-delivery source ARNs; does not configure the provider or state backend |
| `name_prefix` | `string` | Required | Resource naming prefix |
| `environment` | `string` | Required | Tags and master-username suffix |
| `vpc_id` | `string` | Required | VPC for the data security group |
| `db_port` | `string` | Required | Declared interface input; not wired to an RDS port argument |
| `rds_instance_class` | `string` | Required | Database instance class |
| `compute_sg_id` | `string` | Required | Retained interface input; resource definitions here do not consume it |
| `data_private_subnet_ids_list` | `list(string)` | Required | Exact subnet IDs for the DB subnet group |
| `rds_multi_az` | `bool` | Required | Whether the DB instance is Multi-AZ |
| `db_username` | `string` | Required | Master-username base; environment is appended |
| `logs_cmk_arn` | `string` | Required | Log-group and centralized logs-bucket key |
| `cloudwatch_retention_days` | `string` | Required | RDS log-group retention; the module declares a string, not a number |
| `account_id` | `string` | Required | Workload account in policy conditions and log paths |
| `random_id` | `string` | Required | Centralized logs-bucket naming suffix |
| `cloudtrail_arn` | `string` | Required | Retained interface input; resource definitions here do not consume it |
| `bucket_admin_principals` | `list(string)` | Required | Principals exempted from protected policy/versioning-change denies |
| `secrets_manager_cmk_arn` | `string` | Required | RDS master-secret encryption key |
| `backup_enabled` | `bool` | Required | Resolved enablement used for the RDS Backup tag; this module does not resolve profiles or `null` defaults |
| `rds_deletion_protection` | `bool` | Required | Native RDS deletion protection |
| `rds_skip_final_snapshot` | `bool` | Required | Whether deletion skips the final snapshot |
| `rds_delete_automated_backups` | `bool` | Required | Whether instance deletion removes automated backups |
| `rds_final_snapshot_identifier` | `string` | Optional; `null` | Final snapshot identifier when final snapshots are enabled |

The baseline resolves these values before calling the module. Most inputs have no module default; a resource example that omits them is not a complete call.

---

## Outputs

| Name | Description |
|---|---|
| `centralized_logs_bucket_name` | Name of the centralized logs S3 bucket |
| `centralized_logs_bucket_arn` | ARN of the centralized logs S3 bucket |
| `centralized_logs_bucket_id` | ID of the centralized logs S3 bucket |
| `data_sg_id` | ID of the RDS/data security group |
| `rds_address` | DNS address of the RDS instance |
| `rds_endpoint` | RDS connection endpoint in `address:port` form |
| `rds_port` | Port on which the RDS instance accepts connections |
| `rds_database_name` | Initial database name configured on the RDS instance |
| `rds_master_username` | Master username configured on the RDS instance |
| `rds_master_secret_arn` | ARN of the Secrets Manager secret containing the RDS master password; does not expose the secret value |
| `rds_configuration` | Resource-backed RDS identity, instance class, Multi-AZ, subnet-group name, SG set, retention, encryption/public-access and deletion-time lifecycle metadata |

---

## Usage Example

The following is the complete module call from baseline composition, not an independently deployable Terraform root. Its referenced resources, variables, and effective locals must exist in the caller:

```hcl
module "storage" {
  source = "../modules/storage"

  cloud_name     = var.cloud_name
  name_prefix    = local.name_prefix
  environment    = var.environment
  primary_region = data.aws_region.current.region
  vpc_id         = module.networking.vpc_id
  account_id     = var.account_id
  random_id      = var.random_id

  rds_multi_az                  = local.effective_rds_multi_az
  rds_deletion_protection       = local.effective_rds_deletion_protection
  rds_skip_final_snapshot       = local.effective_rds_skip_final_snapshot
  rds_delete_automated_backups  = local.effective_rds_delete_automated_backups
  rds_final_snapshot_identifier = local.effective_rds_final_snapshot_identifier
  rds_instance_class            = var.rds_instance_class

  db_port     = var.db_port
  db_username = var.db_username

  compute_sg_id                = module.compute.compute_sg_id
  data_private_subnet_ids_list = module.networking.data_private_subnet_ids_list

  backup_enabled            = local.effective_backup_enabled
  cloudwatch_retention_days = local.effective_cloudwatch_retention_days

  logs_cmk_arn            = module.security.logs_cmk_arn
  secrets_manager_cmk_arn = module.security.secrets_manager_cmk_arn
  cloudtrail_arn          = module.logging.cloudtrail_arn
  bucket_admin_principals = var.bucket_admin_principals
}
```

---

## Validation

The automated RDS resilience checks are inside [validate-backup.sh](../../scripts/validation/validate-backup.sh), including when scheduled AWS Backup is disabled. They compare live identity, Multi-AZ, DB subnet-group **name**, SG set, deletion protection, backup retention, public accessibility, and storage-encryption state with `rds_configuration`. Deletion-time settings are checked as Terraform lifecycle intent. An output field such as `instance_class` is not proof the validator compares it: RC1 does not include `DBInstanceClass`, engine/version, or all database settings in that equality check.

[Networking validation](../../scripts/validation/validate-networking.sh) checks the data subnet family, and compute/ECS validators check their declared SG relationships. Those are not a SQL connectivity test, an exact audit of every RDS subnet-group member, or application recovery verification. The supplemental commands below are **manual inspections**, not additional automated assertions in the 16-script suite.

Run from the repository root against an initialized, deployed workload. Substitute the profile, environment, and account ID; resolve region and identifiers from that root rather than account-wide discovery:

```bash
export ENV_NAME="prod"
export AWS_PROFILE="prod"
export EXPECTED_ACCOUNT_ID="<12-digit-workload-account-id>"
ENV_DIR="environments/${ENV_NAME}"
export AWS_REGION="$(terraform -chdir="$ENV_DIR" output -raw primary_region)"
export AWS_DEFAULT_REGION="$AWS_REGION"
test "$(aws sts get-caller-identity --query Account --output text)" = "$EXPECTED_ACCOUNT_ID" || exit 1
RDS_IDENTIFIER="$(terraform -chdir="$ENV_DIR" output -json rds_configuration | jq -er '.identifier')"
DB_SUBNET_GROUP_NAME="$(terraform -chdir="$ENV_DIR" output -json rds_configuration | jq -er '.db_subnet_group_name')"
RDS_SECRET_ID="$(terraform -chdir="$ENV_DIR" output -raw rds_master_secret_arn)"
CENTRALIZED_LOGS_BUCKET_NAME="$(terraform -chdir="$ENV_DIR" output -raw centralized_logs_bucket_name)"
./scripts/validation/validate-backup.sh "$ENV_NAME"
```

These commands do not retrieve the database password. Do not paste secret values into logs or evidence.

### Confirm RDS Instance Exists

```bash
aws rds describe-db-instances \
  --db-instance-identifier "${RDS_IDENTIFIER}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'DBInstances[].[DBInstanceIdentifier,DBInstanceStatus,Engine,EngineVersion,DBInstanceClass,PubliclyAccessible,StorageEncrypted,MultiAZ]' \
  --output table
```

Expected:

- RDS instance exists
- Status is `available`
- Engine is PostgreSQL
- Publicly accessible is `false`
- Storage encrypted is `true`
- Multi-AZ equals `rds_configuration.multi_az`; normal production requires `true`

---

### Confirm RDS Subnet Group

```bash
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'DBSubnetGroups[].[DBSubnetGroupName,VpcId,SubnetGroupStatus]' \
  --output table
```

Expected:

- DB subnet group exists
- Subnet group is associated with the workload VPC
- Subnet group status is `Complete`

---

### Confirm RDS Log Exports

```bash
aws rds describe-db-instances \
  --db-instance-identifier "${RDS_IDENTIFIER}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'DBInstances[].{DBInstanceIdentifier:DBInstanceIdentifier,EnabledCloudwatchLogsExports:join(`, `, EnabledCloudwatchLogsExports)}' \
  --output table
```

Expected:

- `postgresql` log export is enabled
- `upgrade` log export is enabled

---

### Confirm RDS CloudWatch Log Groups

```bash
aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --log-group-name-prefix "/aws/rds/instance/${RDS_IDENTIFIER}/" \
  --query 'logGroups[].[logGroupName,retentionInDays,kmsKeyId]' \
  --output table
```

Expected:

- PostgreSQL log group exists
- Upgrade log group exists
- Retention equals the workload `effective_cloudwatch_retention_days` output
- KMS key is configured

---

### Confirm RDS Secret Exists

```bash
aws secretsmanager describe-secret \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --secret-id "${RDS_SECRET_ID}" \
  --query '[Name,ARN,KmsKeyId]' \
  --output table
```

Expected:

- RDS master secret exists
- Secret is encrypted with the Secrets Manager CMK

---

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

### Database Access

The RDS instance is private and not publicly accessible.

Access should come from approved internal workloads only.

Typical pattern:

```text
Compute Security Group -> Data/RDS Security Group -> PostgreSQL TCP/5432
```

Do not expose the RDS instance publicly.

---

### Credential Handling

The database password is generated and stored in Secrets Manager.

The module uses ephemeral and write-only secret handling patterns so the plaintext password is not intentionally persisted in Terraform state.

Do not output the database password from Terraform.

Do not hardcode database credentials in Terraform variables.

---

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

### RDS Fails to Create Due to Subnet Group Issues

Check:

- `data_private_subnet_ids_list` contains valid subnet IDs
- Subnets are in the expected VPC
- Subnets span enough Availability Zones for Multi-AZ deployment
- The DB subnet group was created successfully

Validation command:

```bash
aws rds describe-db-subnet-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --db-subnet-group-name "${DB_SUBNET_GROUP_NAME}"
```

---

### RDS Is Not Reachable from Compute

Check:

- RDS is in private data subnets
- Compute workloads are in expected private subnets
- Compute security group allows egress to the data security group on the database port
- Data security group allows ingress from the compute security group on the database port
- NACLs do not block traffic
- DNS resolution is working
- The RDS endpoint is being used instead of an IP address

---

### RDS Password or Secret Issues

Check:

- The Secrets Manager secret exists
- The secret version exists
- The Secrets Manager CMK allows required access
- Terraform provider version supports the ephemeral and write-only arguments used by this module
- The RDS instance depends on the generated password and secret version correctly

Useful command:

```bash
aws secretsmanager describe-secret \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --secret-id "${RDS_SECRET_ID}"
```

---

### RDS Logs Are Not Appearing in CloudWatch

Check:

- RDS log exports include `postgresql` and `upgrade`
- CloudWatch Log Groups exist
- Log groups are named correctly
- Log groups use a valid logs CMK
- RDS has generated log events
- KMS key policy allows CloudWatch Logs use as expected

---

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

- RDS is encrypted at rest.
- RDS is not publicly accessible.
- RDS uses private data subnets.
- RDS credentials are generated and stored in Secrets Manager.
- The RDS master password should not be output from Terraform.
- RDS PostgreSQL and upgrade logs are exported to CloudWatch Logs.
- RDS log groups are encrypted with the logs CMK.
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

- Private-by-default data placement
- KMS-backed encryption
- Centralized audit log storage
- Secure credential generation and storage
- Least privilege service delivery
- Long-term log retention
- Operational recoverability
- Explicit profile-derived RDS lifecycle settings, with separate documented S3 protection limits

---

## Notes

- This module should be deployed after networking and KMS resources exist.
- The RDS instance depends on private data subnets.
- The centralized logs bucket depends on the logs CMK.
- The RDS master secret depends on the Secrets Manager CMK.
- The logs bucket is intentionally protected by explicit deny statements.
- Production RDS lifecycle settings are supplied by baseline; logs-bucket Object Lock and destructive-lifecycle limits remain separate and require explicit review.
- The `data_sg_id` output should be used by the networking/security policy layer to define database access rules.

## Implementation Sources

- [Resource definitions](main.tf), [input declarations](variables.tf), and [outputs](outputs.tf)
- [Baseline module call](../../baseline/main.tf) and [profile/lifecycle resolution](../../baseline/locals.tf)
- [RDS/Backup validation](../../scripts/validation/validate-backup.sh)
- [Production retirement](../../docs/production-retirement.md)
