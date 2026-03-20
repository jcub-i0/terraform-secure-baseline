# Backup Module

## Overview

The `Backup` module implements automated, tag-based backup and recovery for AWS resources using AWS Backup.

This module enables:

- Scheduled backups for EC2 (EBS volumes) and RDS (or any resource with 'Backup' tag set to 'true')
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
- Automatically includes resources with matching tags
- No manual resource registration required

- **Automated Scheduling**
- Uses cron-based scheduling (UTC)

- **Retention Policy**
- Configurable retention period (default: 30 days)

- **Centralized Backup Vault**
- Dedicated vault per environment

- **IAM Role Integration**
- Uses a least-privileged service role for AWS Backup and Restore

---

## Resources Created

- `aws_backup_vault`
- `aws_backup_plan`
- `aws_backup_selection`

---

## Requirements

- AWS Backup must be enabled in the account
- EC2 instances must:
* Use EBS-backed volumes
* Be in a supported region
- RDS instances must have automated backups enabled
- Resources must be tagged appropriately

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