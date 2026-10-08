# Backup Module

## Overview

The `backup` module provides AWS Backup vaulting, scheduling, retention, tag-based resource selection, and optional Terraform-owned RDS Restore Testing. Baseline supplies profile-derived lifecycle protection and effective settings; this reusable module does not select a deployment profile itself.

Scheduled backup ownership remains separate from vault ownership:

- A dedicated backup vault is retained for the environment.
- The backup plan and backup selection are created only when `backup_enabled = true`.

When backups are enabled, supported resources tagged with `Backup = "true"` are selected by AWS Backup. When backups are disabled, the plan and selection are absent and workload resources are expected to use `Backup = "false"`.

This separation allows the baseline to disable scheduled backups for cost-sensitive environments without coupling that decision to deletion of the backup vault. Separately, `restore_testing_enabled` controls the Restore Testing plan and selection. The baseline enables Restore Testing for the production profile with scheduled Backup enabled.

This module's scheduled AWS Backup policy is distinct from the RDS instance's native automated-backup retention in `modules/storage`. Disabling scheduled AWS Backup is not a statement that RDS native automated backups are disabled.

---

## Architecture

The backup workflow is:

1. The baseline resolves the effective backup configuration:
   - backup enablement
   - backup schedule
   - recovery-point retention period

2. Workload resources receive the effective backup tag:
   ```hcl
   Backup = tostring(var.backup_enabled)
   ```

3. The module always creates the environment backup vault:
   - `aws_backup_vault.main`

4. When `backup_enabled = true`, the module creates:
   - `aws_backup_plan.main[0]`
   - `aws_backup_selection.main[0]`

5. The backup selection targets supported resources with:
   ```hcl
   Backup = "true"
   ```

6. The backup plan runs on the configured AWS Backup schedule.

7. Recovery points are retained according to `delete_backups_after_days`.

When `backup_enabled = false`, the backup vault remains present, but no backup plan or backup selection is created.

---

## Features

- **Conditional Backup Scheduling**
  - The backup plan and selection exist only when backups are enabled.
  - Disabling backups removes scheduled backup behavior without requiring removal of the environment backup vault.

- **Tag-Based Backup Selection**
  - Uses the configurable `backup_tag_key`.
  - The selected tag value is fixed to `"true"`.
  - Supported resources must therefore use `<backup_tag_key> = "true"` to participate in scheduled backups.

- **Automated Scheduling**
  - Uses an AWS Backup cron expression supplied by the baseline.
  - The baseline resolves the effective schedule from the deployment profile and any supported override.

- **Retention Policy**
  - Recovery-point retention is supplied as an effective number of days by the baseline.
  - The module applies that value through the backup plan lifecycle.

- **Dedicated Backup Vault**
  - A dedicated backup vault is retained per workload environment.
  - The vault is encrypted with the customer-managed KMS key supplied through `backup_vault_cmk_arn`.

- **IAM Role Integration**
  - The scheduled backup selection and RDS Restore Testing selection use the supplied AWS Backup service role.

- **RDS Restore Testing**
  - A conditional plan selects recent snapshot recovery points from the Terraform-owned vault.
  - A conditional selection targets the exact RDS ARN and restores into the supplied private DB subnet group/security groups.
  - Terraform configures the test; a successful apply alone is not evidence that a restore has executed.

- **Explicit Vault Lifecycle Policy**
  - `force_destroy` is a required module input.
  - Baseline keeps it `false` for production, including retirement, and `true` for development/minimal.

---

## Resources Created

### Always created

- `aws_backup_vault.main`

### Created only when `backup_enabled = true`

- `aws_backup_plan.main[0]`
- `aws_backup_selection.main[0]`

The backup plan contains a nested `daily-backups` rule. There is no separate Terraform `aws_backup_plan_rule` resource.

### Created only when `restore_testing_enabled = true`

- `aws_backup_restore_testing_plan.rds[0]`
- `aws_backup_restore_testing_selection.rds[0]`

The module's two enablement inputs control separate resource sets. The baseline composes them into its production policy; do not infer that this module independently enforces every baseline profile constraint.

---

## Requirements

- AWS Backup must be available in the target AWS account and Region.

- A customer-managed KMS key ARN must be supplied through:
  - `backup_vault_cmk_arn`

- A valid AWS Backup service role must be supplied through:
  - `backup_service_role_arn`

  The role should trust:

  ```text
  backup.amazonaws.com
  ```

  and include the permissions required for backup and restore operations, such as the AWS-managed policies:

  - `AWSBackupServiceRolePolicyForBackup`
  - `AWSBackupServiceRolePolicyForRestores`

