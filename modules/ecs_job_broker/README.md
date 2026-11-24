# ECS Job Broker Module

## Overview

The `ecs_job_broker` module provides application-owned IAM, an encrypted SQS request queue, a DynamoDB execution ledger, and CloudWatch Logs infrastructure for protected, standalone ECS Fargate job execution.

The module separates broker execution permissions from job-specific ECS launch permissions.

**Current scope:** IAM roles, trust policies, job-launch permissions, a scoped broker runtime IAM policy, an encrypted SQS request queue with a TLS-enforcing resource policy, an encrypted DynamoDB execution ledger table, a CMK-encrypted CloudWatch log group, and an optional, invocation-disabled Lambda function configured from a version-pinned S3 ZIP artifact. The SQS event-source mapping, atomic admission protocol, processing dead-letter queue, and runtime monitoring are not yet implemented.

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

The queue ARN can be passed to `ecs_job_scheduler` as `broker_request_queue_arn`, alongside the same CMK ARN as `broker_request_queue_cmk_arn`. Producer/consumer IAM permissions and effective KMS key-policy authorization must be established through their respective ownership boundaries.

The queue does not authenticate request-body claims, enforce job admission, provide durable deduplication, or process messages. These are future protected-broker responsibilities.

## DynamoDB Execution Ledger

When `jobs` is nonempty, the module creates one DynamoDB table named `${name_prefix}-job-execution-ledger` with the following infrastructure settings:

- **Primary key:** `pk` (string partition key); no sort key or secondary indexes.
- **Capacity:** On-demand (`PAY_PER_REQUEST`).
- **Encryption at rest:** Server-side encryption enabled with the externally supplied application-owned customer-managed KMS key (`execution_ledger_cmk_arn`). The module neither creates that key nor grants key access.
- **Recovery:** Point-in-time recovery enabled.
- **Deletion protection:** Enabled to guard against accidental table deletion; deliberate destruction requires a separately authorized protection change.
- **Retention:** No DynamoDB TTL configured. Expiration must not automatically remove an unresolved execution reservation.

The table provides storage only. A future protected Lambda broker must implement conditional, atomic DynamoDB transactions for request uniqueness and at-most-one-active-execution-per-job reservations. Potential logical keys include `REQUEST#<request_hash>` and `SLOT#<job_key>`, but the module does not create records or enforce that protocol. Runtime reconciliation, safe slot release, and coordination with the independently protected lifecycle fence remain outstanding. Point-in-time restores also require protected reconciliation before admission resumes.

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

No SQS event-source mapping, message handler implementation, or active broker invocation path is provided by this checkpoint. The Terraform resource describes infrastructure and cannot establish the correctness of whatever code is contained in a supplied ZIP.

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

Each `jobs` entry requires:

- `task_definition_arn`: Exact ECS task-definition revision ARN.
- `execution_role_arn`: Job execution role ARN.
- `task_role_arn`: Job application task role ARN.

An empty `jobs` map creates no managed IAM, SQS, DynamoDB, CloudWatch log-group, or Lambda resources. A nonempty `jobs` map alone does not create a Lambda function.

## Outputs

- `broker_execution_role`: Broker role ARN and name, or `null` when no jobs are configured.
- `launcher_roles`: Map of launcher role ARNs and names.
- `launcher_policy_ids`: Map of per-job inline-policy IDs.
- `broker_request_queue`: SQS queue ARN, URL, and name, or `null` when no jobs are configured.
- `execution_ledger`: DynamoDB table ARN and name, or `null` when no jobs are configured.
- `broker_log_group`: CloudWatch log group ARN and name, or `null` when no jobs are configured.
- `broker_lambda`: Lambda function ARN and name, or `null` when no package is configured.

## Security Responsibilities

The module attaches the supplied IAM permissions boundary to broker and launcher roles.

The boundary itself must be independently governed by the platform. Application deployment identities must not be able to remove or weaken mandatory boundaries, modify protected broker code or configuration without authorization, assume launcher roles directly, or bypass protected launch admission.

Effective permissions also depend on the approved IAM boundary policy, trust relationships, deployment identities, and any applicable organization-level restrictions.

The module does not create or authorize those external controls. The queue's TLS-deny policy does not replace separate producer authorization, consumer authorization, or permissions in the external CMK's key policy. The broker runtime IAM policy grants scoped access to the ledger but does not enforce transactional admission or validate request provenance; effective permissions remain subject to the permissions boundary and the external CMK key policies.

Runtime enforcement of private networking, approved security groups, request authentication, durable idempotency, admission concurrency, lifecycle fencing, and execution outcomes remains outstanding. The Lambda's reserved concurrency of zero disables invocation; it is not the per-job execution-concurrency control required of the eventual broker.

## Testing

The module uses Terraform's native test framework.

```shell
terraform -chdir=modules/ecs_job_broker init \
  -backend=false \
  -lockfile=readonly

terraform -chdir=modules/ecs_job_broker test \
  -filter=tests/broker_iam.tftest.hcl
```

The tests cover empty configuration, a two-job IAM authorization contract, encrypted-queue and TLS-deny settings, ledger configuration and deletion protection, broker log encryption and configurable retention, the absence of direct ECS launch permissions in the broker runtime policy, rejection of missing queue/ledger/log CMKs or CloudWatch retention when jobs are configured, and optional Lambda creation from a version-pinned S3 artifact with invocation disabled.

They verify configured Terraform permissions and relationships, not effective AWS permissions or deployed runtime behavior.
