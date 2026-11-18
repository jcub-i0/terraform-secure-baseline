# Database Module

## Ownership

The `database` module owns the private PostgreSQL database capability. It is
composed directly alongside [storage](../storage/README.md) in
[baseline](../../baseline/main.tf). Storage owns the centralized S3 logs bucket;
this module has no S3 resources or dependency on the storage module.

Shared KMS keys remain in [security](../security/README.md), scheduled backups and
Restore Testing in [backup](../backup/README.md), and cross-component security
group rules in [networking security policy](../networking/security_policy/README.md).
Baseline resolves profile defaults and production-retirement settings before
passing them to this module.

## Resources

| File | Declarations |
|---|---|
| [main.tf](main.tf) | `aws_db_instance.main`, `aws_security_group.data`, `aws_security_group.restore_test_db`, `aws_db_subnet_group.data`, `local.rds_identifier` |
| [iam.tf](iam.tf) | Enhanced Monitoring role and policy attachment, trust-policy document, AWS partition lookup |
| [logging.tf](logging.tf) | PostgreSQL and upgrade CloudWatch log groups |
| [secrets.tf](secrets.tf) | Master secret and write-only secret version, ephemeral password generator and secret-version read |

There are ten managed-resource declarations. Only `restore_test_db` is
conditional: `restore_testing_enabled` creates instance `[0]`; otherwise the
security group is absent and its output is `null`. Both security groups use
`revoke_rules_on_delete = true` and have no inline traffic rules.

The data SG is assigned to the source RDS instance. The dedicated restore SG is
passed separately to Backup's Restore Testing metadata. Optional
[Restore Validation](../restore_validation/README.md) uses its own worker SG and
read-only credential secret; it does not receive this module's master password.

## Database Configuration

| Setting | Configuration |
|---|---|
| Identifier | `${name_prefix}-saas-db` |
| Engine | PostgreSQL `17.10` |
| Instance class | Required `rds_instance_class` input |
| Storage | 50 GiB allocated, 200 GiB autoscaling maximum, `gp3`, encrypted |
| Placement | Supplied private data subnets and source database SG |
| Multi-AZ | Supplied `rds_multi_az`; baseline enforces it for production |
| Public access | Disabled |
| Database name | `appdb` |
| Master username | `${db_username}${environment}` |
| Native backup retention | 14 days |
| Backup window | `03:00-04:00` |
| Maintenance window | `sun:05:00-sun:06:00` |
| Log exports | `postgresql`, `upgrade` |
| Enhanced Monitoring | 60 seconds, dedicated role and AWS-managed `AmazonRDSEnhancedMonitoringRole` policy |
| Performance Insights | Enabled with `rds_performance_insights_cmk_arn` |
| Minor version upgrades | Automatic |
| Snapshot tags | Copied from the instance |

The resource omits both an explicit `port` and a database-storage `kms_key_id`.
Baseline's `db_port` controls consumer/security-rule configuration; changing it
alone does not migrate the RDS listener. `rds_port` reports the actual resource
port. Neither the logs key nor the Secrets Manager key is explicitly assigned to
RDS storage encryption.

Log groups retain the names `/aws/rds/instance/<identifier>/postgresql` and
`/aws/rds/instance/<identifier>/upgrade`, use `logs_cmk_arn`, and apply the supplied
retention. RDS explicitly depends on both log groups and the Enhanced Monitoring
policy attachment. The monitoring role trusts `monitoring.rds.amazonaws.com`;
its policy ARN uses the module-local AWS partition lookup.

## Credentials

The ephemeral password generator uses length `20`, excludes punctuation, and
requires each included character type. The secret retains the prefix
`${name_prefix}/database/rds-master-` and uses `secrets_manager_cmk_arn`.

The generated value is JSON-encoded under the `password` key and supplied through
`aws_secretsmanager_secret_version.rds_master.secret_string_wo`. Its
`secret_string_wo_version` is fixed at `1`. RDS receives the same generated value
directly through `password_wo`; `password_wo_version` references that managed
secret-version counter.

The module also reads the secret version ephemerally, with an explicit dependency
on the managed secret version. That read is not the value supplied to RDS and is
retained as part of the existing credential implementation.

Ephemeral/write-only attributes avoid persisting the generated plaintext password
in Terraform state and saved plans. Secret identifiers and non-secret metadata
remain visible. There is no password output, ordinary password input, or
scheduled rotation mechanism. Never place secret values in logs, documentation,
local files, or validation evidence.

## Lifecycle

The module applies the supplied lifecycle settings without resolving profiles:

