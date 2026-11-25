# ECS Job Broker Module

## Overview

The `ecs_job_broker` module provides application-owned IAM, an encrypted SQS request queue, a DynamoDB execution ledger, and CloudWatch Logs infrastructure for protected, standalone ECS Fargate job execution.

The module separates broker execution permissions from job-specific ECS launch permissions.

**Current infrastructure scope:** IAM roles, trust policies, job-launch permissions, scoped broker runtime IAM, an encrypted SQS request queue and processing dead-letter queue (DLQ), an encrypted DynamoDB execution ledger, a CMK-encrypted CloudWatch log group, an optional invocation-disabled Lambda function configured from a version-pinned S3 ZIP artifact, a disabled SQS event-source mapping, and an SNS-backed processing-DLQ alarm.

**Current runtime source scope:** Seven offline helpers implement request-schema-v2 parsing, producer-to-job policy evaluation, durable request-key derivation, producer-catalog section validation, job execution-identity binding validation, job network validation against supplied protected approvals, and Fargate launch-setting validation. The Lambda handler, authenticated delivery integration, complete catalog loading, atomic admission protocol, ECS dispatch, lifecycle coordination, and runtime reconciliation remain unimplemented.

## Offline Runtime Helpers

The owner-authorized offline increments provide the following Python helpers. They make no AWS calls and do not process queue messages or launch tasks.

| Source | Implemented behavior |
|---|---|
| [request_schema.py](lambda/request_schema.py) | Parses an untrusted JSON body into a `JobRequest`; rejects unsupported fields, duplicate JSON fields, missing required fields, unsupported schema versions, and invalid field types or surrounding whitespace. |
| [producer_authorization.py](lambda/producer_authorization.py) | Looks up an exact producer role ID in supplied protected policy configuration, checks exact job membership, and returns the stable logical producer ID. Unknown producers and unauthorized jobs are rejected; wildcard permissions are not expanded. |
| [request_identity.py](lambda/request_identity.py) | Derives a versioned request ledger key from application, environment, logical producer ID, and request key. It does not write a ledger record, reserve execution, or detect conflicting intent. |
| [catalog_producers.py](lambda/catalog_producers.py) | Validates a decoded producer section against supplied declared job keys and returns an immutable role-ID-to-policy mapping. Rejects malformed entries, duplicate or ambiguous bindings, unsupported role-ID forms, and references to undefined jobs. |
| [catalog_job_bindings.py](lambda/catalog_job_bindings.py) | Validates one decoded job binding against a supplied approved cluster ARN and returns an immutable `JobBinding`. Requires an exact task-definition revision and consistent partition/account scope, with the task definition also matching the cluster Region. |
| [catalog_job_network.py](lambda/catalog_job_network.py) | Validates one decoded network section against supplied protected approvals and returns an immutable `JobNetwork`. Requires a subset of approved private subnets, the exact reviewed security-group combination, and explicitly disabled public IP assignment. |
| [catalog_job_fargate.py](lambda/catalog_job_fargate.py) | Validates one decoded Fargate section and returns an immutable `JobFargate`. Requires launch type `FARGATE`, integer task count one, and an explicit platform selector; checks selector syntax without claiming AWS support or task compatibility. |

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

Body identity claims and execution overrides are unsupported fields. The admission generation is an untrusted claim; comparison with the authoritative gate and approved catalog remains outstanding. The current `ecs_job_scheduler` module still emits schema v1 without an admission generation, so its envelope requires a coordinated update before runtime integration. The parser does not accept that legacy envelope.

### Producer Policy and Durable Identity

`authorize_producer` requires its caller to establish the producer role ID through authenticated delivery and supply protected policy configuration. The helper does not extract or authenticate SQS `SenderId`, validate a Lambda invocation's origin, or load an approved catalog. A fabricated SQS-shaped event cannot establish that trust. Application-user and tenant authorization remain the trusted application producer's responsibility.

