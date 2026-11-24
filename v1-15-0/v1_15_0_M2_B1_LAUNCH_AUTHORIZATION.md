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

### C4-A Runtime Admission Design and Initial Offline Implementation

**Status:** Owner-authorized initial offline helper increment implemented
and tested. Outstanding architecture decisions and activation
qualifications below remain open.

**Scope:** Request-schema-v2 parsing, producer-to-job policy evaluation,
durable request-key derivation, and offline regression coverage.
C4-A is a working subdivision, not a newly approved roadmap milestone.

This work preserves the accepted two-state architecture,
application-owned broker resources, independently protected platform
authority, and Lambda + SQS + DynamoDB direction.

The helpers do not establish authenticated AWS delivery, load the
protected catalog, perform transactional admission, or dispatch tasks.
Terraform changes, AWS operations, and broker activation remain outside
this completed increment.

**Validation:** Implementation commit
`97dbda7f6dc1defd19cab4b565d3e9fc0d53398a` passed Terraform Module Tests
run #105: 26 broker tests under Python 3.12.16, 64 Terraform native tests,
and 19 IAM regression tests.

[CI evidence](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/45492053955)

These results establish offline compatibility, not live AWS
qualification or proof of zero drift.

#### Producer identity and authorization

The initial supported category is trusted infrastructure-level job
requests authorized by AWS producer-role identity.

The broker verifies the producer and its permission to request a job.
A trusted application producer remains responsible for required
application-user and tenant authorization. Jobs requiring the broker
to independently verify delegated authorization need a separately
approved contract.

The preferred attribution candidate is the AWS-generated SQS system
`SenderId`, mapped through protected configuration to a stable logical
producer identity and its permitted jobs.

Role-session names, request keys, schedule identifiers, message-body
claims, and custom message attributes are not authentication evidence.
A recreated IAM role must not inherit authorization solely because its
name matches a previously approved role.

This mechanism requires an independently protected SQS delivery path.
A direct Lambda caller can fabricate an SQS-shaped event; inspecting
its apparent queue ARN, event source, or SenderId cannot authenticate
that invocation.

Required controls include queue submission restrictions, producer-role
trust, Scheduler mutation and role-passing restrictions, protected
Lambda invocation and deployment, protected event-source mappings,
and prevention of alternate ECS launch paths.

Preserve Scheduler's schedule-group-scoped trust condition. Per-schedule
authorization also depends on controlling schedule changes and
execution-role passing.

Actual Scheduler/on-demand attribution, role replacement, and bypass
prevention require AWS qualification. Operator redrive and replay
remain unavailable until an approved workflow preserves or
independently re-establishes authorization and durable request identity.

#### Protected job catalog and deployment sequence

The preferred initial representation is immutable JSON packaged with
the approved Lambda ZIP.

The catalog defines producer authorization and complete approved
execution configuration: exact task-definition revision, cluster,
launcher role, task/execution roles, private subnets, approved security
groups and their effective rule union, Fargate configuration, and
execution/concurrency limits.

RunTask uses count one, public IP assignment disabled, and no
caller-controlled execution overrides.

The proposed staged deployment sequence is:

1. Establish application-owned task definitions and IAM identities
   while the broker remains inactive.
2. Resolve and verify the exact identities and approved configuration.
3. Build and approve the runtime/catalog artifact.
4. Record artifact/catalog digests, S3 object version, and association
   with the approved application release and foundation publication.
5. Update the protected application deployment configuration.
6. Qualify the complete controls before activation.

The module's existing null package option permits Lambda creation to
remain omitted during initial resource establishment.

The sequence must preserve one application state, one Terraform writer,
and no reverse foundation dependency. Actual dependency-cycle and
deployment-authority checks remain required.

S3 object-version pinning alone does not prove approval or provenance.
Ordinary application CI must not substitute unauthorized code or catalog
configuration.

#### Admission generations and durable request identity

The proposed request envelope includes an admission generation.
The protected gate binds that generation to an approved catalog.
The caller-supplied generation is only a claim to validate.

Rotate the generation when activating a changed catalog or reopening
admission after lifecycle closure. Older-generation requests fail
closed. This intentionally rejects delayed work across those transitions
and requires coordinated producer configuration.

The current Scheduler envelope lacks this field. Its versioned update
belongs to a subsequent approved implementation checkpoint.

Durable request uniqueness is scoped to:

`(application/environment, logical_producer_id, request_key)`

Do not include job key, admission generation, release version, IAM role
ID, or session name in that uniqueness key.

The original record retains the approved job and immutable execution
intent. A matching duplicate cannot launch again. Reuse of the identity
with a different job or execution intent is a conflict. A generation
change cannot create another execution opportunity or rebind an
existing request to the current catalog.

An approved role replacement may update the mapping to the same logical
producer without resetting request history. Producer authentication and
job authorization remain independent of the producer-supplied request key.

Initially retain durable request identities without automatic expiry or
cleanup. Use opaque identifiers and the minimum non-secret metadata
necessary for authorization, correlation, and recovery.

Future archival, deletion, restore, and recreation require an approved
protocol preserving replay protection. Point-in-time recovery alone does
not establish consistency with protected admission state. Do not add
automatic TTL-based deletion during C4.

#### Protected admission authority and atomic reservation

The leading candidate is a separate DynamoDB gate table in the same
account and Region as the application execution ledger.

The proposed ownership split is:

- Existing protected workload foundation state manages table infrastructure.
- An independently protected coordinator performs eligibility transitions.
- The application broker receives narrowly scoped read/condition-check access.

The exact root, IAM protection, controller, and authority relationship
remain unresolved M0 decisions. Foundation ownership alone does not
establish independent protection.

