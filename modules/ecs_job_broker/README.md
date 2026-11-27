# ECS Job Broker Module

## Overview

The `ecs_job_broker` module provides application-owned IAM, an encrypted SQS request queue, a DynamoDB execution ledger, and CloudWatch Logs infrastructure for protected, standalone ECS Fargate job execution.

The module separates broker execution permissions from job-specific ECS launch permissions.

**Current infrastructure scope:** IAM roles, trust policies, job-launch permissions, scoped broker runtime IAM, an encrypted SQS request queue and processing dead-letter queue (DLQ), an encrypted DynamoDB execution ledger, a CMK-encrypted CloudWatch log group, an optional invocation-disabled Lambda function configured from a version-pinned S3 ZIP artifact, a disabled SQS event-source mapping, and an SNS-backed processing-DLQ alarm.

**Current runtime source scope:** Python helpers load a complete schema-v1 catalog, resolve schema-v2 requests to approved job configuration, and prepare and submit four-record admission transactions. A dispatcher conditionally claims an admitted request, makes one ECS launch call, and transactionally records the observed launch outcome, including an immutable task lookup for an accepted launch. A completion helper uses caller-authenticated ECS `STOPPED` events to record termination and release the matching job slot atomically. `broker.lambda_handler` connects these helpers using fixed packaged configuration, queue-based attribution, scoped SDK clients, invocation-budget guards, and acknowledgement/retry decisions. Admission confirmation alone does not authorize dispatch; the dispatcher must acquire its own conditional claim.

The 204-test offline suite uses fixtures, simulated protected delivery, scripted clients, and pinned SDK request-model tests. The runtime remains disabled. Independently protected deployment and invocation controls, gate initialization, completion-event delivery, lifecycle coordination, monitoring, protected recovery, and live AWS qualification remain outstanding. Queue metadata checks alone cannot authenticate a direct Lambda invocation.

## Runtime Helpers

These Python modules are intended to be packaged together in one optional broker Lambda function per module instance. That function serves the configured jobs; the application job code runs in ECS Fargate tasks. `broker.py` exposes the configured `lambda_handler`, which bootstraps the existing `process_delivery` and `handle_sqs_event` orchestration.

Parsing, catalog loading, and transaction preparation make no AWS calls. `execute_admission` and `record_task_completion` use supplied DynamoDB clients; `dispatch_admitted` also obtains an ECS client through a supplied factory. The production handler constructs those clients and can perform AWS operations when deployed and invoked. Tests keep those operations offline. The handler processes a single SQS record; it does not poll or delete queue messages, and the Terraform event-source mapping remains disabled.

| Source | Implemented behavior |
|---|---|
| [request_schema.py](lambda/request_schema.py) | Parses an untrusted JSON body into a `JobRequest`; rejects unsupported fields, duplicate JSON fields, missing required fields, unsupported schema versions, and invalid field types or surrounding whitespace. |
| [producer_authorization.py](lambda/producer_authorization.py) | Looks up an exact producer role ID in supplied protected policy configuration, checks exact job membership, and returns the stable logical producer ID. Unknown producers and unauthorized jobs are rejected; wildcard permissions are not expanded. |
| [request_identity.py](lambda/request_identity.py) | Derives a versioned request ledger key from application, environment, logical producer ID, and request key. It does not write a ledger record, reserve execution, or detect conflicting intent. |
| [catalog_producers.py](lambda/catalog_producers.py) | Validates a decoded producer section against supplied declared job keys and returns an immutable role-ID-to-policy mapping. Rejects malformed entries, duplicate or ambiguous bindings, unsupported role-ID forms, and references to undefined jobs. |
| [catalog_job_bindings.py](lambda/catalog_job_bindings.py) | Validates one decoded job binding against a supplied approved cluster ARN and returns an immutable `JobBinding`. Requires an exact task-definition revision and consistent partition/account scope, with the task definition also matching the cluster Region. |
| [catalog_job_network.py](lambda/catalog_job_network.py) | Validates one decoded network section against supplied protected approvals and returns an immutable `JobNetwork`. Requires a subset of approved private subnets, the exact reviewed security-group combination, and explicitly disabled public IP assignment. |
| [catalog_job_fargate.py](lambda/catalog_job_fargate.py) | Validates one decoded Fargate section and returns an immutable `JobFargate`. Requires launch type `FARGATE`, integer task count one, and an explicit platform selector; checks selector syntax without claiming AWS support or task compatibility. |
| [catalog.py](lambda/catalog.py) | Loads the complete catalog using the section validators, checks execution limits inline, and loads producer policies against validated job keys. Retains a digest of the supplied catalog text. Resolves a request against a caller-authenticated producer identity and the loaded catalog, returning the selected job configuration and durable request key. |
| [admission.py](lambda/admission.py) | Prepares a frozen four-record transaction containing the gate condition, new request record, job-slot reservation, and accounting increments. Captures the approved execution intent, launch parameters, proposed owner, and attempt token. Classifies a supplied existing request record without granting launch authority or making AWS calls. |
| [admission_executor.py](lambda/admission_executor.py) | Submits one prepared admission through a supplied low-level DynamoDB client, separates outcome certainty from failure reasons, and reads current eligibility and the original record after an established request collision. Defines bounded DynamoDB client settings through `admission_client_config`; it does not construct or configure the supplied client. |
| [dispatch.py](lambda/dispatch.py) | Conditionally claims dispatch ownership, calls ECS once with the stored launch parameters and token, and records the observed outcome through a separate conditional transaction. Accepted results also create an immutable task-to-request lookup. Keeps claim, ECS observation, and recording certainty separate; it does not construct clients, monitor task completion, or perform recovery. |
| [completion.py](lambda/completion.py) | Reads the task lookup and original request consistently, checks supplied trusted terminal evidence against the recorded launch, and atomically records `TASK_STOPPED`, frees the matching slot, and decrements occupied capacity. Handles duplicate completion without another write; it does not authenticate or retain event delivery, acknowledge queue messages, or recover unresolved launches. |
| [broker.py](lambda/broker.py) | Exposes `lambda_handler` with fixed packaged configuration, queue attribution under independently enforced delivery controls, scoped DynamoDB/STS/ECS clients, and budget guards. Connects admission, dispatch, completion, and durable duplicate classification. Returns normally only for `ACK` and raises `RetryDelivery` otherwise. |

### Request Contract

The parser accepts only integer `schema_version = 2`. A minimal request body is:

```json
{
  "schema_version": 2,
  "job_key": "archive",
  "request_key": "request-001",
  "admission_generation": "generation-001"
}
```

The optional fields `schedule_key`, `schedule_arn`, and `scheduled_time` must be supplied together or all omitted. They are correlation metadata; parsing them does not verify schedule provenance or freshness. String fields must be nonempty and have no surrounding whitespace. The parser rejects invalid values rather than normalizing them.

Body identity claims and execution overrides are unsupported fields. The admission generation is an untrusted claim. `resolve_request` compares it with the loaded catalog's generation; the prepared transaction condition checks the protected gate and its approved catalog binding when submitted. The [Scheduler module](../ecs_job_scheduler/README.md) emits schema v2 with the configured admission generation. Gate initialization and live qualification remain pending.

