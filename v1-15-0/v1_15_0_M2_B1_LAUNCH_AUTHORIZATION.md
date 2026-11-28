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
lookup and protected ECS `STOPPED` event contract for offline implementation,
followed by integrated broker orchestration and acknowledgement/retry decisions,
and the authority split and disabled runtime bootstrap.
Catalog loading, request resolution, admission preparation and execution,
conditional dispatch claims, ECS outcome classification, launch-result
transactions, task lookup creation, atomic terminal recording/slot release,
connected request/completion flows, the configured handler, scoped SDK clients,
and invocation-budget guards are implemented with a 204-test offline suite.
Terraform now defines foundation-owned admission gates and keys, scoped broker
gate permissions, schema-v2 Scheduler requests, request-queue producer restrictions,
and disabled completion-event transport with scoped consumer permissions,
separate delivery/processing DLQs,
and failure alarms. PR #1009 also implements dedicated application backend
storage in the existing environment state-bootstrap roots. Concrete
deployment/invocation protections, gate initialization,
delivery integration and key-policy wiring, lifecycle coordination, runtime
monitoring, recovery, and live qualification remain open.

**Scope:** Request-schema-v2 parsing, producer-to-job policy evaluation,
durable request-key derivation, complete schema-v1 catalog loading,
catalog source digests, four-record admission transaction preparation,
duplicate/conflict classification, executor result and cancellation
handling, DynamoDB client configuration, dispatch ownership, one-attempt
ECS calls, immutable task lookups, conditional launch and terminal-state
result/accounting updates, integrated single-message orchestration,
fixed packaged runtime configuration, queue-based attribution under independently
enforced delivery controls, scoped SDK construction, invocation-budget guards,
acknowledgement/retry decisions, and offline regression coverage. Terraform
configures a 60-second Lambda timeout and 360-second request/completion queue
visibility; it also defines per-application foundation gates, their keys, scoped
broker access, Scheduler generation inputs, request-queue producer restrictions,
and the ECS EventBridge-to-SQS completion path. Invocation, consumption, and the
completion rule remain disabled.
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
`broker.py` connects these helpers, classifies durable duplicates, and returns
acknowledgement/retry decisions. Its configured `lambda_handler` loads fixed
package files, attributes request/completion records, constructs scoped clients,
and checks remaining invocation time before operations. Real clients would
perform AWS operations; tests use scripted clients and pinned SDK stubs without
network access. This implementation does not establish artifact provenance,
authenticate a forged direct invocation, establish effective protected delivery,
or perform protected recovery. Budget guards do not cancel in-flight calls or
prove an uncertain attempt resolved. AWS operations and broker activation remain
outside the completed offline increment.

**Current coverage:** 204 offline Python tests, including nine admission
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
failures, and minimal terminal evidence. Twenty-two broker tests connect the
actual helpers with scripted clients and simulated authenticated delivery,
covering request/duplicate/completion flows, acknowledgement/retry decisions,
authentication and configuration failures, unresolved and inconsistent duplicates,
admission/claim/result uncertainty, fresh conditional admission on redelivery,
early completion, lost acknowledgements, and restricted diagnostics. Sixteen
additional runtime tests bring `test_broker.py` to 38 tests: fixed package and
function/resource scope bindings, role-ID attribution independent of session/body
claims, queue separation, completion without request configuration or launcher
credentials, exact catalog bytes and independent approvals, bootstrap error
redaction, exact role/Region/temporary credential use without fallback, budget
loss between stages, and pinned SDK request-model compatibility. The SDK test
constructs real Boto3 clients with fake credentials and Botocore `Stubber`, blocks
network access, and fails rather than skips if dependencies are missing.
These tests inspect generated operations, supplied records, client construction,
and scripted or SDK-stubbed responses. They do not execute DynamoDB conditions or
actual HTTP retries, launch ECS tasks, or prove AWS concurrency, authentication,
effective IAM, or fencing. Twenty-four plan-only broker Terraform tests cover the
infrastructure contract, including scoped gate access, 60/360-second timing,
and disabled activation. Seven completion-delivery tests cover optional creation,
family routing across revisions, exact-rule queue submission policies, failure
routing/alarms, scoped consumer permissions, and rejected scope/family inputs.
Five request-delivery tests cover the unconditional submission deny by default,
exact role allowlisting without grants or activation, preserved TLS protection,
and rejection of wildcard, cross-account, and STS session ARNs.
Three gate tests, eight Scheduler tests, and four admission-specific baseline
tests cover storage, key ownership, foundation
wiring, and schema-v2 request envelopes.

