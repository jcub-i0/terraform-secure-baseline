# Backup Module

## Overview

The `backup` module provides AWS Backup vaulting, scheduling, retention, and tag-based resource selection for workload resources.

The module is designed around two distinct states:

- A dedicated backup vault is retained for the environment.
- The backup plan and backup selection are created only when `backup_enabled = true`.

When backups are enabled, supported resources tagged with `Backup = "true"` are selected by AWS Backup. When backups are disabled, the plan and selection are absent and workload resources are expected to use `Backup = "false"`.

This separation allows the baseline to disable scheduled backups for cost-sensitive environments without coupling that decision to deletion of the backup vault.

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
  - The backup selection uses the supplied AWS Backup service role.

---

## Resources Created

### Always created

- `aws_backup_vault.main`

### Created only when `backup_enabled = true`

- `aws_backup_plan.main[0]`
- `aws_backup_selection.main[0]`

The backup plan contains a nested `daily-backups` rule. There is no separate Terraform `aws_backup_plan_rule` resource.

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

The module is normally called by the baseline after deployment-profile and override resolution:

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

| Name | Description | Type | Default |
|---|---|---|---|
| `name_prefix` | Prefix used for module resource names | `string` | n/a |
| `environment` | Workload environment name used in resource tags | `string` | n/a |
| `backup_enabled` | Whether to create the AWS Backup plan and backup selection | `bool` | n/a |
| `backup_schedule` | AWS Backup schedule expression used by the backup plan when backups are enabled | `string` | n/a |
| `delete_backups_after_days` | Number of days to retain AWS Backup recovery points before deletion when backups are enabled | `number` | n/a |
| `backup_vault_cmk_arn` | ARN of the customer-managed KMS key used to encrypt the backup vault | `string` | n/a |
| `backup_service_role_arn` | IAM role ARN used by AWS Backup for resource backups | `string` | n/a |
| `backup_tag_key` | Tag key used by the backup selection | `string` | `"Backup"` |

The tag value selected by the module is intentionally fixed to `"true"`.

---

## Outputs

| Name | Description |
|---|---|
| `backup_vault_name` | Name of the environment backup vault |
| `backup_plan_id` | ID of the AWS Backup plan when backups are enabled; `null` otherwise |

---

## Validation

The workload validation suite includes `validate-backup.sh`.

Run it directly with:

```bash
AWS_PROFILE=dev ./scripts/validation/validate-backup.sh dev
```

The validator checks the effective Terraform backup contract against live AWS state.

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

## Security Considerations

- The backup vault is encrypted with a customer-managed KMS key.
- Backup access is controlled through IAM and the AWS Backup service role.
- Tag-based selection limits scheduled backups to resources explicitly marked for backup.
- Disabling scheduled backups does not require deleting the environment backup vault.
- Retaining the vault separately from the plan helps avoid coupling a cost-control setting to immediate backup-vault removal.

`force_destroy` is currently enabled on the module-managed vault and should be reviewed before production use.

---

## Limitations

- Backup schedules use AWS Backup cron expressions and are evaluated in UTC.
- The module does not currently configure cross-Region backup copies.
- The module does not currently configure cross-account backup copies.
- Backup Vault Lock is not currently configured.
- Cold-storage lifecycle configuration is not currently implemented.
- Resource-type support and AWS Backup service capabilities still depend on AWS Backup support for the selected resource.

---

## Future Enhancements

- Cross-Region backup replication
- Cross-account backup replication
- Backup Vault Lock
- Cold-storage lifecycle policies
- Backup-specific monitoring and alerting
- Production hardening of vault deletion behavior

---

## Summary

The `backup` module retains a dedicated encrypted backup vault for each workload environment and conditionally creates scheduled backup behavior when backups are enabled.

The baseline resolves backup enablement, schedule, and retention according to the deployment profile and supported overrides. The module then creates the backup plan and tag-based selection only when enabled, while workload resources expose `Backup = "true"` or `Backup = "false"` to keep live resource selection aligned with the effective backup contract.