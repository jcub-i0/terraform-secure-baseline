# Backup Module

## Overview

The `Backup` module implements automated, tag-based backup and recovery for AWS resources using AWS Backup.

This module enables:

- Scheduled backups for EC2 (EBS volumes) and RDS (or any supported AWS Backup resource with the `Backup = "true"` tag)
- Centralized backup management via AWS Backup
- Tag-based resource selection
- Secure storage of recovery points in a dedicated backup vault
- Configurable retention policies

This ensures that critical infrastructure and data can be restored in the event of failure, compromise, or data loss.

---

## Architecture

The backup workflow is as follows:

1. Resources are tagged with:
- `Backup = "true"`

2. AWS Backup selects tagged resources via:
- `aws_backup_selection`

3. A scheduled backup plan runs:
- `aws_backup_plan`
- `aws_backup_plan_rule`

4. Backups are stored in:
- `aws_backup_vault`

5. Recovery points are created and retained according to policy

---

## Features

- **Tag-Based Backup Selection**
- Automatically includes supported resources with matching tags
- No manual resource registration required

- **Automated Scheduling**
- Uses cron-based scheduling (UTC)

- **Retention Policy**
- Configurable retention period (default: 30 days)

- **Centralized Backup Vault**
- Dedicated vault per environment

- **IAM Role Integration**
- Uses a least-privileged service role for AWS Backup and restore operations

---

## Resources Created

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`

---

## Requirements

- AWS Backup must be enabled in the target AWS account and region

- A valid AWS Backup service role must be configured:
  - Trusted entity: `backup.amazonaws.com`
  - Attached policies:
    - `AWSBackupServiceRolePolicyForBackup`
    - `AWSBackupServiceRolePolicyForRestores`

- Resources must be tagged appropriately for selection:
  ```hcl
  Backup = "true"
  ```

- AWS Backup must have resource type support enabled in:
  - `AWS Backup` ➔ `Settings` ➔ `Resource assignments`
  - Ensure EC2, RDS, and any other resources with the `Backup = "true"` tag are enabled

- IAM permissions must allow AWS Backup to:
  - Describe resources (i.e., EC2 tags)
  - Create snapshots
  - Write to the backup vault
  > The `AWSBackupServiceRolePolicyForBackup` and `AWSBackupServiceRolePolicyForRestores` AWS-managed roles fulfil these permission requirements

---

## Usage

### Example

```hcl
module "backup" {
source = "./modules/backup"

name_prefix                = var.name_prefix
backup_schedule            = "cron(5 5 * * ? *)"
backup_retention_days      = 30
backup_tag_key             = "Backup"
backup_tag_value           = "true"
backup_service_role_arn    = module.iam.backup_service_role_arn
}
```

---

## Required Resource Tagging

To include a resource in backups:

```hcl
tags = {
    Backup = "true"
}
```

Only resources with this tag will be backed up.

---

## Inputs

| Name | Description | Type | Default |
|------|-------------|------|---------|
| `name_prefix` |	Prefix for resource naming | string	| n/a |
| `backup_schedule` |	Cron expression (UTC) for backup execution | string | "cron(5 5 * * ? *)" |
| `backup_retention_days` | Number of days to retain backups | number | 30 |
| `backup_tag_key` | Tag key used for selection | string | "Backup" |
| `backup_tag_value` | Tag value used for selection | string | "true" |
| `backup_service_role_arn` | IAM role ARN used by AWS Backup | string | n/a |

---

## Outputs

| Name | Description |
|------|-------------|
| `backup_vault_name` | Name of the backup vault |
| `backup_plan_id` | ID of the backup plan |

---

## Validation

To confirm the module is working:

1. Navigate to:

`AWS Backup` ➔ `Jobs`
- Verify jobs complete successfully

2. Navigate to:

`AWS Backup` ➔ `Recovery points`
- Confirm recovery points exist

3. Restore a resource:

`AWS Backup` ➔ `Recovery points` ➔ `Restore`
- Validate successful recovery

4. Confirm tag-based selection:

- Resources with `Backup = "true"` are backed up
- Untagged resources are not included

---

## Security Considerations

- Backups are stored in a dedicated vault
- IAM role follows least-privilege principles
- Encryption is handled via AWS-managed or customer-managed KMS keys
- Backup access is controlled via IAM policies

---

## Limitations

- Backup schedules are defined in UTC (not local time)
- EC2 instance metadata is not backed up (only volumes)
- No cross-region replication (can be added later)
- No cold storage lifecycle configured (optional enhancement)

---

## Future Enhancements

- Cross-region backup replication
- Backup vault lock (immutability)
- Lifecycle policies (cold storage / archive tier)
- Backup monitoring and alerting

---

## Summary

This module provides a simple, scalable, and secure backup solution for AWS workloads
It ensures that critical resources can be automatically backed up and restored with minimal operational overhead.