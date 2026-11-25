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

The following list records the platform-selection boundary. The C4-A
section below records subsequent design approvals and offline
implementation. Platform selection alone did not settle:

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

### C4-A Runtime Admission Design and Offline Implementation

**Status:** The owner approved the four-record admission model, admission
executor, dispatch ownership and result recording, and the immutable task
lookup and protected ECS `STOPPED` event contract for offline implementation.
Catalog loading, request resolution, admission preparation and execution,
conditional dispatch claims, ECS outcome classification, launch-result
transactions, task lookup creation, and atomic terminal recording/slot release
are implemented with a 166-test offline suite. Concrete gate authority,
permissions, runtime integration, protected completion-event delivery,
recovery, and activation qualification remain open.

**Scope:** Request-schema-v2 parsing, producer-to-job policy evaluation,
durable request-key derivation, complete schema-v1 catalog loading,
catalog source digests, four-record admission transaction preparation,
duplicate/conflict classification, executor result and cancellation
handling, DynamoDB client configuration, dispatch ownership, one-attempt
ECS calls, immutable task lookups, conditional launch and terminal-state
result/accounting updates, and offline regression coverage.
C4-A is a working subdivision, not a newly approved roadmap milestone.

This work preserves the accepted two-state architecture,
application-owned broker resources, independently protected platform
authority, and Lambda + SQS + DynamoDB direction.

The helpers load supplied catalog text and prepare the conditional
transaction payload. The executor submits that payload through a supplied
DynamoDB client, classifies responses and SDK failures, and reads the gate
and original request after an established collision. The dispatcher uses
supplied clients to claim an admitted request, call ECS, and record the
observed launch outcome with a task lookup for accepted launches. The
completion helper reads that lookup and original request, then conditionally
records supplied trusted terminal evidence and releases the matching slot.
Real clients would perform AWS operations; current tests use scripted clients
only. The implementation does not establish artifact provenance or authenticated
AWS delivery, construct runtime SDK clients, enforce invocation deadlines,
consume completion events from a deployed queue, or perform protected recovery.
Terraform changes, AWS operations, and broker activation remain outside the
completed offline increment.

**Current coverage:** 166 offline Python tests, including nine admission
tests for transaction shape and conditions, persistent key formats,
launch snapshots, exact catalog-text digests, stable retry payloads,
fresh attempts on redelivery, duplicate/conflict classification,
generation/role-replacement behavior, slot/accounting scope, resolution
denials, and unexpected-record rejection. Sixteen executor tests cover
exact submission payloads, owner checks, client settings, acknowledgments
after SDK retries, collision lookups, current gate eligibility, cancellation
reasons, known rejections, preserved uncertainty, lookup failures, malformed
responses/records, and result representations that exclude sensitive record
contents and service messages. Twenty-seven dispatcher tests cover conditional
claims and result writes, exact launcher/launch inputs, the ECS retry-policy
check, repeated and competing entries, claim uncertainty, accepted/refused/
unknown launches, slot and counter changes, recording failures, retained
task identifiers, response binding checks, immutable task-lookup creation and
conflicts, and selective diagnostic evidence. Twenty-six completion tests cover
consistent reads, task/attempt/snapshot binding, atomic slot release and occupied
accounting, catalog changes, nonterminal events, early or missing records,
duplicates and competing writes, lost acknowledgements and redelivery, read
failures, and minimal terminal evidence.
These tests inspect generated operations, supplied records, and scripted
client behavior. The competing-entry tests model claim/cache and write responses;
they do not execute DynamoDB conditions or actual SDK retries, launch ECS
tasks, or prove AWS concurrency, authentication, effective IAM, or fencing.

**Initial increment validation (historical):** Implementation commit
`97dbda7f6dc1defd19cab4b565d3e9fc0d53398a` passed Terraform Module Tests
run #105: 26 broker tests under Python 3.12.16, 64 Terraform native tests,
and 19 IAM regression tests.