### Producer Policy and Durable Identity

`authorize_producer` requires its caller to establish the producer role ID through authenticated delivery and supply protected policy configuration. The helper does not extract or authenticate SQS `SenderId`, validate a Lambda invocation's origin, or load an approved catalog. A fabricated SQS-shaped event cannot establish that trust. Application-user and tenant authorization remain the trusted application producer's responsibility.

Each `ProducerPolicy` contains a stable `logical_producer_id` and an immutable `frozenset` of allowed job keys. An empty set permits no jobs. A replacement role ID requires an explicit protected mapping change; retaining the logical producer ID preserves the scope of existing request identities.

`request_ledger_key` uses the ordered tuple `(application_id, environment, logical_producer_id, request_key)`. It serializes those values as a compact ASCII-escaped JSON array, hashes the encoded array with SHA-256, and prefixes the hexadecimal digest with `request:v1:`. This storage-format version is independent of request schema v2. Application and environment must come from stable protected configuration, and the logical producer ID must come from successful producer authorization.

Job key, admission generation, schedule metadata, release version, IAM role ID, and session name are excluded from request uniqueness. Reusing an identity for another job therefore produces the same ledger key. `classify_existing_request` compares the proposed execution intent with a supplied original request record; the executor uses this helper after an established request collision and a current gate check. Computing a stable key alone does not prevent duplicate launches. Changes to the key format or identity scope require a protocol that preserves existing request history.

### Catalog Loading and Request Resolution

Use `load_catalog` to validate the complete catalog before resolving requests. It accepts a JSON string with exactly `schema_version`, `application_id`, `environment`, `admission_generation`, `cluster_arn`, `jobs`, and `producers`. Catalog `schema_version` must be integer `1`; it is independent of request schema version `2`. Application, environment, generation, cluster, and job-key strings must be nonempty with no surrounding whitespace.

`jobs` is an object keyed by job name. Each job contains exactly `binding`, `network`, `fargate`, and `execution_policy`. The first three sections use the validators described below. `execution_policy` requires exactly `max_active_executions` and `run_task_total_max_attempts`, both integer `1`. These declare one active execution per job and one total SDK attempt per `RunTask` call, including the initial request. The loader validates these values directly; it does not reserve concurrency or configure an SDK client.

Supply resource approvals separately from the catalog:

| Argument | Required relationship |
|---|---|
| `approved_cluster_arn` | Must exactly match the catalog's `cluster_arn`. |
| `approved_private_subnet_ids` | A `frozenset` defining the approved private-subnet pool for configured jobs. |
| `approved_security_groups_by_job` | A mapping from each catalog job key to its reviewed security-group `frozenset`; no job keys may be missing or extra. |

These inputs must come from qualified, protected configuration rather than being derived from the selections being checked. The caller must establish artifact approval and the intended application and environment. Resource approvals are checked for each configured job.

Duplicate JSON fields at any nesting level, nonstandard constants such as `NaN` or `Infinity`, unsupported fields, and invalid sections reject the whole catalog. All jobs must validate, including jobs that a particular producer cannot request. The returned frozen `JobCatalog` contains read-only job and producer-policy mappings with immutable values. Empty job and producer collections are supported and permit no requests.

`JobCatalog.source_sha256` is the SHA-256 digest of the exact supplied string encoded as UTF-8, including whitespace. Admission preparation uses this value in the gate condition and proposed request record. The digest identifies the loaded text; it does not establish artifact approval or provenance. Load the packaged catalog text without rewriting it before comparing its digest with the protected approval.

Once catalog JSON, resource approvals, and an authenticated producer role ID are available, the application can use the helpers as follows:

```python
from catalog import load_catalog, resolve_request

catalog = load_catalog(
    catalog_json,
    approved_cluster_arn=approved_cluster_arn,
    approved_private_subnet_ids=approved_private_subnet_ids,
    approved_security_groups_by_job=approved_security_groups_by_job,
)
resolved = resolve_request(
    request_json,
    catalog=catalog,
    producer_role_id=authenticated_producer_role_id,
)
```

`resolve_request` parses the request, requires its generation to match the loaded catalog, and evaluates the producer's permission for the exact job. It returns a frozen `ResolvedRequest` containing the parsed request, logical producer ID, selected `CatalogJob`, and durable ledger key. It does not authenticate the supplied role ID, check a live admission gate, write the ledger, or authorize dispatch. Repeated resolution can return the same key, including for changed job intent; admission preparation and existing-record classification are described below, while durable enforcement requires transaction execution.

### Admission Transaction Preparation

`prepare_admission` resolves a request against a loaded catalog and prepares a low-level DynamoDB `TransactWriteItems` request. Supply the authenticated producer role ID, owning invocation ID, and distinct gate/ledger table ARNs from protected caller context. The returned frozen `PreparedAdmission` contains the request key, fresh attempt ID, canonical execution-intent JSON, and complete transaction JSON. Its `transaction_request()` method returns a fresh payload copy without submitting it.

The prepared transaction targets four records:

| Record | Key scope | Prepared operation |
|---|---|---|
| Gate, in a separate protected table | `gate:v1:<sha256>` of application/environment | Check schema/type, `OPEN` state, admission generation, catalog digest, and execution-ledger ARN. |
| Request, in the execution ledger | Existing `request:v1:<sha256>` identity | Put a new schema-v1 `REQUEST` with status `REGISTERED`, original intent, exact launch parameters, provenance, and proposed attempt ownership; require that the key does not exist. |
| Job slot, in the execution ledger | `slot:v1:<sha256>` of application/environment/job | Require an absent slot or a schema-v1 `SLOT` in state `FREE`; set it to `OCCUPIED` by this request and attempt. |
| Accounting, in the execution ledger | `accounting:v1:<sha256>` of application/environment | Require an existing schema-v1 `ACCOUNTING` record with `unresolved_launches >= 0` and `occupied_slots >= unresolved_launches`; increment both counters by one. |

The additional keys use SHA-256 over ordered, compact ASCII-escaped JSON arrays, as the request identity does. Slot and accounting keys exclude generations and releases so later catalogs cannot bypass outstanding work. The approved design tracks unresolved launch attempts separately from occupied job slots, including slots held by known tasks. Dispatch implements launch-result transitions, and completion implements terminal-state slot release through supplied clients. Protected initialization, deployed integration, and recovery remain outstanding. Admission never initializes missing accounting or releases a slot.

Using the loaded catalog and request from the previous example:

```python
from admission import prepare_admission

prepared = prepare_admission(
    request_json,
    catalog=catalog,
    producer_role_id=authenticated_producer_role_id,
    owner_invocation_id=invocation_id,
    gate_table_arn=gate_table_arn,
    ledger_table_arn=ledger_table_arn,
)
transaction = prepared.transaction_request()
```

Each preparation generates a fresh attempt ID used as both the DynamoDB `ClientRequestToken` and the stored ECS `clientToken`. SDK retries must retain the same preparation and unchanged payload; a newly authenticated delivery receives a new preparation and must not reuse another invocation's ownership. The executor provides no outer retry or recovery loop. The request snapshot includes the exact `RunTask` parameters, role bindings, and execution policy. Neither these tokens nor a stored owner ID independently authorize dispatch.