**Initial increment validation (historical):** Implementation commit
`97dbda7f6dc1defd19cab4b565d3e9fc0d53398a` passed Terraform Module Tests
run #105: 26 broker tests under Python 3.12.16, 64 Terraform native tests,
and 19 IAM regression tests.

[CI evidence](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/45492053955)

That historical run covers the initial 26-test helper increment, not the
current 204-test suite. Offline results do not establish live AWS
qualification or proof of zero drift.

#### Producer identity and authorization

The initial supported category is trusted infrastructure-level job
requests authorized by AWS producer-role identity.

The broker verifies the producer and its permission to request a job.
A trusted application producer remains responsible for required
application-user and tenant authorization. Jobs requiring the broker
to independently verify delegated authorization need a separately
approved contract.

The runtime bootstrap implements attribution using the SQS system `SenderId`
in assumed-role `role-id:session-name` form. It extracts the role ID and maps
it through the protected catalog to a stable logical producer identity and
its permitted jobs. This attribution is trustworthy only under the independently
enforced delivery and invocation controls below.

The request queue now restricts submission through `request_producer_role_arns`,
a set of exact IAM role ARNs in the approved cluster's account and partition.
The default empty set produces an unconditional `sqs:SendMessage` deny; existing
compositions must configure approved producers before submissions can succeed.
A nonempty set uses `ArnNotEqualsIfExists` on `aws:PrincipalArn` to deny other
or missing principal identities. The existing insecure-transport deny remains,
and the policy adds no Allow grants. Scheduler producers use their execution-role
ARNs; wildcard, STS session, and schedule ARNs are not accepted.

Queue admission by role ARN remains separate from catalog job authorization by
role ID. A replacement role with the same ARN still needs its new role ID mapped
in the protected catalog. Producers also require separate SQS/KMS permissions
and protected role trust. Changing the allowlist does not remove already queued
messages, close the admission gate, or establish a lifecycle fence.

Role-session names, request keys, schedule identifiers, message-body
claims, and custom message attributes are not authentication evidence.
A recreated IAM role must not inherit authorization solely because its
name matches a previously approved role.

This mechanism requires an independently protected SQS delivery path.
A direct Lambda caller can fabricate an SQS-shaped event; inspecting
its apparent queue ARN, event source, or SenderId cannot authenticate
that invocation.

The request submission policy is now defined. Required independent controls
include protected producer-role trust, Scheduler mutation and role-passing
restrictions, protected Lambda invocation and deployment, protected event-source
mappings, and prevention of alternate ECS launch paths.

Preserve Scheduler's schedule-group-scoped trust condition. Per-schedule
authorization also depends on controlling schedule changes and
execution-role passing.

Actual Scheduler/on-demand attribution, role replacement, and bypass
prevention require AWS qualification. Operator redrive and replay
remain unavailable until an approved workflow preserves or
independently re-establishes authorization and durable request identity.

#### Protected job catalog and deployment sequence

The initial representation is immutable schema-v1 JSON packaged as `catalog.json`
beside `broker.py` in the approved Lambda ZIP. The complete loader and fixed-file
runtime loading are implemented. A separate packaged `runtime.json` supplies
protected scope and resource approvals. Protected artifact packaging, approval,
and deployment remain outstanding.

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
Computing this digest does not establish approval. The runtime decodes the
packaged UTF-8 bytes directly without newline translation or JSON rewriting.
The coordinator must bind the independently approved digest to the admission
generation. Runtime cluster/network approval values must come from independent
review, not from copying the catalog's selections into its own approval inputs.

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

Scheduler now emits schema v2 and requires `admission_generation` whenever
schedules are configured. It preserves the schedule ARN and scheduled-time
request key; generation changes do not create a new request identity. Schedules
remain disabled by default and must stay disabled pending qualification.

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