[CI evidence](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/45492053955)

That historical run covers the initial 26-test helper increment, not the
current 166-test suite. Offline results do not establish live AWS
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

The initial representation is immutable schema-v1 JSON to be packaged
with the approved Lambda ZIP. The complete catalog loader is implemented;
protected artifact packaging and deployment remain outstanding.

The catalog defines producer authorization and complete approved
execution configuration: exact task-definition revision, cluster,
launcher role, task/execution roles, private subnets, approved security
groups and their effective rule union, Fargate configuration, and
execution/concurrency limits.

RunTask uses count one, public IP assignment disabled, and no
caller-controlled execution overrides.

The loaded `JobCatalog.source_sha256` identifies the exact supplied
catalog string encoded as UTF-8, including whitespace. Admission
preparation uses it for the gate comparison and request provenance.
Computing this digest does not establish approval. The runtime must load
the packaged text without rewriting it, and the coordinator must bind
the independently approved digest to the admission generation.

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

The implemented schema-v2 request envelope includes an admission generation.
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

The approved offline model uses a separate DynamoDB gate table in the
same account and Region as the application execution ledger. This
model approval does not establish the concrete gate authority or its
infrastructure and IAM implementation.

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
perform multiple actions against one item. Preparation defines schema-v1
records and admission expressions as described below. Submission and error
handling are implemented in the supplied-client executor; the protected
AWS integration and its qualification remain outstanding.

Transactional permissions derive from the underlying item actions.
Do not introduce a speculative standalone `dynamodb:TransactWriteItems`
IAM permission.

#### Approved four-record admission model

One admission operation targets a protected gate and three records in
the existing `pk`-only execution ledger. The launch attempt is embedded
in the request record for the initial one-attempt policy.

| Record | Key scope | Admission action |
|---|---|---|
| Gate | `gate:v1:<sha256>` over `(application_id, environment)` | Condition-check schema/type, `OPEN` state, admission generation, catalog digest, and execution-ledger ARN. |
| Request | Existing `request:v1:<sha256>` over `(application_id, environment, logical_producer_id, request_key)` | Put the original intent and proposed attempt ownership only if the key does not exist. |
| Job slot | `slot:v1:<sha256>` over `(application_id, environment, job_key)` | Acquire an absent slot or an existing schema-v1 `SLOT` in state `FREE`; set it to `OCCUPIED` by this request and attempt. |
| Accounting | `accounting:v1:<sha256>` over `(application_id, environment)` | Require initialized accounting and atomically increment unresolved launch attempts and occupied slots. |

All key hashes use ordered, compact ASCII-escaped JSON arrays and SHA-256.
Prefixes, tuple field order, and encoding are persistent storage format
v1. Slot and accounting identities exclude producer, request, release,
and admission generation. Changing a catalog cannot create a fresh slot
or reset accounting for an existing job or application scope.

Admission uses `schema_version = 1` and `record_type` values
`GATE`, `REQUEST`, `SLOT`, and `ACCOUNTING`. The request has initial
`status = REGISTERED`. It retains application/environment, logical
producer and request identity, job, original generation/catalog digest,
attempt ID, owning invocation ID, canonical `intent_json`, and exact
`run_task_request_json`. Optional schedule metadata is retained for
correlation only.

Accepted-launch recording subsequently adds a schema-v1 `TASK_LOOKUP` in the
same ledger. It is not part of the four-record admission transaction; its
identity and terminal-recording contract are specified below.

Execution intent includes the job, launcher/task/execution roles,
approved RunTask parameters, and execution policy. Generation, catalog
provenance, invocation/attempt IDs, generated tokens, and schedule
correlation metadata are excluded from intent comparison. Therefore:

- A current-generation request with unchanged original execution intent
  is a duplicate even if the generation or catalog digest has changed.
- Reusing the durable identity with a different job or execution intent
  is a conflict.
