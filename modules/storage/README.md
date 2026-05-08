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

The security group itself is created in this module. Traffic rules for database access should be managed intentionally so that only approved workload security groups can reach the database port.

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

Current configuration:

| Setting | Value |
|---|---|
| Engine | PostgreSQL |
| Engine version | `16.6` |
| Instance class | `db.t4g.micro` |
| Allocated storage | `50 GB` |
| Maximum allocated storage | `200 GB` |
| Storage type | `gp3` |
| Storage encryption | Enabled |
| Multi-AZ | Enabled |
| Publicly accessible | Disabled |
| Database name | `appdb` |
| Backup retention | `14 days` |
| Backup window | `03:00-04:00` |
| Maintenance window | `sun:05:00-sun:06:00` |
| CloudWatch log exports | `postgresql`, `upgrade` |
| Performance Insights | Enabled |
| Auto minor version upgrade | Enabled |

The instance is tagged with:

```text
Backup = true
```

This allows the broader backup module to select the database for backup coverage if tag-based backup selection is enabled.

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

- 30-day retention
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

The RDS instance then uses the generated password through the write-only RDS password argument.

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

The 2555-day retention period is approximately 7 years.

This supports long-term audit retention while reducing storage cost over time.

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

This protects log objects from deletion.

---

### Restrict Bucket Policy Changes

The bucket policy denies bucket policy modification unless the caller is listed in:

```hcl
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

```hcl
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

This helps enforce encrypted log storage.

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

```hcl
"aws:SourceAccount" = var.account_id
```

---

### Allow Firewall Log Delivery

The bucket policy allows AWS log delivery to write firewall logs under:

```text
firewall/flow/AWSLogs/<account_id>/*
```

The policy allows the log delivery service principal:

```text
delivery.logs.amazonaws.com
```

This supports centralized firewall flow log delivery into the logs bucket.

---

## Important Production Notes

Several resources currently include comments indicating settings that should be changed for production. They do not have the production-ready values to enable testing and demos during initial deployment.

### RDS Deletion Protection

Current setting:

```hcl
deletion_protection = false
```

For production, this should generally be changed to:

```hcl
deletion_protection = true
```

This helps prevent accidental deletion of the RDS instance.

---

### RDS Final Snapshot

Current setting:

```hcl
skip_final_snapshot = true
```

For production, this should generally be changed to:

```hcl
skip_final_snapshot = false
```

This ensures a final snapshot is created before database deletion.

---

### Centralized Logs Bucket Object Lock

Current setting:

```hcl
object_lock_enabled = false
```

For production or audit-sensitive environments, consider enabling Object Lock at bucket creation time.

Important:

Object Lock generally must be enabled when the bucket is created. It cannot be casually enabled later on an existing bucket.

---

### Centralized Logs Bucket Force Destroy

Current setting:

```hcl
force_destroy = true
```

For production, this should generally be changed to:

```hcl
force_destroy = false
```

This helps prevent Terraform from deleting a non-empty logs bucket.

---

### Centralized Logs Bucket Prevent Destroy

Current setting:

```hcl
prevent_destroy = false
```

For production, this should generally be changed to:

```hcl
prevent_destroy = true
```

This provides an additional Terraform-level guardrail against accidental deletion.

---

## Inputs

| Name | Description | Required |
|---|---|---:|
| `name_prefix` | Prefix used for resource naming | Yes |
| `environment` | Environment name, such as `dev`, `staging`, or `prod` | Yes |
| `vpc_id` | ID of the VPC where the data security group is created | Yes |
| `db_port` | Database port used by security policy rules | Yes |
| `compute_sg_id` | Security group ID for compute workloads that may access the database | Yes |
| `data_private_subnet_ids_list` | List of private data subnet IDs used by the DB subnet group | Yes |
| `db_username` | Base database username; environment is appended to it | Yes |
| `logs_cmk_arn` | KMS CMK ARN used for centralized logs and RDS log group encryption | Yes |
| `account_id` | AWS account ID used in bucket policy conditions and log delivery paths | Yes |
| `random_id` | Random string used to make the centralized logs bucket name globally unique | Yes |
| `cloudtrail_arn` | CloudTrail ARN input for integration with logging resources | Yes |
| `bucket_admin_principals` | List of IAM principal ARNs allowed to modify protected bucket settings | Yes |
| `secrets_manager_cmk_arn` | KMS CMK ARN used to encrypt the RDS master secret | Yes |
| `cloud_name` | Cloud or project name used by the broader baseline | Yes |