Each `ProducerPolicy` contains a stable `logical_producer_id` and an immutable `frozenset` of allowed job keys. An empty set permits no jobs. A replacement role ID requires an explicit protected mapping change; retaining the logical producer ID preserves the scope of existing request identities.

`request_ledger_key` uses the ordered tuple `(application_id, environment, logical_producer_id, request_key)`. It serializes those values as a compact ASCII-escaped JSON array, hashes the encoded array with SHA-256, and prefixes the hexadecimal digest with `request:v1:`. This storage-format version is independent of request schema v2. Application and environment must come from stable protected configuration, and the logical producer ID must come from successful producer authorization.

Job key, admission generation, schedule metadata, release version, IAM role ID, and session name are excluded from request uniqueness. Reusing an identity for another job therefore produces the same ledger key; the future admission protocol must compare the original approved execution intent and reject conflicts. Computing a stable key alone does not prevent duplicate launches. Changes to the key format or identity scope require a protocol that preserves existing request history.

### Catalog Section Validation

`load_producer_policies` accepts a decoded list of entries containing exactly `logical_producer_id`, `role_ids`, and `allowed_jobs`. Each logical producer has one entry with one or more role IDs; an approved replacement role can share the same logical identity and permissions. Duplicate logical producers, repeated list values, and role IDs assigned to multiple producers are rejected. Role IDs must use the supported `AROA` form, with 16–128 ASCII word characters in total; role ARNs, session-qualified IDs, and wildcard expressions are rejected.

The caller supplies `declared_job_keys` as a `frozenset` of validated job keys. Every allowed job must be present in that set. An empty producer list or an empty allowed-job list grants no permissions. The result is a read-only mapping containing frozen `ProducerPolicy` values, so later changes to the input lists cannot change loaded permissions. The complete catalog loader must eventually derive the declared keys from validated job entries.

`load_job_binding` accepts exactly `task_definition_arn`, `launcher_role_arn`, `execution_role_arn`, and `task_role_arn`. The approved cluster ARN is supplied separately from protected configuration. The task definition must specify a full revision ARN in the same partition, Region, and account as the cluster; all three IAM role ARNs must match its partition and account. The validator supports `aws`, `aws-us-gov`, and `aws-cn` partitions and IAM role paths, rejects wildcard ARNs and extra fields such as execution overrides, and preserves exact accepted values in a frozen `JobBinding`.

`load_job_network` accepts exactly `subnet_ids`, `security_group_ids`, and `assign_public_ip`. The caller supplies nonempty `frozenset` approvals through `approved_private_subnet_ids` and `approved_security_group_ids`. The subnet list must contain 1–16 distinct IDs selected from the approved private-subnet pool. The security-group list must contain 1–5 distinct IDs and match the complete reviewed combination, regardless of order; membership in a broader pool of individually approved groups is insufficient. Both lists and their approval sets require valid IDs with 8 or 17 lowercase hexadecimal characters after the resource prefix. Public IP assignment must be explicitly `DISABLED`. The frozen `JobNetwork` stores the accepted ID lists as tuples, preserving their supplied order.

Network approvals must come from qualified, protected configuration, including review of the security-group combination's effective rule union. The helper does not establish subnet privacy, VPC/account/Region membership, effective security-group rules, or continued approval after infrastructure changes.

`load_job_fargate` accepts exactly `launch_type`, `platform_version`, and `count`. Launch type must be `FARGATE`, and count must be the integer `1`; booleans, floats, and strings are rejected. The platform selector must be explicitly supplied as `LATEST` or three dot-separated nonnegative integers without leading zeros. No fields receive implicit defaults, and extra fields are rejected. The frozen `JobFargate` preserves the accepted selector. Platform validation checks syntax only and does not maintain an AWS version allowlist or establish task-definition compatibility. Count one limits an individual launch call; it does not reserve a per-job concurrency slot.

