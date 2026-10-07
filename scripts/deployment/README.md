# Deployment and Lifecycle Scripts

## Purpose

`scripts/deployment` contains the ECS/Fargate image-publication and immutable digest-promotion tooling, the exact-plan artifact helper, and the production retirement/cleanup gates used by v1.11. Terraform owns ECR repositories and ECS infrastructure; the image-publication scripts build and publish images outside Terraform, resolve the digest recorded by ECR, and prepare the one-field configuration change that selects a release.

| Script | Responsibility | Mutation boundary |
|---|---|---|
| `deploy-application.sh` | Build and publish an image; resolve its authoritative digest | Writes ECR images and optional local metadata; does not deploy ECS |
| `update-application-digest.sh` | Select one service image digest | Changes one canonical JSON field locally; does not commit, push, or apply |
| `terraform-plan-artifact.sh` | Create/verify a saved Terraform plan artifact | Creates local plan files; never applies Terraform |
| `validate-production-retirement-plan.sh` | Check a saved retirement Stage-1 plan | Reads the plan; does not apply it |
| `cleanup-retirement-durable-data.sh` | Inventory or explicitly delete production ECR/Backup contents | `plan` inventories; `apply` permanently deletes the scoped durable data |
| `validate-retirement-readiness.sh` | Check converged retirement state and live AWS readiness | Read-only AWS checks; does not clean up or apply |

The canonical production lifecycle procedure is [Production Retirement](../../docs/production-retirement.md). The image-publication flow below is separate from that destructive lifecycle.

The canonical workload configuration is tracked at:

```text
environments/<env>/container-workloads.auto.tfvars.json
```

Operators maintain one `ecs_services` map in that file. A service may initially use `image_digest = null`. In this registered-but-unreleased state, Terraform keeps the required ECR repository but creates no task definition, ECS service, per-service IAM roles, task security group, or per-service runtime log group.

## Release Flow

```text
registered ecs_services entry
  -> Deploy Application workflow
  -> resolve repository and CPU architecture from canonical configuration
  -> Docker build
  -> publish through the short-lived AWS image-publisher role
  -> resolve and verify the authoritative ECR sha256 digest
  -> release job changes only ecs_services.<service>.image_digest
  -> automated release PR
  -> informational Terraform Plan on the PR
  -> human review and merge
  -> self-contained Terraform Apply workflow and protected approval
  -> verify and apply the exact saved plan
  -> ECS convergence
  -> separate workload validation/evidence
```

The `Deploy Application` workflow publishes an image and opens a release PR. It does not merge the PR, run Terraform Apply, or directly deploy the ECS service.

## Immutable Image Contract

The runtime accepts only exact image digests:

```text
<repository_url>@sha256:<64 lowercase hexadecimal characters>
```

`deploy-application.sh` publishes with an immutable ECR tag, then queries ECR for the authoritative digest. Terraform consumes that digest after the release PR is reviewed and merged. Terraform never resolves `latest`, builds an image, or pushes an image.

Any digest that remains active or deployable must retain at least one tag so it is not eligible for the untagged-image lifecycle policy. Publication or cleanup automation must not leave an active/deployable digest untagged.

## `deploy-application.sh`

The `publish` operation:

1. validates the environment, service, repository key, build context, Dockerfile, platform, and optional expected AWS account;
2. confirms that the Terraform-named ECR repository already exists in the active account;
3. refuses to reuse an existing immutable image tag;
4. builds one `linux/amd64` or `linux/arm64` image;
5. authenticates Docker and pushes the tagged image to ECR;
6. queries ECR for a valid authoritative `sha256` digest; and
7. optionally writes machine-readable publication metadata.

The default image tag is `sha-<source-commit>`. When that default is used, the build context must be a clean Git working tree. An explicitly supplied tag can be used when the source commit is unavailable or the source tree is dirty, but the tag must still be unused and valid for the immutable repository.

Representative local use:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/deployment/deploy-application.sh publish \
  --environment dev \
  --service api \
  --repository-name api \
  --build-context ../my-application \
  --platform linux/amd64 \
  --metadata-file /tmp/api-image.json