The approved model uses a separate DynamoDB gate table in the same account
and Region as the application execution ledger. The owner subsequently approved
the following authority split for the disabled runtime bootstrap checkpoint:

- A platform-controlled deployment workflow is the sole privileged writer of
  application state, including protected broker code, configuration, IAM, and
  delivery resources. Ordinary application CI cannot substitute unapproved
  artifacts or acquire this authority.
- A separate independently protected gate controller owns mutable eligibility,
  generation, catalog-binding, initialization, and lifecycle transitions.
- The application broker reads/condition-checks the gate and maintains execution
  records; it cannot mutate gate authority or its own deployment controls.

The existing `dev`, `staging`, and `prod` foundation roots now accept
`job_admission_applications`, defaulting to an empty set. `modules/security`
creates a dedicated CMK and alias per application; `baseline/main.tf` calls
`modules/ecs_job_admission_gate` with the corresponding key ARN. Each table uses
on-demand capacity, CMK encryption, point-in-time recovery, and deletion protection,
with no TTL or Terraform-managed items. The `job_admission_gates` output exposes
table/key references by application ID for future protected publication.

Broker resources remain in application state. The optional `admission_gate`
input grants exact-table `GetItem`/`ConditionCheckItem` access and exact-key
`kms:Decrypt`, restricted to DynamoDB and the gate table/account encryption
context. Gate and key ARNs must match the approved cluster's partition, account,
and Region, and the gate must be distinct from the ledger. No gate-write grant
is added; omitting the input adds no gate access.

These are Terraform implementations, not deployed qualification. Protected
publication, deployment identities and trust policies, the gate controller,
and initialization remain pending. An empty gate table authorizes no jobs.
The existing broad foundation administrative role is not an ordinary application
deployment identity; foundation ownership alone does not establish independent
protection.

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
handling are implemented in the executor, with client construction supplied by
the runtime bootstrap; protected initialization, deployment/invocation controls,
and effective AWS permission qualification remain outstanding.

Transactional permissions derive from the underlying item actions.
Do not introduce a speculative standalone `dynamodb:TransactWriteItems`
IAM permission.

#### Approved four-record admission model

One admission operation targets a protected gate and three records in
the existing `pk`-only execution ledger. The launch attempt is embedded
in the request record for the initial one-attempt policy.

| Record | Key scope | Admission action |
| --- | --- | --- |
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
| --- | --- |
| `CONFIRMED` | HTTP 200 acknowledges the exact operation, potentially an idempotent SDK replay of an earlier commit. It does not confer a new dispatch permit. |
| `DUPLICATE` | A conclusively rejected submission collides with an original request whose intent matches, and the collision lookup confirms current gate eligibility. Ownership remains with the original record. |
| `CONFLICT` | A conclusively rejected submission collides with an original request whose intent differs, and the collision lookup confirms current gate eligibility. No original record is changed. |
| `REJECTED` | The evidence establishes no commit for this submission, not for the request's lifetime. Existing reservations remain untouched. |
| `UNKNOWN` | A commit or outstanding write remains possible. End the current invocation without resubmission, dispatch, state release, or ownership transfer. Later authenticated redelivery follows the conditional admission contract below. |

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
The runtime bootstrap uses these `Config` arguments with
`ignore_configured_endpoint_urls = true`. It checks the invocation budget before
admission submission and collision lookup. Socket timeouts are not an end-to-end
deadline, and actual SDK retry/timing behavior still requires AWS qualification.
No wrapper retry may discard an earlier `UNKNOWN`
result or substitute a fresh token within the invocation to resolve uncertainty.
Later authenticated redelivery may prepare a new candidate under the same durable
request key, as described in the integrated broker contract below; it cannot
adopt an existing attempt. The protected recovery protocol remains a later
checkpoint.

#### Dispatch ownership and launch-result recording

