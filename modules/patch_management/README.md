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
| Run Command delivery timeout | 3,600 seconds |
| Service role | `var.patch_maintenance_window_role_arn` |

The window cutoff stops scheduling new tasks one hour before the three-hour
window ends; it is not a guarantee that every update or reboot finishes in that
window. `timeout_seconds` is the Run Command delivery/start timeout, not an
explicit patch-document execution timeout. The module supplies neither a
specific document revision/hash nor an `executionTimeout` parameter. See the
[AWS Run Command parameter semantics](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_MaintenanceWindowRunCommandParameters.html).

## Patch Baseline Behavior

This module does not create a custom patch baseline, patch-group-to-baseline
registration, or an SSM State Manager association. The `PatchGroup` tag is a
target selector here; the document/baseline used at execution remains an
additional fact to inspect.

Patch Manager installs updates approved by the baseline applicable to the
target instance. A node can therefore be reported as compliant even when
`apt list --upgradable` shows packages that are not approved by that baseline.

The compute module's first-boot `dist-upgrade` and this module's scheduled Patch
Manager execution serve different purposes:

- First boot updates the newly launched operating system.
- Patch Manager provides ongoing scheduled patching.

The target is selected by a single tag key/value in the execution account and
Region. It does not also filter by VPC, Environment, Ubuntu platform, Terraform
ownership, or `IsolationAllowed`. Another managed node with the same tag can
be included; a quarantined instance retains its patch tag and is not excluded
by this module.

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

The following is a direct child-module example from a caller beside
`modules/`. In the integrated baseline, only naming, the maintenance-window
role, and `patch_tag_value` are passed to this module. The other settings use
the defaults below. In particular, the deployment profile does not disable
this schedule, and declaring a new `TF_VAR_patching_enabled` on a root that
has no such input does not wire an override into this module. Change the
calling interface deliberately when an override is required.

```hcl
module "patch_management" {
  source = "../modules/patch_management"

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

Run these local Bash examples from the repository root after initializing the
selected workload backend with reviewed settings. Set the intended account
independently of the current credentials. `us-east-1` and `dev` are examples,
not universal deployment settings. These examples use a named AWS profile;
GitHub OIDC jobs instead use their configured default credential chain.

```bash
export AWS_PAGER=""
export AWS_PROFILE="dev"
export AWS_REGION="us-east-1"
export ENVIRONMENT="dev"
export EXPECTED_ACCOUNT_ID="<WORKLOAD-ACCOUNT-ID>"

prepare_workload_context() {
  local caller
  case "${ENVIRONMENT:-}" in
    dev|staging|prod) ;;
    *) printf '%s\n' 'Select dev, staging, or prod.' >&2; return 1 ;;
  esac
  : "${AWS_PROFILE:?Set the workload profile}"
  : "${AWS_REGION:?Set the service Region}"
  [[ "${EXPECTED_ACCOUNT_ID:-}" =~ ^[0-9]{12}$ ]] || {
    printf '%s\n' 'Set the intended 12-digit account ID.' >&2; return 1;
  }
  caller="$(aws sts get-caller-identity --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --query Account --output text)" || return 1
  [[ "$caller" == "$EXPECTED_ACCOUNT_ID" ]] || {
    printf '%s\n' 'AWS caller account mismatch.' >&2; return 1;
  }
  WORKLOAD_ROOT="environments/${ENVIRONMENT}"
  WORKLOAD_OUTPUTS_JSON="$(terraform -chdir="$WORKLOAD_ROOT" output -json)" || return 1
  jq -e --arg region "$AWS_REGION" '
    .primary_region.value == $region and
    (.name_prefix.value | type == "string" and length > 0) and
    (.vpc_id.value | type == "string" and startswith("vpc-"))
  ' <<< "$WORKLOAD_OUTPUTS_JSON" >/dev/null || return 1
  NAME_PREFIX="$(jq -r '.name_prefix.value' <<< "$WORKLOAD_OUTPUTS_JSON")"
  VPC_ID="$(jq -r '.vpc_id.value' <<< "$WORKLOAD_OUTPUTS_JSON")"
  export WORKLOAD_ROOT NAME_PREFIX VPC_ID
}