```

The local script requires `aws`, `docker`, `jq`, and `docker-credential-ecr-login` (the Amazon ECR Docker Credential Helper). Git is used for source provenance and the default tag when the build context is a Git working tree. Supply `--region` or `AWS_REGION` explicitly; the example's `us-east-1` is not a fallback. Supplying `EXPECTED_ACCOUNT_ID` is strongly recommended so a publication cannot silently target the wrong workload account.

`--profile` or `AWS_PROFILE` selects a local AWS CLI profile. When non-empty, the script also exports `AWS_PROFILE` for the credential helper. The helper must be available on `PATH` before local publication; the script fails if it is absent rather than falling back to password-file login.

When requested, the metadata JSON records:

- environment and service;
- cloud name and repository key;
- resolved ECR repository name, URI, registry ID, and AWS Region;
- source commit and dirty-state indicator;
- build context, Dockerfile, and platform;
- immutable image tag and authoritative image digest;
- tagged and digest-pinned image URIs; and
- publication timestamp.

The metadata contains no ECR authorization token or AWS credentials.

### ECR authentication and temporary Docker configuration

The publication script does not call `docker login` or `aws ecr get-login-password`. After the image build, it creates a temporary directory with permissions `0700` and a `config.json` with permissions `0600`. That JSON contains only a registry-specific `credHelpers` mapping to `ecr-login`; it contains no embedded authorization token.

The push uses that directory through a command-scoped `DOCKER_CONFIG` override. The script sets `AWS_ECR_DISABLE_CACHE=true` so the helper's ECR authorization-token file cache is disabled. The helper obtains authorization through the active AWS credential chain. The script installs an `EXIT` trap and explicitly removes the temporary directory after a successful push. Cleanup is best-effort on normal shell exit; an uncatchable process/runner termination cannot execute a shell trap.

The preceding `docker build` uses the caller's existing Docker configuration. This change does not erase credentials previously stored in the caller's ordinary Docker configuration, and it does not claim that AWS credentials or ECR tokens never exist in process memory. Publication metadata does not contain those credentials.

## `update-application-digest.sh`

This script updates only:

```text
ecs_services.<service>.image_digest
```

in the selected tracked workload configuration. It requires:

```bash
./scripts/deployment/update-application-digest.sh \
  --environment dev \
  --service api \
  --image-digest "sha256:<64-lowercase-hex-characters>"