The approved dispatcher contract is implemented in
[dispatch.py](../modules/ecs_job_broker/lambda/dispatch.py), with offline scripted
and SDK-stubbed coverage. `dispatch_admitted` receives the original `PreparedAdmission`,
its `admission_result`, the current invocation ID, a ledger client, and a
trusted `launcher_client_factory`. Request/attempt evidence and the prepared
owner must match before client I/O. A nonconfirmed admission does not enter
the dispatch protocol. Neither a caller-supplied invocation ID nor an
admission receipt is independently an authentication or launch credential.

The factory receives the stored launcher-role ARN and must return an ECS
client using that job's launcher identity and approved Region. Client setup
must not launch tasks. The dispatcher checks an effective integer
`total_max_attempts = 1` before acquiring the claim. Factory failure or an
invalid retry policy leaves existing reservations untouched. The runtime bootstrap
implements exact-role assumption, explicit Region and temporary ECS credentials,
connection/read timeouts, and invocation-budget guards. Effective IAM and actual
timing behavior remain qualification requirements. The ledger client uses the
existing bounded DynamoDB configuration.

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
| --- | --- | --- | --- |
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

The delivery path is ECS Task State Change events through an EventBridge rule
and encrypted completion queue to the broker. Terraform now defines this path,
queue submission restrictions, scoped consumer IAM, and failure handling as
described below. Protected deployment/invocation controls, key-policy wiring,
and deployed delivery qualification remain pending. The handler can route a
distinct configured completion queue, or reject completion routing when its ARN
is `null`. Ordinary application producers and direct Lambda callers must not be
able to inject trusted completion evidence.
Checking event `source`, type, account, or Region alone does not authenticate delivery.

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
delivery evidence require deployed runtime integration; the broker adapter below
implements the offline acknowledgement/retry decisions.

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

#### Completion-event infrastructure

The application-owned `ecs_job_broker` module accepts optional
`completion_delivery = { queue_cmk_arn, task_definition_family_arns }`.
The default `null` creates no completion resources or consumer grants. Configured
delivery requires jobs, an exact CMK ARN, and revision-free family ARNs in the
approved cluster's partition, account, and Region, covering every current job.

[events.tf](../modules/ecs_job_broker/events.tf) defines a default-bus rule for
`aws.ecs` / `ECS Task State Change`, the exact account/Region/cluster, and task-level
`lastStatus = STOPPED`. Each family uses an ARN prefix ending in `:` so older
revisions still match without admitting similarly named families. Routing does
not depend on successful exit codes or the current catalog revision. Retired
families and broker infrastructure must remain until tasks and pending events
have drained; Terraform cannot establish that historical drain condition.

The target preserves the complete original event. [queue.tf](../modules/ecs_job_broker/queue.tf)
defines the distinct encrypted standard completion queue with 360-second
visibility, four-day retention, and `maxReceiveCount = 5`. Its processing DLQ
accepts redrive only from that queue. EventBridge uses a separate delivery DLQ
with a retry policy bounded at 86,400 seconds and 185 attempts. Both DLQs use the
supplied CMK and 14-day retention. [alarms.tf](../modules/ecs_job_broker/alarms.tf)
routes either DLQ's visible-message alarm and EventBridge's
`InvocationsFailedToBeSentToDlq` alarm to the existing `alarm_topic_arn`.

All completion queues deny insecure transport. The completion queue and delivery
DLQ allow `events.amazonaws.com` to send only for the exact rule and source account;
separate explicit denies reject non-EventBridge senders and other or absent source
rule ARNs, including callers with independent same-account IAM send grants.
The processing DLQ retains SQS-managed redrive and has no EventBridge send grant.
The broker receives only receive/delete/attribute access to the completion queue
and decrypt access to its exact CMK through regional SQS with that queue's
encryption context. No send, DLQ-consumption, or replay grants are added.

The external application-owned CMK policy must separately authorize EventBridge's
`kms:GenerateDataKey` and `kms:Decrypt` operations. The module neither creates that
key nor manages its policy. The `broker_completion_delivery` output groups `queue`,
`dlqs.delivery`, `dlqs.processing`, `rule`, and `event_source_mapping_uuid`;
the protected runtime package must bind its `completion_queue_arn` to `queue.arn`.
The mapping exists only when a Lambda package is configured.

