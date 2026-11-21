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

**Status:** Protected runtime admission contract accepted.
The owner approved AWS Lambda + Amazon SQS + DynamoDB
as the M2-B2 implementation direction on November 21, 2026.

Concrete IAM trust, protected deployment authority,
producer authentication, lifecycle fencing, and runtime
qualification remain outstanding. This decision does not
authorize Terraform Apply or AWS deployment.

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

### M2-B2-D1 — Approved Broker Platform Direction

**Decision date:** 2026-11-21
**Status:** Owner-approved architecture direction; implementation pending.

#### Selected architecture

The protected job-launch broker uses:

- Amazon SQS as the encrypted application-owned request transport.
- AWS Lambda as the independently protected request processor.
- Amazon DynamoDB for durable request deduplication, atomic
  admission reservations, concurrency tracking, and execution state.
- Dedicated per-job launcher IAM roles for narrowly authorized
  ECS RunTask and iam:PassRole operations.

EventBridge Scheduler and authorized on-demand producers submit
requests through the same broker-request queue. Scheduler does
not directly invoke ECS.

The application Terraform state owns the broker's application
resources. Foundation state retains ownership of the ECS cluster,
shared networking, and foundation-managed security infrastructure.
Platform/bootstrap authority independently governs mandatory IAM
ceilings and protected coordination.

No third workload Terraform state is introduced.

#### Authorization and trust boundaries

The broker resolves an approved job key to protected configuration:
exact task-definition revision, cluster, task/execution roles,
private subnets, security groups, Fargate configuration, and
execution limits.

Caller-provided ECS configuration and role/network overrides
are prohibited. Initial RunTask count is one.

SQS message-body fields, including schedule identifiers and
caller claims, are not authentication evidence. The mechanism
for verified producer attribution and job-level authorization
must be finalized and qualified before implementation.

The broker's runtime identity may assume only the approved
job-launch identities. It must not receive unrestricted
RunTask, PassRole, or application administrative permissions.

Ordinary application CI must not be able to bypass protected
admission by modifying broker code, approved configuration,
IAM trust, permission ceilings, or protected eligibility state.

These controls require independently enforced deployment and
mutation authority; repository review alone is insufficient.

#### Idempotency, concurrency, and lifecycle

The initial policy permits one active execution per job.

DynamoDB must atomically enforce durable request uniqueness,
job concurrency reservations, and the required protected
admission conditions.

Repeated SQS deliveries must not create additional launches.
ECS client-token idempotency supplements, but does not replace,
the durable execution ledger.

Ambiguous RunTask results remain subject to protected
reconciliation. Expired leases, execution timeouts, and
record expiration must not independently authorize retries
or release potentially active execution slots.

The protected lifecycle coordinator must block new admission
before maintenance, database parking, or teardown.

Previously admitted but unfinished launches must be reconciled
before lifecycle operations proceed. Checking eligibility during
reservation does not by itself prevent a previously authorized
RunTask call from occurring afterward.

Actual ECS task completion and failure reporting require
separate runtime state monitoring.

#### Outstanding implementation decisions

The selected platform does not settle:

- Exact broker execution-role trust and protected deployment identity.
- Producer authentication and queue authorization policies.
- Approved job-catalog representation and modification authority.
- DynamoDB item schema, transitions, retention, and reconciliation.
- Coordinator eligibility, fencing, and in-flight launch handling.
- Network admission across direct and service-managed ECS launch paths.
- Runtime observability, encrypted failure delivery, and live
  positive/negative security qualification.

These decisions require focused implementation design and
appropriate owner approval before their controls are deployed.

This checkpoint records platform selection only. It does not
constitute completed M2-B2 implementation or live qualification.

## Qualification boundary

M2-B1a establishes a reusable Terraform policy contract only.

Subsequent qualification must verify the generated policies and demonstrate positive and negative launch authorization for two independently scoped jobs, including unauthorized revisions, clusters and role passing.

Live AWS authorization and protected network-admission behavior require separate deployment approval.

This contract does not authorize an AWS Apply, a task launch, or completion of the broader M2 milestone.