- A stale-generation request remains ineligible; duplicate classification
  does not bypass current authentication, authorization, or gate checks.
- The original record is retained without rebinding it to the new catalog.

`prepare_admission` first resolves the request against the supplied
catalog and authenticated producer context. It produces a frozen
`PreparedAdmission`, containing four actions in this order:

1. Check the protected gate: schema v1, type `GATE`, state `OPEN`, and
   exact generation, catalog digest, and execution-ledger ARN matches.
2. Put the new request using `attribute_not_exists(pk)`.
3. Update the slot only if absent or explicitly free with the expected
   schema/type; bind it to the request key and attempt ID.
4. Update an existing schema-v1 `ACCOUNTING` record only when
   `unresolved_launches >= 0` and
   `occupied_slots >= unresolved_launches`; add one to both counters.

The transaction must succeed as a unit for admission to acquire ownership.
The accounting record requires protected initialization before admission
opens. Missing accounting must fail closed; neither admission nor a new
release may silently initialize or reset counters over existing history.

Each preparation generates a fresh attempt ID used as the DynamoDB
`ClientRequestToken` and the stored ECS `clientToken`. The frozen
transaction retains its exact parameters; `transaction_request()` returns
a fresh payload copy. Retries of that operation must retain the same
preparation. A new delivery gets a new attempt, and must not replay a
previous invocation's token to acquire its launch authority. Service
idempotency tokens supplement the durable request record.

`classify_existing_request` accepts a supplied low-level DynamoDB item
or `None` and returns `ABSENT`, `DUPLICATE`, or `CONFLICT`. Unexpected
record identity or schema raises `InvalidLedgerRecord`. No result grants
launch authority, including a duplicate whose stored owner matches the
current invocation. Absence is not a reservation, and the helper does not
read the ledger, modify the original record, or resolve concurrent writes.

Only the invocation that successfully acquires the new reservation may
progress toward dispatch. A request already present in the ledger cannot
grant a new launch opportunity. Transaction contention or infrastructure
errors must not be automatically labeled as duplicates or busy jobs.
If the transaction outcome remains uncertain, do not dispatch or release
reservations based on that uncertainty. The executor contract below
preserves that distinction; protected recovery remains unimplemented.

#### Admission executor result and retry contract

`execute_admission` accepts a frozen `PreparedAdmission`, a trusted
low-level DynamoDB client, and the current invocation ID. A mismatched
owner raises `ValueError` before client I/O. This is a local ownership
check, not authentication: runtime must freshly authenticate delivery
and prepare the request from protected context.

The executor makes one `transact_write_items` call with the original
payload and token. It performs no preflight read and has no outer retry
or cross-invocation recovery loop. Only the configured SDK retries that
submission. A result must not be treated as permission to repeat a write,
take over an original attempt, dispatch a task, or release reservations.

The frozen `AdmissionResult` separates submission certainty from its
diagnostic `reason`:

| Outcome | Contract |
|---|---|
| `CONFIRMED` | HTTP 200 acknowledges the exact operation, potentially an idempotent SDK replay of an earlier commit. It does not confer a new dispatch permit. |
| `DUPLICATE` | A conclusively rejected submission collides with an original request whose intent matches, and the collision lookup confirms current gate eligibility. Ownership remains with the original record. |
| `CONFLICT` | A conclusively rejected submission collides with an original request whose intent differs, and the collision lookup confirms current gate eligibility. No original record is changed. |
| `REJECTED` | The evidence establishes no commit for this submission, not for the request's lifetime. Existing reservations remain untouched. |
| `UNKNOWN` | A commit or outstanding write remains possible. Do not resubmit, dispatch, release state, or transfer ownership based on this result. |