The rule is `DISABLED`, both SQS mappings have `enabled = false`, and Lambda
reserved concurrency stays zero. A disabled rule captures no events. Queue policy
restrictions do not protect against unauthorized deployment/policy changes or
forged direct Lambda invocation; independent authority controls and effective
IAM/KMS/delivery qualification remain required. Finite DLQ retention is not
automatic recovery or proof permitting slot release, replay, or fence completion.

#### Integrated broker orchestration and delivery disposition

The owner approved the integrated offline contract implemented by
[broker.py](../modules/ecs_job_broker/lambda/broker.py). `process_delivery`
connects the existing catalog, admission, dispatch, and completion helpers.
`handle_sqs_event` accepts exactly one record and uses the current invocation ID
with supplied protected configuration, clients, and an authentication adapter.
The configured `broker.lambda_handler` now bootstraps this adapter as described below.

The injected `authenticate_delivery(record)` must establish protected delivery
provenance and return `AuthenticatedDelivery` with a trusted request/completion
kind and producer attribution. Body fields cannot select that trusted route or
identity. Creating this object, matching queue ARN or `SenderId`, or checking
event shape does not authenticate an invocation. Tests simulate the trusted
boundary. The production bootstrap checks queue and sender metadata. Request and
completion queue restrictions are now defined, but concrete AWS invocation restrictions,
deployment protections, and bypass prevention still require implementation and
qualification.

Requests load the supplied protected catalog and require its application/environment
to match runtime scope before admission. Completion uses the original launch
snapshot and does not load the current catalog, evaluate the admission gate, or
construct a launcher client. Gate closure and catalog replacement must not prevent
terminal recording for an already-recorded task.

`DeliveryResult` contains `ACK` or `RETRY`, a diagnostic reason, and available
request/attempt/dispatch/task identifiers and error code. `ACK` establishes that
message handling is complete; it does not establish application-job success.

| Condition | Disposition and authority |
| --- | --- |
| ECS `ACCEPTED` or conclusive `REJECTED`, with result recording `CONFIRMED` | `ACK`; the launch outcome is durably recorded. |
| Eligible matching duplicate with consistent original `LAUNCH_ACCEPTED`, `LAUNCH_REJECTED`, or `TASK_STOPPED` evidence | `ACK`; no dispatch or ownership transfer. |
| Duplicate `REGISTERED`, `DISPATCHING`, or `LAUNCH_UNKNOWN`; malformed or inconsistent resolved record | `RETRY`; preserve the original attempt. |
| Invalid, unauthorized, stale, or conflicting request; gate/slot/accounting denial; authentication or infrastructure failure | `RETRY`; retain the reason for bounded failure handling. |
| Admission `UNKNOWN`, launcher setup failure, unconfirmed dispatch claim, launch `UNKNOWN`, or unconfirmed result recording | `RETRY`; no further dispatch, takeover, or reservation cleanup in this invocation. |
| Completion `RECORDED`, `ALREADY_RECORDED`, or `IGNORED` | `ACK`; a consistent nonterminal event requires no terminal write. |
| Completion `DEFERRED`, `REJECTED`, or `UNKNOWN` | `RETRY`; preserve delivery for later processing or investigation. |

A recorded `LAUNCH_UNKNOWN` remains unresolved. Duplicate classification requires
current producer authorization plus the executor's gate and intent checks. Resolved
duplicates additionally require original owner/attempt/dispatch identity,
consistent stored launch parameters and launch observation, and matching terminal
evidence for `TASK_STOPPED`. The returned duplicate identifiers belong to the
original attempt. A duplicate never passes to dispatch.

Uncertainty ends the current invocation without an outer retry or replacement
token. On a later authenticated request delivery, preparation creates a fresh
candidate attempt under the same durable request key. Conditional creation
arbitrates admission. If the earlier uncertain operation committed, the original
record remains owned by its original attempt; unresolved work is retried without
takeover. If it did not commit and the fresh candidate wins all admission
conditions, that candidate may proceed through the normal dispatch claim.
Neither SQS delivery identity nor receive count grants execution authority.

`handle_sqs_event` returns a serializable result only for `ACK` and raises
`RetryDelivery` otherwise. Authentication failures and unexpected processing
exceptions fail the invocation with diagnostic codes rather than raw exception
messages. Results exclude message bodies, catalog contents, and internal ledger
snapshots; unbound completion-event task fields are not echoed into results.