- Resources intended for backup must use the configured backup tag key with the value:

  ```hcl
  Backup = "true"
  ```

  The default key is `Backup`.

- Workload resources that should not be selected for backup should use:

  ```hcl
  Backup = "false"
  ```

---

## Usage

### Example

The following excerpt belongs inside the existing baseline and uses its locals and other module outputs; it is not a standalone root. It includes every required input:

```hcl
module "backup" {
  source = "../modules/backup"

  name_prefix = local.name_prefix
  environment = var.environment

  backup_enabled            = local.effective_backup_enabled
  backup_schedule           = local.effective_backup_schedule
  backup_vault_cmk_arn      = module.security.backup_vault_cmk_arn
  delete_backups_after_days = local.effective_delete_backups_after_days
  backup_service_role_arn   = module.iam.backup_service_role_arn

  force_destroy = local.effective_backup_vault_force_destroy

  restore_testing_enabled                 = local.effective_restore_testing_enabled
  restore_testing_schedule                = local.effective_restore_testing_schedule
  restore_testing_start_window_hours      = local.effective_restore_testing_start_window_hours
  restore_testing_selection_window_days   = local.effective_restore_testing_selection_window_days
  restore_testing_validation_window_hours = local.effective_restore_testing_validation_window_hours
  restore_testing_rds_arn                 = module.storage.rds_configuration.arn
  restore_testing_db_subnet_group_name    = module.storage.rds_configuration.db_subnet_group_name
  restore_testing_vpc_security_group_ids  = [module.storage.data_sg_id]
}
```

An explicit tag key may also be supplied:

```hcl
backup_tag_key = "Backup"
```

The module does not resolve deployment profiles itself. It consumes already-resolved effective values from the baseline.

---

## Baseline Integration

The baseline owns deployment-profile behavior and resolves:

- `effective_backup_enabled`
- `effective_backup_schedule`
- `effective_delete_backups_after_days`
- `effective_backup_vault_force_destroy`
- `effective_restore_testing_enabled` and the effective Restore Testing schedule/windows

The current baseline behavior is:

| Deployment state | Backup enabled | Schedule | Retention |
|---|---:|---|---:|
| `production` default | `true` | `cron(0 5 * * ? *)` | 30 days |
| `development` default | `false` | `null` | `null` |
| `minimal` default | `false` | `null` | `null` |
| Non-production with backups explicitly enabled | `true` | `cron(0 5 * * ? *)` unless overridden | 7 days unless overridden |

When backups are disabled, the effective schedule and retention outputs are `null`.

The baseline also propagates `effective_backup_enabled` to workload modules so EC2 and RDS resources use:

```hcl
Backup = tostring(var.backup_enabled)
```

This keeps backup resource selection aligned with the effective backup state.

---

## RDS Restore Testing Contract

The plan name replaces hyphens in `name_prefix` with underscores and appends `_rds_restore_test`. The selection is named `rds_restore`.

| Setting | Implemented value or input |
|---|---|
| Recovery-point selection algorithm | `LATEST_WITHIN_WINDOW` |
| Included vault | This module's `aws_backup_vault.main.arn` |
| Recovery-point type | `SNAPSHOT` |
| Protected resource type | `RDS` |
| Protected resource | Exact `restore_testing_rds_arn` |
| IAM role | `backup_service_role_arn`, also used by scheduled backup selection |
| DB subnet group override | `restore_testing_db_subnet_group_name` |
| VPC security groups override | JSON-encoded `restore_testing_vpc_security_group_ids` |
| Public-access override | String `"false"` |
| Multi-AZ override for the temporary restored instance | String `"false"` |

The restored test instance is deliberately configured as private and Single-AZ. This does not change the source production RDS instance's Multi-AZ policy. The baseline supplies the source RDS subnet-group name and data security-group ID; this is infrastructure restore verification, not application/business-data validation.

The baseline's current enabled defaults are:

| Setting | Production Restore Testing value |
|---|---|
| Schedule | `cron(0 8 ? * SUN *)` |
| Start window | 2 hours |
| Recovery-point selection window | 2 days |
| Validation window | 1 hour |

These are derived in `baseline/locals.tf`, not defaults in the reusable module's input declarations. Development/minimal profiles do not enable Restore Testing through the baseline, even when ordinary scheduled Backup is explicitly enabled there. When disabled, the baseline's effective schedule/window values and this module's Restore Testing metadata outputs are `null`.

