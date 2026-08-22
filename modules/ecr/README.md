# ECR Module

## Overview

The `ecr` module creates a stable map of private Amazon Elastic Container Registry repositories for a workload environment. It provides repository infrastructure for future container runtimes without building, publishing, or selecting container images.

## Resources Created

For every repository key in `repositories`, the module creates:

- One `aws_ecr_repository.repositories` instance
- One `aws_ecr_lifecycle_policy.untagged_cleanup` instance

Repository names use `${name_prefix}-${repository_key}`. The repository key is
both the stable Terraform `for_each` identity and the environment-local portion
of the rendered AWS repository name.

Repository keys must use lowercase letters and numbers separated only by
periods, underscores, or hyphens. The complete rendered name must not exceed
256 characters.

## Inputs

| Input | Type | Required | Description |
|---|---|---:|---|
| `name_prefix` | `string` | Yes | Baseline naming prefix used to construct repository names. |
| `environment` | `string` | Yes | Workload environment identity used for tagging. |
| `kms_key_arn` | `string` | Yes | ARN of the customer-managed KMS key used for repository encryption. |
| `repositories` | `map(object({}))` | No | Repositories keyed by their environment-local repository name. Defaults to `{}`. |

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

The values are currently empty objects, so each repository's identity and name
come entirely from its map key. No per-repository settings are exposed. Adding,
removing, or renaming a map key changes the corresponding repository instance
and AWS repository name.

The module intentionally does not expose configuration for force deletion, tag mutability, encryption type, image scanning, repository policies, lifecycle retention, image references, or arbitrary caller tags. Those settings are platform-owned or deferred.

## Encryption and KMS Ownership

Every repository is encrypted with the required customer-managed KMS key from `kms_key_arn`. ECR encryption configuration is immutable after repository creation, so repositories use KMS encryption from their first creation.

This module consumes the key but does not create or manage it. The dedicated
ECR customer-managed key and alias are owned by `modules/security` as
`aws_kms_key.ecr` and `aws_kms_alias.ecr`. `baseline/main.tf` passes
`module.security.ecr_cmk_arn` to this module. ECR must receive the key ARN, not
the alias ARN.

## Tag Immutability

All repositories use `image_tag_mutability = "IMMUTABLE"`. Existing tags cannot be reassigned to different image digests. The module does not resolve tags or select deployment digests; future Terraform-managed deployments will use reviewed, digest-pinned image references.

## Lifecycle Policy and Release-Tag Invariant

The lifecycle policy expires only untagged images older than 30 days. It does not match or expire tagged images and does not assume an application-specific release-tag convention.

Any image digest that is active or remains deployable by Terraform **MUST retain at least one immutable release tag**. Release, build, and publishing automation **MUST NOT remove the final release tag** from a digest while that digest remains active or deployable.

Tag immutability prevents tag reassignment, but it does not prevent deletion of a tag or an untagged image. Preserving the final release tag is therefore part of the v1.8.0 platform contract. Sophisticated historical release retention is deferred.

## Development/Test Destruction Posture

The current workload environments are regularly applied and destroyed to control development and test costs. Repositories therefore use:

```hcl
force_delete = true # CHANGE THIS IN PROD
```

This permits `terraform destroy` to remove a repository that still contains development images. Persistent production usage must reconsider this setting before deployment. The module does not use `prevent_destroy` protection.

Repository force deletion and lifecycle cleanup are separate concerns. The 30-day lifecycle rule handles ordinary cleanup of untagged build artifacts; it is not a prerequisite for environment teardown, and users do not need to wait for lifecycle expiration before destroying an environment.

## Scanning Ownership

The module configures neither repository basic scanning nor registry enhanced scanning. Amazon Inspector ownership remains in `modules/security`.

Future repository enablement must ensure that `ECR` is included in the effective Inspector resource types whenever ECR repositories are enabled. This module intentionally does not create `image_scanning_configuration`, `aws_ecr_registry_scanning_configuration`, or any other parallel scanning ownership.

## Repository Policies and IAM

The module does not create an `aws_ecr_repository_policy`. Repositories are workload-local, and same-account image pull and publishing permissions belong to later IAM and release integration. No cross-account image model is currently approved.

## Current Integration Status

The repository resource declares the standard `Name`, `Environment`, and
`Terraform` tags. Its `Name` tag is the rendered repository name:
`${var.name_prefix}-${each.key}`.

`baseline/main.tf` instantiates this module and supplies the ECR CMK key ARN.
It does not currently pass `repositories`, so the module receives its `{}`
default and creates no repositories. The workload environment roots do not yet
expose repository configuration or repository outputs.

## Outputs

The `repositories` output is keyed by the same repository keys as the input
map. Values come from `aws_ecr_repository.repositories`, and each entry
contains:

- `arn`
- `name`
- `repository_url`
- `registry_id`

The module does not output registry credentials, authorization tokens, image tags, image digests, or selected deployment images.

## Ownership Boundary

This module owns private repositories, encryption configuration, immutable tags, lifecycle policies, standard tags, and repository metadata outputs.

It does not own:

- Container image builds or publishing
- Image-tag or deployment-digest selection
- ECS clusters, services, or task definitions
- IAM execution roles, task roles, or publishing permissions
- Repository resource policies
- Networking or VPC endpoints
- Inspector or registry-level scanning configuration
- GuardDuty or containment
- KMS key creation
- Workload-environment repository configuration or output propagation

The security-owned KMS key and baseline module call are present. Repository
configuration propagation, effective Inspector ECR activation, and live ECR
validation remain future integration work within the existing workload
baseline validation layer.