The adapter follows the existing batch-size-one contract without partial-batch
responses, manual SQS deletion, or manual failure forwarding. Request delivery
uses the configured bounded queue-to-DLQ path once integrated and activated.
Completion transport and its separate failure paths are also defined in Terraform
but remain disabled pending protected integration and qualification. A DLQ
arrival does not resolve an execution, release capacity, or complete a lifecycle
fence; queue retention is finite and protected recovery remains required.

#### Runtime bootstrap, SDK, and invocation-budget contract

The owner approved implementation of the runtime bootstrap with activation
disabled. The configured `broker.lambda_handler` lives in the existing
[broker.py](../modules/ecs_job_broker/lambda/broker.py); this checkpoint adds no
Python modules. It composes the existing helpers rather than creating a second
execution path.

The handler accepts exactly one SQS record and reads fixed `runtime.json` beside
its own source. The schema-v1 configuration contains stable `application_id` and
`environment`, the unqualified `function_arn`, `ledger_table_arn`,
`request_queue_arn`, and `completion_queue_arn` (a distinct queue or `null`).
The function ARN must match Lambda context; an alias/version qualifier on the
invoked ARN may refer to the same configured function. Resource ARNs must match
the function's partition, account, Region, and expected service. Neither event
fields nor custom message attributes select configuration files or trusted scope.

Request processing additionally requires `requests.gate_table_arn` and
`requests.catalog_approvals`, containing `approved_cluster_arn`,
`approved_private_subnet_ids`, and `approved_security_groups_by_job`. The gate
must be distinct from the ledger, and the cluster must match function scope.
The handler reads the fixed `catalog.json` bytes without rewriting them, then
uses the existing catalog validators with these independently approved values.
Completion processing needs only common configuration and a ledger client;
it does not load the catalog or request-specific configuration, inspect gate
eligibility, or construct STS/ECS clients.

The adapter requires SQS source/Region consistency and exact configured queue
ARNs. Requests use the system `SenderId` role ID for catalog authorization;
session names and body/custom-attribute identity claims confer no authority.
Only the distinct configured completion queue can select completion processing.
These are consistency and attribution checks under an independently protected
transport, not proof that a direct invocation came from SQS. Platform controls
must prevent ordinary direct invocation, unauthorized queue submission/mutation,
and unauthorized event-source-mapping or Lambda deployment changes before activation.

All SDK clients use the Region derived from the verified function ARN,
standard retry mode, and `ignore_configured_endpoint_urls = true`:

| Client | Credential authority | Total attempts per API call | Connect/read timeouts |
| --- | --- | --- | --- |
| DynamoDB | Broker execution role | 3, including the initial request | 1 / 2 seconds |
| STS | Broker execution role | 1 | 1 / 2 seconds |
| ECS | Explicit credentials returned for the exact stored launcher role | 1 | 1 / 3 seconds |

After confirmed admission, the launcher factory requests an STS session for
the stored job-specific role, with `DurationSeconds = 900` and session name
`broker-<Lambda aws_request_id>`. It requires all three temporary credential
fields and an expiration more than 65 seconds ahead. Missing, incomplete,
or expiring credentials fail setup without using broker credentials for ECS.
There is no cached launcher session or fallback. This establishes client
construction behavior; live qualification must verify effective role identity,
permissions, and session behavior.

The deployment package must include the Python 3.12 dependencies in
[requirements-sdk.txt](../modules/ecs_job_broker/lambda/requirements-sdk.txt):
Boto3 `1.43.118`, Botocore `1.43.118`, s3transfer `0.19.0`, jmespath `1.1.0`,
python-dateutil `2.9.0.post0`, six `1.17.0`, and urllib3 `2.7.0`. Package the
complete pinned set with the source and configuration; review and refresh pins
before release. The Terraform Module Tests workflow installs this same set
before the 204-test suite. SDK coverage uses request models and `Stubber` with
fake credentials and network access blocked; it does not exercise actual HTTP
retries or prove deployed SDK behavior. Packaging does not establish provenance,
and the protected artifact publishing/approval pipeline remains unimplemented.