These helpers validate decoded configuration sections only. They do not decode a complete JSON catalog, verify artifact approval or provenance, confirm that AWS resources exist, or establish effective IAM permissions. Job-binding validation also does not verify the roles registered on the actual task definition. Complete catalog composition, protected deployment qualification, and enforcement of the validated configuration during dispatch remain outstanding.

The helpers do not provide the configured `broker.lambda_handler` entry point or build an approved deployment package. Offline tests use simulated identity and policy inputs. Remaining architecture decisions, implementation work, and activation qualifications are recorded in the [launch authorization record](../../v1-15-0/v1_15_0_M2_B1_LAUNCH_AUTHORIZATION.md).

## IAM Architecture

The module creates:

- One Lambda broker execution role when jobs are configured.
- One dedicated launcher role per approved job.
- A broker policy granting `sts:AssumeRole` on the configured launcher roles only.
- Per-job policies granting `ecs:RunTask` and `iam:PassRole` under explicit resource restrictions.
- A broker runtime policy scoped to its request queue, execution ledger, associated CMKs, and dedicated log group.

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
- **Visibility timeout:** 180 seconds, a provisional setting to reconcile with the Lambda function timeout and batching configuration when the consumer is implemented.
- **Message retention:** Four days (345,600 seconds).
- **Failure redrive:** After repeated unsuccessful receives, messages are eligible to move to the broker processing DLQ when the configured `maxReceiveCount` of 5 is exceeded.

The queue ARN can be passed to `ecs_job_scheduler` as `broker_request_queue_arn`, alongside the same CMK ARN as `broker_request_queue_cmk_arn`. Producer/consumer IAM permissions and effective KMS key-policy authorization must be established through their respective ownership boundaries.

The queue does not authenticate request-body claims, enforce job admission, provide durable deduplication, or process messages. These are future protected-broker responsibilities.

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

The table provides storage only. The offline identity helper derives `request:v1:<sha256>` request keys, but does not create records. A future protected Lambda broker must implement conditional, atomic DynamoDB transactions that check the authoritative gate and generation/catalog binding, establish request uniqueness, acquire the job slot, and register exclusive launch-attempt ownership. Slot and attempt record schemas, conflict detection, runtime reconciliation, safe slot release, and coordination with the independently protected lifecycle fence remain outstanding. Point-in-time restores also require protected reconciliation before admission resumes.

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
| Broker log group | `logs:CreateLogStream`, `logs:PutLogEvents` for its log streams |

The runtime policy does not grant `ecs:RunTask` or `iam:PassRole`. Those operations remain restricted to dedicated per-job launcher roles, which the broker may assume through its separately scoped `sts:AssumeRole` policy. The log group is created by Terraform; the broker runtime policy does not grant `logs:CreateLogGroup`.

These IAM permissions enable future runtime integrations but do not implement request authentication, atomic admission, correct job-state transitions, or protected lifecycle coordination. No active SQS consumer is created in this checkpoint.

## Broker Lambda Infrastructure

The module optionally creates `aws_lambda_function.broker` when `jobs` is nonempty and `broker_lambda_package` is supplied. When the package is `null`, **no Lambda function is created**, even if jobs are configured. The configured function:

- Uses the name `${name_prefix}-job-broker`, Python 3.12, the `broker.lambda_handler` entry point, an `x86_64` architecture, 256 MiB memory, and a 30-second timeout.
- Loads its ZIP from the supplied S3 bucket and object key, pinned to the exact `version_id`. The module does not build, upload, verify, or approve deployment artifacts.
- Encrypts its environment configuration using the externally supplied customer-managed key `broker_lambda_cmk_arn`. Appropriate KMS key-policy and deployment permissions must be established separately.
- Receives `BROKER_QUEUE_URL` and `EXECUTION_LEDGER_NAME` through environment variables derived from the module-managed SQS queue and DynamoDB table.
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