The module does not seed a recovery point, force an immediate restore, run SQL/application assertions, or implement a custom validation-result submitter. Keep test configuration, actual restore execution, validation results, and cleanup evidence separate.

---

## Required Resource Tagging

When backups are enabled, a resource is eligible for the module-managed backup selection only when its backup tag matches:

```hcl
tags = {
  Backup = "true"
}
```

With the default `backup_tag_key`, the backup selection is equivalent to:

```hcl
selection_tag {
  type  = "STRINGEQUALS"
  key   = "Backup"
  value = "true"
}
```

When backups are disabled, workload resources should instead resolve to:

```hcl
Backup = "false"
```

and the backup plan and selection should not exist.

---

## Inputs

All inputs except `backup_tag_key` have no default and must be supplied in a module call. Disabling a conditional resource does not make its input arguments optional. The baseline supplies `null` for unused schedule/window values; enabled resources require usable values.

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name_prefix` | `string` | Required | Prefix used for names |
| `environment` | `string` | Required | Environment tag |
| `backup_enabled` | `bool` | Required | Create the scheduled plan and selection |
| `backup_schedule` | `string` | Required | Scheduled backup expression; baseline passes `null` when disabled |
| `delete_backups_after_days` | `number` | Required | Recovery-point retention; baseline passes `null` when disabled |
| `backup_vault_cmk_arn` | `string` | Required | Vault encryption key ARN |
| `backup_service_role_arn` | `string` | Required | Role for backup and Restore Testing selections |
| `backup_tag_key` | `string` | `"Backup"` | Selection tag key; selected value is always `"true"` |
| `force_destroy` | `bool` | Required | Permit provider-driven recovery-point deletion during vault destruction |
| `restore_testing_enabled` | `bool` | Required | Create the RDS Restore Testing resources |
| `restore_testing_schedule` | `string` | Required | Restore Testing schedule |
| `restore_testing_start_window_hours` | `number` | Required | Scheduled restore start window |
| `restore_testing_selection_window_days` | `number` | Required | Eligible recovery-point window |
| `restore_testing_validation_window_hours` | `number` | Required | Restore Testing validation window |
| `restore_testing_rds_arn` | `string` | Required | Exact source RDS resource ARN |
| `restore_testing_db_subnet_group_name` | `string` | Required | DB subnet group for the restored instance |
| `restore_testing_vpc_security_group_ids` | `list(string)` | Required | Security groups for the restored instance |

The baseline does not expose every module input as a public workload override. In particular, its Restore Testing windows/schedule and vault deletion policy are derived rather than independent workload toggles.

---

## Outputs

| Name | Description |
|---|---|
| `backup_vault_name` | Name of the environment backup vault |
| `backup_plan_id` | ID of the AWS Backup plan when backups are enabled; `null` otherwise |
| `backup_vault_configuration` | Object containing `name`, `arn`, `kms_key_arn`, and Terraform `force_destroy` intent |
| `restore_testing_plan` | Plan `name`, `arn`, `schedule_expression`, `start_window_hours`, and `recovery_point_selection`; `null` when disabled |
| `restore_testing_selection` | Selection `name`, `restore_testing_plan_name`, `protected_resource_type`, `protected_resource_arns`, `iam_role_arn`, `restore_metadata_overrides`, and `validation_window_hours`; `null` when disabled |

---

## Validation

The workload validation suite includes `validate-backup.sh`.

Run it directly with:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/validation/validate-backup.sh dev
```

The validator checks the effective Terraform backup contract against live AWS state and also owns the RDS resilience comparison. Region must agree with the deployed workload output; `us-east-1` above is an explicit example, not a service-region fallback.

### When backups are disabled

The validator expects:

- `effective_backup_enabled = false`
- `effective_backup_schedule = null`
- `effective_delete_backups_after_days = null`
- the environment backup vault to remain present
- no environment backup plan
- no backup selection
- environment EC2 resources to use `Backup = "false"`
- the environment RDS instance to use `Backup = "false"`

### When backups are enabled

The validator expects:

- `effective_backup_enabled = true`
- a non-null effective backup schedule
- a non-null positive retention period
- the backup vault to exist and be encrypted
- exactly one environment backup plan
- the plan to contain the `daily-backups` rule
- the rule schedule to exactly match `effective_backup_schedule`
- the rule retention to exactly match `effective_delete_backups_after_days`
- the rule to target the environment backup vault
- exactly one backup selection
- the selection to use the expected service role
- the selection to use `<backup_tag_key> = "true"`
- environment EC2 and RDS resources to use `Backup = "true"`