Terraform now configures a **60-second Lambda timeout** and **360-second request
and completion queue visibility timeout**, six times the function timeout. Batch
size remains one with a zero-second batching window. The handler uses Lambda context's
`get_remaining_time_in_millis()` to guard operation starts:

| Stage about to start | Minimum remaining invocation time |
| --- | --- |
| Bootstrap | 15 seconds |
| New request admission after catalog resolution/preparation | 50 seconds |
| Admission submission or collision lookup | 15 seconds |
| Launcher setup, including STS | 35 seconds |
| Dispatch ownership claim | 32 seconds |
| Single ECS launch call | 20 seconds |
| Launch-result recording | 15 seconds |
| Completion task-lookup read | 45 seconds |
| Completion original-request read | 30 seconds |
| Terminal-state transaction | 15 seconds |

The production handler supplies budget callbacks to admission, dispatch, and
completion; injected/offline callers may omit them. A failed guard stops further
operations and causes retry handling without releasing state or granting another
launch. Budget exhaustion after admission can leave `REGISTERED`; after the
claim or ECS call it can leave `DISPATCHING` with unresolved/occupied accounting.
Completion budget loss never authorizes speculative release. Guards reserve time
for subsequent work but cannot cancel in-flight calls or establish that an
uncertain operation has finished. Actual SDK backoff, network timing, and late
execution behavior require AWS qualification and protected recovery.

Bootstrap faults return retry diagnostics without raw configuration, credentials,
message bodies, or service exception text. The handler does not initialize
gate/accounting records, mutate its deployment/IAM, implement the gate controller,
or recover uncertain attempts. Existing Terraform environment variables
`BROKER_QUEUE_URL` and `EXECUTION_LEDGER_NAME` remain present; this bootstrap uses
the packaged configuration instead. Terraform does not generate the package files.
Reserved concurrency stays zero, both SQS mappings and the completion-event rule
stay disabled, and schedules must remain disabled.

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
delivery integration, deployed coordination, and recovery remain outstanding:

| Transition | `unresolved_launches` | `occupied_slots` |
| --- | --- | --- |
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
configuration; the bootstrap sets explicit connection/read timeouts and checks
remaining invocation time as specified above.

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
qualification. The configured timeout values and budget guards do not replace
protected completion-event delivery or the outstanding recovery procedure.

#### Implementation and activation boundaries

The owner accepted the request schema, producer mapping, catalog,
generation, uniqueness/conflict, and override-rejection contracts for
the offline helper work, and subsequently approved the four-record
admission model, executor design, dispatch ownership and result recording,
the immutable task lookup and protected ECS `STOPPED` event contract,
integrated orchestration with acknowledgement/retry decisions, and the authority
split and disabled runtime bootstrap for offline implementation. These contracts
preserve explicit outcome certainty,
operational diagnostics, bounded SDK retries, conditional dispatch ownership,
and atomic launch/terminal result and accounting transitions.

Offline fixtures may supply simulated authenticated identity context.
They do not prove AWS attribution or effective lifecycle fencing.

Approval covers admission, dispatch, task lookup, completion, orchestration,
and runtime bootstrap source with scripted and SDK-stubbed coverage and simulated
protected delivery. Terraform implementation also covers the 60/360-second
settings, foundation gates and keys, scoped broker gate permissions, schema-v2
Scheduler payloads, request-queue producer restrictions, and completion-event
transport, consumer IAM, failure queues, and alarms while activation remains
disabled. It does not authorize AWS
execution, completion-event infrastructure deployment, or ECS task launches.
Before actual AWS execution, implement and approve the concrete policies and
provisioning for the accepted deployment/invocation authority split, gate controller
and initialization, coordinator lifecycle operations, and protected request/completion
delivery. The bootstrap supplies
role-scoped SDK clients and budget guards, whose effective behavior still requires
qualification. These controls must preserve the approved admission/accounting
contract and independent protection. Actual SDK retries, transaction races, ECS
outcomes, and runtime recovery require AWS qualification.

