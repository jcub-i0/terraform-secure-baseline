# ECR Module

## Overview

The `ecr` module creates a stable map of private Amazon Elastic Container Registry repositories for a workload environment. It supplies repository infrastructure to the ECS/Fargate runtime without building, publishing, selecting, or scaling container workloads.

Repository ownership is intentionally independent of ECS service runtime state. A canonical service can require its repository while remaining registered-but-unreleased with `image_digest = null`, and later ECS Service Auto Scaling configuration does not change repository ownership or lifecycle.

## Resources Created

For every repository key in `repositories`, the module creates:

- One `aws_ecr_repository.repositories` instance
- One `aws_ecr_lifecycle_policy.untagged_cleanup` instance

Repository names use `${name_prefix}-${repository_key}`. The repository key is both the stable Terraform `for_each` identity and the environment-local portion of the rendered AWS repository name.

Repository keys must use lowercase letters and numbers separated only by periods, underscores, or hyphens. The complete rendered name must not exceed 256 characters.

## Inputs

| Input | Type | Required | Description |
|---|---|---:|---|
| `name_prefix` | `string` | Yes | Baseline naming prefix used to construct repository names. |
| `environment` | `string` | Yes | Workload environment identity used for tagging. |
| `kms_key_arn` | `string` | Yes | ARN of the customer-managed KMS key used for repository encryption. |
| `repositories` | `map(object({}))` | No | Repositories keyed by their environment-local repository name. Defaults to `{}`. |
| `force_delete` | `bool` | Yes | Whether Terraform may remove repositories containing images. No module default; baseline supplies the profile-derived policy. |

Example input:

```hcl
repositories = {
  application = {}
  worker      = {}
}
```

With `name_prefix = "secure-baseline-development"`, this example creates:

- `secure-baseline-development-application`
- `secure-baseline-development-worker`

The values are currently empty objects, so each repository's identity and name come entirely from its map key. No per-repository settings are exposed. Adding, removing, or renaming a map key changes the corresponding repository instance and AWS repository name.

The module exposes one shared `force_delete` input for its repository set. It does not expose per-repository overrides for force deletion, tag mutability, encryption type, image scanning, repository policies, lifecycle retention, image references, or arbitrary caller tags. Those other settings remain platform-owned or deferred.

## Encryption and KMS Ownership

Every repository is encrypted with the required customer-managed KMS key from `kms_key_arn`. ECR encryption configuration is immutable after repository creation, so repositories use KMS encryption from their first creation.

This module consumes the key but does not create or manage it. The dedicated ECR customer-managed key and alias are owned by `modules/security` as `aws_kms_key.ecr` and `aws_kms_alias.ecr`. `baseline/main.tf` passes `module.security.ecr_cmk_arn` to this module. ECR must receive the key ARN, not the alias ARN.

## Tag Immutability

All repositories use `image_tag_mutability = "IMMUTABLE"`. Existing tags cannot be reassigned to different image digests. The module does not resolve tags or select deployment digests; Terraform-managed ECS deployments use reviewed, digest-pinned image references.

## Lifecycle Policy and Release-Tag Invariant

The lifecycle policy expires only untagged images older than 30 days. It does not match or expire tagged images and does not assume an application-specific release-tag convention.

Any image digest that remains active or deployable **MUST retain at least one tag** so it is not eligible for the untagged-image lifecycle policy. Publication or cleanup automation must not leave an active/deployable digest untagged.

Tag immutability prevents tag reassignment, but it does not prevent deletion of a tag or an untagged image. Any digest that remains active or deployable must retain at least one tag so it is not eligible for the untagged-image lifecycle policy. Sophisticated historical release retention is deferred.

## Profile-Derived Destruction Posture

The repository resource uses `force_delete = var.force_delete`. Baseline supplies:

| Baseline profile/state | `force_delete` |
|---|---|
| Normal `production` | `false` |
| `production` with `production_retirement_mode = true` | `false` |
| `development` or `minimal` | `true` |

The reusable module does not resolve deployment profiles itself and has no `prevent_destroy` guard. `force_delete = false` prevents Terraform from automatically emptying a repository to delete it; it is not a general AWS prohibition on image deletion by authorized principals.

Production retirement requires deliberate image disposition. The supported `prod` Destroy path invokes a separately approved cleanup helper to delete images in the Terraform-owned repository set, verifies that the repositories are empty, and then applies the reviewed Terraform destroy plan. It does not temporarily set `force_delete = true`. Required images must be retained elsewhere before deletion is authorized. See [Production Retirement](../../docs/production-retirement.md).