Recognized service rejections establish `REJECTED` only with an HTTP
400/403 response and an explicit integer `RetryAttempts = 0`. Missing
retry metadata or a positive retry count leaves a final rejection
`UNKNOWN`: the count does not establish outcomes of earlier SDK attempts.
Timeouts, unclassified client failures, server errors, transactions still
in progress, token mismatches, and unexpected success responses also
preserve uncertainty. A successful SDK retry may confirm an earlier
commit; neither the acknowledgment nor a cached success is a fresh check
of current eligibility or authorization for another launch.

Cancellation codes retain the transaction's gate/request/slot/accounting
order. Reasons distinguish failed accounting conditions, gate ineligibility,
slot unavailability, configuration/permission faults, transient service
failures, and unclassified cancellations. `SLOT_UNAVAILABLE` is not proof
of normal contention: the condition also rejects malformed slot records.
Known faults are not hidden by a simultaneous request collision, and
missing or unfamiliar cancellation details never imply a duplicate.

Only a conclusively rejected request collision, with no gate or accounting
failure and at most a simultaneous slot-condition failure, triggers
`transact_get_items`. The executor reads the gate and original request in
one snapshot, checks the gate's schema/type, open state, generation,
catalog digest, and ledger binding, and then calls
`classify_existing_request`. A failed lookup, ineligible gate, or
missing/malformed original record preserves the known rejection of the
submission without returning an original record or acquiring ownership.
This lookup is not a dispatch claim or a replacement for lifecycle fencing.

Results retain the candidate request key and attempt ID, write/lookup AWS
request IDs, the write's SDK retry count, error codes, and cancellation
codes when available. Duplicate/conflict results include an immutable JSON
snapshot of the original request, retaining its original owner and attempt
even when they match the submitted candidate. The snapshot is internal
runtime data and must not be logged or exposed to producers. Service error messages and
cancellation items are excluded from diagnostic fields, and the original
snapshot is excluded from `repr`. Explicit serialization still requires
care to avoid exposing that snapshot.

`admission_client_config()` returns fresh Botocore `Config` arguments:
`retries = {"mode": "standard", "total_max_attempts": 3}`,
`connect_timeout = 1`, and `read_timeout = 2` seconds. The three-attempt
limit includes the initial request and applies separately to each API
call, including a collision lookup. This is a DynamoDB policy; it does
not change the separate one-attempt ECS `RunTask` policy.

The helper creates no client, and the executor trusts its supplied client.
Future runtime wiring must use `Config(**admission_client_config())` and
qualify actual SDK behavior. Socket timeouts are not an end-to-end deadline;
integration must budget both admission and collision lookup within the
Lambda invocation. No wrapper retry may discard an earlier `UNKNOWN`
result or substitute a fresh token to resolve uncertainty. The protected
recovery protocol remains a later checkpoint.

#### Dispatch ownership and launch-result recording

The approved dispatcher contract is implemented in
[dispatch.py](../modules/ecs_job_broker/lambda/dispatch.py), with scripted
clients only. `dispatch_admitted` receives the original `PreparedAdmission`,
its `admission_result`, the current invocation ID, a ledger client, and a
trusted `launcher_client_factory`. Request/attempt evidence and the prepared
owner must match before client I/O. A nonconfirmed admission does not enter
the dispatch protocol. Neither a caller-supplied invocation ID nor an
admission receipt is independently an authentication or launch credential.

The factory receives the stored launcher-role ARN and must return an ECS
client using that job's launcher identity and approved Region. Client setup
must not launch tasks. The dispatcher checks an effective integer
`total_max_attempts = 1` before acquiring the claim. Factory failure or an
invalid retry policy leaves existing reservations untouched. Role assumption,
effective IAM verification, explicit timeout selection, and invocation-budget
enforcement remain runtime integration requirements. The ledger client must
use the existing bounded DynamoDB configuration.

One dispatch claim transaction targets three existing ledger records:

1. Update the request from `REGISTERED` to `DISPATCHING`, requiring schema/type,
   the original invocation owner, attempt, execution intent, and exact launch
   snapshot, plus absence of a prior `dispatch_id`. Store the new dispatch ID.
