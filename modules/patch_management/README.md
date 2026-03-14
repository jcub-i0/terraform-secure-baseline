# Patch Management

## Overview

The 'patch_management' module provides automated weekly OS patching for Ubuntu EC2 instances using AWS Systems Manager Patch Manager and a Systems Manager Maintenance Window.

This module is designed for private-subnet workloads and integrates with the broader `tf-secure-baseline` environment by targeting instances via tags instead of hardcoded instance IDs.

## Features

- Creates an SSM Maintenance Window for scheduled patching
- Targets EC2 instances dynamically using tags
- Runs the `AWS-RunPatchBaseline` document with `Install`
- Reboots instances automatically when required
- Supports configurable schedules and time zones
- Uses an externally managed IAM role for the maintenance window task

## Resources Created

This module creates the following AWS resources:

- `aws_ssm_maintenance_window`
- `aws_ssm_maintenance_window_target`
- `aws_ssm_maintenance_window_task`

## How it Works

1. A weekly SSM Maintenance Window is created.
2. EC2 instances with the configured patch tag are registered as patch targets.
3. During the scheduled window, Systems Manager runs `AWS-RunPatchBaseline`.
4. Patch Manager applies patches according to the active patch baseline.
5. If required, the instance is rebooted automatically.

## Important Behavior

Patch compliance is based on the active Patch Manager baseline.

This means:

- A node can be reported as **compliant** even if `apt list --upgradable` still shows some packages.
- By default, Patch Manager may install only the updates required by the current baseline, rather than every available package.

For this reason, Patch Manager compliance should be treated as the primary AWS-side validation of patch success.

## Requirements

The following must already be in place for this module to work correctly:

- EC2 instances must be managed by AWS Systems Manager
- SSM Agent must be installed and running on target instances
- Target instances must be tagged with the configured patch group tag
- Target instances must be able to reach required Ubuntu repositories
- Required VPC endpoints / networking for Systems Manager must already exist
- A valid IAM role for the maintenance window task must already exist

## Usage

```hcl
module "patch_management" {
  source = "./modules/patch_management"

  cloud_name                        = var.cloud_name
  patch_maintenance_window_role_arn = module.iam.patch_maintenance_window_role_arn
  patch_tag_value                   = var.patch_tag_value
}
```

### Example EC2 Tag

Instances must include the configured patch group tag in order to be targeted by the maintenance window, as shown below:
```hcl
tags = {
  Name       = "EC2-app-1"
  Terraform  = "true"
  PatchGroup = "weekly-linux"
}
```

### Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `cloud_name` | Name of the cloud environment | `string` | n/a | yes |
| `patch_tag_key` | Tag key used to target patchable instances | `string` | `"PatchGroup"` | no |
| `patch_tag_value` | Tag value used to target patchable instances | `string` | `"weekly-linux"` | no |
| `patch_schedule` | Cron-formatted schedule for patches to take place | `string` | `"cron(0 3 ? * SUN)"` | no |
| `schedule_timezone` | Timezone used by the maintenance window schedule | `string` | `"America/New_York"` | no |
| `patching_enabled` | Enable or disable patching | `bool` | `true` | no |
| `patch_maintenance_window_role_arn` | ARN of the IAM role used by the maintenance window task | `string` | n/a | yes |

### Outputs

> This module currently does not expose outputs.

### Validation

Successful module operation can be validated through:
- Systems Manager ➔ Maintenance Windows ➔ Execution History
- Systems Manager ➔ Run Command ➔ Command History
- Systems Manager ➔ Patch Manager ➔ Compliance

Expected successful indicators include:

- Maintenance Window execution status = `Success`
- Run Command status = `Success`
- Patch compliance = `Compliant`

## Notes

- This module is intended for Ubuntu-based EC2 instances.
- The maintenance window task uses `max_concurrency = "1"` to patch one instance at a time.
- The task uses `RebootIfNeeded`, so instances may restart during patching.
- This module assumes patch baselines are managed by AWS Patch Manager defaults unless customized.

## Related Modules

This module is intended to work alongside:

- `compute`
- `iam`
- `networking`
- `vpc_endpoints`
- `firewall`

## Future Enhancements

Potential future improvements include:

- Custom patch baselines
- Patch groups for multiple environments
- Patch compliance outputs
- SNS notifications for patch window results
- Maintenance window task logging enhancements