When enabled, the validator also reports recovery points and recent backup jobs and fails if the latest backup job for a protected resource is failed, aborted, or expired.

---

### RDS resilience and lifecycle checks

In enabled and disabled scheduled-Backup states, the validator compares live RDS identity, Multi-AZ, DB subnet-group name, the exact VPC security-group set, deletion protection, native backup retention, public accessibility, and storage encryption with `rds_configuration`.

Deletion-time `skip_final_snapshot`, `delete_automated_backups`, and final-snapshot identifier semantics are checked as Terraform lifecycle intent/consistency; they are not all live RDS configuration fields. This is not an exhaustive database configuration audit: do not claim exact engine version, instance class, or the contents of the DB subnet group are checked by that equality expression.

### Restore Testing evidence limits

When enabled, the validator compares the live plan and selection with Terraform, including source RDS ARN, role, schedule/windows, vault selection, and private restore metadata. It separately reports the latest restore execution.

The absence of a Restore Testing job produces a warning rather than a failure; a pending/running job is also reported without establishing completed qualification. A latest restore status of `FAILED` or `ABORTED` fails validation. Application validation status `FAILED`/`TIMED_OUT` and cleanup `FAILED` are reported as warnings, not enforced as application-level acceptance gates. A suite `PASS` must not be presented as proof that a new restore, business-data validation, and cleanup all succeeded.

For release/recovery evidence, retain the actual job identifiers, source revision/configuration, completion state, validation scope, and temporary-resource cleanup result. Earlier qualification must not be relabeled as a new run against a different commit or configuration. Absence of current recovery points after a fresh deployment also must not be described as established recoverability.

---

## Security Considerations

- The backup vault is encrypted with a customer-managed KMS key.
- Backup access is controlled through IAM and the AWS Backup service role.
- Tag-based selection limits scheduled backups to resources explicitly marked for backup.
- Disabling scheduled backups does not require deleting the environment backup vault.
- Retaining the vault separately from the plan helps avoid coupling a cost-control setting to immediate backup-vault removal.

`force_destroy` is a required module input. Baseline supplies `false` for production in both normal and retirement mode, and `true` for development/minimal. It is provider destruction behavior, not a live vault attribute or a substitute for IAM restrictions.

The production retirement workflow uses separately authorized durable-data cleanup rather than setting this flag to `true`. Cleanup targets all recovery points in the Terraform-listed vault and requires deliberate retention decisions first. RDS final snapshots and retained native automated backups are separate from that vault cleanup. See [Production Retirement](../../docs/production-retirement.md), including its `prod`-only cleanup limitation.

---

## Limitations

- Backup schedules use AWS Backup cron expressions and are evaluated in UTC.
- The module does not currently configure cross-Region backup copies.
- The module does not currently configure cross-account backup copies.
- Backup Vault Lock is not currently configured.
- Cold-storage lifecycle configuration is not currently implemented.
- Restore Testing does not implement application-level data verification or guaranteed recovery objectives.
- Retirement mode does not disable the backup or Restore Testing schedules; coordinate active jobs and respect readiness failures.
- Resource-type support and AWS Backup service capabilities still depend on AWS Backup support for the selected resource.

---

## Future Enhancements

- Cross-Region backup replication
- Cross-account backup replication
- Backup Vault Lock
- Cold-storage lifecycle policies
- Backup-specific monitoring and alerting

---

## Summary

The `backup` module retains a dedicated encrypted backup vault for each workload environment and conditionally creates scheduled backup behavior when backups are enabled.

The baseline resolves backup enablement, schedule, and retention according to the deployment profile and supported overrides. The module then creates the backup plan and tag-based selection only when enabled, while workload resources expose `Backup = "true"` or `Backup = "false"` to keep live resource selection aligned with the effective backup contract.

Production adds protected vault lifecycle and Terraform-owned RDS Restore Testing. The module's configuration and metadata support verification; actual recovery and cleanup outcomes require execution evidence.

## Implementation References

- [Resources](main.tf), [inputs](variables.tf), and [outputs](outputs.tf)
- [Baseline module call](../../baseline/main.tf) and [effective settings](../../baseline/locals.tf)
- [Backup and RDS validator](../../scripts/validation/validate-backup.sh)
- [RDS resource implementation](../storage/main.tf)
- [Production retirement](../../docs/production-retirement.md)