```

The script requires a clean repository working tree, validates the existing JSON and service registration, rejects an invalid or already-selected digest, and proves that removing the target `image_digest` leaves the before/after JSON semantically identical. It then runs `git diff --check` for the tracked file. It receives the authoritative digest as an input; it does not discover or resolve the digest itself. It does not commit, push, open a PR, plan Terraform, or apply Terraform.

The GitHub release/PR job calls this script with the digest resolved and re-checked by the separate publisher job. Because the mutation is restricted to `image_digest`, releases do not rewrite a service's `scaling`, `deployment`, ingress, IAM, or other canonical runtime configuration.

## GitHub `Deploy Application` Workflow

The manual workflow accepts:

- workload environment (`dev`, `staging`, or `prod`);
- canonical service key;
- build context relative to the checked-out repository root;
- Dockerfile path relative to that context; and
- an optional immutable image tag.

The publisher job installs the Ubuntu package `amazon-ecr-credential-helper` when `docker-credential-ecr-login` is not already on `PATH`, and verifies that the helper is available before invoking the publication script. It does not pin a package version in RC1.

The workflow build context must resolve inside the repository checkout. The workflow reads `repository_name` and `cpu_architecture` from the selected canonical service entry and maps `X86_64` to `linux/amd64` or `ARM64` to `linux/arm64`; operators do not enter a parallel repository or platform value.

The matching `<env>-plan` GitHub Environment supplies:

```text
ACCOUNT_ID
PRIMARY_REGION
CLOUD_NAME
IMAGE_PUBLISHER_ROLE_GITHUB_ARN
BRANCHES_IMAGE_PUBLISHER_GITHUB
```

`BRANCHES_IMAGE_PUBLISHER_GITHUB` defaults in the workflow to `["main"]` when unset, but the configured value must be a non-empty JSON array and must include the branch from which publication runs. The account-stack Terraform output `image_publisher_role_github_arn` supplies the role ARN after the optional image publisher role is enabled and applied.

### Publisher job authority

The image-publisher job:

- requests a GitHub OIDC token and assumes the branch-trusted, environment-specific AWS image-publisher role;
- has GitHub `contents: read` but not `contents: write`;
- can obtain an ECR authorization token and query/publish images only to repositories matching the workload name prefix; and
- has no broad Terraform state, ECS, IAM, or general AWS administration authority.

The publisher job intentionally has no GitHub Environment assignment. Its IAM trust uses branch-based GitHub OIDC subjects; assigning an environment would change the token subject and break that trust contract.

### Release/PR job authority

The release job:

- has GitHub `contents: write` and `pull-requests: write` so it can create a release branch, commit the canonical configuration change, and open a PR;
- receives no AWS credentials and has no `id-token` permission;
- checks out the exact publication source commit;
- requires exactly one tracked file to change; and
- verifies that the selected service's `image_digest` equals the digest resolved from ECR.

This separation keeps AWS image-publishing authority out of the repository mutation job and GitHub repository write authority out of the AWS publisher job.

## Failure and Safety Behavior

The tooling fails closed for invalid service/repository syntax, unsupported platforms, account mismatches, missing or inaccessible repositories, tag reuse, invalid or unresolved digests, missing canonical configuration, unregistered services, dirty release checkouts, and configuration mutations outside the selected digest field.

Successful publication does not imply deployment. Operators must review the release PR and its standalone informational Terraform Plan, merge the PR, run the protected `Terraform Apply` workflow, and confirm ECS convergence with the workload validation suite. For autoscaled services, Terraform applies runtime changes without reasserting the configured bootstrap `desired_count`; Application Auto Scaling retains ownership of the live desired count within the configured bounds.

## Ownership Boundary

The image-publication scripts and `Deploy Application` workflow own image publication metadata and digest handoff. They do not own ECR repository provisioning, ECS runtime resources, task IAM roles, security groups, schema migrations, application tests, release approval policy, or Terraform state. Those concerns remain with their existing platform, application, and organizational owners.

## Exact Terraform Plan Artifacts

`terraform-plan-artifact.sh` supports `create` and `verify`, with `--mode apply` or `--mode destroy`. Callers supply `--working-directory`, `--artifact-directory`, `--artifact-basename`, and a non-secret `--context-json` object. Workflows own the AWS identity, policy, approval, and eventual Terraform apply.

For a basename such as `baseline-destroy`, the helper produces:

```text
baseline-destroy.tfplan
baseline-destroy-plan.txt
baseline-destroy-plan-metadata.json
baseline-destroy-plan.sha256
```

Creation refuses to overwrite existing artifact files. The checksum manifest covers the binary plan, readable plan, and metadata. Verification checks the manifest, exact metadata/context, Terraform CLI version, and supported destroy-plan actions. Destroy mode requires at least one deletion and permits only `delete`, `no-op`, and `read` resource actions. This is artifact/context validation, not an independent security approval or proof that every resource deletion is appropriate.

The helper requires GitHub Actions identity variables, including `GITHUB_SHA`, `GITHUB_REPOSITORY`, `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_REF`, `GITHUB_ACTOR`, and `GITHUB_WORKFLOW_REF`. It is not a general local helper that runs unchanged outside Actions. Do not invent workflow identity variables to label a local plan as CI evidence.

The workload Apply/Destroy and Identity Center cleanup paths use their own saved artifacts. Their plan artifacts are retained for one day in the current workflows. Protect these artifacts and their logs: checksums are not encryption, and plan files can contain sensitive configuration.

## Production Retirement Helpers

Use the [runbook](../../docs/production-retirement.md) for the complete order and approvals. These helpers must not be treated as interchangeable:

- `validate-production-retirement-plan.sh` accepts `--working-directory` and `--plan-file`. It checks allowed resource action types and the planned production/lifecycle/zero-capacity outputs. It does not whitelist every permissible in-place attribute update, so the full plan still needs review.
- `cleanup-retirement-durable-data.sh` accepts only `prod` in RC1. It requires the expected account ID and checks the deployed production retirement outputs. `--mode plan` inventories; `--mode apply --confirm DELETE-DURABLE-DATA` re-inventories and deletes scoped ECR images and Backup recovery points. The inventory is not a saved Terraform plan or immutable item-level approval artifact. Active Backup jobs prevent apply-mode cleanup.
- `validate-retirement-readiness.sh` accepts a workload environment, reads its Terraform state/outputs, and checks production posture, live deletion protections, ECS quiescence, zero autoscaling bounds, empty ECR repositories, and an empty Backup vault without active backup jobs. It performs no deletion. It must pass after cleanup and immediately before the final destroy operations.

The latter two helpers derive the service region from deployed `primary_region` and reject conflicting explicit region inputs. Their optional `--region`/`--profile` inputs are unrelated to the Terraform state backend's location. The full RC1 cleanup workflow is not supported for a production-profile `dev` or `staging` environment because of the cleanup helper's explicit `prod` restriction.

Production retirement mode does not enable ECR/ECS force deletion or Backup vault force destruction. The Destroy workflow requires explicit durable-data authorization and separate protected cleanup, Identity Center cleanup, and final destroy steps. Later cancellation does not undo earlier approved deletions or access changes.

## Implementation References

This page targets v1.11.0 behavior at `v1.11.0-rc1` (`728166fa17bf42fe06bf540729c6aba1e70e05d5`). It does not assert a new live publication or retirement test on this exact commit.

- [Image publisher](deploy-application.sh) and [digest update](update-application-digest.sh)
- [Publication workflow](../../.github/workflows/deploy-application.yml)
- [Plan artifact helper](terraform-plan-artifact.sh)
- [Retirement plan guard](validate-production-retirement-plan.sh)
- [Durable-data cleanup](cleanup-retirement-durable-data.sh)
- [Retirement readiness](validate-retirement-readiness.sh)
- [Terraform Apply](../../.github/workflows/terraform-apply.yml) and [Terraform Destroy](../../.github/workflows/terraform-destroy.yml)