Foundation Terraform must not consume application outputs or continuously
manage the coordinator's mutable eligibility records. No third workload
Terraform state is introduced.

The broker and ordinary application deployment identities must not
modify protected eligibility, generations, catalog associations, or
their protective infrastructure. The execution ledger must also be
protected against unauthorized record or infrastructure changes.

One admission transaction must check the authoritative gate and approved
generation/catalog, establish request uniqueness, acquire the job slot,
and durably register exclusive launch-attempt ownership.

Gate closure and admission must be ordered against the same authoritative
eligibility item. Foundation publication eligibility alone does not
authorize job admission.

DynamoDB transactions require the same account and Region and cannot
perform multiple actions against one item. Exact schemas and conditional
expressions remain implementation work.

Transactional permissions derive from the underlying item actions.
Do not introduce a speculative standalone `dynamodb:TransactWriteItems`
IAM permission.

#### Launch ownership and lifecycle fencing

Every launch attempt must be durably registered before dispatch.
Only the invocation acquiring exclusive launch ownership may dispatch.
Duplicate delivery must not grant another launch opportunity.

The required lifecycle sequence is:

1. Close admission.
2. Resolve or safely fence every outstanding launch attempt.
3. Complete the launch fence.
4. Drain tracked tasks.
5. Authorize operations requiring quiescence, including database
   parking or teardown.

If closure precedes admission, the admission transaction fails.
If admission precedes closure, the registered attempt remains an
outstanding obligation.

An already-admitted attempt may complete after admission closes.
The fence remains incomplete, and draining cannot begin while a late
launch remains possible.

Discovery must account for every outstanding attempt across relevant
releases and catalog generations, including interrupted invocations,
uncertain ECS outcomes, and failed result writes. An empty incomplete
or eventually consistent result does not establish fence completion.

The later implementation must demonstrate authoritative discovery
completeness. This proposal does not prematurely select an index,
counter, or lease mechanism.

A resolved launch attempt is distinct from a released job slot.
A known running task retains its slot until trustworthy terminal
resolution. Actual task-start and container-exit outcomes require
separate correlation and monitoring.

#### Initial dispatch policy and protected recovery

Before dispatch, persist an explicitly chosen ECS clientToken and
immutable ECS request parameters.

The proposed initial RunTask policy is one Botocore attempt using
`total_max_attempts = 1`, with explicit connection/read timeouts selected
within the Lambda execution budget.

Scope this configuration to the ECS launch client. It is a conservative
initial implementation policy, not an immutable architectural requirement
or a guarantee of exactly-once ECS execution.

An initial request can create a task even if its response is lost.
Multiple invocations must still be prevented from independently
obtaining launch ownership.

ECS client-token protection is time-limited and supplements the durable
ledger. Do not rely on an SDK-generated token for cross-invocation
request identity.

No further RunTask call is permitted after an attempt is conclusively
resolved. SQS redelivery, executor timeout, or lease expiry cannot
automatically transfer ownership or authorize another dispatch.

A crash after ownership registration but before transmission may leave
the attempt unresolved. This availability tradeoff requires protected
recovery; it does not justify automatic reservation release.

Recovery must establish the original outcome and that no remaining
executor or outstanding dispatch can produce a late launch. A single
negative task observation, expired credentials, changed epoch, DLQ
arrival, or elapsed timeout is insufficient on its own.

If safe reconciliation cannot be established, retain the unresolved
attempt and block fence completion. Exact timeout values, conclusive-error
classification, and the recovery procedure require subsequent review.

#### Implementation and activation boundaries

Before the first offline decision-logic increment, obtain owner acceptance
of the applicable request schema, producer mapping, catalog, generation,
uniqueness/conflict, and override-rejection contracts.

Offline fixtures may supply simulated authenticated identity context.
They do not prove AWS attribution or effective lifecycle fencing.

Before transactional execution, approve the concrete gate authority,
transaction protocol, permissions, and lifecycle relationships.

Before activation, implement and qualify producer authentication,
protected artifact deployment, IAM ceilings, network admission,
alternate-path prevention, lifecycle fencing, execution monitoring,
and protected recovery.

Keep Lambda reserved concurrency at zero, the SQS mapping disabled,
and schedules disabled throughout unqualified development.

#### Focused acceptance cases

| Case | Required outcome |
|---|---|
| Unknown producer or unauthorized job | Denied without launch authority |
| Forged body identity or execution override | Cannot grant authority or alter approved execution |
| Matching duplicate request | No additional launch |
| Same request identity with different job or intent | Conflict; no additional launch |
| Stale generation | Rejected without rebinding to current configuration |
| New generation with previously admitted identity | No renewed execution opportunity |
| Gate closure wins the admission race | Admission fails |
| Admission wins the closure race | Registered attempt blocks fence completion until resolved |
| Interrupted executor, lost response, or failed result write | No automatic takeover or relaunch |
| Outstanding attempt from an older release | Included in complete fence accounting |
| Resolved launch with a running task | Job slot remains occupied |
| Ledger restore or history removal | No silent restoration of replay authority |

These are acceptance requirements for subsequent focused tests and
qualification, not claims of implemented or verified behavior.

## Qualification boundary

M2-B1a establishes a reusable Terraform policy contract only.

Subsequent qualification must verify the generated policies and demonstrate positive and negative launch authorization for two independently scoped jobs, including unauthorized revisions, clusters and role passing.

Live AWS authorization and protected network-admission behavior require separate deployment approval.

This contract does not authorize an AWS Apply, a task launch, or completion of the broader M2 milestone.