| Baseline posture | Deletion protection | Final snapshot | Delete automated backups |
|---|---|---|---|
| Normal production | Enabled | Required | `false` |
| Production retirement | Disabled | Required | `false` |
| Development/minimal | Disabled | Skipped | `true` |

Production's final snapshot identifier is derived by baseline as
`<name_prefix>-saas-db-final-<random_id>`. When `rds_skip_final_snapshot` is true,
the resource's final snapshot identifier is `null`. Production remains Multi-AZ
during retirement. The `Backup` tag is `tostring(backup_enabled)`; disabling
scheduled AWS Backup does not disable the instance's native backup retention.

These are configuration and deletion-time intent, not proof of completed
snapshots or recovery. See [production retirement](../../docs/production-retirement.md).

## Inputs

All inputs are required unless a default is listed. Names, types, and nullability
match the extracted interface; `cloudwatch_retention_days` remains a `string`.

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name_prefix` | `string` | Required | Resource naming |
| `environment` | `string` | Required | Tags and master-username suffix |
| `vpc_id` | `string` | Required | VPC for both security groups |
| `data_private_subnet_ids_list` | `list(string)` | Required | DB subnet-group membership |
| `rds_instance_class` | `string` | Required | Instance class |
| `rds_multi_az` | `bool` | Required | Source database Multi-AZ setting |
| `db_username` | `string` | Required | Master-username base |
| `logs_cmk_arn` | `string` | Required | RDS log-group encryption |
| `cloudwatch_retention_days` | `string` | Required | RDS log retention |
| `secrets_manager_cmk_arn` | `string` | Required | Master-secret encryption |
| `rds_performance_insights_cmk_arn` | `string` | Required | Performance Insights encryption |
| `backup_enabled` | `bool` | Required | Resolved enablement for the Backup tag |
| `restore_testing_enabled` | `bool` | `false`; non-nullable | Dedicated restore SG creation |
| `rds_deletion_protection` | `bool` | Required | Native deletion protection |
| `rds_skip_final_snapshot` | `bool` | Required | Final-snapshot behavior |
| `rds_delete_automated_backups` | `bool` | Required | Automated-backup deletion behavior |
| `rds_final_snapshot_identifier` | `string` | `null` | Final snapshot identifier when enabled |

## Outputs

| Name | Contract |
|---|---|
| `data_sg_id` | Source database SG ID |
| `restore_test_db_sg_id` | Dedicated restore SG ID, or `null` when disabled |
| `rds_address` | Database DNS address |
| `rds_endpoint` | Connection endpoint in address:port form |
| `rds_port` | Actual database port |
| `rds_database_name` | Initial database name |
| `rds_master_username` | Configured master username |
| `rds_master_secret_arn` | Secret ARN only; no credential value |
| `rds_configuration` | Resource-backed identity, monitoring, networking, resilience and lifecycle metadata |

`rds_configuration` preserves these fields: `identifier`, `arn`,
`monitoring_interval`, `monitoring_role_arn`, `performance_insights_enabled`,
`performance_insights_kms_key_id`, `multi_az`, `instance_class`,
`db_subnet_group_name`, `vpc_security_group_ids`, `deletion_protection`,
`backup_retention_period`, `publicly_accessible`, `storage_encrypted`,
`skip_final_snapshot`, `delete_automated_backups`, and `final_snapshot_identifier`.

Use the complete [baseline module call](../../baseline/main.tf) for composition.
Database SG outputs feed security policy and consumers directly; no forwarding
through the S3 storage module is needed.

## Validation

Offline source comparisons, Terraform validation, and the existing Restore
Testing opt-in/isolation regressions check configuration and interface behavior.
They do not prove live infrastructure equivalence or database recovery.

For a separately authorized deployed workload,
[validate-backup.sh](../../scripts/validation/validate-backup.sh) compares the
resource-backed identity, Multi-AZ, subnet-group name, SG set, deletion protection,
backup retention, public access, encryption, Enhanced Monitoring, and Insights
configuration. It checks final-snapshot and automated-backup deletion settings
as Terraform intent. It does not compare every engine/version, instance-class,
storage or subnet-membership setting, run SQL, or force failover.

Networking and compute/ECS validators check their own subnet and SG contracts.
The optional Restore Validation workflow provides separate SQL recovery checks.
Do not infer that a backup-validator PASS proves SQL recovery or completed cleanup.

## Implementation Sources

- [Inputs](variables.tf) and [outputs](outputs.tf)
- [Baseline composition](../../baseline/main.tf) and [effective settings](../../baseline/locals.tf)
- [Networking security policy](../networking/security_policy/main.tf)
- [Backup and Restore Testing](../backup/main.tf)
- [Restore Validation](../restore_validation/README.md)