Repository force deletion and lifecycle cleanup are separate concerns. The 30-day lifecycle rule handles untagged images by time since image push; it is not a prerequisite for intentional environment teardown. The cleanup helper's RC1 environment restriction is `prod`, even though the baseline's lifecycle values are profile-derived.

---

## Scanning Ownership

The module configures neither repository basic scanning nor registry enhanced scanning. Amazon Inspector ownership remains in `modules/security`.

Baseline adds `ECR` to `effective_inspector_resource_types` whenever the effective repository set is non-empty. This module intentionally does not create `image_scanning_configuration`, `aws_ecr_registry_scanning_configuration`, or any other parallel scanning ownership.

## Repository Policies and IAM

The module does not create an `aws_ecr_repository_policy`. Repositories are workload-local. Same-account ECS pull permissions are owned by `modules/iam`; image-publishing authority belongs to the application delivery workflow rather than this module. No cross-account image model is currently approved.

## Current Integration Status

Each workload root passes `repositories` to baseline. Baseline merges those explicit keys with repository keys required by the canonical `ecs_services` map and passes the effective set to this module. It also supplies the dedicated security-owned ECR CMK key ARN. Workload roots expose `ecr_repositories` and `ecr_cmk_arn` for consumers and validation.

Every registered canonical service contributes its `repository_name` even when `image_digest = null`. This lets Terraform create or retain the repository while keeping the task definition, ECS service, per-service roles, task security group, runtime log group, Application Auto Scaling target, and scaling policies absent until an immutable digest is selected.

Service runtime settings do not alter repository derivation. In particular:

- `scaling = null` versus a configured scaling object has no effect on ECR repository ownership.
- Deployment-health settings have no effect on ECR repository ownership.
- Ingress settings have no effect on ECR repository ownership.
- Application Auto Scaling and Terraform-owned operational alarms are outside this module.

Explicit repositories still support initial repository provisioning without permanent duplication:

```hcl
repositories = { test = {} }
ecs_services = {}
```

After an `ecs_services` entry references `repository_name = "test"`, `repositories` may return to `{}` before or after image publication. Because both paths use the same repository map key, Terraform retains the existing repository.

## Outputs

The `repositories` output is keyed by the same repository keys as the input map. Values come from `aws_ecr_repository.repositories`, and each entry contains:

- `arn`
- `name`
- `repository_url`
- `registry_id`
- `force_delete`

The module does not output registry credentials, authorization tokens, image tags, image digests, or selected deployment images.

## Ownership Boundary

This module owns private repositories, encryption configuration, immutable tags, lifecycle policies, standard tags, and repository metadata outputs.

It does not own:

- Container image builds or publishing
- Image-tag or deployment-digest selection
- ECS clusters, services, or task definitions
- ECS Service Auto Scaling targets or policies
- ECS deployment-health configuration
- Terraform-owned ECS operational alarms
- IAM execution roles, task roles, or publishing permissions
- Repository resource policies
- Networking or VPC endpoints
- Inspector or registry-level scanning configuration
- GuardDuty or containment
- KMS key creation
- Application release sequencing or deployment workflow behavior

Those responsibilities belong to other modules or baseline integration.

The implemented `Deploy Application` workflow owns the separate image-publication boundary: it publishes an image through the image-publisher role, resolves the authoritative ECR digest, and opens a release PR. It does not change this module's ownership or make Terraform build or push images.

`validate-ecr.sh` uses the workload-root repository output as its authoritative inventory and passes cleanly for `{}`. For configured repositories it validates live identity, immutable tags, exact equality with `ecr_cmk_arn`, and the approved untagged-only lifecycle policy. It also checks the Terraform-owned `force_delete` value against the lifecycle contract; that flag is provider deletion intent, not a live ECR repository attribute. `validate-security-workload.sh` separately checks the Terraform-computed effective Inspector resource types.

## Implementation References

This page targets v1.11.0, reconciled against `v1.11.0-rc1` (`728166fa17bf42fe06bf540729c6aba1e70e05d5`).

- [Repository resources](main.tf), [inputs](variables.tf), and [outputs](outputs.tf)
- [Baseline derivation](../../baseline/locals.tf) and [module integration](../../baseline/main.tf)
- [ECR validator](../../scripts/validation/validate-ecr.sh)
- [Publication and lifecycle tooling](../../scripts/deployment/README.md)
