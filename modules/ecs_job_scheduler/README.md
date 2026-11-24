# ECS Job Scheduler Module

## Overview

The `ecs_job_scheduler` module provides optional, application-owned scheduling for standalone workloads using Amazon EventBridge Scheduler.

The module creates schedules that deliver structured job requests to an existing Amazon SQS queue consumed by a protected job-launch service. This separation allows scheduled and on-demand workloads to share a common execution authorization and admission boundary.

Schedules are disabled by default and use dedicated execution roles, encrypted dead-letter queues, and CloudWatch alarms for delivery failures.

The module is generic and supports applications hosted on `terraform-secure-baseline` without introducing application-specific job definitions into the foundation infrastructure.

## Architecture

The scheduling workflow is:

1. EventBridge Scheduler invokes a configured schedule.
2. Scheduler delivers a structured JSON request to the application's SQS broker-request queue.
3. The application's protected job-launch service validates and processes the request.
4. The launch service manages authorized workload execution independently of Scheduler.

Scheduler does not invoke Amazon ECS directly.

The module does not create ECS task definitions, ECS clusters, job-launch services, broker-request queues, KMS keys, or SNS topics. These components are supplied and managed through their respective infrastructure ownership boundaries.

## Resources

When schedules are configured, the module manages:

| Resource | Purpose |
|---|---|
| `aws_scheduler_schedule_group` | Application schedule namespace |
| `aws_scheduler_schedule` | Individual schedules |
| `aws_iam_role` | Dedicated execution identity per schedule |
| `aws_iam_role_policy` | Scoped delivery and encryption permissions |
| `aws_sqs_queue` | Encrypted dead-letter queue per schedule |
| `aws_cloudwatch_metric_alarm` | Per-schedule delivery-failure monitoring |

An empty `schedules` map produces no managed resources.

## Inputs

| Variable | Description | Default |
|---|---|---|
| `name_prefix` | Application resource naming prefix | Required |
| `environment` | Application environment identifier | Required |
| `schedules` | Map of configured job schedules | `{}` |
| `broker_request_queue_arn` | Existing SQS broker-request queue ARN | `null` |
| `dlq_kms_key_arn` | Customer-managed KMS key ARN for Scheduler DLQs | `null` |
| `broker_request_queue_cmk_arn` | KMS key ARN for an SSE-KMS-encrypted broker queue | `null` |
| `alarm_topic_arn` | Existing SNS topic for delivery-failure alarms | `null` |

The broker-request queue ARN, DLQ CMK ARN, and alarm topic ARN are required when the schedule map is nonempty.

The broker queue's CMK ARN is supplied when that queue uses SSE-KMS.

### Schedule configuration

Each schedule supports:

| Attribute | Description | Default |
|---|---|---|
| `job_key` | Job identifier submitted to the launch service | Required |
| `schedule_expression` | EventBridge Scheduler expression | Required |
| `timezone` | Scheduling timezone | `UTC` |
| `enabled` | Enables schedule execution | `false` |
| `maximum_retry_attempts` | Maximum delivery retry attempts | `3` |
| `maximum_event_age_in_seconds` | Maximum delivery retry age | `3600` |

For example:

```hcl
schedules = {
  archive = {
    job_key             = "archive"
    schedule_expression = "rate(1 day)"
  }

  report = {
    job_key             = "report"
    schedule_expression = "cron(0 8 * * ? *)"
    timezone            = "America/New_York"
  }
}
```

Both schedules remain disabled unless explicitly configured otherwise.

Schedule expressions are validated for supported syntax shape. AWS performs authoritative validation of scheduling expressions and timezones.

## Resource Naming

Resource names derive from `name_prefix` and the schedule map key.

The current IAM execution-role naming convention requires:

`length(name_prefix) + length(schedule_key) <= 43`

This ensures the generated IAM role name remains within AWS's
64-character limit.

Use alphanumeric characters, hyphens, and underscores for naming components to maintain compatibility with generated
SQS queue names.

IAM role names are unique within an AWS account, regardless of Region. Independent deployments in the same account must use distinct naming prefixes to prevent collisions.

The module does not silently truncate generated resource names.

## Scheduler Behavior

### Default-disabled execution

Every schedule is created in the `DISABLED` state by default.

Setting `enabled = true` requests an enabled schedule through Terraform. Application deployment controls must independently authorize schedule activation and verify that the protected launch service is operational.

### Target delivery

Schedules target an existing application-owned SQS broker-request queue.

Each schedule submits a JSON payload containing:

```json
{
  "schema_version": 1,
  "job_key": "archive",
  "schedule_key": "archive",
  "schedule_arn": "<aws.scheduler.schedule-arn>",
  "scheduled_time": "<aws.scheduler.scheduled-time>",
  "request_key": "<aws.scheduler.schedule-arn>|<aws.scheduler.scheduled-time>"
}
```

Scheduler replaces the supported context attributes at invocation time.

The `request_key` provides a stable logical identifier for a scheduled occurrence, including delivery retries. The protected launch service is responsible for durable idempotency, authorization, concurrency control, and execution tracking.

The payload is request data, not proof of authorization.

### Retry handling

Each schedule has configurable delivery retry attempts and maximum event age.

Retries apply to Scheduler target delivery. They do not provide application-level retry orchestration or guarantee successful ECS task completion.