2. Condition-check the schema-v1 `SLOT` in `OCCUPIED` state, bound to the same
   request, attempt, and job.
3. Condition-check schema-v1 `ACCOUNTING` with `unresolved_launches >= 1`
   and `occupied_slots >= unresolved_launches`.

The claim changes neither counter and creates no additional record. The dispatcher
generates a fresh `dispatch_id` for each entry, using it as the claim's
`ClientRequestToken`. SDK retries within that entry retain the same token and
parameters. A new entry receives a new token, so it cannot replay an earlier
claim's cached success; its conditional write must acquire a still-unclaimed
request. The claim ID is never accepted as a caller-supplied reusable permit.

Only a confirmed claim proceeds to one `run_task` call with the stored
parameters and original ECS client token. A rejected or uncertain claim
stops before ECS and performs no cleanup or ownership-recovering read.
The claim does not recheck an open gate: the original admission registered
an obligation that remains accounted for after closure. Fence completion
must wait for that obligation to be resolved or safely fenced.

`DispatchResult` separates `claim` and `recording` write evidence from the
`launch` observation. Write outcomes are `NOT_ATTEMPTED`, `CONFIRMED`,
`REJECTED`, and `UNKNOWN`; launch outcomes are `NOT_ATTEMPTED`, `ACCEPTED`,
`REJECTED`, and `UNKNOWN`. Claim and recording writes preserve uncertainty
after unobserved SDK attempts, following the same conservative response
contract as admission submission.

The initial ECS classifier requires explicit `RetryAttempts = 0` for a
conclusive observation. An HTTP 200 response with exactly one task ARN and
no failures can be `ACCEPTED`. The task ARN must match the admitted partition,
account, and Region; a cluster-qualified ARN must identify the expected
cluster. Returned cluster/revision fields, when present, must match the
stored request. Optional task fields are not required to be present.

An HTTP 200 response with an empty tasks list and nonempty failures carrying
reason codes can be `REJECTED` when no failure identifies a task that may
need tracking. The supported exception refusals are `AccessDeniedException`,
`BlockedException`, `ClusterNotFoundException`, `InvalidParameterException`,
`PlatformTaskDefinitionIncompatibilityException`, `PlatformUnknownException`,
and `UnsupportedFeatureException`. They require HTTP 400/403, zero SDK
retries, and absent or empty `resourceIds` before they can resolve the launch
as rejected.

Timeouts, server errors, generic `ClientException`, `ConflictException`,
unfamiliar errors, missing/positive retry metadata, and contradictory or
unexpected responses remain `UNKNOWN`. Available task identifiers from
task responses, failure resources, and token conflicts are retained for
reconciliation. HTTP success alone does not establish an accepted task,
and acceptance does not establish application completion.

After observing ECS, the dispatcher attempts a separate recording transaction
with a fresh token distinct from admission and claim tokens. It targets the
three records below, plus an immutable task-lookup put for an accepted launch.
Every request update requires the same owner, attempt, `dispatch_id`,
execution intent, launch snapshot, and prior `DISPATCHING` state. Every
transaction checks matching slot ownership and positive valid accounting:

| Observed launch outcome | Request update | Slot operation | Accounting operation |
|---|---|---|---|
| `ACCEPTED` | Set `LAUNCH_ACCEPTED`, `task_arn`, and `launch_observation_json`. | Check the occupied slot; retain its owner. | Subtract one unresolved launch; leave occupied slots unchanged. |
| `REJECTED` | Set `LAUNCH_REJECTED` and `launch_observation_json`. | Set the matching slot to `FREE`; remove its request and attempt bindings. | Subtract one from both counters. |
| `UNKNOWN` | Set `LAUNCH_UNKNOWN` and `launch_observation_json`. | Check the occupied slot without changing it. | Check accounting without decrementing either counter. |

