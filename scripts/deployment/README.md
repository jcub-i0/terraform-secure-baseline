# Application Deployment Scripts

## Purpose

`scripts/deployment` contains the application image-publication and immutable digest-promotion tooling for the v1.8.0 ECS/Fargate runtime. Terraform owns ECR repositories and ECS infrastructure; these scripts build and publish images outside Terraform, resolve the digest recorded by ECR, and prepare the one-field configuration change that selects a release.

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
  -> ECS convergence and workload validation
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
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/deployment/deploy-application.sh publish \
  --environment dev \
  --service api \
  --repository-name api \
  --build-context ../my-application \
  --platform linux/amd64 \
  --metadata-file /tmp/api-image.json
```

The local script requires `aws`, `docker`, and `jq`, and it uses the active AWS CLI credentials. Supplying `EXPECTED_ACCOUNT_ID` is strongly recommended so a publication cannot silently target the wrong workload account.

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

The script requires a clean repository working tree, validates the existing JSON and service registration, rejects an invalid or already-selected digest, and proves that removing the target `image_digest` leaves the before/after JSON semantically identical. It then runs `git diff --check` for the tracked file. It does not commit, push, open a PR, plan Terraform, or apply Terraform.

## GitHub `Deploy Application` Workflow

The manual workflow accepts:

- workload environment (`dev`, `staging`, or `prod`);
- canonical service key;
- build context relative to the checked-out repository root;
- Dockerfile path relative to that context; and
- an optional immutable image tag.

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

Successful publication does not imply deployment. Operators must review the release PR and its standalone Terraform Plan, merge the PR, run the protected `Terraform Apply` workflow, and confirm ECS convergence with the workload validation suite.

## Ownership Boundary

These scripts and the workflow own image publication metadata and digest handoff. They do not own ECR repository provisioning, ECS runtime resources, task IAM roles, security groups, schema migrations, application tests, release approval policy, or Terraform state. Those concerns remain with their existing platform, application, and organizational owners.