## IAM Security

Each schedule receives a dedicated execution role.

The role's trust policy is restricted to:

- The `scheduler.amazonaws.com` service principal.
- The current AWS account using `aws:SourceAccount`.
- The associated Scheduler group ARN using `aws:SourceArn`.

Execution policies grant `sqs:SendMessage` to the configured broker-request queue and the schedule's own DLQ.

When customer-managed KMS keys are used, the role receives the corresponding `kms:GenerateDataKey` and `kms:Decrypt` permissions scoped to the configured key ARNs.

The Scheduler execution role does not receive `ecs:RunTask` or `iam:PassRole` permissions.

The protected launch service independently enforces approved job identities, exact task-definition revisions, cluster restrictions, private networking, permitted security groups, bounded concurrency, and lifecycle authorization.

A Scheduler request does not bypass those protections.

## Encryption and Key Ownership

The module uses externally supplied customer-managed KMS keys.

For application-owned scheduling resources, a dedicated application CMK can protect both Scheduler DLQs and the broker-request queue.

The module does not create, rotate, or modify KMS keys or their resource policies.

The application infrastructure must provide compatible KMS key policies and IAM permissions for Scheduler delivery, SQS encryption, and authorized consumers.

The module configures SQS DLQ encryption using `dlq_kms_key_arn`. It does not configure a customer-managed KMS key for EventBridge Scheduler's own stored target-payload encryption.

KMS key availability, permissions, and resource-policy compatibility are deployment requirements.

### External authorization requirements

The Scheduler execution role requires permission to send messages to the broker-request queue and use its customer-managed KMS key when SSE-KMS is configured.

Encrypted Scheduler DLQ delivery has a separate authorization requirement: the DLQ's customer-managed KMS key policy must authorize the `scheduler.amazonaws.com` service principal for `kms:GenerateDataKey` and `kms:Decrypt`.

Granting these actions to the Scheduler execution role alone does not satisfy the service-principal requirement for DLQ delivery.

Where the broker-request queue is in another AWS account, its SQS resource policy and applicable KMS key policy must also authorize the intended producer identity.

All external grants should be restricted to approved resources and identities. Their effective behavior must be qualified before schedules are activated.

## Dead-Letter Queues and Monitoring

Each configured schedule receives a dedicated standard SQS dead-letter queue.

DLQ configuration includes:

- Customer-managed KMS encryption.
- Fourteen-day message retention.
- Independent schedule-level resource ownership.
- A dedicated CloudWatch alarm.

The alarm monitors the SQS `ApproximateNumberOfMessagesVisible` metric and enters the alarm state when visible messages exceed zero during an evaluation period.

Notifications are delivered through the configured SNS alarm topic.

### Monitoring scope

The DLQ alarm identifies Scheduler target-delivery failures that successfully reach the queue.

It does not independently detect:

- Failures to deliver messages to the DLQ itself.
- ECS tasks that start but exit unsuccessfully.
- Application processing errors after successful SQS delivery.
- Rejected job-launch requests.
- Unavailable or unhealthy launch-service consumers.

Operational monitoring should additionally cover Scheduler delivery-error metrics, broker processing failures, application task-state changes, and execution outcomes.

## Outputs

### `schedule_group`

Returns the Scheduler group's name and ARN.

Returns `null` when no schedules are configured.

### `schedules`

Returns a map keyed by schedule name containing:

- Schedule ARN, name, and state.
- Associated job key.
- Scheduler execution-role ARN.
- DLQ ARN, URL, and name.
- DLQ CloudWatch alarm name.

The outputs expose infrastructure metadata without including job credentials or queue message contents.

## Testing

The module is tested using Terraform's native test framework.

The repository uses Terraform `1.17.1` and its locked AWS provider version.

From the repository root:

```bash
terraform -chdir=modules/ecs_job_scheduler init \
  -backend=false \
  -lockfile=readonly

terraform -chdir=modules/ecs_job_scheduler test \
  -filter=tests/scheduler.tftest.hcl
```

The test suite covers:

1. Empty configuration produces no Scheduler resources.
2. Independent schedules remain disabled by default.
3. Missing broker-request queue configuration is rejected.
4. Missing DLQ CMK configuration is rejected.
5. Invalid schedule configuration is rejected.

Tests use nonproduction credentials and an overridden AWS caller-identity data source.

They validate Terraform configuration and resource relationships without creating AWS resources.

Runtime delivery, effective IAM authorization, KMS access, and launch-service admission require integration testing in the target AWS environment.

The module is also included in the repository's Terraform module-test CI workflow.

## Integration Requirements

Applications integrating this module must provide:

- An existing SQS broker-request queue.
- A protected job-launch service that consumes and authorizes requests.
- Approved KMS keys and compatible key policies.
- An authorized SNS alarm destination.
- Application deployment controls governing schedule activation.
- Durable request deduplication and concurrency enforcement.
- Lifecycle coordination for workload draining, suspension, and teardown.
- Operational monitoring for Scheduler delivery and workload execution failures.

The application Terraform state owns the schedules and supporting application resources. Shared foundation resources remain under their respective foundation ownership boundaries.

The module supplies reusable scheduling infrastructure without granting application callers unrestricted ECS execution authority.