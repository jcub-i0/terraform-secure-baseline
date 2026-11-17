# ECS Task Module

## Overview

`ecs_task` registers standalone Linux/Fargate task definitions for application jobs. Each entry in `tasks` defines one independent job with its own task family, log group, and supplied IAM role references. An empty map creates no resources.

Unlike [`ecs_service`](../ecs_service/README.md), this module creates no ECS service or continuously maintained task count. It does not launch tasks. A separate authorized launcher must select the task-definition revision, cluster, network configuration, and Fargate platform version.

## Resources Created

For each job key, the module creates:

| Resource | Configuration |
|---|---|
| `aws_ecs_task_definition.jobs[job]` | Family `${name_prefix}-job-${job}`, `FARGATE` compatibility, `awsvpc` networking, Linux runtime, and the configured CPU, memory, architecture, and roles. |
| `aws_cloudwatch_log_group.job_logs[job]` | Name `/aws/ecs/${name_prefix}/jobs/${job}`, configured retention, and the supplied KMS key association. |

Both resources receive `Name`, `Environment`, and `Terraform = "true"` tags. All containers in a job use that job's log group, the `awslogs` driver, and stream prefix `ecs`.

## Inputs

| Input | Type | Default | Description |
|---|---|---|---|
| `name_prefix` | `string` | Required | Prefix for task families and log-group names. |
| `environment` | `string` | Required | Value of the `Environment` tag. |
| `primary_region` | `string` | Required | Region written into container logging options; does not configure the AWS provider. |
| `logs_cmk_arn` | `string` | Required | Existing customer-managed KMS key ARN for job log groups. |
| `cloudwatch_retention_days` | `number` | Required | Log retention in days. |
| `tasks` | `map(object(...))` | `{}` | Jobs keyed by stable job name; fields below. |

### Job configuration

The job key also names the primary container, which is always `essential = true`.

| Field | Type | Default | Description |
|---|---|---|---|
| `image` | `string` | Required | Primary image as `repository@sha256:<64 lowercase hexadecimal characters>`. |
| `cpu` | `number` | Required | CPU units for the whole task. |
| `memory` | `number` | Required | Memory in MiB for the whole task. |
| `execution_role_arn` | `string` | Required | Externally managed execution role for ECS image pulls, logging, and secret retrieval. |
| `task_role_arn` | `string` | Required | Externally managed application role used by the job containers. |
| `cpu_architecture` | `string` | `"X86_64"` | Task architecture; use an architecture supported by Fargate and the images, such as `ARM64`. |
| `command` | `list(string)` | `null` | Primary command override; null omits the field and leaves the image command in effect. |
| `environment_variables` | `map(string)` | `{}` | Primary plaintext environment variables. |
| `secrets` | `map(string)` | `{}` | Primary environment names mapped to ECS secret `valueFrom` references, such as Secrets Manager or SSM Parameter Store ARNs. |
| `task_volumes` | `set(string)` | `[]` | Names of task-local volumes; no EFS or host-path configuration. |
| `mount_points` | `list(object(...))` | `[]` | Primary-container mounts; schema below. |
| `ephemeral_storage_gib` | `number` | `null` | Task storage override in GiB; null omits the block and uses the platform default. |
| `sidecars` | `map(object(...))` | `{}` | Companion containers keyed by name; schema below. |
| `depends_on` | `list(object(...))` | `[]` | Primary-container startup prerequisites; schema below. |

Each `mount_points` entry requires `source_volume` and `container_path` strings, with optional `read_only` boolean defaulting to `false`. Every `source_volume` must be declared in the job's `task_volumes`. Mounts are currently exposed only for the primary container.

### Sidecars and startup dependencies

Each `sidecars.<name>` object supports:

| Field | Type | Default | Description |
|---|---|---|---|
| `image` | `string` | Required | Digest-pinned image, using the same rule as the primary. |
| `essential` | `bool` | `false` | Set explicitly to `true` for a companion whose continued operation is required. |
| `command` | `list(string)` | `null` | Optional command override. |
| `environment_variables` | `map(string)` | `{}` | Sidecar plaintext environment variables. |
| `secrets` | `map(string)` | `{}` | Sidecar environment names mapped to secret references. |

Sidecar names must differ from the primary job key. All containers share task-level CPU/memory allocation and IAM role references; there are no per-container roles or resource-budget inputs.

Each job-level `depends_on` entry requires two strings: `container_name`, naming an existing sidecar, and `condition`:

- `START`: wait for the sidecar to start.
- `COMPLETE`: wait for the sidecar to finish, regardless of exit status.
- `SUCCESS`: wait for the sidecar to finish with exit status zero.

`COMPLETE` and `SUCCESS` require a nonessential sidecar. Only the primary can declare dependencies; sidecar-to-sidecar graphs and `HEALTHY` dependencies are not supported. There are no health-check, startup/shutdown timeout, entry-point, or sidecar mount inputs. A nonessential sidecar is not an ongoing readiness guarantee.

## Outputs

Both outputs are maps keyed by job name:

| Output | Per-job fields |
|---|---|
| `task_definitions` | `arn`, `family`, `revision`, `execution_role_arn`, `task_role_arn` |
| `log_groups` | `arn`, `name` |

The task-definition ARN identifies the registered revision. These outputs expose resource metadata, not launch authorization or IAM/network readiness attestations.

## Usage

This complete module call assumes a repository-root caller with an AWS provider configured for `us-east-1`. In an application repository, use a version-pinned source for this module. Replace the illustrative image digests, existing role ARNs, and KMS key ARN with your application resources.

```hcl
module "jobs" {
  source = "./modules/ecs_task"

  name_prefix               = "example-dev"
  environment               = "dev"
  primary_region            = "us-east-1"
  cloudwatch_retention_days = 14
  logs_cmk_arn              = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"

  tasks = {
    archive = {
      image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/archive@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      cpu                = 256
      memory             = 512
      execution_role_arn = "arn:aws:iam::123456789012:role/archive-execution"
      task_role_arn      = "arn:aws:iam::123456789012:role/archive-task"
    }
    report = {
      image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/report@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      cpu                = 256
      memory             = 512
      execution_role_arn = "arn:aws:iam::123456789012:role/report-execution"
      task_role_arn      = "arn:aws:iam::123456789012:role/report-task"
    }
  }
}
```

## Security and Ownership

- **Images:** Custom validation requires digest pinning for every primary and sidecar image. It does not establish image provenance, availability, or safety.
- **IAM:** Roles, policies, trust, permissions boundaries, and `iam:PassRole` authorization are owned outside this module. Role ARNs are passed through; the module does not enforce distinct roles or prove least privilege. Use separate execution/application roles and appropriate per-job scopes. Secret references are passed through without creating secrets or granting access.
- **Logs:** The module associates each log group with `logs_cmk_arn`. The caller must supply a usable key and compatible key policy; the association alone does not prove successful log delivery. Keep secret values out of plaintext environment variables and Terraform configuration.
- **State:** Under the approved architecture, instantiate this module in application-owned Terraform state. The calling root determines the backend; this module does not configure or enforce state separation. Foundation cluster, network, and key ownership remain external.

## Validation

The [native test file](tests/task_definitions.tftest.hcl) contains eight mocked-provider plan runs covering empty input, two independent jobs and role references, command/log/KMS rendering, task storage, sidecar defaults and `SUCCESS` rendering, plus rejection of mutable primary/sidecar images, undeclared volumes, and missing dependencies.

From the repository root, with Terraform supporting `mock_provider` and the locked AWS provider available:

```sh
terraform -chdir=modules/ecs_task init -backend=false -lockfile=readonly
terraform -chdir=modules/ecs_task validate
terraform -chdir=modules/ecs_task test -filter=tests/task_definitions.tftest.hcl
```

Initialization may download providers; use a prepopulated provider mirror/cache for offline execution. The tests use `mock_provider "aws"` and `command = plan`. They check Terraform configuration and generated values, not real task startup, dependency timing, image pulls, effective IAM permissions, secret retrieval, or log delivery.

## Limitations and Deferred Work

M2-A implements task-definition and log-group registration only. IAM provisioning, authorized/bounded `RunTask` execution, scheduling, failure alerting, and live AWS qualification remain deferred to M2-B/C work and subsequent qualification. Retries, execution deadlines, exit-status handling, and migration release gates belong to external orchestration.

There are no cluster, subnet, security-group, public-IP, or platform-version inputs here. A future launcher must enforce approved private networking and select a compatible platform. CPU/memory combinations and routine AWS parameter limits remain provider/AWS responsibilities.

The [approved interface design](../../v1-15-0/v1_15_0_M0_C2_C4_CONSOLIDATED_INTERFACE_DESIGN.md#32-generic-standalone-task-definition-and-invocation-interface) includes broader launch-readiness, invocation, and observability requirements. Those requirements are not current module capabilities; mocked test success is not AWS qualification.
