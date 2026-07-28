# Patch Management Module

## Overview

The `patch_management` module provides scheduled operating system patching for
tagged Ubuntu EC2 instances through AWS Systems Manager Patch Manager.

It creates an SSM Maintenance Window, selects managed instances by tag, and runs
the AWS-managed `AWS-RunPatchBaseline` document with the `Install` operation.

## Features

- Creates a recurring SSM Maintenance Window
- Targets EC2 instances by tag
- Runs `AWS-RunPatchBaseline`
- Installs baseline-approved patches
- Reboots instances when required
- Supports configurable schedules and time zones
- Uses an externally managed maintenance-window IAM role

## Resources Created

- `aws_ssm_maintenance_window.patching`
- `aws_ssm_maintenance_window_target.patching`
- `aws_ssm_maintenance_window_task.patching`

## How It Works

1. The maintenance window starts according to `patch_schedule`.
2. Systems Manager selects managed instances matching:
   `tag:<patch_tag_key> = <patch_tag_value>`.
3. The maintenance-window task runs `AWS-RunPatchBaseline`.
4. Patch Manager installs patches approved by the applicable baseline.
5. The instance reboots when required.

## Maintenance Window Settings

| Setting | Value |
|---|---|
| Name | `<name_prefix>-weekly-patching` |
| Schedule | `var.patch_schedule` |
| Time zone | `var.schedule_timezone` |
| Duration | 3 hours |
| Cutoff | 1 hour |
| Enabled | `var.patching_enabled` |
| Allow unassociated targets | `false` |

The task uses:

| Setting | Value |
|---|---|
| Document | `AWS-RunPatchBaseline` |
| Operation | `Install` |
| Reboot option | `RebootIfNeeded` |
| Maximum concurrency | `1` |
| Maximum errors | `1` |
| Timeout | 3,600 seconds |
| Service role | `var.patch_maintenance_window_role_arn` |

## Patch Baseline Behavior

This module does not create a custom patch baseline.

Patch Manager installs updates approved by the baseline applicable to the
target instance. A node can therefore be reported as compliant even when
`apt list --upgradable` shows packages that are not approved by that baseline.

The compute module's first-boot `dist-upgrade` and this module's scheduled Patch
Manager execution serve different purposes:

- First boot updates the newly launched operating system.
- Patch Manager provides ongoing scheduled patching.

## Requirements

The following must already exist:

- Ubuntu EC2 instances registered as SSM managed nodes
- SSM Agent installed and running
- An EC2 instance profile with Systems Manager permissions
- The configured patch target tag
- A maintenance-window service role
- Network access to Systems Manager
- Network access to required Ubuntu repositories
- An applicable Patch Manager baseline

SSM connectivity does not prove that Ubuntu repositories are reachable. Private
instances still need NAT, an approved Network Firewall path, or an internal
package mirror.

## Usage

```hcl
module "patch_management" {
  source = "../../modules/patch_management"

  name_prefix = local.name_prefix
  environment = var.environment

  patch_maintenance_window_role_arn = module.iam.patch_maintenance_window_role_arn

  patch_tag_key   = "PatchGroup"
  patch_tag_value = var.patch_tag_value

  patch_schedule    = "cron(0 3 ? * SUN *)"
  schedule_timezone = "America/New_York"
  patching_enabled  = true
}
```

## Example Target Tag

```hcl
tags = {
  PatchGroup = "weekly-linux"
}
```

## Inputs

| Name | Type | Default | Required | Description |
|---|---|---|---:|---|
| `name_prefix` | `string` | n/a | Yes | Prefix used for resource names |
| `environment` | `string` | n/a | Yes | Environment name used in tags |
| `patch_tag_key` | `string` | `"PatchGroup"` | No | Tag key used to select patch targets |
| `patch_tag_value` | `string` | `"weekly-linux"` | No | Tag value used to select patch targets |
| `patch_schedule` | `string` | `"cron(0 3 ? * SUN *)"` | No | AWS cron schedule |
| `schedule_timezone` | `string` | `"America/New_York"` | No | IANA time zone for the schedule |
| `patching_enabled` | `bool` | `true` | No | Enables or disables the maintenance window |
| `patch_maintenance_window_role_arn` | `string` | n/a | Yes | IAM role used by the maintenance-window task |

The default schedule runs every Sunday at 3:00 AM Eastern Time.

## Outputs

This module currently exposes no Terraform outputs.

## Validation

Confirm the maintenance window:

```bash
aws ssm describe-maintenance-windows \
  --region "${AWS_REGION}" \
  --filters "Key=Name,Values=${NAME_PREFIX}-weekly-patching" \
  --query 'WindowIdentities[].[WindowId,Name,Enabled,Schedule,ScheduleTimezone,Duration,Cutoff]' \
  --output table
```

Confirm managed instances:

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' \
  --output table
```

Review maintenance-window executions:

```bash
aws ssm describe-maintenance-window-executions \
  --region "${AWS_REGION}" \
  --window-id "${WINDOW_ID}" \
  --query 'WindowExecutions[].[WindowExecutionId,Status,StartTime,EndTime]' \
  --output table
```

Review patch state:

```bash
aws ssm describe-instance-patch-states \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'InstancePatchStates[].[InstanceId,Operation,InstalledCount,MissingCount,FailedCount,OperationEndTime]' \
  --output table
```

Expected indicators:

- Maintenance-window execution status is successful
- Target instances are SSM `Online`
- `FailedCount` is `0`
- Compliance matches the applicable patch baseline

## Troubleshooting

### No Instances Are Patched

Check:

- The maintenance window is enabled
- Instances have the exact target tag
- SSM Agent is online
- The maintenance-window target uses the expected tag key and value
- The task references the registered target

### Patch Installation Fails

Check:

- Ubuntu repository DNS resolution
- Compute TCP/443 egress
- Private subnet routing
- NAT Gateway or Network Firewall availability
- Instance-profile permissions
- Maintenance-window service-role permissions
- Disk space and APT lock state

### Some Packages Remain Upgradable

Patch Manager installs baseline-approved patches, not necessarily every package
shown by `apt list --upgradable`.

Review the applicable patch baseline and Patch Manager compliance before
treating remaining packages as a failure.

## Operational Notes

- Instances are patched one at a time because `max_concurrency = "1"`.
- One failed target can stop later targets because `max_errors = "1"`.
- `RebootIfNeeded` may restart instances during the maintenance window.
- Setting `patching_enabled = false` disables scheduled execution but does not
  remove the maintenance-window resources.
- Larger fleets may require a longer window or higher concurrency.

## Related Modules

- `compute`
- `iam`
- `networking`
- `vpc_endpoints`
- `firewall`