Before activation, implement and qualify producer authentication,
protected artifact deployment, IAM ceilings, network admission,
alternate-path prevention, lifecycle fencing, execution monitoring,
and protected recovery.

The cohesive offline execution path and runtime bootstrap are implemented.
Remaining implementation includes enforcing the approved deployment/invocation
authority split, protected publication, gate initialization and lifecycle
operations, protected request/completion delivery integration and key-policy wiring,
runtime monitoring beyond the defined failure alarms, and protected recovery.
Artifact approval and live positive/negative qualification also remain required.
The approved authority split does
not by itself provision or qualify these controls, or activate the broker.

Keep Lambda reserved concurrency at zero, both SQS mappings and the completion
rule disabled, and schedules disabled throughout unqualified development.

#### Application backend and next deployment-authority checkpoint

PR #1009 implements `modules/application_state_backend`, called through the
default-empty `application_state_backends` map in `bootstrap/<env>/state`.
Each configured application/environment gets a dedicated bucket and CMK,
versioning, native locking, and resource policies separating state access from
backend administration. The backend uses `application.tfstate`; its infrastructure
belongs to state-bootstrap, while the application state owns workload resources.
The module and three bootstrap roots have 14 mocked Terraform cases included in
CI. This is implementation coverage, not AWS authorization or runtime evidence.

**Next checkpoint:** generic protected application deployment IAM and
account-bootstrap wiring. Provide separate Plan/Apply identities, exact
state/lock/key permissions, protected workflow trust and independently governed
deployer, workload, broker and launcher permission ceilings. Enforce boundary
attachment/protection and prevent unauthorized broker invocation, launcher
assumption, direct launches, gate writes and deployment-control changes.
Backend resource policies alone do not grant these identity permissions.
Protected artifact publication and the application composition remain subsequent
integration work; no ordinary image-publishing identity becomes the privileged
application-state writer.

Resolve administrative-operation integration during this design. Applications
may need per-operation inputs and trustworthy operator attribution; the current
broker request schema still accepts only the approved job/request/generation
and optional scheduling metadata. A fixed application runner consuming
independently authorized operation requests is a candidate, not an implemented
or approved schema extension. Any selected path must preserve admission,
accounting and lifecycle fencing without granting arbitrary ECS overrides.
Application-specific CLI commands and tenant-operation semantics stay outside
the broker. See the [generic interface reconciliation](./v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md#9-current-generic-requirements-and-adopter-boundary).

#### Focused acceptance cases

| Case | Required outcome |
| --- | --- |
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
| Admission acknowledgement is lost, then the request is redelivered | Fresh conditional admission under the same durable key; never adopt an existing attempt |
| Conclusive launch refusal or a failed application task is durably handled | Acknowledgement denotes completed message handling, not application success |
| Missing/mismatched packaged scope or unapproved queue | Fail bootstrap without admitting work |
| Launcher assumption fails or credentials are incomplete/expiring | No ECS credential fallback or dispatch; preserve any admitted reservation |
| Insufficient invocation budget between stages | Stop new operations; preserve unresolved work and occupied capacity |
| Current catalog or request-specific configuration is unavailable for completion | Completion can still use common protected configuration and the original stored launch |
| Ledger restore or history removal | No silent restoration of replay authority |

The 204-test suite covers offline parsing, authorization, catalog loading,
key derivation, transaction preparation, supplied-record classification,
executor responses/cancellations, dispatch claim/result and task-lookup
contracts, completion identity/transaction/redelivery behavior, integrated
acknowledgement/retry flows, fixed runtime configuration, attribution consistency,
scoped client construction, budget guards, and pinned SDK request compatibility
relevant to these cases.
The full runtime outcomes in this table remain acceptance requirements
for subsequent implementation and qualification; offline coverage does
not establish deployed enforcement.

## Qualification boundary

M2-B1a establishes a reusable Terraform policy contract only.

Subsequent qualification must verify the generated policies and demonstrate positive and negative launch authorization for two independently scoped jobs, including unauthorized revisions, clusters and role passing.

Live AWS authorization and protected network-admission behavior require separate deployment approval.

This contract does not authorize an AWS Apply, a task launch, or completion of the broader M2 milestone.
