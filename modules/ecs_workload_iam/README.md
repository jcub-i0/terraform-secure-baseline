# ECS Workload IAM Module

## Overview

`ecs_workload_iam` creates a separate ECS task execution role and application task role for every entry in `workloads`. Long-running services ([ecs_service](../ecs_service/README.md)) and standalone jobs ([ecs_task](../ecs_task/README.md)) use the same trust policy, execution-policy generation, and task-role attachment logic.

The module creates only ECS workload IAM. It does not instantiate the foundation-wide [iam](../iam/README.md) module or any of its resources. Application-owned Terraform states can call it directly, alongside `ecs_task` or `ecs_service`, without pulling in foundation IAM.

v1.15.0 R1-A extracted this implementation from `modules/iam/ecs.tf` without changing its behavior. Resource types, resource names, `for_each` keys, AWS role and policy names, trust conditions, and policy statements are the same as before. Only the module path changed: in baseline composition the resources moved from `module.baseline.module.iam` to `module.baseline.module.ecs_workload_iam`. No `moved` blocks or state moves are declared. See [Address Change](#address-change).

---

## Resources

| Resource | Key | Purpose |
|---|---|---|
| `aws_iam_role.ecs_task_execution_roles` | workload | ECS runtime role for image pulls, log delivery, and startup secret retrieval |
| `aws_iam_role.ecs_task_roles` | workload | Application role used by the workload containers |
| `aws_iam_role_policy.ecs_task_execution_policies` | workload | Custom inline execution policy |
| `aws_iam_role_policy_attachment.ecs_task_managed_policies` | `<workload>\|<policy-arn>` | Optional managed policies attached to the application task role only |

Supporting data sources: `aws_partition.current`, `aws_iam_policy_document.ecs_tasks_assume_role` (shared trust), and `aws_iam_policy_document.ecs_task_execution_policies` (per workload).

Role names:

```text
<name_prefix>-<workload>-ecs-execution
<name_prefix>-<workload>-ecs-task
```

The inline execution policy has the same name as the execution role. Both roles carry `Name`, `Environment`, and `Terraform = "true"` tags.

---

## Trust Policy

Both role types trust `ecs-tasks.amazonaws.com` for `sts:AssumeRole`. Two conditions apply:

- `aws:SourceAccount` must equal `account_id`.
- `aws:SourceArn` must match `arn:<partition>:ecs:<primary_region>:<account_id>:*`.

The condition covers ECS resources throughout the configured account and Region, not a single service, job, or task definition. Separate role names do not narrow that trust pattern.

---

## Execution Policy

The custom execution policy permits:

- `ecr:GetAuthorizationToken` on `*`, because that ECR API does not support resource-level permissions.
- `ecr:BatchCheckLayerAvailability`, `ecr:GetDownloadUrlForLayer`, and `ecr:BatchGetImage` on only the workload's `ecr_repository_arns`.
- The same three pull actions on exactly `guardduty_agent_ecr_repository_arns`, only when that set is non-empty. Otherwise the `AllowGuardDutyAgentImagePulls` statement is omitted.
- `logs:CreateLogStream` and `logs:PutLogEvents` on stream ARNs (`<log-group-arn>:*`) beneath only the workload's `log_group_arns`.
- `secretsmanager:GetSecretValue` on only `execution_secret_arns`, only when that set is non-empty.
- `ssm:GetParameters` on only `execution_ssm_parameter_arns`, only when that set is non-empty.
- `kms:Decrypt` on only `task_execution_kms_key_arns`, only when that set is non-empty.

The module does not attach the AWS-managed `AmazonECSTaskExecutionRolePolicy`. Its generated grants contain no `iam:PassRole`, and it does not automatically add the ECR encryption CMK to execution-role permissions.

`task_execution_kms_key_arns` defaults to `[]`. It is needed only when ECS startup secret injection requires execution-role decryption with a customer-managed KMS key. It is **not** a list of all baseline-managed CMKs. Take the key identity from the referenced secret or parameter, not from the set of keys the baseline creates. A populated set grants exactly the declared keys, subject to the key policy. Application-initiated AWS SDK and KMS calls use the separate task role.

In the baseline, `guardduty_agent_ecr_repository_arns` is populated only for protected `production` and `development` services, with the exact regional repository:

```text
arn:<partition>:ecr:<region>:<guardduty-agent-account-id>:repository/aws-guardduty-agent-fargate
```

The generated GuardDuty statement contains pull actions only, not push or repository-administration actions.

---

## Application Task Roles

Application task roles have no policies by default. `task_role_managed_policy_arns` attaches existing AWS-managed or same-account customer-managed policies **only to the application task role**. The execution role is unchanged. This module creates the attachments, **not** the application policies. Application owners provision and approve their customer-managed policies separately.

A precondition restricts each attached ARN to the current partition and to either the configured account or AWS-managed policies (`arn:<partition>:iam::(<account_id>|aws):policy/...`). This does not prove that the policy exists or is least privilege. Policy ARNs must be known during planning, and the policies must exist when the attachment is created. An omitted or empty set adds no attachments and no attachment-readiness entry. Removing an ARN plans a detachment.

For baseline services, `validate-iam.sh` verifies the exact attached policy ARNs and rejects unexpected attachments and inline task policies. It does not analyze the contents or effective permissions of externally managed policies. The application owner must review policy grants, versions, and resource-based access before approval.

---

## Inputs

| Name | Type | Description | Required |
|---|---|---|---:|
| `name_prefix` | `string` | Prefix used in role and inline-policy names | Yes |
| `environment` | `string` | Environment tag value | Yes |
| `account_id` | `string` | Account used by the trust conditions and the managed-policy ARN precondition | Yes |
| `primary_region` | `string` | Region used by the `aws:SourceArn` trust condition | Yes |
| `workloads` | `map(object(...))` | Workload IAM inputs keyed by stable service or job name. Defaults to `{}` | No |

Each workload object has this shape:

```hcl
map(object({
  ecr_repository_arns                 = set(string)
  guardduty_agent_ecr_repository_arns = optional(set(string), [])
  log_group_arns                      = set(string)
  execution_secret_arns               = optional(set(string), [])
  execution_ssm_parameter_arns        = optional(set(string), [])
  task_execution_kms_key_arns         = optional(set(string), [])
  task_role_managed_policy_arns       = optional(set(string), [])
}))
```

These values become IAM `Resource` entries verbatim, so variable validation rejects wildcard or partial scopes:

- **ECR:** application and GuardDuty repository ARNs must be exact repository ARNs in a supported partition. GuardDuty repositories may belong to another account.
- **SSM:** parameters must be full ARNs. Names and paths are rejected.
- **KMS:** keys must be key ARNs. Key IDs and aliases are rejected.
- **Secrets Manager:** secrets must be full ARNs, including the six-character suffix, without ECS JSON-key or version selectors.

`log_group_arns` is not format-validated. Supply exact log-group ARNs without the `:*` suffix; the module adds it.

`task_role_managed_policy_arns` does **not** feed the execution policy. It only creates attachments on the application task role.

---

## Outputs

The four outputs are separate contracts. Do not substitute role ARNs for the readiness outputs.

| Name | Shape | Purpose |
|---|---|---|
| `execution_roles` | `map(object({ arn, name }))` keyed by workload | Execution role references for task definitions |
| `task_roles` | `map(object({ arn, name }))` keyed by workload | Application task role references for task definitions |
| `execution_policy_ids` | `map(string)` keyed by workload | Inline execution-policy IDs, for launch readiness. These are not managed-policy attachment IDs |
| `task_role_policy_attachment_ids` | `map(set(string))` | Task-role managed-policy attachment IDs, for launch readiness. Contains only workloads with at least one managed policy |

`ecs_service` consumes both readiness outputs through its `execution_policy_ids` and `task_role_policy_attachment_ids` inputs, so a service does not launch before its execution policy and configured attachments exist. `ecs_task` only registers task definitions and has no readiness inputs. Launch authorization for jobs (`ecs:RunTask`, `iam:PassRole`) is out of scope here.

---

## Usage

### Baseline (long-running services)

The baseline derives `local.ecs_iam_services` from the canonical `ecs_services` map, with one entry per deployable service:

```hcl
module "ecs_workload_iam" {
  source = "../modules/ecs_workload_iam"

  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  workloads = local.ecs_iam_services
}
```

`ecs_service` receives `execution_roles[*].arn` and `task_roles[*].arn` through `local.ecs_runtime_services`, plus both readiness outputs. A registered service with `image_digest = null` does not get a role pair until an exact digest is selected.

### Direct consumer (standalone jobs)

Build log-group ARNs from the consumer's naming contract. **Do not** feed `module.ecs_task.log_groups` (or `module.ecs_service.log_groups`) back into `workloads`. Those log groups are created from task inputs that already contain the role ARNs, so the reverse reference creates a Terraform dependency cycle. `ecs_task` names job log groups `/aws/ecs/<name_prefix>/jobs/<job>`:

```hcl
data "aws_partition" "current" {}

module "job_iam" {
  source = "../modules/ecs_workload_iam"

  name_prefix    = local.name_prefix
  environment    = var.environment
  account_id     = var.account_id
  primary_region = var.primary_region

  workloads = {
    report = {
      ecr_repository_arns = [aws_ecr_repository.report.arn]
      log_group_arns = [
        "arn:${data.aws_partition.current.partition}:logs:${var.primary_region}:${var.account_id}:log-group:/aws/ecs/${local.name_prefix}/jobs/report"
      ]
    }
  }
}

module "jobs" {
  source = "../modules/ecs_task"

  # ... naming, logs_cmk_arn, retention ...

  tasks = {
    report = {
      image              = "${aws_ecr_repository.report.repository_url}@sha256:<digest>"
      cpu                = 256
      memory             = 512
      execution_role_arn = module.job_iam.execution_roles["report"].arn
      task_role_arn      = module.job_iam.task_roles["report"].arn
    }
  }
}
```

Use a version-pinned module source in application repositories. Use the same workload key and `name_prefix` in both modules.

---

## Address Change

R1-A changes module paths only. The state migration prohibition still applies.

| Before | After |
|---|---|
| `module.baseline.module.iam.aws_iam_role.ecs_task_execution_roles["<service>"]` | `module.baseline.module.ecs_workload_iam.aws_iam_role.ecs_task_execution_roles["<service>"]` |
| `module.baseline.module.iam.aws_iam_role.ecs_task_roles["<service>"]` | `module.baseline.module.ecs_workload_iam.aws_iam_role.ecs_task_roles["<service>"]` |
| `module.baseline.module.iam.aws_iam_role_policy.ecs_task_execution_policies["<service>"]` | `module.baseline.module.ecs_workload_iam.aws_iam_role_policy.ecs_task_execution_policies["<service>"]` |
| `module.baseline.module.iam.aws_iam_role_policy_attachment.ecs_task_managed_policies["<service>\|<arn>"]` | `module.baseline.module.ecs_workload_iam.aws_iam_role_policy_attachment.ecs_task_managed_policies["<service>\|<arn>"]` |

Resource types, names, and instance keys are unchanged; use this mapping when comparing plans. The v1.15.0 R0 baseline recorded empty workload states (create-only plans), so these shipped environments need no state migration. A state that already tracks these roles at the old addresses would instead plan a delete at the old address and a create at the new address, both under the same AWS role names. Review that plan before any apply.

---

## Validation

[tests/ecs_execution_policy.tftest.hcl](tests/ecs_execution_policy.tftest.hcl) runs offline plan tests with a credential-free AWS provider. It covers:

- Empty input.
- Per-workload role isolation and exact execution-policy statements, including optional GuardDuty, secret, SSM, and KMS grants.
- Task-role-only managed-policy attachments.
- The four output contracts and attachment-readiness omission.
- Rejection of wildcard SSM, KMS, Secrets Manager, ECR, and GuardDuty repository scopes, and of cross-account managed policies.
- A direct `ecs_task` composition through [tests/fixtures/ecs_task_composition](tests/fixtures/ecs_task_composition/main.tf). It verifies there is no dependency cycle and that the IAM log-group ARNs match the log groups `ecs_task` creates.

```sh
terraform -chdir=modules/ecs_workload_iam init -backend=false -lockfile=readonly
terraform -chdir=modules/ecs_workload_iam test
```

These tests check generated configuration, not effective AWS authorization. `scripts/validation/validate-iam.sh` validates the deployed baseline roles and policies through the workload root outputs `ecs_task_execution_roles` and `ecs_task_roles`, whose names are unchanged.

---

## Security Notes and Scope

- Execution and application task roles are separate and isolated per workload.
- Application task roles carry no permissions unless managed policies are explicitly attached.
- Execution policies are custom and resource-scoped, except for `ecr:GetAuthorizationToken`.
- Not implemented here: permissions boundaries, `ecs:RunTask`, `iam:PassRole`, launch authorization, scheduling, and network admission.