prepare_workload_context
```

Stop if this preflight fails. The `${VAR:?message}` expressions require a
non-empty value; they do not validate a profile's authority. Keep the selected
credentials, account, Region, and backend consistent throughout each test.
Re-run the complete preflight after changing environments.

`validate-ssm.sh` checks managed-node registration/online status and reports
matching maintenance-window and patch-baseline inventories. It does not make
absence of a matching window a hard failure, nor compare every task parameter
or prove a successful patch run. The inspections below supplement that scope;
they are not an additional workload validator.

Confirm the maintenance window:

Resolve the exact named window and its task, rejecting missing or ambiguous
results. These are read-only requests:

```bash
inspect_patch_configuration() (
  set -euo pipefail
  prepare_workload_context
  windows="$(aws ssm describe-maintenance-windows --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --filters "Key=Name,Values=${NAME_PREFIX}-weekly-patching" \
    --output json)"
  window_id="$(jq -er --arg name "${NAME_PREFIX}-weekly-patching" '
    [.WindowIdentities[]? | select(.Name == $name)] |
    if length == 1 then .[0].WindowId else error("Expected exactly one window") end
  ' <<< "$windows")"
  aws ssm get-maintenance-window --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --window-id "$window_id" \
    --query '{WindowId:WindowId,Name:Name,Enabled:Enabled,Schedule:Schedule,Timezone:ScheduleTimezone,Duration:Duration,Cutoff:Cutoff,AllowUnassociatedTargets:AllowUnassociatedTargets}' \
    --output json
  aws ssm describe-maintenance-window-targets --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --window-id "$window_id" \
    --query 'Targets[].{Id:WindowTargetId,Name:Name,ResourceType:ResourceType,Targets:Targets}' \
    --output json
  tasks="$(aws ssm describe-maintenance-window-tasks --profile "$AWS_PROFILE" \
    --region "$AWS_REGION" --window-id "$window_id" --output json)"
  task_id="$(jq -er --arg name "${NAME_PREFIX}-run-patch-baseline" '
    [.Tasks[]? | select(.Name == $name)] |
    if length == 1 then .[0].WindowTaskId else error("Expected exactly one named task") end
  ' <<< "$tasks")"
  aws ssm get-maintenance-window-task --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --window-id "$window_id" --window-task-id "$task_id" \
    --query '{Id:WindowTaskId,Name:Name,Type:TaskType,Document:TaskArn,Role:ServiceRoleArn,Priority:Priority,Concurrency:MaxConcurrency,Errors:MaxErrors,Targets:Targets,Invocation:TaskInvocationParameters}' \
    --output json
  printf 'Reviewed window ID: %s\nReviewed task ID: %s\n' "$window_id" "$task_id"
)
inspect_patch_configuration
```

Compare every returned setting with the reviewed applied configuration,
including the target tag, its registered target ID in the task, service-role
ARN, priority `1`, `Install`, and `RebootIfNeeded`. These commands print values;
they do not silently certify their equality. Record the exact window/task IDs
for execution review, and investigate unexpected additional targets or tasks.

Confirm managed instances:

Select the exact workload instance from the reviewed target inventory and
repeat for all intended targets. Also inspect tag-matching nodes outside that
inventory before allowing a patch run.

```bash
export INSTANCE_ID="<REVIEWED-WORKLOAD-INSTANCE-ID>"
aws ssm describe-instance-information \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
  --query 'InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]' \
  --output table
```

Review maintenance-window executions after setting `WINDOW_ID` to the exact
reviewed ID above. A list of prior executions is not evidence for a newly
created instance or the current task definition:

```bash
aws ssm describe-maintenance-window-executions \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --window-id "${WINDOW_ID:?Set the reviewed window ID}" \
  --query 'WindowExecutions[].[WindowExecutionId,Status,StartTime,EndTime]' \
  --output table
```

Review patch state:

```bash
aws ssm describe-instance-patch-states \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --instance-ids "${INSTANCE_ID}" \
  --query 'InstancePatchStates[].{Instance:InstanceId,Baseline:BaselineId,Snapshot:SnapshotId,Group:PatchGroup,Operation:Operation,Start:OperationStartTime,End:OperationEndTime,Installed:InstalledCount,PendingReboot:InstalledPendingRebootCount,Missing:MissingCount,Failed:FailedCount}' \
  --output table
```

Require a relevant execution timestamp, intended document and baseline,
complete expected-target coverage, successful per-target execution, acceptable
missing/failed/pending-reboot counts, and subsequent application health. An
empty `InstancePatchStates` result is missing evidence, not zero failures.
`FailedCount=0` alone does not establish compliance or that an `Install`
operation ran; inspect `Operation`, timestamps, and baseline identity.

Use `describe-maintenance-window-execution-tasks` and
`describe-maintenance-window-execution-task-invocations` for the selected
execution, then inspect its linked Run Command result. A window-level status
does not replace per-node results. This module does not configure dedicated
S3/CloudWatch command-output archival or command-status notifications; retain
review evidence through an approved process.

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

- `max_concurrency = "1"` limits this task execution, not all maintenance windows or independent commands in the account.
- The task sets `max_errors = "1"`; inspect AWS per-target status and error-threshold behavior rather than assuming every target ran.
- `RebootIfNeeded` may restart instances during the maintenance window.
- Setting `patching_enabled = false` disables scheduled execution but does not
  remove the maintenance-window resources.
- Larger fleets may require a reviewed window/concurrency change. The module
  does not drain load balancers, test application health between nodes, or
  coordinate an AZ-aware rolling update.
- Disabling the window does not cancel a command that is already running.
- Quarantined nodes can still match the target tag, while their endpoint-only
  egress may prevent public package retrieval. Do not relax containment merely
  to make a patch job pass.

## Related Modules

- [compute](../compute/README.md)
- [IAM](../iam/README.md)
- [networking](../networking/README.md)
- [VPC endpoints](../vpc_endpoints/README.md)
- [firewall](../firewall/README.md)

Implementation references: [resources](main.tf), [inputs](variables.tf), and
[baseline composition](../../baseline/main.tf).