The tests cover empty configuration, a two-job IAM authorization contract, encrypted queue and TLS-deny settings, processing-DLQ configuration and its SNS-backed alarm, ledger configuration and deletion protection, broker log encryption and configurable retention, the absence of direct ECS launch permissions in the broker runtime policy, rejection of missing queue/ledger/log CMKs or CloudWatch retention when jobs are configured, and optional Lambda creation from a version-pinned S3 artifact with a disabled single-message SQS mapping.

They verify configured Terraform permissions and relationships, not effective AWS permissions or deployed runtime behavior.

### Offline Python Tests

The runtime helpers use Python's standard-library `unittest` framework and require no AWS credentials or third-party Python dependencies. CI selects Python 3.12 to match the configured Lambda runtime; use Python 3.12 locally for the same interpreter-version coverage.

```shell
PYTHONDONTWRITEBYTECODE=1 \
PYTHONPATH="$PWD/modules/ecs_job_broker/lambda" \
python3.12 -m unittest discover \
  -s modules/ecs_job_broker/tests \
  -p 'test_*.py' \
  -v
```

The current suite contains 72 offline Python tests:

| Test file | Tests | Coverage |
|---|---|---|
| [test_request_schema.py](tests/test_request_schema.py) | 9 | Request parsing, required generation, schema version, duplicate/unsupported fields, schedule metadata completeness, and rejection without normalization. |
| [test_producer_authorization.py](tests/test_producer_authorization.py) | 9 | Exact producer/job authorization, role replacement, invalid policy values, and rejection of unauthorized requests. |
| [test_request_identity.py](tests/test_request_identity.py) | 8 | Stable key encoding, namespace separation, role replacement, and exclusion of job/generation/schedule changes from request identity. |
| [test_catalog_producers.py](tests/test_catalog_producers.py) | 12 | Producer-section structure, role-ID syntax and length bounds, duplicate bindings, undefined jobs, empty permissions, and immutable loaded policies. |
| [test_catalog_job_bindings.py](tests/test_catalog_job_bindings.py) | 11 | Exact revision and cluster ARNs, partition/Region/account consistency, role paths, rejection of wildcards and extra fields, and immutable loaded bindings. |
| [test_catalog_job_network.py](tests/test_catalog_job_network.py) | 13 | Approved subnet subsets, exact security-group combinations, explicit public-IP disabling, ID syntax and legacy lengths, list size bounds and duplicates, invalid approval context, unsupported fields, and immutable loaded networks. |
| [test_catalog_job_fargate.py](tests/test_catalog_job_fargate.py) | 10 | Explicit numeric and `LATEST` platform selectors, syntax-only version validation, fixed Fargate launch type, strict integer task count one, required fields, rejection of extra fields and malformed selectors, and immutable loaded settings. |

A fixed expected hash in the request-identity tests guards against accidental changes to the persistent key format. The network and Fargate catalog suites add 23 tests to the preceding 49-test suite.

The [Terraform Module Tests workflow](../../.github/workflows/terraform-module-tests.yml) runs these tests after successful Python 3.12 setup. It records the interpreter version and test output in `test-evidence/ecs-job-broker-python.log`, included in the `terraform-module-test-evidence` artifact. Shell `pipefail` preserves test failures when output is piped through `tee`.

### Recorded CI Evidence

[Terraform Module Tests run #105](https://github.com/jcub-i0/terraform-secure-baseline/actions/runs/45492053955), for implementation commit `97dbda7f6dc1defd19cab4b565d3e9fc0d53398a` tested through its PR merge commit, passed all 26 broker Python tests under Python 3.12.16 and all seven broker Terraform tests. The complete workflow also passed its other Terraform suites and IAM regressions and uploaded the test evidence.

Run #105 is historical evidence for the initial 26-test suite. It predates all four catalog validators and does not establish CI results for the current 72-test suite.

These results establish offline compatibility and regression coverage. They do not qualify authenticated AWS delivery, protected artifact provenance, transactional admission, durable deduplication, lifecycle fencing, or live execution, and they do not prove zero live drift. Lambda reserved concurrency remains zero and the SQS event-source mapping remains disabled pending implementation and approval of the complete runtime controls.