Only an `ACCEPTED` result adds the fourth action: create a `TASK_LOOKUP`
requiring `attribute_not_exists(pk)`. A lookup conflict rejects the entire
recording transaction and cannot reassign the task. Accepted recording thus
has four cancellation-reason positions: request, slot, accounting, and lookup.
Claims and rejected/unknown result transactions retain three positions.

These changes commit together or not at all. Expected-state/attempt/claim
conditions prevent repeated result processing from decrementing counters
again. The original request identity, intent, and provenance are retained.
`launch_observation_json` contains structured outcome/reason data, AWS request
ID and retry count, error/failure codes, and available task/resource ARNs;
it excludes full task payloads, service messages, and failure-detail text.

An accepted task remains an accepted in-memory observation even if recording
is rejected or uncertain. A failed recording may leave `DISPATCHING` or an
already-committed result; no additional ECS call or cleanup follows. Likewise,
a confirmed write of `LAUNCH_UNKNOWN` records uncertainty without resolving
the obligation. `NOT_ATTEMPTED` describes this dispatcher entry and does not
release an existing reservation. The completion contract below handles tasks
whose acceptance was durably recorded. Uncertain launches and failed launch
recording remain obligations for protected recovery.

#### Task lookup and terminal-state recording

The owner approved an immutable task lookup and protected ECS `STOPPED` event
contract for offline implementation. [completion.py](../modules/ecs_job_broker/lambda/completion.py)
implements `record_task_completion` through a supplied low-level DynamoDB client.
The caller supplies protected application/environment identifiers, the ledger
table ARN, and one decoded event whose delivery origin it has authenticated.

Each accepted launch creates a schema-v1 `TASK_LOOKUP` in the existing `pk`-only
ledger, atomically with `LAUNCH_ACCEPTED` and its accounting update:

- Key: `task:v1:<sha256>` over `(application_id, environment, task_arn)`, using
  the same ordered compact ASCII-escaped JSON-array encoding as other keys.
- Fields: schema/type, application/environment, `task_arn`, `request_pk`,
  `attempt_id`, and `dispatch_id`.
- Creation requires an absent key. The lookup is retained after completion;
  this checkpoint introduces no expiry, reassignment, deletion, or backfill.

The lookup enables direct strongly consistent reads without a secondary index
or a ledger scan. It identifies the candidate request; the original request and
conditional transaction still establish the exact launch binding. The admission
model, launch attempt token, and approved ECS parameters remain unchanged.

The intended delivery path is ECS Task State Change events through a protected
EventBridge rule and encrypted completion queue to the broker. That infrastructure,
its IAM/invocation protections, retained evidence, and handler integration remain
unimplemented. Ordinary application producers and direct Lambda callers must
not be able to inject trusted completion evidence. Checking event `source`,
type, account, or Region alone does not authenticate delivery.

The helper requires task-level `lastStatus = STOPPED`. A desired stop,
individual container exit, or missing task observation cannot release capacity.
It checks event account/Region and ECS ARN scope against the protected ledger
context, then consistently reads the lookup and original request. Schema/type,
application/environment, request, attempt, dispatch, and task bindings must
agree. The event cluster and exact task-definition revision must match the
original stored launch; the attempt token, job, and execution-intent snapshot
must also be consistent.

For an accepted launch, one three-item transaction performs:

1. Update the original request from `LAUNCH_ACCEPTED` to `TASK_STOPPED` and
   store `completion_observation_json`. Require the same schema/type, scope,
   job, original owner, attempt, dispatch, task ARN, intent, and launch snapshot,
   with no prior completion evidence.
2. Set the schema-v1 job slot from `OCCUPIED` to `FREE` and remove its request
   and attempt bindings, requiring the exact request/attempt/job ownership.
3. Decrement only `occupied_slots`, requiring schema-v1 `ACCOUNTING`,
   `unresolved_launches >= 0`, and `occupied_slots > unresolved_launches`.