---

## Outputs

| Name | Description |
|---|---|
| `centralized_logs_bucket_name` | Name of the centralized logs S3 bucket |
| `centralized_logs_bucket_arn` | ARN of the centralized logs S3 bucket |
| `centralized_logs_bucket_id` | ID of the centralized logs S3 bucket |
| `data_sg_id` | ID of the RDS/data security group |

---

## Usage Example

```hcl
module "storage" {
  source = "../modules/storage"

  name_prefix                  = local.name_prefix
  environment                  = var.environment
  vpc_id                       = module.networking.vpc_id
  account_id                   = data.aws_caller_identity.current.account_id
  random_id                    = random_id.random_id.hex

  db_port                      = var.db_port
  db_username                  = var.db_username

  compute_sg_id                = module.compute.compute_sg_id
  data_private_subnet_ids_list = module.networking.data_private_subnet_ids_list

  logs_cmk_arn                 = module.security.logs_cmk_arn
  secrets_manager_cmk_arn      = module.security.secrets_manager_cmk_arn
  cloudtrail_arn               = module.logging.cloudtrail_arn
  bucket_admin_principals      = var.bucket_admin_principals
}
```

---

## Validation

### Confirm RDS Instance Exists

```bash
aws rds describe-db-instances \
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
- Multi-AZ is enabled

---

### Confirm RDS Subnet Group

```bash
aws rds describe-db-subnet-groups \
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
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'DBInstances[].[DBInstanceIdentifier,EnabledCloudwatchLogsExports]' \
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
  --log-group-name-prefix "/aws/rds/instance" \
  --query 'logGroups[].[logGroupName,retentionInDays,kmsKeyId]' \
  --output table
```

Expected:

- PostgreSQL log group exists
- Upgrade log group exists
- Retention is 30 days
- KMS key is configured

---

### Confirm RDS Secret Exists

```bash
aws secretsmanager list-secrets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'SecretList[?contains(Name, `/database/rds-master-`)].[Name,ARN,KmsKeyId]' \
  --output table
```

Expected:

- RDS master secret exists
- Secret is encrypted with the Secrets Manager CMK

---

### Confirm Centralized Logs Bucket Exists

List the S3 buckets in the account:

```bash
aws s3 ls \
  --profile "${AWS_PROFILE}"
```

Expected:

- The Terraform state bucket is listed.
- The centralized logs bucket is listed.
- The centralized logs bucket name includes the expected naming pattern:

```text
<name_prefix>-centralized-logs-<random_id>
```

Notes:

- This confirms the bucket is visible to the caller.
- This command is useful as a quick account-level sanity check.
- Use the centralized logs bucket name from this output for the more specific bucket validation commands below.

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
  --bucket "${CENTRALIZED_LOGS_BUCKET}" \
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
  --bucket "${CENTRALIZED_LOGS_BUCKET}" \
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
  --bucket "${CENTRALIZED_LOGS_BUCKET}" \
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
  --bucket "${CENTRALIZED_LOGS_BUCKET}" \
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
- `AWSCloudTrailAclCheck`
- `AWSCloudTrailWrite`
- `AllowFirewallLogDeliveryAclCheck`
- `AllowFirewallLogDeliveryWrite`

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

These principals are allowed to modify protected bucket settings such as:

- Bucket policy
- Versioning configuration

Include only trusted administrative principals.

Common examples may include:

- Account admin role
- Break-glass role
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
- Prefix matches `firewall/flow/AWSLogs/<account_id>/*`
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
- Production-aligned security defaults

---

## Notes

- This module should be deployed after networking and KMS resources exist.
- The RDS instance depends on private data subnets.
- The centralized logs bucket depends on the logs CMK.
- The RDS master secret depends on the Secrets Manager CMK.
- The logs bucket is intentionally protected by explicit deny statements.
- For production, review deletion protection, final snapshots, Object Lock, force destroy, and prevent destroy settings before deployment.
- The `data_sg_id` output should be used by the networking/security policy layer to define database access rules.