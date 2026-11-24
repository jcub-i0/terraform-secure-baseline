
# ECS Job Broker Module

## Overview

The `ecs_job_broker` module provides application-owned IAM resources for protected, standalone ECS Fargate job execution.

The module separates broker execution permissions from job-specific ECS launch permissions.

**Current scope:** IAM roles, trust policies, and permissions only. The broker Lambda function, SQS request queue, DynamoDB execution ledger, runtime admission logic, and monitoring are not yet implemented by this module.

## IAM Architecture

The module creates:

- One Lambda broker execution role when jobs are configured.
- One dedicated launcher role per approved job.
- A broker policy granting `sts:AssumeRole` on the configured launcher roles only.
- Per-job policies granting `ecs:RunTask` and `iam:PassRole` under explicit resource restrictions.

The broker execution role trusts `lambda.amazonaws.com` and does not receive direct ECS launch permissions.

Each launcher trusts the broker execution role.

### Launcher Authorization

Each launcher is restricted to:

- The exact configured ECS task-definition revision.
- The approved ECS cluster through the `ecs:cluster` condition.
- The job's configured task and execution IAM roles.
- Role passing to `ecs-tasks.amazonaws.com` only.

Launcher authorization does not independently enforce task network configuration, concurrency, idempotency, or lifecycle fencing. These require protected runtime admission controls.

## Inputs

| Input | Description | Default |
|---|---|---|
| `name_prefix` | Application resource naming prefix | Required |
| `environment` | Environment identifier for tagging | Required |
| `approved_cluster_arn` | Exact approved ECS cluster ARN | Required |
| `permissions_boundary_arn` | Platform-governed IAM permissions boundary ARN | Required, non-null |
| `jobs` | Map of approved standalone jobs | `{}` |

Each `jobs` entry requires:

- `task_definition_arn`: Exact ECS task-definition revision ARN.
- `execution_role_arn`: Job execution role ARN.
- `task_role_arn`: Job application task role ARN.

An empty `jobs` map creates no managed IAM resources.

## Outputs

- `broker_execution_role`: Broker role ARN and name, or `null` when no jobs are configured.
- `launcher_roles`: Map of launcher role ARNs and names.
- `launcher_policy_ids`: Map of per-job inline-policy IDs.

## Security Responsibilities

The module attaches the supplied IAM permissions boundary to broker and launcher roles.

The boundary itself must be independently governed by the platform. Application deployment identities must not be able to remove or weaken mandatory boundaries, modify protected broker code or configuration without authorization, assume launcher roles directly, or bypass protected launch admission.

Effective permissions also depend on the approved IAM boundary policy, trust relationships, deployment identities, and any applicable organization-level restrictions.

The module does not create or authorize those external controls.

Runtime enforcement of private networking, approved security groups, request authentication, durable idempotency, concurrency, lifecycle fencing, and execution outcomes remains outstanding.

## Testing

The module uses Terraform's native test framework.

```shell
terraform -chdir=modules/ecs_job_broker init \
  -backend=false \
  -lockfile=readonly

terraform -chdir=modules/ecs_job_broker test \
  -filter=tests/broker_iam.tftest.hcl
```

The tests cover empty configuration and a two-job IAM authorization contract.

They verify configured Terraform permissions and relationships, not effective AWS permissions or deployed runtime behavior.