The strict accounting comparison preserves the unresolved-launch count and
prevents occupied capacity from falling below it. All three changes commit
together. A fresh completion transaction token is distinct from admission and
dispatch tokens; SDK retries retain that completion payload and token. Durable
prior-state and ownership conditions prevent double release on later delivery.
Completion requires neither an open gate nor the current catalog generation:
previously recorded tasks must remain drainable after closure and across releases.

`CompletionResult` separates the outcome/reason from recording `WriteEvidence`
and structured read-failure diagnostics. `RECORDED` means the transaction was
acknowledged; `ALREADY_RECORDED` means a consistent original `TASK_STOPPED` record
already contains matching terminal evidence and no new write occurs. An old
notification therefore cannot release a subsequently acquired slot. A consistent
nonterminal event is `IGNORED` before ledger I/O. Invalid event/record bindings or
a conclusively rejected transaction return `REJECTED`, with distinct reasons.
Read failures, unexpected read responses, and uncertain writes return `UNKNOWN`.

A missing lookup/request or a still-unresolved launch returns `DEFERRED`. This
includes an event arriving before accepted-launch recording, an untracked task,
or an older accepted record without a lookup; absence cannot distinguish these
cases. The caller must retain evidence for later processing or protected recovery.
This helper does not create missing lookups, resolve unknown launches, or release
their reservations. Queue acknowledgement, retry/failure routing, and retained
delivery evidence remain runtime integration requirements.

A lost completion acknowledgement may hide a committed transaction. The helper
performs no separate cleanup or outer retry; a later delivery can consistently
observe the original terminal record. Competing conditional writes cannot both
release the same reservation. Scripted tests model these responses; AWS
transaction execution, event authenticity, and delivery behavior require
qualification.

`TASK_STOPPED` establishes termination, not application success. Nonzero exits
and startup failures may release capacity after the task stops. Retained evidence
includes task/cluster/revision identifiers, event ID/time/resource version,
stopped time/code, and available container names and exit codes. Optional
diagnostics do not determine release eligibility; full task payloads, overrides,
and free-form stop/container reasons are excluded.

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

The approved model uses the application/environment accounting record
across every release and generation. `unresolved_launches` counts attempts
whose launch outcome is not conclusively recorded or that may still
produce a task. `occupied_slots` also includes slots held by known tasks.
The counters establish whether obligations remain; retained request
records identify those obligations for investigation and recovery.

The following counter transitions are approved requirements for execution
and reconciliation code. Admission increments, dispatch launch-result updates,
and terminal-state slot release have scripted-client coverage. Protected event
delivery, deployed coordination, and recovery remain unimplemented:

| Transition | `unresolved_launches` | `occupied_slots` |
|---|---|---|
| New admission | Add one | Add one |
| Launch conclusively recorded with a task | Subtract one | Unchanged |
| Conclusive failure with no remaining launch possibility | Subtract one | Subtract one |
| Previously recorded task conclusively terminates | Unchanged | Subtract one |
| Timeout, lost response, or interrupted executor | Unchanged | Unchanged |

Result and terminal-state transitions must update the request, relevant
slot state, and counters transactionally, conditioning on the expected
attempt and prior state. Duplicate processing must not decrement counters
twice. A known running task must retain its occupied slot after its launch
attempt is resolved.

Fence completion requires the same gate to remain closed for the same
closure operation and `unresolved_launches == 0`. Subsequent workload
quiescence additionally requires `occupied_slots == 0`. The coordinator
must establish these conditions transactionally when recording the
corresponding lifecycle transition. Concrete coordinator operations and
the closure-operation binding remain unimplemented.

An empty scan cannot replace these conditions. The later implementation
must demonstrate complete accounting, trustworthy outcome resolution,
and protected initialization and restore behavior. Counters must not be
reset on catalog changes, releases, or role replacement. The shared
accounting item introduces contention across jobs in the same application;
that tradeoff is accepted for this initial model.

