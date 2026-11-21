# ECS Job Launch Authorization

## Purpose

This document defines the reusable M2-B1a authorization contract for launching standalone ECS Fargate jobs.

The reusable `ecs_task` module registers job task definitions and log groups. The `ecs_workload_iam` module provides their task execution and application roles.

Neither module grants permission to invoke jobs.

Launch authorization belongs to a separately controlled application-owned identity, with IAM policies managed in application Terraform state.

This example demonstrates two independent synthetic jobs, `archive` and `report`. It is an illustrative application composition fragment, not a standalone deployable Terraform root.

## Authorization model

Each job receives a dedicated launcher identity.

The launcher's IAM policy permits:

- `ecs:RunTask` on the exact approved task-definition revision, restricted to the approved ECS cluster.
- `iam:PassRole` on the job's exact task execution and application task roles, restricted to `ecs-tasks.amazonaws.com`.

The launcher must not inherit unrelated administrative or task-role permissions.

## Terraform composition example

The example assumes that the application-owned composition already defines:

- `module.jobs` using `ecs_task`, with `archive` and `report` task definitions.
- `module.job_iam` using `ecs_workload_iam`, with corresponding execution and task roles.
- `aws_iam_role.launcher`, containing separately approved application-owned launcher roles for both jobs.
- `var.approved_cluster_arn`, identifying the permitted foundation ECS cluster.
- `var.name_prefix`, for application-owned IAM resource naming.

Launcher role trust policies, mandatory permission boundaries and protected execution identities must be independently approved. This example does not define or authorize their creation.

```hcl
locals {
  launcher_jobs = toset(["archive", "report"])
}

data "aws_iam_policy_document" "job_launch" {
  for_each = local.launcher_jobs

  statement {
    sid       = "RunApprovedTaskRevision"
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [module.jobs.task_definitions[each.key].arn]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.approved_cluster_arn]
    }
  }

  statement {
    sid     = "PassOnlyApprovedJobRoles"
    effect  = "Allow"
    actions = ["iam:PassRole"]

    resources = [
      module.job_iam.execution_roles[each.key].arn,
      module.job_iam.task_roles[each.key].arn
    ]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "job_launch" {
  for_each = local.launcher_jobs

  name   = "${var.name_prefix}-${each.key}-job-launch"
  role   = aws_iam_role.launcher[each.key].name
  policy = data.aws_iam_policy_document.job_launch[each.key].json
}
```

Each launcher role must have distinct, appropriately restricted trust and effective permissions. A caller able to assume both launcher roles can exercise both grants.

The example derives task-definition revision ARNs and task/execution-role ARNs from the existing module outputs, avoiding broad IAM resource patterns.

## Runtime admission boundary

IAM authorization is necessary but insufficient for secure standalone execution.

The independently protected application launcher must also enforce:

- Explicit approved private subnet IDs.
- Explicit approved security-group IDs and rules.
- `assignPublicIp = DISABLED`.
- Approved Fargate launch configuration.
- Bounded task counts, concurrency and retries.
- No unapproved task, execution-role, command, environment, CPU/memory or storage overrides.
- Correct job-to-cluster and job-to-role associations.
- Recorded launch results and failures.

`iam:PassRole` restrictions do not themselves bind an allowed role to a particular role-override field. The launcher must reject role overrides and use the roles registered in the approved task definition.

The AWS authorization for `ecs:RunTask` does not guarantee private networking. Callers must be unable to bypass protected launch admission using the launcher's credentials.

These runtime admission protections remain M2-B2 and M0 security requirements. They are not implemented by this example.

## M2-B2 — Protected Runtime Admission Contract

**Status:** Architecture approved for implementation planning.
Concrete enforcement, trusted execution identity, and live
qualification remain pending M0 security approval.

### Caller interface

Authorized callers request a job using:

- An approved job key.
- An idempotency identifier.
- An authenticated caller identity.

Callers must not supply arbitrary ECS task definitions, IAM roles,
subnets, security groups, commands, environment variables, or
resource overrides.

### Protected launch broker

An independently protected launcher resolves each job key to
approved configuration containing:

- Exact task-definition revision ARN.
- Approved ECS cluster ARN.
- Expected task and execution roles.
- Private subnet IDs and approved security-group IDs.
- Fargate platform configuration.
- Execution, concurrency, and retry limits.

The broker constructs the ECS RunTask request with:

- Count = 1.
- Approved task definition and cluster.
- Explicit private networking.
- assignPublicIp = DISABLED.
- No caller-controlled role or container overrides.

The initial concurrency policy permits one active execution per
job. Concurrency and idempotency decisions must be enforced
atomically using durable, protected state.

### Identity and bypass prevention

The broker uses a dedicated runtime identity with narrowly scoped
RunTask and PassRole permissions.

Ordinary application callers, image-publishing identities, and
Scheduler execution roles must not be able to bypass protected
admission by directly assuming the broker identity or invoking ECS
with unrestricted permissions.

Platform-controlled IAM ceilings, trust policies, and security-group
mutation authority remain independent of ordinary application CI.

### Lifecycle coordination

New launches and retries must be blocked by the protected lifecycle
fence before workload draining, database parking, or teardown.

Scheduler-triggered and on-demand requests follow the same
admission rules.

An expired lease or interrupted executor must not automatically
restore launch authority without reconciliation.

### Results and qualification

The broker records the caller, job, approved revision, request
identity, AWS request ID, returned task ARN, and launch outcome.

RunTask acceptance is not equivalent to successful task completion.
Runtime completion and failure reporting require separate ECS task
state monitoring.

M2-B2 is not qualified until authorized launches and denied bypass
attempts are demonstrated against the actual protected identity.

No deployment or AWS mutation is authorized by this contract.

## Qualification boundary

M2-B1a establishes a reusable Terraform policy contract only.

Subsequent qualification must verify the generated policies and demonstrate positive and negative launch authorization for two independently scoped jobs, including unauthorized revisions, clusters and role passing.

Live AWS authorization and protected network-admission behavior require separate deployment approval.

This contract does not authorize an AWS Apply, a task launch, or completion of the broader M2 milestone.