`classify_existing_request(prepared, item)` accepts a supplied low-level DynamoDB `Item`, or `None` for absence. It returns `ABSENT`, `DUPLICATE`, or `CONFLICT`; unexpected record identity or schema raises `InvalidLedgerRecord`. The comparison uses canonical execution intent, excluding generation, catalog provenance, invocation/attempt IDs, generated tokens, and schedule correlation metadata. An unchanged intent across generations is a duplicate; changing the job or approved execution intent conflicts. The original record is not modified, and even a duplicate owned by the same invocation grants no new launch authority.

All classifications require current authentication, authorization, and gate eligibility. Absence is not a reservation. The executor below handles submission results and collision lookups; the [dispatcher](#dispatch-and-launch-results) acquires dispatch ownership separately. Protected recovery remains unimplemented. The [architecture record](../../v1-15-0/v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md#approved-four-record-admission-model) describes the approved accounting and lifecycle requirements.

### Admission Executor

`execute_admission(prepared, client=..., owner_invocation_id=...)` accepts a trusted low-level DynamoDB client and the current invocation ID. It rejects a preparation owned by another invocation before client I/O. The caller must authenticate delivery and supply protected configuration; this owner comparison does not authenticate the caller.

The executor makes one `transact_write_items` call with the unchanged prepared payload. There is no preflight read or outer retry loop. An established request collision can trigger one `transact_get_items` call that reads the current gate and original request together. The supplied SDK client may retry either API call under the bounded policy below.

The frozen `AdmissionResult` separates `outcome` from the diagnostic `reason`:

| Outcome | Meaning |
|---|---|
| `CONFIRMED` | The exact prepared operation was acknowledged, possibly through an SDK retry of an earlier commit. This is not a fresh dispatch permit. |
| `DUPLICATE` | This submission was rejected; a collision lookup found an eligible current gate and an original record with matching intent. The original owner remains unchanged. |
| `CONFLICT` | This submission was rejected; a collision lookup found an eligible current gate and an original record with different intent. |
| `REJECTED` | The evidence establishes no commit for this submission. It does not establish the absence of an earlier request or authorize releasing existing state. |
| `UNKNOWN` | The operation may have committed or remain in progress. End this invocation without resubmitting, dispatching, transferring ownership, or releasing reservations. A later authenticated delivery follows the conditional admission rules described below. |

Reasons distinguish gate ineligibility, slot unavailability, failed accounting conditions, permission/configuration errors, transient service failures, and lookup faults. `SLOT_UNAVAILABLE` does not prove a healthy occupied slot: its condition also rejects malformed slot records. Missing or unfamiliar cancellation details do not become a duplicate or an invented contention diagnosis.

A recognized service rejection is conclusive only with an HTTP 400/403 response and `RetryAttempts = 0`. A final rejection with missing retry metadata or one or more SDK retries remains `UNKNOWN`, because the retry count does not establish what happened on earlier attempts. The final failure reason is retained without overriding that uncertainty. A failed collision lookup preserves the known rejection of this submission.

Results retain the submitted candidate's request key and attempt ID, AWS request IDs, SDK retry count, error codes, and ordered cancellation codes when available. Duplicate/conflict results also carry a frozen JSON snapshot of the original record, whose attempt and owner may differ from the candidate. That snapshot is for trusted runtime use and must not be logged or returned to producers. Service error messages and cancellation items are excluded from diagnostic fields; the original snapshot is excluded from the result's `repr`, which does not redact an explicit serialization of the result.

`admission_client_config()` returns fresh arguments for `botocore.config.Config`:

| Setting | Value |
|---|---|
| Retry mode | `standard` |
| Maximum total attempts per API call | `3`, including the initial request |
| Connection timeout | `1` second |
| Read timeout | `2` seconds |

The helper creates no client; `broker.lambda_handler` constructs the DynamoDB client with these settings and disables configured endpoint-URL overrides. The executor trusts its supplied client rather than configuring it. These settings are separate from the catalog's one-attempt ECS `RunTask` policy. Runtime budget guards reserve time before admission and collision lookup; socket timeouts and guards cannot cancel an in-flight operation. Effective timing and retry behavior still require AWS qualification.

Coverage includes scripted responses and the pinned SDK request model. Protected initialization, lifecycle integration, and effective AWS authorization remain prerequisites for actual AWS execution. No executor result grants launch authority or permits reservation cleanup.

### Dispatch and Launch Results

`dispatch_admitted` takes the original `PreparedAdmission`, its `admission_result`, the current `owner_invocation_id`, a `ledger_client`, and a trusted `launcher_client_factory`. The admission result must be `CONFIRMED` and match the prepared request and attempt. Ownership or evidence mismatches raise `ValueError` before client I/O; a nonconfirmed admission returns without contacting either service.

The factory receives the stored job-specific launcher-role ARN. The production handler assumes that exact role and constructs an ECS client in the approved Region using the returned temporary credentials, explicit timeouts, and no credential fallback. The dispatcher checks that the client's effective `total_max_attempts` is integer `1` before acquiring a claim. Client setup failure or a different retry policy prevents dispatch and leaves existing reservations untouched. Effective AWS identity, permissions, and timing require live qualification. The ledger client uses the DynamoDB configuration described above.

The dispatch claim is a three-item transaction against the existing execution ledger. It changes the request from `REGISTERED` to `DISPATCHING`, requiring the original owner, attempt, execution intent, launch snapshot, and absence of a prior `dispatch_id`. It also checks the matching occupied job slot and initialized accounting with a positive unresolved count. The claim leaves both counters unchanged and introduces no additional record.

Each dispatcher entry generates a fresh `dispatch_id`, also used as that claim's transaction token. SDK retries within the entry use the same token; another entry receives a new token and cannot replay an earlier claim's cached success. Only a confirmed claim proceeds to one `run_task` call using the exact stored parameters and ECS client token. A rejected or uncertain claim stops before ECS. The claim does not require the gate to remain open: an already-admitted attempt remains accountable after gate closure, and its unresolved count blocks fence completion.

The frozen `DispatchResult` carries the request, attempt, and dispatch identifiers, plus three separate results:

| Field | Meaning |
|---|---|
| `claim` | `WriteEvidence` indicating `NOT_ATTEMPTED`, `CONFIRMED`, `REJECTED`, or `UNKNOWN` for the ownership transaction. |
| `launch` | `LaunchObservation` indicating `NOT_ATTEMPTED`, `ACCEPTED`, `REJECTED`, or `UNKNOWN`, with available task identifiers and structured diagnostics. Acceptance does not establish task completion. |
| `recording` | `WriteEvidence` for the transaction recording the launch observation. An accepted ECS task remains an accepted observation even if this write fails or has an uncertain outcome. |

After a confirmed claim, the dispatcher attempts to record the observation as follows. These state and counter changes take effect together only if the recording transaction commits:

| Launch observation | Request state | `unresolved_launches` | `occupied_slots` and slot |
|---|---|---|---|
| `ACCEPTED` | `LAUNCH_ACCEPTED`, with `task_arn` | Subtract one | Unchanged; the task retains its slot until terminal completion is recorded. |
| `REJECTED` | `LAUNCH_REJECTED` | Subtract one | Subtract one; free only the matching request/attempt's slot. |
| `UNKNOWN` | `LAUNCH_UNKNOWN` | Unchanged | Unchanged; retain the unresolved obligation. |

An accepted-result transaction also creates a schema-v1 `TASK_LOOKUP` in the same ledger, making four actions in total; rejected and unknown results retain three actions. Its key is `task:v1:<sha256>` over `(application_id, environment, task_arn)`, using the existing compact ASCII-escaped JSON-array encoding. It stores that scope and task ARN, plus `request_pk`, `attempt_id`, and `dispatch_id`. Creation requires an absent key, so an existing task lookup cannot be reassigned. The lookup is retained after completion and leaves the four-record admission transaction unchanged.

The recording transaction requires the same owner, attempt, `dispatch_id`, immutable snapshot, and prior `DISPATCHING` state, with matching slot ownership and valid accounting. These conditions prevent repeated result processing from decrementing counters again. Recording uses a separate transaction token. Failure to record may leave `DISPATCHING` or an already-committed result; it never causes another ECS call or automatic cleanup. A recorded `UNKNOWN` remains unresolved, and `NOT_ATTEMPTED` does not release an existing reservation.

Conclusive ECS observations require `RetryAttempts = 0`. The classifier accepts an unambiguous single-task response, or recognizes an explicit no-task failure response or a supported request/authorization refusal. Timeouts, server errors, generic `ClientException`, token conflicts, missing retry metadata, and contradictory responses remain `UNKNOWN`. Available task identifiers are retained for reconciliation. The [dispatch architecture contract](../../v1-15-0/v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md#dispatch-ownership-and-launch-result-recording) specifies the supported refusal set and response checks.

The request retains a structured `launch_observation_json`; full task payloads, service error messages, and failure-detail text are not copied into that evidence. The handler supplies client construction and invocation-budget guards. Protected deployment/invocation controls, completion-event delivery, and recovery remain prerequisites for activation and qualification.

### Task Completion and Slot Release

`record_task_completion` accepts one decoded ECS Task State Change event, protected application/environment identifiers, the ledger table ARN, and a supplied low-level DynamoDB client:

```python
from completion import record_task_completion

result = record_task_completion(
    authenticated_ecs_event,
    application_id=application_id,
    environment=environment,
    ledger_table_arn=ledger_table_arn,
    ledger_client=ledger_client,
)
```

The caller must establish that the event came through the approved protected ECS delivery path. Matching `source`, account, Region, or event type is a consistency check, not authentication; a fabricated event must never reach this helper as trusted completion evidence. The handler supports a distinct configured completion queue, but the EventBridge/queue infrastructure, delivery permissions, and invocation protections are not yet implemented.

Only task-level `lastStatus = STOPPED` can release capacity. A desired stop or an individual container exit is insufficient. The helper consistently reads the immutable lookup and original request, requiring matching scope, attempt, dispatch, task ARN, cluster, and exact task-definition revision. It uses the stored launch snapshot, so a later catalog change or closed admission gate does not prevent completion of an already-recorded launch.

One transaction performs the following changes:

| Record | Condition and update |
|---|---|
| Request | Require `LAUNCH_ACCEPTED`, matching ownership and immutable launch identity, and no prior completion evidence. Set `TASK_STOPPED` and `completion_observation_json`. |
| Job slot | Require the occupied slot to belong to the same request, attempt, and job. Set `FREE` and remove its request/attempt bindings. |
| Accounting | Require schema/type, `unresolved_launches >= 0`, and `occupied_slots > unresolved_launches`. Subtract one occupied slot; leave unresolved launches unchanged. |

These conditions prevent duplicate processing or a delayed event from releasing another attempt's slot. `TASK_STOPPED` records termination, not application success: a nonzero exit or startup failure can release capacity once the task is conclusively stopped. Evidence retains task identifiers, event ID/time/version, stop time/code, and available container names and exit codes; it excludes full task payloads, overrides, and free-form reasons.

The frozen `CompletionResult` separates its outcome/reason from `recording` write evidence and structured read-failure diagnostics:

| Outcome | Meaning |
|---|---|
| `RECORDED` | The completion transaction was acknowledged. |
| `ALREADY_RECORDED` | The original request already contains matching terminal evidence; no further write is made. |
| `IGNORED` | A consistent task event is not `STOPPED`; no ledger I/O occurs. |
| `DEFERRED` | The lookup/request is missing, or the launch remains unresolved. Retain the notification for later processing or protected recovery. |
| `REJECTED` | Event/record consistency checks failed, or the write was conclusively rejected. The reason and write evidence distinguish these cases. |
| `UNKNOWN` | A read failed or returned an unexpected response, or the completion write may have committed without an acknowledgement. |

An early event can be retried after the accepted-launch transaction creates its lookup. A later delivery can also discover that an uncertain completion write committed. Missing lookups, including older accepted records without a lookup, never authorize release or automatic backfill. The handler supplies a ledger client, budget guards, and acknowledgement/retry decisions; deployed completion delivery and failure routing, retained delivery evidence, and protected recovery remain outstanding.

### Integrated Broker and Message Handling

`process_delivery` connects the helpers for one `AuthenticatedDelivery` using supplied protected configuration and clients. Request deliveries load the catalog, resolve the producer's job permissions, submit admission, and dispatch only after confirmed admission and a confirmed dispatch claim. Completion deliveries use the original stored launch and do not load the current catalog, check the admission gate, or construct a launcher client.

`handle_sqs_event` accepts exactly one record and calls a supplied `authenticate_delivery(record)` adapter. That adapter must establish delivery provenance and return the trusted request/completion kind and producer attribution. Constructing `AuthenticatedDelivery`, matching a queue ARN or `SenderId`, or supplying an SQS-shaped event does not establish authentication. Message-body claims cannot select the trusted route or producer identity.

The frozen `DeliveryResult` contains a disposition, diagnostic reason, and available request/attempt/dispatch/task identifiers and error code. `ACK` means message handling is complete, not that the application job succeeded:

| Delivery result | Disposition |
|---|---|
| ECS acceptance or conclusive no-task rejection is durably recorded | `ACK` |
| Eligible matching duplicate has a consistent original `LAUNCH_ACCEPTED`, `LAUNCH_REJECTED`, or `TASK_STOPPED` record | `ACK`; never dispatch again |
| Duplicate remains `REGISTERED`, `DISPATCHING`, or `LAUNCH_UNKNOWN`, or its resolved evidence is inconsistent | `RETRY`; preserve the original attempt |
| Invalid, unauthorized, stale, or conflicting request; gate/slot/accounting failure; authentication or infrastructure fault | `RETRY` |
| Uncertain admission, launcher setup failure, unconfirmed claim, unknown launch, or unconfirmed result recording | `RETRY`; no takeover or reservation cleanup |
| Completion is `RECORDED`, `ALREADY_RECORDED`, or `IGNORED` | `ACK` |
| Completion is `DEFERRED`, `REJECTED`, or `UNKNOWN` | `RETRY` |

An uncertain operation ends the current invocation without a wrapper retry. A later authenticated request delivery prepares a fresh candidate attempt under the same durable request key. Conditional creation arbitrates admission: a committed original remains owned by its original attempt, while a fresh candidate may proceed only if it wins a new reservation. Redelivery never adopts an unresolved original or authorizes another dispatch for it. Duplicate acknowledgement also requires current authorization/gate eligibility and consistent stored result evidence.

The single-message adapter returns a serializable result only for `ACK`; otherwise it raises `RetryDelivery`. This matches the existing batch-size-one configuration without partial-batch responses or manual SQS deletion/failure forwarding. Request failures use the configured bounded queue-to-DLQ path once integrated and activated; completion transport and its failure path remain unimplemented. DLQ arrival does not resolve an execution or free its slot. Results exclude raw message bodies, catalog contents, internal ledger snapshots, and service exception messages.

### Runtime Bootstrap and Packaged Configuration

`broker.lambda_handler` reads fixed `runtime.json` and, for requests only, `catalog.json` beside `broker.py` in the deployment ZIP. Events cannot choose configuration paths. The protected artifact process must supply both files; Terraform does not generate them or build the ZIP.

The `runtime.json` configuration contains:

| Field | Required value |
|---|---|
| `schema_version` | Integer `1`. |
| `application_id`, `environment` | Stable protected scope identifiers matching the request catalog. |
| `function_arn` | Exact unqualified Lambda ARN; checked against the invoked function, including invocations through its aliases or versions. |
| `ledger_table_arn`, `request_queue_arn` | Exact resources in the function's partition, account, and Region. |
| `completion_queue_arn` | A distinct queue ARN in that scope, or `null` to leave completion routing closed. |
| `requests.gate_table_arn` | Separate protected gate table in the same scope; required for request processing. |
| `requests.catalog_approvals` | `approved_cluster_arn`, an `approved_private_subnet_ids` array, and an `approved_security_groups_by_job` map of job keys to arrays of approved security-group IDs. Required for requests. |

Cluster and network approvals must come from independent platform review. Copying catalog-selected values into approval fields does not establish approval. Catalog bytes are decoded as UTF-8 without newline translation or JSON rewriting, preserving the digest used by admission. Completion processing needs only the common configuration and ledger client; it does not read `catalog.json` or request-specific gate/approval configuration, or construct STS/ECS clients.

For the exact request queue, the handler extracts the IAM role ID from the SQS system `SenderId` in `role-id:session-name` form and resolves it through the catalog's exact producer mapping. The session name grants no authority. Only the distinct configured completion queue selects completion processing. Body fields and custom attributes cannot select either producer identity or route. These checks depend on independently enforced queue-submission, event-source-mapping, deployment, and invocation controls: a direct caller can fabricate the same metadata.

Package the Python modules, configuration, and all dependencies pinned in [requirements-sdk.txt](lambda/requirements-sdk.txt) together for Python 3.12. The pins are Boto3/Botocore `1.43.118`, s3transfer `0.19.0`, jmespath `1.1.0`, python-dateutil `2.9.0.post0`, six `1.17.0`, and urllib3 `2.7.0`. Do not rely on an independently changing runtime SDK; review and refresh the pins before release. Artifact publishing, provenance verification, and approval remain external implementation work.

The handler derives the SDK Region from the verified function ARN and disables configured endpoint-URL overrides. DynamoDB and STS use broker credentials. Only dispatch after confirmed admission requests a 900-second STS session for the exact stored launcher role; ECS receives all three returned temporary credential fields. Missing or expiring credentials fail setup without falling back to broker credentials.

| Client | Maximum total attempts per call | Connect timeout | Read timeout |
|---|---|---|---|
| DynamoDB | 3 | 1 second | 2 seconds |
| STS | 1 | 1 second | 2 seconds |
| ECS | 1 | 1 second | 3 seconds |

All clients use standard retry mode. Lambda has a **60-second timeout** and the request queue has a **360-second visibility timeout**, six times the function timeout, with no batching window. The handler checks remaining invocation time before starting admission, launcher setup, dispatch, result recording, and completion operations. Insufficient budget fails processing for retry while preserving any existing reservation; it never authorizes cleanup or another launch. These checks cannot cancel an in-flight call or prove an uncertain attempt resolved. The [runtime bootstrap contract](../../v1-15-0/v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md#runtime-bootstrap-sdk-and-invocation-budget-contract) records the stage thresholds and qualification limits.

### Catalog Section Validation

`load_producer_policies` accepts a decoded list of entries containing exactly `logical_producer_id`, `role_ids`, and `allowed_jobs`. Each logical producer has one entry with one or more role IDs; an approved replacement role can share the same logical identity and permissions. Duplicate logical producers, repeated list values, and role IDs assigned to multiple producers are rejected. Role IDs must use the supported `AROA` form, with 16–128 ASCII word characters in total; role ARNs, session-qualified IDs, and wildcard expressions are rejected.

The caller supplies `declared_job_keys` as a `frozenset` of validated job keys. Every allowed job must be present in that set. An empty producer list or an empty allowed-job list grants no permissions. The result is a read-only mapping containing frozen `ProducerPolicy` values, so later changes to the input lists cannot change loaded permissions. `load_catalog` derives the declared keys from the validated job entries before loading producer policies.

`load_job_binding` accepts exactly `task_definition_arn`, `launcher_role_arn`, `execution_role_arn`, and `task_role_arn`. The approved cluster ARN is supplied separately from protected configuration. The task definition must specify a full revision ARN in the same partition, Region, and account as the cluster; all three IAM role ARNs must match its partition and account. The validator supports `aws`, `aws-us-gov`, and `aws-cn` partitions and IAM role paths, rejects wildcard ARNs and extra fields such as execution overrides, and preserves exact accepted values in a frozen `JobBinding`.

`load_job_network` accepts exactly `subnet_ids`, `security_group_ids`, and `assign_public_ip`. The caller supplies nonempty `frozenset` approvals through `approved_private_subnet_ids` and `approved_security_group_ids`. The subnet list must contain 1–16 distinct IDs selected from the approved private-subnet pool. The security-group list must contain 1–5 distinct IDs and match the complete reviewed combination, regardless of order; membership in a broader pool of individually approved groups is insufficient. Both lists and their approval sets require valid IDs with 8 or 17 lowercase hexadecimal characters after the resource prefix. Public IP assignment must be explicitly `DISABLED`. The frozen `JobNetwork` stores the accepted ID lists as tuples, preserving their supplied order.

Network approvals must come from qualified, protected configuration, including review of the security-group combination's effective rule union. The helper does not establish subnet privacy, VPC/account/Region membership, effective security-group rules, or continued approval after infrastructure changes.

`load_job_fargate` accepts exactly `launch_type`, `platform_version`, and `count`. Launch type must be `FARGATE`, and count must be the integer `1`; booleans, floats, and strings are rejected. The platform selector must be explicitly supplied as `LATEST` or three dot-separated nonnegative integers without leading zeros. No fields receive implicit defaults, and extra fields are rejected. The frozen `JobFargate` preserves the accepted selector. Platform validation checks syntax only and does not maintain an AWS version allowlist or establish task-definition compatibility. Count one limits an individual launch call; it does not reserve a per-job concurrency slot.

These section validators operate on decoded configuration; `load_catalog` composes them into the complete catalog. They do not verify artifact approval or provenance, confirm that AWS resources exist, or establish effective IAM permissions. Job-binding validation also does not verify the roles registered on the actual task definition. The dispatcher uses the stored approved configuration; protected deployment qualification must establish its effective runtime enforcement.

The configured handler loads these helpers from the deployment package; the repository does not yet build or approve that artifact. Offline tests use simulated identity and policy inputs. Remaining architecture decisions, implementation work, and activation qualifications are recorded in the [launch authorization record](../../v1-15-0/v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md).

## IAM Architecture

The module creates:

- One Lambda broker execution role when jobs are configured.
- One dedicated launcher role per approved job.
- A broker policy granting `sts:AssumeRole` on the configured launcher roles only.
- Per-job policies granting `ecs:RunTask` and `iam:PassRole` under explicit resource restrictions.
- A broker runtime policy scoped to its request queue, execution ledger, optional foundation admission gate, associated CMKs, and dedicated log group.

The broker execution role trusts `lambda.amazonaws.com` and does not receive direct ECS launch permissions.

Each launcher trusts the broker execution role.

### Launcher Authorization

Each launcher is restricted to:

- The exact configured ECS task-definition revision.
- The approved ECS cluster through the `ecs:cluster` condition.
- The job's configured task and execution IAM roles.
- Role passing to `ecs-tasks.amazonaws.com` only.

Launcher authorization does not independently enforce task network configuration, concurrency, idempotency, or lifecycle fencing. These require protected runtime admission controls.

## Broker Request Queue

When `jobs` is nonempty, the module creates one standard SQS queue named `${name_prefix}-job-broker-requests`:

- **Encryption at rest:** SSE-KMS with the externally supplied application-owned customer-managed KMS key (`broker_request_queue_cmk_arn`). The module does not create the key or grant KMS permissions.
- **Encryption in transit:** The queue resource policy denies `sqs:*` requests when `aws:SecureTransport` is `false`. This policy does not itself grant producers or consumers queue access.
- **Visibility timeout:** 360 seconds, six times the configured 60-second Lambda timeout, with a zero-second batching window.
- **Message retention:** Four days (345,600 seconds).
- **Failure redrive:** After repeated unsuccessful receives, messages are eligible to move to the broker processing DLQ when the configured `maxReceiveCount` of 5 is exceeded.

The queue ARN can be passed to `ecs_job_scheduler` as `broker_request_queue_arn`, alongside the same CMK ARN as `broker_request_queue_cmk_arn`. Producer/consumer IAM permissions and effective KMS key-policy authorization must be established through their respective ownership boundaries.

The queue does not authenticate request-body claims, enforce job admission, provide durable deduplication, or process messages. The broker implements admission and durable identity handling, subject to the protected delivery and activation requirements above.

## Processing Dead-Letter Queue and Alarm

When `jobs` is nonempty, the module creates a separate standard SQS DLQ named `${name_prefix}-job-broker-processing-dlq` for requests that repeatedly fail **broker processing**. This is distinct from the per-schedule delivery-failure DLQs managed by `ecs_job_scheduler`.

- **Encryption:** SSE-KMS using the same externally supplied `broker_request_queue_cmk_arn` as the request queue; the module does not create or authorize the key.
- **Retention:** 14 days (1,209,600 seconds), longer than the request queue's four-day retention.
- **Redrive admission:** A `byQueue` redrive allow policy restricts the DLQ to the module's broker request queue.
- **Transport protection:** A queue policy denies requests with `aws:SecureTransport = false`.
- **Monitoring:** An `aws_cloudwatch_metric_alarm` observes the DLQ's `ApproximateNumberOfMessagesVisible` metric. It uses a five-minute `Maximum`, one evaluation period, and a threshold greater than zero, with missing data treated as `notBreaching`. Alarm actions target the externally supplied `alarm_topic_arn` SNS topic.

The module does not grant operators DLQ read, replay, or redrive permissions, and it does not configure the external SNS topic's delivery permissions. A message arriving in the DLQ is **not proof that an ECS launch failed**; ambiguous launch results and DynamoDB reservations still require protected reconciliation. With the event-source mapping disabled, the broker is not yet consuming messages or exercising this processing-failure path.

## DynamoDB Execution Ledger

When `jobs` is nonempty, the module creates one DynamoDB table named `${name_prefix}-job-execution-ledger` with the following infrastructure settings:

- **Primary key:** `pk` (string partition key); no sort key or secondary indexes.
- **Capacity:** On-demand (`PAY_PER_REQUEST`).
- **Encryption at rest:** Server-side encryption enabled with the externally supplied application-owned customer-managed KMS key (`execution_ledger_cmk_arn`). The module neither creates that key nor grants key access.
- **Recovery:** Point-in-time recovery enabled.
- **Deletion protection:** Enabled to guard against accidental table deletion; deliberate destruction requires a separately authorized protection change.
- **Retention:** No DynamoDB TTL configured. Durable request identities are initially retained without automatic expiry or cleanup, and expiration must not remove an unresolved execution reservation.

The module provisions storage and includes [transaction preparation](#admission-transaction-preparation), an [admission executor](#admission-executor), [dispatch/result recording](#dispatch-and-launch-results), and [completion recording](#task-completion-and-slot-release). Preparation binds admission to a condition on a separate [foundation-owned gate](../ecs_job_admission_gate/README.md). Accepted launch results add an immutable task lookup in the existing table; terminal recording updates the original request, slot, and accounting together. The eligibility controller, protected accounting initialization, deployed runtime integration, completion-event delivery, and recovery remain unimplemented.

The approved design retains accounting across releases and generations. Unresolved attempts must remain accounted for until their outcomes and absence of further launch authority are established; known tasks continue to occupy slots until terminal recording. Launch-result and terminal-state counter updates have scripted-client coverage; deployed lifecycle coordination and trustworthy event delivery require subsequent implementation and qualification. Point-in-time restore or table recreation also requires a protected protocol preserving request history, task bindings, and replay protection before admission resumes.

## Broker Runtime IAM and Logging

When `jobs` is nonempty, the module creates a dedicated CloudWatch log group at `/aws/lambda/${name_prefix}-job-broker`, with the following configuration:

- **Retention:** `cloudwatch_retention_days` supplied explicitly by the application composition; no hardcoded module retention period. The application must obtain an approved value through the foundation-to-application contract or another independently approved configuration.
- **Encryption:** The log group is encrypted with the externally supplied CMK (`broker_log_cmk_arn`). The regional CloudWatch Logs service requires appropriate authorization in the CMK key policy; the module does not create or modify that policy.

The broker execution role receives an inline runtime policy with these permissions:

| Resource | Allowed operations |
|---|---|
| Broker request queue | `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:GetQueueAttributes` on the exact queue ARN |
| Request queue CMK | `kms:Decrypt`, limited by `kms:ViaService` to regional SQS |
| Execution ledger | `dynamodb:GetItem`, `dynamodb:PutItem`, `dynamodb:UpdateItem`, `dynamodb:ConditionCheckItem` on the exact table ARN |
| Ledger CMK | `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey`, `kms:DescribeKey`, limited by `kms:ViaService` to regional DynamoDB |
| Admission gate, when configured | `dynamodb:GetItem` and `dynamodb:ConditionCheckItem` on the exact foundation table ARN; no gate-write grant |
| Gate CMK, when configured | `kms:Decrypt` on the exact key, limited to regional DynamoDB and the gate table/account encryption context |
| Broker log group | `logs:CreateLogStream`, `logs:PutLogEvents` for its log streams |

The runtime policy does not grant `ecs:RunTask` or `iam:PassRole`. Those operations remain restricted to dedicated per-job launcher roles, which the broker may assume through its separately scoped `sts:AssumeRole` policy. The log group is created by Terraform; the broker runtime policy does not grant `logs:CreateLogGroup`.

Supply `admission_gate` with the foundation's protected `{ table_arn, cmk_arn }` references. Both must match the approved cluster's partition, account, and Region, and the gate must be separate from the ledger. The default `null` adds no gate permissions. This input configures IAM only; the protected runtime package must use the same gate table reference. These grants do not initialize the gate or activate the broker.

## Broker Lambda Infrastructure

The module optionally creates `aws_lambda_function.broker` when `jobs` is nonempty and `broker_lambda_package` is supplied. When the package is `null`, **no Lambda function is created**, even if jobs are configured. The configured function:

- Uses the name `${name_prefix}-job-broker`, Python 3.12, the `broker.lambda_handler` entry point, an `x86_64` architecture, 256 MiB memory, and a 60-second timeout.
- Loads its ZIP from the supplied S3 bucket and object key, pinned to the exact `version_id`. The module does not build, upload, verify, or approve deployment artifacts.
- Encrypts its environment configuration using the externally supplied customer-managed key `broker_lambda_cmk_arn`. Appropriate KMS key-policy and deployment permissions must be established separately.
- Receives `BROKER_QUEUE_URL` and `EXECUTION_LEDGER_NAME` through environment variables derived from the module-managed SQS queue and DynamoDB table. The implemented bootstrap uses the fixed packaged `runtime.json` instead; these variables do not supply its configuration.
- Uses the existing broker execution role and depends on the log group and broker IAM policies being provisioned first.
- Sets `reserved_concurrent_executions = 0` to throttle all function invocations until runtime admission and lifecycle safeguards are independently approved.

The S3 object version pins the referenced package but **does not prove integrity, provenance, or release authorization**. Artifact approval and control of who can update the function, its IAM role, or reserved concurrency are external deployment-security responsibilities.

The Terraform resource describes infrastructure and cannot establish the correctness of whatever code is contained in a supplied ZIP.

## SQS Event-Source Mapping

When the optional broker Lambda function exists, the module creates one `aws_lambda_event_source_mapping` connecting the broker request queue to that function. The mapping is deliberately **disabled** (`enabled = false`) and configured with `batch_size = 1` and `maximum_batching_window_in_seconds = 0`.

Without a configured Lambda artifact, the mapping is absent. Even with an artifact configured, the function retains `reserved_concurrent_executions = 0`, independently preventing invocation. These are deployment safety settings, not an implementation of request authentication or per-job admission.

The mapping must not be enabled, Lambda reserved concurrency raised, or request producers activated until the protected runtime, artifact provenance, IAM/KMS authority, lifecycle fencing, and failure-handling requirements have been independently implemented and approved. The request queue retains messages for only four days while processing remains disabled.

## Inputs

| Input | Description | Default |
|---|---|---|
| `name_prefix` | Application resource naming prefix | Required |
| `environment` | Environment identifier for tagging | Required |
| `approved_cluster_arn` | Exact approved ECS cluster ARN | Required |
| `permissions_boundary_arn` | Platform-governed IAM permissions boundary ARN | Required, non-null |
| `jobs` | Map of approved standalone jobs | `{}` |
| `admission_gate` | Foundation gate references: `{ table_arn, cmk_arn }`; adds scoped read/check and decrypt access | `null` (no gate access) |
| `broker_request_queue_cmk_arn` | Application-owned CMK ARN for SSE-KMS encryption of the broker request queue | Required when `jobs` is nonempty; otherwise `null` |
| `execution_ledger_cmk_arn` | Application-owned CMK ARN for DynamoDB ledger encryption | Required when `jobs` is nonempty; otherwise `null` |
| `broker_log_cmk_arn` | Externally supplied CMK ARN for CloudWatch broker logs | Required when `jobs` is nonempty; otherwise `null` |
| `cloudwatch_retention_days` | Approved CloudWatch log retention period supplied by the application composition | Required when `jobs` is nonempty; otherwise `null` |
| `broker_lambda_package` | S3 ZIP artifact coordinates (`bucket`, `key`, `version_id`) for optional Lambda creation | `null` (no Lambda) |
| `broker_lambda_cmk_arn` | Customer-managed KMS key ARN for Lambda environment encryption | Required when `broker_lambda_package` is set; otherwise `null` |
| `alarm_topic_arn` | Approved SNS topic ARN for processing-DLQ message alarms | Required when `jobs` is nonempty; otherwise `null` |

Each `jobs` entry requires:

- `task_definition_arn`: Exact ECS task-definition revision ARN.
- `execution_role_arn`: Job execution role ARN.
- `task_role_arn`: Job application task role ARN.

An empty `jobs` map creates no managed IAM, SQS, DynamoDB, CloudWatch log-group, Lambda, event-source mapping, or alarm resources. A nonempty `jobs` map alone does not create a Lambda function or event-source mapping.

## Outputs

- `broker_execution_role`: Broker role ARN and name, or `null` when no jobs are configured.
- `launcher_roles`: Map of launcher role ARNs and names.
- `launcher_policy_ids`: Map of per-job inline-policy IDs.
- `broker_request_queue`: SQS queue ARN, URL, and name, or `null` when no jobs are configured.
- `execution_ledger`: DynamoDB table ARN and name, or `null` when no jobs are configured.
- `broker_log_group`: CloudWatch log group ARN and name, or `null` when no jobs are configured.
- `broker_lambda`: Lambda function ARN and name, or `null` when no package is configured.
- `broker_processing_dlq`: Processing DLQ ARN, URL, and name, or `null` when no jobs are configured.
- `broker_event_source_mapping_uuid`: Disabled SQS-to-Lambda mapping UUID, or `null` when no broker Lambda is configured.

## Security Responsibilities

The module attaches the supplied IAM permissions boundary to broker and launcher roles.

The boundary itself must be independently governed by the platform. Application deployment identities must not be able to remove or weaken mandatory boundaries, modify protected broker code or configuration without authorization, assume launcher roles directly, or bypass protected launch admission.

Effective permissions also depend on the approved IAM boundary policy, trust relationships, deployment identities, and any applicable organization-level restrictions.

The approved authority split assigns the sole privileged application-state writer to a platform-controlled deployment workflow, with a separate protected controller managing gate transitions. The broker may read/check eligibility and maintain execution state; it must not modify its own deployment or gate authority. Deployment/invocation protections and the controller remain to be implemented. Broker resources remain application-owned, with no additional workload state or reverse foundation dependency.

The module does not create or authorize those external controls. The queue's TLS-deny policy does not replace separate producer authorization, consumer authorization, or permissions in the external CMK's key policy. The broker runtime IAM policy grants scoped access to the ledger but does not enforce transactional admission or validate request provenance; effective permissions remain subject to the permissions boundary and the external CMK key policies.

Runtime enforcement of private networking, approved security groups, request authentication, durable idempotency, admission concurrency, lifecycle fencing, and execution outcomes remains outstanding. The Lambda's reserved concurrency of zero disables invocation; it is not the per-job execution-concurrency control required of the eventual broker.

## Testing

Run the following commands from the repository root.

### Terraform Infrastructure Tests

The infrastructure tests use Terraform's native test framework.

```shell
terraform -chdir=modules/ecs_job_broker init \
  -backend=false \
  -lockfile=readonly

terraform -chdir=modules/ecs_job_broker test \
  -filter=tests/broker_iam.tftest.hcl
```

The 12 plan-only tests cover resource and IAM contracts, encryption and required settings, scoped gate access and separation from the ledger, and optional Lambda creation with activation disabled. They also assert the 60-second function timeout and 360-second queue visibility setting.

They verify configured Terraform permissions and relationships, not effective AWS permissions or deployed runtime behavior.

### Offline Python Tests

The offline tests use Python's standard-library `unittest` framework and require the pinned SDK dependencies below. No AWS credentials or AWS access are needed. Most tests use scripted clients; a bootstrap test constructs real pinned SDK clients with fake credentials and Botocore `Stubber` to check request-model compatibility with network access blocked. Use Python 3.12 to match the configured Lambda runtime.

```shell
python3.12 -m venv /tmp/ecs-job-broker-tests
. /tmp/ecs-job-broker-tests/bin/activate
python -m pip install --disable-pip-version-check --only-binary=:all: \
  -r modules/ecs_job_broker/lambda/requirements-sdk.txt

PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$PWD/modules/ecs_job_broker/lambda" \
python -m unittest discover \
  -s modules/ecs_job_broker/tests \
  -p 'test_*.py' \
  -v
```

The current suite contains 204 offline Python tests:

| Test file | Tests | Coverage |
|---|---|---|
| [test_request_schema.py](tests/test_request_schema.py) | 9 | Request parsing, required generation, schema version, duplicate/unsupported fields, schedule metadata completeness, and rejection without normalization. |
| [test_producer_authorization.py](tests/test_producer_authorization.py) | 9 | Exact producer/job authorization, role replacement, invalid policy values, and rejection of unauthorized requests. |
| [test_request_identity.py](tests/test_request_identity.py) | 8 | Stable key encoding, namespace separation, role replacement, and exclusion of job/generation/schedule changes from request identity. |
| [test_catalog_producers.py](tests/test_catalog_producers.py) | 12 | Producer-section structure, role-ID syntax and length bounds, duplicate bindings, undefined jobs, empty permissions, and immutable loaded policies. |
| [test_catalog_job_bindings.py](tests/test_catalog_job_bindings.py) | 11 | Exact revision and cluster ARNs, partition/Region/account consistency, role paths, rejection of wildcards and extra fields, and immutable loaded bindings. |
| [test_catalog_job_network.py](tests/test_catalog_job_network.py) | 13 | Approved subnet subsets, exact security-group combinations, explicit public-IP disabling, ID syntax and legacy lengths, list size bounds and duplicates, invalid approval context, unsupported fields, and immutable loaded networks. |
| [test_catalog_job_fargate.py](tests/test_catalog_job_fargate.py) | 10 | Explicit numeric and `LATEST` platform selectors, syntax-only version validation, fixed Fargate launch type, strict integer task count one, required fields, rejection of extra fields and malformed selectors, and immutable loaded settings. |
| [test_catalog.py](tests/test_catalog.py) | 16 | Complete catalog loading and request resolution, authorization failures, generation checks, external resource approvals, rejection of duplicate JSON fields and invalid sections, inline execution limits, immutable results, empty catalogs, and stable identity across generation, role, and job-intent changes. |
| [test_admission.py](tests/test_admission.py) | 9 | Four-record transaction shape and conditions, stable storage keys, exact launch snapshots, catalog-text digests, repeatable retry payloads, fresh delivery attempts, duplicate/conflict classification, identity preservation across generation and role changes, slot/accounting scope, resolution denials, and unexpected-record rejection. |
| [test_admission_executor.py](tests/test_admission_executor.py) | 16 | Exact submission payloads, owner checks, client configuration, acknowledgments after SDK retries, duplicate/conflict lookups, current gate eligibility, cancellation reasons, known rejections, preserved uncertainty, lookup failures, malformed responses/records, and exclusion of record contents and service messages from result representations. |
| [test_dispatch.py](tests/test_dispatch.py) | 27 | Conditional claims and result transactions, exact launcher/launch inputs, SDK retry-policy checks, repeated and competing dispatch entries, claim uncertainty, accepted/refused/unknown launches, slot and counter changes, failed result recording, immutable task-lookup creation and conflicts, retained task identifiers, response binding checks, and selective diagnostic evidence. |
| [test_completion.py](tests/test_completion.py) | 26 | Consistent lookup/request reads, exact task and launch identity, atomic slot release and occupied-count decrement, completion across catalog changes, nonterminal events, early/missing records, duplicate and competing completion, rejected/uncertain writes, lost-acknowledgement redelivery, read failures, and minimal terminal evidence. |
| [test_broker.py](tests/test_broker.py) | 38 | 22 orchestration tests covering request/duplicate/completion flows, acknowledgement/retry decisions, denials, uncertainty, redelivery, and restricted diagnostics; 16 runtime tests covering fixed configuration, queue/SenderId attribution, exact catalog bytes and independent approvals, launcher credentials and client settings, budget loss, completion independence, bootstrap failures, and pinned SDK request compatibility. |

Fixed expected hashes in the request-identity, catalog, admission, and dispatch tests guard against accidental changes to persistent key formats. Broker tests connect the actual helpers with simulated protected delivery; completion fixtures use the actual dispatch-generated lookup. Admission tests inspect generated operations and supplied records. Scripted and SDK-stubbed responses model service outcomes; they do not execute DynamoDB conditions, exercise actual HTTP retries, establish AWS transaction atomicity or event authenticity, or launch ECS tasks. The SDK test is required rather than skipped when dependencies are missing.

The [Terraform Module Tests workflow](../../.github/workflows/terraform-module-tests.yml) installs the same pinned dependencies and runs the suite with Python 3.12.

These tests verify offline contracts and configuration behavior. They do not establish live AWS readiness. Authenticated delivery, artifact provenance, transactional admission, lifecycle fencing, and execution behavior require separate AWS qualification before activation. Lambda reserved concurrency remains zero and the SQS event-source mapping remains disabled until the runtime controls are implemented and approved.