A resolved launch attempt is distinct from a released job slot.
A known running task retains its slot until trustworthy terminal
resolution. Task lookups and terminal recording implement the offline
correlation/update contract; authenticated event delivery and operational
monitoring remain required for deployed behavior.

#### Initial dispatch policy and protected recovery

Before dispatch, persist an explicitly chosen ECS clientToken and
immutable ECS request parameters.

The approved initial RunTask policy is one Botocore attempt using
`total_max_attempts = 1`. The dispatcher checks the supplied client's retry
configuration; runtime integration must select explicit connection/read
timeouts within the Lambda execution budget and enforce the remaining budget.

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
attempt and block fence completion. The dispatcher implements the initial
conclusive ECS classifier described above; effective behavior requires AWS
qualification. Exact ECS timeout values, deadline integration, protected
completion-event delivery, and the recovery procedure remain outstanding.

#### Implementation and activation boundaries

The owner accepted the request schema, producer mapping, catalog,
generation, uniqueness/conflict, and override-rejection contracts for
the offline helper work, and subsequently approved the four-record
admission model, executor design, dispatch ownership and result recording,
and the immutable task lookup and protected ECS `STOPPED` event contract for
offline implementation. These contracts preserve explicit outcome certainty,
operational diagnostics, bounded SDK retries, conditional dispatch ownership,
and atomic launch/terminal result and accounting transitions.

Offline fixtures may supply simulated authenticated identity context.
They do not prove AWS attribution or effective lifecycle fencing.

Approval covers admission, dispatch, task lookup, and completion source with
scripted-client coverage; it does not authorize transactional AWS execution,
completion-event infrastructure deployment, or ECS task launches.
Before actual AWS execution, approve the concrete gate authority, permissions,
initialization, and coordinator lifecycle operations, and integrate the
authenticated request/completion delivery, role-scoped SDK clients, and
invocation budget. These must implement the approved admission and accounting contract while preserving
the independent protection described above. Actual SDK retries, transaction
races, ECS outcomes, and runtime recovery require AWS qualification.

Before activation, implement and qualify producer authentication,
protected artifact deployment, IAM ceilings, network admission,
alternate-path prevention, lifecycle fencing, execution monitoring,
and protected recovery.

The next implementation focus is a cohesive offline execution path connecting
the existing helpers, trusted delivery boundaries, and explicit message
acknowledgement/retry decisions. This direction does not settle the outstanding
protected authority or deployed authentication decisions.

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
| Accepted launch records a task | Immutable task lookup commits with the accepted result and accounting change |
| Matching trusted task-level `STOPPED` event | Record termination and release only that task's slot atomically; preserve unresolved launches |
| Duplicate completion after slot reuse | No second decrement or release of the new reservation |
| Completion arrives before launch recording or its write acknowledgement is lost | Preserve uncertainty/evidence; later delivery may observe the durable result |
| Forged completion delivery or mismatched task/attempt | No release authority; field consistency alone does not authenticate delivery |
| Ledger restore or history removal | No silent restoration of replay authority |

The 166-test suite covers offline parsing, authorization, catalog loading,
key derivation, transaction preparation, supplied-record classification,
executor responses/cancellations, dispatch claim/result and task-lookup
contracts, and completion identity/transaction/redelivery behavior relevant
to these cases.
The full runtime outcomes in this table remain acceptance requirements
for subsequent implementation and qualification; offline coverage does
not establish deployed enforcement.

## Qualification boundary

M2-B1a establishes a reusable Terraform policy contract only.

Subsequent qualification must verify the generated policies and demonstrate positive and negative launch authorization for two independently scoped jobs, including unauthorized revisions, clusters and role passing.

Live AWS authorization and protected network-admission behavior require separate deployment approval.

This contract does not authorize an AWS Apply, a task launch, or completion of the broader M2 milestone.
