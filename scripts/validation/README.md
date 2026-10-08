# Validation Scripts

## Purpose

This directory contains the read-only AWS inspection entry points and local evidence exporters for `tf-secure-baseline`. This reference is not proof of completed testing; use the tested commit, effective configuration, and retained evidence for each deployment or historical qualification.

The validation scripts are intended to confirm that deployed Terraform stacks and AWS resources match the expected baseline architecture. They are useful for:

- deployment verification
- release validation
- client handoff evidence
- troubleshooting
- audit-readiness support
- regression checks after infrastructure changes

These scripts do **not** replace a SOC 2 audit, ISO 27001 audit, formal control assessment, or operating effectiveness review.

The validation scripts are located in:

```text
scripts/validation/
```

---

## Validation Layers

`tf-secure-baseline` has four validation layers and matching evidence exporters:

```text
Workload bootstrap validation  -> validate-bootstrap.sh <dev|staging|prod>
Workload baseline validation   -> validate-baseline.sh <dev|staging|prod>
Control-plane validation       -> validate-control-plane.sh
Security-operations validation -> validate-security-operations.sh

Workload bootstrap evidence    -> export-bootstrap.sh <dev|staging|prod>
Workload baseline evidence     -> export-baseline.sh <dev|staging|prod>
Control-plane evidence         -> export-control-plane.sh
Security-operations evidence   -> export-security-operations.sh
```

| Layer | Scope | Validation script | Evidence exporter |
|---|---|---|---|
| Workload bootstrap | `bootstrap/<env>/state` and `bootstrap/<env>/account` | `validate-bootstrap.sh` | `export-bootstrap.sh` |
| Workload baseline | deployed workload environment under `environments/<env>` | `validate-baseline.sh` | `export-baseline.sh` |
| Control plane | state/OIDC, AWS Organizations topology and prerequisites, IAM Identity Center | `validate-control-plane.sh` | `export-control-plane.sh` |
| Security operations | centralized Security Hub CSPM, GuardDuty, and Security Hub V2 governance | `validate-security-operations.sh` | `export-security-operations.sh` |

The boundary is intentional: control plane proves organization structure and prerequisites; security operations proves delegated centralized-security configuration; workload validation proves member-account realization and workload controls.

---

## Required Local Tools

The scripts expect these tools to be available locally:

```text
aws
terraform
jq
git
```

Some scripts may require additional AWS CLI permissions depending on the resources being checked.

Use Bash (not `sh`), AWS CLI, Git, `jq`, and the Terraform CLI **1.15.8** with the tracked lockfiles. Standard shell utilities are also used; this list is not a complete portable installation manifest. Commands below run from the repository root. Replace angle-bracket values before execution and select the correct account/profile for each layer. No example authorizes a production mutation.

Initialize the selected Terraform backends before validation. A fresh checkout of an already-migrated state root needs its reviewed runtime `backend.tf` materialized from the tracked template; merely initializing the root without that backend can read the wrong state location. Follow the [bootstrap reference](../bootstrap/README.md) and [quickstart](../../docs/quickstart.md). Do not run `init -upgrade` to solve an evidence run's version mismatch.

Validators can read sensitive Terraform state and write temporary local files. Exporters additionally write reports/logs. “Read-only” describes their intended AWS inspection behavior, not an absence of local writes or an IAM read-only guarantee: Plan roles also have state-related authority. A GitHub Environment declaration is not proof that required reviewers were configured.

---

## Common Environment Variables

Most scripts use the following environment variables:

| Variable | Purpose | Required |
|---|---|---|
| `AWS_PROFILE` | Named local profile for the target account; omit for GitHub OIDC/default-chain execution | Optional; identify the actual caller |
| `AWS_REGION` | Workload: optional equality assertion against applied `primary_region`; administrative layers: explicit service Region | Required for bootstrap/control plane/security operations |
| Workload positional argument | `dev`, `staging`, or `prod`; scripts assign internal `ENV_NAME` from `$1`. Exporting `ENV_NAME` is not an alternative to that argument. | Required for workload entry points |
| `EXPECTED_ACCOUNT_ID` | Expected AWS account ID for safety checks | Recommended |
| `EXPECTED_GITHUB_REPOSITORY` | Expected GitHub repository in `<owner>/<repo>` form for OIDC trust validation. Required for strict Image Publisher repository/branch trust validation. | Bootstrap / control plane |
| `CLOUD_NAME` | Cloud/project prefix, defaults to `tf-secure-baseline` | Optional |
| `NAME_PREFIX` | Resource name prefix override. Defaults to `${CLOUD_NAME}-${ENV_NAME}` for environment-specific scripts. | Optional |
| `REQUIRE_STATE_STACK_REMOTE` | Makes migrated state-stack backend findings fail instead of warn. Defaults to `false` in direct script/exporter runs; GitHub evidence workflows default it to `true`. | Optional |
| `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE` | Requires the workload GitHub Image Publisher role to exist. Defaults to `false`; when the role output is present, the role is still validated even if this flag is `false`. | Workload bootstrap only |
| `EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES` | Non-empty JSON array of branches expected in Image Publisher OIDC trust. Falls back to `BRANCHES_IMAGE_PUBLISHER_GITHUB`, then `["main"]`. | Workload bootstrap only |
| `STRICT_GITHUB_SUBJECT_CHECKS` | Workload-bootstrap Plan/Apply subject checks; defaults to `true`. This is not a control-plane strictness input. | Workload bootstrap only |
| `IDENTITY_CENTER_WORKLOADS` | JSON map containing the `dev`, `staging`, and `prod` Identity Center workload configurations. Required by the control-plane validator and exporter. | Control plane only |
| `IDENTITY_CENTER_SECOPS` | JSON object containing the security-operations Identity Center configuration. Required by the control-plane validator and exporter. | Control plane only |
| `WORKLOADS_OU_NAME` | Workloads OU name used by centralized-security validation. Defaults to `Workloads`. | Security operations / control plane |
| `WORKLOAD_ACCOUNT_NAMES` | Space-delimited workload account names used by the security-operations exporter. Defaults to `dev staging prod`. | Security operations only |
| `STRICT_WORKLOAD_CMK_POLICY_CHECKS` | Current workload CMK references in bootstrap IAM; default `true` | Workload bootstrap only |
| `REQUIRE_BOOTSTRAP_GITHUB_OIDC` / `REQUIRE_BOOTSTRAP_GITHUB_APPLY_ROLE` | Required bootstrap OIDC/Apply-role checks; each defaults to `true` | Workload bootstrap only |
| `STRICT_ACCOUNT_OU_CHECKS` / `STRICT_IDENTITY_CENTER_ASSIGNMENTS` | Required topology/assignment findings fail by default (`true`) | Control plane only |
| `CHECK_OPTIONAL_SECOPS_GROUPS` | Additional optional-group checks; default `false` | Control plane only |
| `REQUIRE_CONTROL_PLANE_GITHUB_OIDC` | Control-plane OIDC checks; default `true` | Control plane only |

Example service-region context (replace `us-east-1` with the intended service Region, not the backend Region):

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
```

Most environment-specific scripts derive naming with this pattern:

```bash
ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"
```

This allows client or custom deployments to override `CLOUD_NAME` without editing script internals. Set `NAME_PREFIX` directly only when validating resources that intentionally do not follow the default `${CLOUD_NAME}-${ENV_NAME}` naming convention.

### Region authority and execution context

The workload runner, workload exporters, and individual workload validators resolve the service Region from the **applied** `environments/<env>` output `primary_region`. The shared `resolve_workload_region` helper rejects a conflicting supplied `AWS_REGION`, including an explicitly empty value. The AWS profile's default Region, `AWS_DEFAULT_REGION`, and the S3 backend Region are not substitutes for that output. Use `unset AWS_REGION`, not `AWS_REGION=""`, when deliberately allowing the workload helper to resolve it; an unreadable or unapplied workload root still fails.

Workload-bootstrap, control-plane, and security-operations validators/exporters instead require an explicit, non-empty service `AWS_REGION`. They do not discover their scope from workload state. Bootstrap/control-plane state checks use the separately resolved backend Region for their state S3/KMS queries. Keep these concepts distinct:

| Setting or evidence | Meaning |
|---|---|
| Workload `primary_region` output | Provider-backed, applied workload service Region used by workload validation |
| Administrative `AWS_REGION` | Explicit service Region for bootstrap/control-plane/security-operations validation |
| State-root `state_region` | Terraform provider input for provisioning the state resources |
| S3 backend `region` | Region configured for the selected state bucket/backend; not changed by a workload Region override |

Set the correct profile and expected account before reading state. A successful Region comparison is not a cross-Region deployment, replication, or disaster-recovery qualification. Changing `TF_VAR_primary_region` without changing the applied state does not retarget a validation run.

---

## Workload Bootstrap Validation

Use `validate-bootstrap.sh` to validate the bootstrap resources for a workload account.

This script validates:

- `bootstrap/<env>/state` exists
- `bootstrap/<env>/account` exists
- the active AWS account matches `EXPECTED_ACCOUNT_ID` when supplied; supply it explicitly for acceptance evidence
- `bootstrap/<env>/state/backend.tf` declares the migrated S3 backend when remote-state validation is enabled
- the state, account, and workload backends use `use_lockfile = true`
- backend files resolve a shared Terraform state bucket and region with distinct state object keys
- the state-stack S3 object exists and is readable
- `terraform state pull` succeeds through the state stack backend
- the backend bucket matches the state stack `tf_state_bucket_name` output
- the state S3 bucket exists
- the state S3 bucket has versioning enabled
- the state S3 bucket has public access block enabled
- the state S3 bucket uses SSE-KMS
- the state CMK is resolved from the live bucket encryption configuration
- the state CMK exists, is enabled, and is customer-managed
- GitHub OIDC provider exists
- GitHub Plan and Apply roles exist
- GitHub trust policies reference the expected repository and subjects
- GitHub role policies reference the Terraform state bucket, state objects including `.tflock` objects, and state CMK
- GitHub Apply role references the current workload-created Lambda and Secrets Manager CMKs
- the optional GitHub Image Publisher role is validated whenever `image_publisher_role_github_arn` is present, and is required when `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true`
- the Image Publisher role ARN belongs to the active workload account and resolves to the expected live IAM role
- Image Publisher trust is exactly one `Allow` statement using `sts:AssumeRoleWithWebIdentity`, the workload-account GitHub OIDC provider, `sts.amazonaws.com` audience, and the exact configured branch subjects
- Image Publisher permissions exactly match the Terraform-defined ECR publication/query action contract
- `ecr:GetAuthorizationToken` is granted exactly once with `Resource = "*"`
- all other Image Publisher ECR permissions are scoped exactly to `arn:<partition>:ecr:<region>:<account-id>:repository/<name-prefix>-*`
- the Image Publisher policy contains no Terraform-state, ECS, IAM, conditional, deny, `NotAction`, `NotResource`, or general AWS administration authority

### Architecture Assumption

The workload bootstrap architecture uses:

```text
bootstrap/<env>/state
  - creates the S3 state bucket and KMS CMK
  - uses that bucket as an S3 backend after migration
  - uses a state-stack-specific object key
  - use_lockfile = true

bootstrap/<env>/account
  - S3 backend
  - uses an account-stack-specific object key
  - use_lockfile = true

environments/<env>
  - S3 backend
  - uses a workload-stack-specific object key
  - use_lockfile = true
```

The state, account, and workload Terraform roots share the environment's state bucket but must never share the same object key. `validate-bootstrap.sh` does not rely on local `terraform.tfstate`; after initialization it reads the migrated state stack from S3.

For bootstrap validation, the remote backend files are the source of truth for:

```text
state bucket name
state backend region
state object keys
use_lockfile = true
```

The script derives the state bucket from the backend files, then validates the live S3 bucket and KMS encryption configuration through AWS APIs.

DynamoDB state locking is not part of the architecture. This project uses Terraform S3 native locking with `use_lockfile = true`. Reading that declaration and checking policy access do not constitute a live lock-contention test.

### State-stack migration note

Existing deployments that previously kept `bootstrap/<env>/state` or `bootstrap/control_plane/state` locally must migrate each state stack deliberately:

1. Back up the current state with `terraform state pull`.
2. Configure a unique S3 backend key for that Terraform root.
3. Run `terraform init -migrate-state` from the state-stack directory.
4. Reinitialize from a clean checkout and confirm `terraform state pull` succeeds.
5. Run validation with `REQUIRE_STATE_STACK_REMOTE=true`.

The validation scripts and evidence workflows never migrate state automatically.

### Remote State Stack Validation

Remote-state migration evidence is controlled by:

```bash
REQUIRE_STATE_STACK_REMOTE="${REQUIRE_STATE_STACK_REMOTE:-false}"
```

| Value | Behavior |
|---|---|
| `true` | Missing, mismatched, colliding, or unreadable state-stack backend evidence fails validation. Use this for release-readiness and client-facing evidence. |
| `false` | The same checks run as warnings. Use only during migration or troubleshooting. |

The workload bootstrap and control-plane GitHub evidence workflows default this setting to `true`.

### Workload CMK Policy Validation

`validate-bootstrap.sh` checks whether the workload GitHub Apply role policy references the current workload-created CMK outputs from `environments/<env>`:

```text
lambda_cmk_arn
secrets_manager_cmk_arn
```

This behavior is controlled by:

```bash
STRICT_WORKLOAD_CMK_POLICY_CHECKS="${STRICT_WORKLOAD_CMK_POLICY_CHECKS:-true}"
```

Behavior:

| Value | Behavior |
|---|---|
| `true` | Stale or missing workload Lambda / Secrets Manager CMK policy references fail validation. This is the default and is recommended for client-readiness evidence. |
| `false` | Stale or missing workload CMK policy references are reported as warnings. The checks still run; they become advisory rather than skipped. |

Use `STRICT_WORKLOAD_CMK_POLICY_CHECKS=false` only for transitional runs, early/manual GitHub workflow testing, or environments where the workload stack has not yet been reconciled back into `bootstrap/<env>/account`.

### GitHub Image Publisher Validation

The Image Publisher role is owned by `bootstrap/<env>/account`, so its IAM trust and publication-policy boundary are validated in the workload bootstrap layer rather than the workload baseline layer. ECR repository configuration and ECS runtime resources remain workload-baseline concerns.

If `image_publisher_role_github_arn` is present in the account-stack outputs, `validate-bootstrap.sh` validates the role even when it is not explicitly required. Set the following for release/client-facing evidence when application image publication is enabled:

```bash
export REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true
export EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES='["main"]'
```

`REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true` requires `REQUIRE_BOOTSTRAP_GITHUB_OIDC=true`. The expected branch value must be a non-empty JSON array of non-empty strings. If `EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES` is unset, the validator/exporter uses `BRANCHES_IMAGE_PUBLISHER_GITHUB` when available and otherwise defaults to `["main"]`.

For an enabled Image Publisher role, the validator requires:

- the Terraform output `image_publisher_role_github_arn` to resolve to a live IAM role in the active workload account
- exactly one trust statement with `Effect = "Allow"`
- the exact trust action `sts:AssumeRoleWithWebIdentity`
- the exact workload-account GitHub OIDC federated principal and no additional principal types
- only `StringEquals` trust conditions for `token.actions.githubusercontent.com:aud` and `token.actions.githubusercontent.com:sub`
- the exact audience `sts.amazonaws.com`
- exact branch-based subjects of the form `repo:<owner>/<repo>:ref:refs/heads/<branch>` for the configured branch set
- the exact Terraform-defined ECR publication/query action set: `ecr:GetAuthorizationToken`, `ecr:BatchCheckLayerAvailability`, `ecr:BatchGetImage`, `ecr:CompleteLayerUpload`, `ecr:DescribeImages`, `ecr:DescribeRepositories`, `ecr:InitiateLayerUpload`, `ecr:PutImage`, and `ecr:UploadLayerPart`
- exactly one `ecr:GetAuthorizationToken` grant with `Resource = "*"`
- all repository-scoped permissions using exactly `arn:<partition>:ecr:<region>:<account-id>:repository/<name-prefix>-*`
- only unconditional `Allow` statements using `Action` and `Resource`, with no additional state, ECS, IAM, or general administrative authority

When strict publisher validation is required, `EXPECTED_GITHUB_REPOSITORY` must also be set so the exact repository and branch subjects can be constructed and compared.

### Strict Publisher-Enabled Release Validation

For a workload deployment that enables application image publication, use both strict remote-state and strict publisher requirements for release/client-facing bootstrap evidence:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true \
EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES='["main"]' \
./scripts/validation/validate-bootstrap.sh dev
```

Deployments that intentionally do not enable application image publication should leave `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=false`. In that case, absence of the role is allowed; if the role output is present, it is still validated.

### Dev

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

### Staging

```bash
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh staging
```

### Prod

```bash
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh prod
```

### Advisory Workload CMK Mode

If the workload environment has not been applied yet, or if `bootstrap/<env>/account` has not yet been re-applied with the current workload-created CMK ARNs, strict workload CMK policy validation may fail.

Use advisory mode only when stale/missing workload CMK policy references should be warnings rather than failures:

```bash
STRICT_WORKLOAD_CMK_POLICY_CHECKS=false \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

For validated client handoff evidence, leave `STRICT_WORKLOAD_CMK_POLICY_CHECKS` unset so it defaults to `true`.

### GitHub Workflow Usage

`validate-bootstrap.sh` is read-only and does not run `terraform init`. For manual GitHub workflow usage, initialize the remote-backed stacks first so Terraform outputs can be read from the S3 backend:

```bash
export AWS_PROFILE="dev"
export AWS_REGION="us-east-1"
export EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>"
# Verify this account and the reviewed backend template first.
aws sts get-caller-identity

# Only for an already-migrated state root; do not overwrite an existing backend.
if [[ ! -e bootstrap/dev/state/backend.tf ]]; then
  cp bootstrap/dev/state/backend.tf.migrated.example bootstrap/dev/state/backend.tf
fi
./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
terraform -chdir=bootstrap/dev/account init -input=false
terraform -chdir=environments/dev init -input=false

AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

Repeat with the matching profile, account ID, and environment name for `staging` and `prod`.

The manual **Export Bootstrap Evidence** workflow uses the `<env>-plan` GitHub Environment and initializes all three roots before exporting evidence. It defaults `REQUIRE_STATE_STACK_REMOTE` to `true`, renders the report in the Actions run summary, and uploads the evidence directory as an artifact.

For a publisher-enabled workload release, also require the Image Publisher role and provide the expected branch JSON to the exporter. The publisher trust remains branch-based; do not reinterpret the Image Publisher role as using the `<env>-plan` GitHub Environment subject.

Under GitHub OIDC, `AWS_PROFILE` is intentionally not set. The report should identify the credential source as `GitHub OIDC environment credentials`.

For strict workload CMK evidence, the expected deployment sequence is below. After the initial state apply, migrate and verify the state root with `migrate-state-stack.sh` **before** treating remote-state evidence as complete. Reconciliation mutates IAM when applied and is not part of validation itself.

```text
1. Apply bootstrap/<env>/state.
2. Apply bootstrap/<env>/account, including the Image Publisher role and branch allowlist when application publication is enabled.
3. Apply environments/<env>.
4. Capture current workload outputs for lambda_cmk_arn and secrets_manager_cmk_arn.
5. Re-apply or reconcile bootstrap/<env>/account with those current CMK ARNs while preserving the enabled Image Publisher role and branch allowlist.
6. Run validate-bootstrap.sh or export-bootstrap.sh with strict workload CMK behavior; for publisher-enabled release evidence, also set REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true and the exact EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES JSON.
```

---

## Workload Baseline Validation

Use `validate-baseline.sh` to validate deployed workload baseline resources.

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/validation/validate-baseline.sh dev
```

Run for each deployed workload environment from its separately configured profile/account/Region context. The following are alternatives, not a loop to execute under one unchanged profile:

```bash
./scripts/validation/validate-baseline.sh dev
./scripts/validation/validate-baseline.sh staging
./scripts/validation/validate-baseline.sh prod
```

`validate-baseline.sh` runs the individual workload validation scripts:

```text
validate-env.sh
validate-networking.sh
validate-vpc-endpoints.sh
validate-ecr.sh
validate-logging.sh
validate-security-workload.sh
validate-kms.sh
validate-backup.sh
validate-sns.sh
validate-sqs.sh
validate-eventbridge.sh
validate-lambda.sh
validate-ssm.sh
validate-compute.sh
validate-ecs-runtime.sh
validate-iam.sh
```

A successful run should end with:

```text
Validation scripts passed:  16/16
Validation scripts failed:  0/16
```

The runner invokes the scripts **sequentially**, continues after a child fails, and returns a failure after the final summary if any child failed or was missing/not executable. An earlier prerequisite or Region-resolution failure can stop it before the loop. `16/16` counts top-level script exit codes, not individual assertions, warning-free operation, executed application traffic, or completed recovery tests.

`validate-baseline.sh` prints its results; `export-baseline.sh` independently reruns the same child scripts and writes the timestamped evidence package. It does not package a previous runner invocation. For a single evidence-producing pass, use the exporter; use direct validators for focused diagnostics.

The historical runtime-operations qualification narrative records all 16 workload validators passing, strict workload-bootstrap validation passing, and a converged Terraform plan with no changes. The qualification also exercised CPU and memory scale-out/scale-in, conditional ALB request scaling, fixed-versus-autoscaled desired-count ownership, digest release while scaled, deployment-health settings, and ECS operational alarms. This is point-in-time technical-control evidence, not a compliance certification; each deployment should retain its own generated evidence.

That historical statement is not evidence that the tests were repeated. Record the implementation/deployment commit, validator checkout, selected digests and configuration for each new evidence set; a release tag does not retroactively re-date earlier tests.

---

## Individual Workload Validation Scripts

Individual scripts can be run directly for focused troubleshooting.

Examples:

```bash
./scripts/validation/validate-networking.sh dev
./scripts/validation/validate-vpc-endpoints.sh dev
./scripts/validation/validate-ecr.sh dev
./scripts/validation/validate-logging.sh dev
./scripts/validation/validate-security-workload.sh dev
./scripts/validation/validate-kms.sh dev
./scripts/validation/validate-backup.sh dev
./scripts/validation/validate-sns.sh dev
./scripts/validation/validate-sqs.sh dev
./scripts/validation/validate-eventbridge.sh dev
./scripts/validation/validate-lambda.sh dev
./scripts/validation/validate-ssm.sh dev
./scripts/validation/validate-compute.sh dev
./scripts/validation/validate-ecs-runtime.sh dev
./scripts/validation/validate-iam.sh dev
```

Use individual scripts when validating a specific area after a targeted change.

### Exact topology and lifecycle checks

`validate-networking.sh` reads `network_topology`, `lifecycle_protection`, and the effective egress/domain outputs. It compares the live main VPC CIDR and attached Internet Gateway with Terraform, then validates each of the seven subnet families by count, AZ, subnet ID, CIDR, and disabled public-IP auto-assignment. It also compares the **entire live VPC subnet-ID set** with the union of those families, so an extra subnet is not accepted merely because all expected subnets exist.

The default topology is three AZs for `production` and two for `development`/`minimal`, with seven families in every selected AZ, including firewall-private subnets even when Network Firewall is absent. These are profile defaults, not a hard-coded universal 21/14-subnet check: supported explicit AZ/subnet inputs are reflected in the applied topology. The baseline derives canonical `/24` subnets from its canonical IPv4 `/16` input when `subnet_cidrs` is null.

The routing checks cover same-AZ subnet/route-table associations and the expected IGW, NAT and firewall targets. In `network_firewall` mode, compute default traffic reaches the same-AZ firewall, firewall default traffic reaches the same-AZ NAT, and the compute-CIDR return override exists only on the matching **egress-public** route table. Ingress-public traffic retains VPC-local access to ALB targets rather than taking that return path. Network Firewall must be `READY`/`IN_SYNC`, with expected ready attachments and deletion protection matching Terraform.

NAT inventory is read with an `available,pending` filter and checked against Terraform IDs and same-AZ egress-public placement. That inventory comparison alone must not be relabeled as an independent assertion that every NAT Gateway is already `available`; inspect availability separately when qualifying usable egress. The checks do not transmit application traffic or establish that every possible firewall policy setting was audited.

The domain-target set is compared exactly without rebuilding Terraform's allowlist composition. A successful target-set comparison is not a TLS-decryption test or proof that every protocol/traffic path traverses the firewall. In `vpc_endpoints_only`, the public subnet families and IGW still exist; private compute has no general internet default route.

### Networking domain validation

`validate-networking.sh` reads `effective_egress_mode` and `effective_allowed_egress_domains` from the selected workload environment's Terraform outputs. Terraform owns composition of the effective Network Firewall allowlist; the script does not recreate platform and caller domain-union logic.

When the effective mode is `network_firewall`, the script describes the live `${NAME_PREFIX}-egress-stateful-domains` stateful rule group and performs an order-independent, exact set comparison between its domain targets and `effective_allowed_egress_domains`. Missing or unexpected live domains fail validation. For `nat_only` and `vpc_endpoints_only`, the effective domain output must be empty and the script does not query a domain rule group. Supplying `allowed_egress_domains` does not create connectivity in those modes.

### ECR validation

`validate-ecr.sh` treats the workload-root `ecr_repositories` output as the authoritative repository inventory. When it is `{}`, the validator reports that no repositories are configured and exits successfully without querying live ECR.

For every configured repository, it compares the live name, ARN, and registry ID with the Terraform output; requires immutable tags and KMS encryption with a configured key; requires the live repository KMS key to equal the workload-root `ecr_cmk_arn`; and requires exactly the approved lifecycle rule that expires only untagged images older than 30 days. Tagged-image expiration fails validation.

### VPC endpoint hardening

`validate-vpc-endpoints.sh` validates the non-overridable platform Interface Endpoint inventory, including `ecr.api`, `ecr.dkr`, and `guardduty-data`. It also requires every Interface Endpoint to be available, in the expected VPC, private-DNS enabled, attached to the exact endpoint-private subnet set, and attached to exactly the shared Interface Endpoint SG. The S3 Gateway Endpoint must have the exact union of endpoint-private, compute-private, and serverless-private route-table associations.

### Inspector effective resource types

When Inspector is enabled, the expected scan-type set is the effective Terraform output. A profile's cost choice is not inferred from repository names by the validator.

`validate-security-workload.sh` uses `effective_inspector_resource_types` as its only expected Inspector resource set and fails for both missing and unexpectedly enabled live scan types, including EC2, ECR, Lambda, Lambda code, and code repositories. It does not reconstruct the repository-to-ECR composition policy.

### ECS runtime and IAM validation

`validate-ecs-runtime.sh` is the single ECS runtime entry point. Its sourced modules
under `lib/ecs-runtime/` separate shared helpers (`common.sh`), Terraform outputs
and membership checks (`contract.sh`), cluster and Container Insights checks
(`cluster.sh`), service/task/network checks (`services.sh`), injected-agent/coverage checks (`guardduty.sh`), Application Auto Scaling
(`autoscaling.sh`), conditional ALB checks (`ingress.sh`), operational alarms
(`alarms.sh`), and final counts/output (`summary.sh`). These modules are internal;
the baseline runner still invokes one ECS runtime validator. Operational alarms
run independently of the conditional ALB stage for configured services.

`validate-ecs-runtime.sh` uses the workload-root ECS output maps as the authoritative service inventory. It always validates the environment ECS cluster. When `ecs_services = {}`, it confirms that the live service inventory is empty, requires the ALB output to be `null`, and skips per-service checks.

For configured services it validates Fargate service placement, the resource-backed platform version, deployment circuit breaker and rollback, desired/running/pending steady state, and a completed primary rollout. It also validates the task-definition platform and separate roles; exactly one essential service container; a digest-pinned image from an output-backed ECR repository; port and `awslogs` settings; exact log-group identity, retention, and `logs_cmk_arn`; task-SG endpoint, resource-backed S3 prefix-list, database-access, and egress-mode relationships; and conditional ALB service attachments and ALB/task SG relationships.

Desired-count ownership is conditional on the canonical scaling contract. A fixed service (`scaling = null`) must have a live ECS `desiredCount` exactly equal to Terraform. An autoscaled service may differ from its configured bootstrap `desired_count`, but the live value must remain within `min_capacity` and `max_capacity`.

Application Auto Scaling validation requires the exact target inventory for the environment cluster and exact target attributes, including min/max capacity, `ecs:service:DesiredCount`, ECS namespace, resource identity, and unsuspended scaling state. The policy inventory must also match Terraform exactly. CPU, memory, and conditional ALB request-count policies must be `TargetTrackingScaling`, with exact targets, scale-in/out cooldowns, predefined metric types, and—when applicable—the resource-backed ALB request resource label. Customized metric specifications are not accepted by the contract.

The validator also compares `minimum_healthy_percent`, `maximum_percent`, and `health_check_grace_period_seconds` exactly with the canonical deployment configuration.

The environment cluster check validates the Terraform-owned Container Insights performance log group when Container Insights is enabled: exact name and ARN, effective retention, and exact `logs_cmk_arn`. When Container Insights is disabled, the resource-backed log-group output must be `null`.

When an ALB is present, the validator compares the resource-backed ALB, listener, ACM certificate, TLS policy, load-balancer ARN suffix, and target-group metadata with live AWS. It also requires exact Terraform-owned **ingress-public** placement, the fixed 404 default, `ip` target groups, and meaningful forwarding listener rules. The ALB frontend is HTTPS, while target groups and their health checks use HTTP; the configuration check is not end-to-end TLS or an application authorization test.

Operational alarms are validated independently of the conditional ALB stage. The expected Terraform-owned inventory consists only of task-deficit and ingress unhealthy-target alarms; AWS-managed target-tracking alarms are deliberately outside this operational inventory. Task-deficit alarms must implement the Container Insights `DesiredTaskCount - RunningTaskCount` contract, and ingress alarms must implement `AWS/ApplicationELB` `UnHealthyHostCount` with the resource-backed ALB/target-group suffix dimensions. `OK` passes, `INSUFFICIENT_DATA` warns while metric evaluation completes, and `ALARM` fails validation.

`validate-iam.sh` owns the ECS IAM assertions. For each service it validates the separate execution and task roles, ECS task trust restrictions, the custom repository- and log-group-scoped execution policy, optional ARN-identifiable Secrets Manager and SSM permissions, absence of managed-policy attachments and `iam:PassRole`, and an initially policy-free application task role. It compares the live execution-policy `kms:Decrypt` resources exactly with `ecs_service_configuration[*].task_execution_kms_key_arns`; an empty expected set requires the decrypt action to be absent.

The runtime validator compares the live cluster Container Insights setting with `ecs_cluster.container_insights`, database rule presence/absence with `ecs_service_configuration`, and live service/logging/ALB settings with their resource-backed outputs. Internal SG readiness IDs remain intentionally internal. Repository keys are never treated as ECS service identities. A registered canonical service whose `image_digest` is null is not present in the deployable runtime output maps and therefore does not require live per-service resources.

#### Production availability and empty-runtime limits

For deployable production services outside retirement, the canonical floor is two fixed tasks or an autoscaling minimum of two. The normal runtime validator additionally requires `minimum_healthy_percent = 100`, `maximum_percent >= 200`, and AZ rebalancing `ENABLED`. A three-AZ subnet set and the sample's three-task choice do not independently prove one live task per AZ; capture actual placement and ALB target health separately when qualifying that configuration.

For protected profiles, `guardduty.sh` validates exactly one running injected agent per protected running task and checks `AUTO_MANAGED`/`HEALTHY` coverage with no unresolved issues. It accepts the documented exact/prefixed agent names. With no deployable services, live coverage is not required; with no protected running tasks, protected healthy coverage is not required yet. A PASS with an empty runtime does not exercise instrumentation. The application-container check accepts `UNKNOWN` health when no ECS-native health check exists and rejects `UNHEALTHY`; that is not proof of an application transaction or database connection.

For `minimal`, agents are not required and healthy coverage is not required; when the coverage branch is applicable, absence is valid or the returned expected-cluster record must use `DISABLED` management. Supporting IAM, endpoint and EventBridge validators cover the agent's authority, Terraform-owned endpoint reuse, and configured notification path. Configuration equality is not a test that a real coverage event reached a human recipient.

### SQS inspection limits

`validate-sqs.sh` checks the required named queues, accepts configured SSE-KMS **or** SQS-managed encryption, checks SNS producer subscription/policy relationships where declared, and reports redrive configuration and approximate message counts. Do not describe it as an exact KMS-key, exact `maxReceiveCount`, complete queue-policy, or zero-DLQ-depth validator. A printed count or redrive policy is not automatically a blocking assertion. Review the raw values and any related alarm/delivery evidence separately.

### RDS, AWS Backup, and Restore Testing validation

`validate-backup.sh` is also the RDS resilience validator; there is no separate `validate-rds.sh` and no seventeenth workload entry point. Required outputs include `rds_configuration`, `backup_vault_configuration`, `lifecycle_protection`, `restore_testing`, and `effective_backup_enabled`. Only the supported disabled Backup schedule/retention outputs are treated as null when Terraform omits them; missing required contract objects are not silently ignored.

| Check | Evidence established |
|---|---|
| Live RDS | Expected DB identifier/ARN, Multi-AZ, DB subnet-group **name**, exact VPC SG set, deletion protection, native backup retention, public accessibility, and storage-encryption flag |
| RDS deletion-time intent | Resource-backed `skip_final_snapshot`, `delete_automated_backups`, and final-snapshot identifier consistency; these are not all live RDS API settings |
| Backup vault | Live name/ARN/encryption and Terraform `force_destroy` consistency with `lifecycle_protection`; `force_destroy` is Terraform deletion behavior, not a live vault API flag |
| Scheduled Backup | Effective enablement, plan/selection presence or absence, rule schedule/retention/vault, service-role/tag selection, and EC2/RDS `Backup` tags |
| Enabled Restore Testing | Exact plan/selection, protected RDS ARN, role, schedule/windows, source vault and private restore metadata |
| Restore execution reporting | Latest restore job, validation result and temporary-resource deletion status; each status has a different acceptance rule |

RDS-native automated backups are separate from the AWS Backup schedule and Restore Testing. The production database is a PostgreSQL **DB instance**, not Aurora or a Multi-AZ DB cluster. The production source is Multi-AZ; the temporary Restore Testing override is private and Single-AZ. Neither a three-AZ subnet group nor its name proves three database servers.

This is not an exhaustive RDS configuration validator. In particular, it does not compare every engine/version, DB instance class, storage/parameter-group setting, or exact member-subnet set, and it does not log in to PostgreSQL or force failover. The `instance_class` output alone is not proof that the live `DBInstanceClass` was compared.

When Restore Testing is disabled, the validator returns without requiring live Restore Testing configuration. It does **not** inventory all live restore plans and prove their absence. When enabled, interpret the latest job as follows:

| Reported state | Current script behavior | Evidence limit |
|---|---|---|
| No restore jobs | Warning; configuration can pass | No restore execution established by this run |
| Restore `PENDING` / `RUNNING` | Warning | Restore has not completed |
| Restore `COMPLETED` | Execution success | Not by itself application validation or cleanup success |
| Restore `FAILED` / `ABORTED` | Failure | Restore execution failed |
| Application validation `FAILED` / `TIMED_OUT` | Warning | Must be reviewed separately; not an accepted application recovery result |
| Temporary-resource deletion `FAILED` | Warning | Cleanup has not been proven successful |
| Unknown/in-progress validation or cleanup status | Informational message or warning | Retain the exact status and follow up; do not infer completion |

A `validate-backup.sh` PASS may therefore coexist with an unexecuted restore, failed application validation, or unresolved cleanup. Keep the raw log and record the reviewer's recovery/cleanup acceptance separately. See the [Backup module](../../modules/backup/README.md), [storage reference](../../modules/storage/README.md), and [evidence guide](../../docs/assurance/validation-evidence-guide.md).

### Production retirement is a separate validation posture

Normal production runtime validation expects nonzero production capacity. Do not weaken it to make a deliberately retired environment pass. The retirement helpers remain under `scripts/deployment/`, outside the four evidence layers and 16 workload-validator count:

| Helper | Operation and boundary |
|---|---|
| `validate-production-retirement-plan.sh` | Read-only check of the exact saved Stage-1 plan: only read/no-op/in-place updates, expected retirement outputs, and zero planned service/scaling capacity; not a whitelist of every permissible attribute change |
| `cleanup-retirement-durable-data.sh --mode plan` | Read-only durable ECR/Backup inventory; does not authorize deletion |
| `cleanup-retirement-durable-data.sh --mode apply` | Explicitly authorized **mutation**, not validation; re-inventories before deleting scoped images/recovery points |
| `validate-retirement-readiness.sh` | Read-only live gate: native protections relaxed, RDS final-snapshot intent preserved, ECS desired/running/pending zero, scaling unable to restore capacity, empty ECR/vault and no active Backup jobs |
| `terraform-plan-artifact.sh` | Creates/verifies exact-plan artifacts within its GitHub workflow contract; it does not apply Terraform |

The implemented sequence is Stage-1 saved-plan review/apply, inventory and convergence checks, separately approved durable cleanup, readiness, saved workload destroy plan, separately planned/approved Identity Center cleanup, then final workload-destroy approval and exact-plan verification/application with another readiness check. Earlier cleanup is not undone by rejecting a later approval.

The complete durable-cleanup path is limited to `prod`; production Destroy requires `delete_durable_retirement_data=true` even for an empty inventory. Stage 1 keeps production ECR/ECS/Backup force-deletion flags false. Setting a service digest to null, changing production to a cheaper profile, or manually stopping tasks is not a substitute for the staged contract. Autoscaled ECS resources still ignore direct `desired_count` changes, so planned zero capacity alone is not live quiescence evidence.

Use the [production retirement runbook](../../docs/production-retirement.md) for the exact approval chain. Retain separate Stage-1, cleanup, readiness, Identity Center, and destroy evidence. Moving a state stack to an independent backend does not remove the state module's literal `prevent_destroy` guards; whole-platform retirement is not established by successful workload destruction.

---

## Control-Plane Validation

Use `validate-control-plane.sh` to validate control-plane bootstrap and governance resources.

This script validates:

- control-plane AWS caller identity
- control-plane Terraform state backend resources
- optional strict proof that the control-plane state stack uses a readable S3 backend
- control-plane state bucket, CMK, and lock configuration
- GitHub OIDC provider
- control-plane GitHub Plan and Apply roles
- GitHub OIDC trust conditions
- AWS Organizations root and expected OU structure
- workload account placement under the expected `NonProd` and `Prod` OUs
- IAM Identity Center instance
- required workload `SecOps-Operator-*` groups
- required `SecOps-Administrator` group for the security-operations account
- optional workload and security-operations Analyst and Engineer groups
- the consolidated Identity Center Terraform outputs:
  - `workload_permission_set_arns`
  - `secops_permission_set_arns`
- permission-set existence for `dev`, `staging`, `prod`, and `security-operations`
- account assignments for each workload account and the security-operations account

### Identity Center Configuration Inputs

The validator requires the current consolidated Identity Center configuration:

```text
IDENTITY_CENTER_WORKLOADS
IDENTITY_CENTER_SECOPS
```

The same values may be supplied using Terraform's standard environment-variable names:

```text
TF_VAR_identity_center_workloads
TF_VAR_identity_center_secops
```

`IDENTITY_CENTER_WORKLOADS` must be a JSON object containing `dev`, `staging`, and `prod`. Each entry must contain a 12-digit `account_id` and a non-empty `primary_region`. The Analyst and Engineer flags are optional and default to `false`.

`IDENTITY_CENTER_SECOPS` must contain the security-operations account ID. Its Analyst and Engineer flags are also optional and default to `false`.

Example:

```bash
export IDENTITY_CENTER_WORKLOADS='{
  "dev": {
    "account_id": "<DEV-ACCOUNT-ID>",
    "primary_region": "us-east-1",
    "enable_secops_analyst": false,
    "enable_secops_engineer": false
  },
  "staging": {
    "account_id": "<STAGING-ACCOUNT-ID>",
    "primary_region": "us-east-1",
    "enable_secops_analyst": false,
    "enable_secops_engineer": false
  },
  "prod": {
    "account_id": "<PROD-ACCOUNT-ID>",
    "primary_region": "us-east-1",
    "enable_secops_analyst": false,
    "enable_secops_engineer": false
  }
}'

export IDENTITY_CENTER_SECOPS='{
  "account_id": "<SECURITY-OPERATIONS-ACCOUNT-ID>",
  "enable_secops_analyst": false,
  "enable_secops_engineer": false
}'

AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

The account IDs used for AWS Organizations and Identity Center assignment checks are derived from these JSON structures. The old `ACCOUNT_ID_DEV`, `ACCOUNT_ID_STAGING`, and `ACCOUNT_ID_PROD` inputs are no longer used by this script.

### Control-Plane Remote State Evidence

For strict release or client-facing evidence, run with:

```bash
export REQUIRE_STATE_STACK_REMOTE=true
```

The validator confirms that `bootstrap/control_plane/state/backend.tf` declares S3 with `use_lockfile = true`, that the configured state object exists and is readable, that the bucket matches the state stack output, and that `terraform state pull` succeeds.

The **Export Control-Plane Evidence** workflow uses the `control-plane-plan` GitHub Environment, initializes all four control-plane Terraform roots, supplies the Identity Center workload and security-operations JSON values, and defaults remote-state validation to `true`.

### Optional SecOps Groups

Required groups are always checked:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

To validate optional Analyst and Engineer groups, set:

```bash
export CHECK_OPTIONAL_SECOPS_GROUPS=true
```

The validator uses the corresponding `enable_secops_analyst` and `enable_secops_engineer` values from `IDENTITY_CENTER_WORKLOADS` and `IDENTITY_CENTER_SECOPS` to determine whether each optional group is required.

Example:

```bash
CHECK_OPTIONAL_SECOPS_GROUPS=true \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

This example assumes `IDENTITY_CENTER_WORKLOADS` and `IDENTITY_CENTER_SECOPS` were exported as shown above.

### Identity Center Assignment Strictness

Identity Center account-assignment checks are controlled by:

```bash
STRICT_IDENTITY_CENTER_ASSIGNMENTS="${STRICT_IDENTITY_CENTER_ASSIGNMENTS:-true}"
```

| Value | Behavior |
|---|---|
| `true` | A missing assignment for a discovered workload or security-operations permission set fails validation. |
| `false` | Missing assignments are reported as warnings. |

### AWS Organizations Account Placement

The control-plane validator checks the current organization topology and account placement:

```text
Root
├── Workloads
│   ├── NonProd
│   │   ├── dev
│   │   └── staging
│   └── Prod
│       └── prod
└── Security
    └── security-operations
```

Account placement behavior is controlled by:

```bash
STRICT_ACCOUNT_OU_CHECKS="${STRICT_ACCOUNT_OU_CHECKS:-true}"
```

With the current default `true`, a placement mismatch fails validation. Set the flag to `false` only for deliberate transitional troubleshooting, and document the weaker evidence posture.

---

## Security-Operations Validation

Use `validate-security-operations.sh` from the dedicated `security-operations` account to validate centralized security governance.

Example:

```bash
AWS_PAGER="" \
AWS_PROFILE=security-operations \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<SECURITY-OPERATIONS-ACCOUNT-ID>" \
./scripts/validation/validate-security-operations.sh
```

The validator checks selected live AWS state and Terraform state for:

- security-operations account identity
- centralized Security Hub CSPM administrator state and finding aggregation
- Security Hub CSPM `CENTRAL` organization configuration
- per-workload CSPM configuration policies and associations
- GuardDuty delegated-administrator detector and organization enrollment
- GuardDuty organization protection plans and Runtime Monitoring configuration
- Security Hub V2 administrator state
- Security Hub V2 organization policy attachment to the `Workloads` OU
- effective Security Hub V2 policy for configured workload accounts
- directly required trusted-service/delegated-administrator prerequisites

The security-operations validator does not replace complete organization topology checks or workload-local checks. Use `validate-control-plane.sh` for the former and `validate-baseline.sh` / `validate-security-workload.sh` for the latter.

Its evidence is scoped to `bootstrap/security_operations/security_services` and the required live governance dependencies; it is not a complete validation of the security-operations state/account substacks. The Terraform-managed GuardDuty organization feature subset must match exactly, and additional AWS-returned features/configurations outside that subset must remain `NONE`.

---

## Exporting Validation Evidence

Evidence exporters generate timestamped report packages with:

```text
summary.md
summary.json
per-script validation logs
```

Generated evidence is environment-specific and should generally not be committed to the repository.

Review raw logs as well as the summary. The baseline exporter records per-script PASS/FAIL from exit status and does not aggregate every warning or maintain a completed-test ledger. Its `manual_validation_remaining` array is static guidance, not a record of which tests you actually performed. A prerequisite failure can leave an incomplete package or no package; do not reuse the newest older directory as evidence of a failed new run.

Keep companion provenance for the validator checkout SHA, deployment SHA, selected image digests, effective profile and topology, service/backend Regions, toolchain/lockfile identity, workflow run/attempt, approvals, and acceptance exceptions. These are not automatically supplied as a complete signed manifest in the baseline summary. Preserve generated summaries/logs unchanged and use the [evidence guide](../../docs/assurance/validation-evidence-guide.md) and [report template](../../docs/assurance/validation-report-template.md) for reviewer records.

The credential-source label is inferred from environment variables. Verify actual caller identity and workflow authentication separately rather than treating that string as proof of how credentials were obtained.

### Workload Bootstrap Evidence

For a publisher-enabled workload release, generate strict bootstrap evidence with both remote-state and Image Publisher requirements enabled:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true \
EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES='["main"]' \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-bootstrap.sh dev
```

If application image publication is intentionally disabled for the workload, leave `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=false`; the exporter still validates the role whenever `image_publisher_role_github_arn` is present.

The generated Markdown and JSON summaries record whether the publisher role and remote state were required, the expected publisher branch set, and the Image Publisher validation scope. `expected_github_image_publisher_branches` is emitted as a JSON array in `summary.json`.

Package location:

```text
validation-results/<environment>/bootstrap/<timestamp>/
```

### Workload Baseline Evidence

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-baseline.sh dev
```

Package location:

```text
validation-results/<environment>/baseline/<timestamp>/
```

Current baseline logs include:

```text
validate-env.log
validate-networking.log
validate-vpc-endpoints.log
validate-ecr.log
validate-logging.log
validate-security-workload.log
validate-kms.log
validate-backup.log
validate-sns.log
validate-sqs.log
validate-eventbridge.log
validate-lambda.log
validate-ssm.log
validate-compute.log
validate-ecs-runtime.log
validate-iam.log
```

### Control-Plane Evidence

The exporter consumes the consolidated Identity Center configuration used by Terraform:

```bash
IDENTITY_CENTER_WORKLOADS='<JSON-WORKLOAD-CONFIGURATION-MAP>' \
IDENTITY_CENTER_SECOPS='<JSON-SECURITY-OPERATIONS-CONFIGURATION>' \
AWS_PROFILE="control-plane" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-control-plane.sh
```

Package location:

```text
validation-results/control-plane/<timestamp>/
```

### Security-Operations Evidence

```bash
AWS_PROFILE="security-operations" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<SECURITY-OPERATIONS-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-security-operations.sh
```

Package location:

```text
validation-results/security-operations/security-services/<timestamp>/
```

Expected files:

```text
summary.md
summary.json
validate-security-operations.log
```

---

## Recommended Full Validation Order

For a complete release/client-facing evidence pass, follow the platform boundaries rather than treating one report as sufficient:

1. `export-control-plane.sh` (or direct control-plane validation for diagnostics)
2. `export-security-operations.sh`
3. `export-bootstrap.sh <env>` for each deployed workload account after reconciliation
4. `export-baseline.sh <env>` for each deployed workload account
5. Review all generated summaries and logs together
6. Complete approved live/manual tests

This order aligns evidence with the deployment architecture: control-plane prerequisites first, centralized security next, then workload bootstrap and workload realization.

---

## What Remains Manual

The validation scripts are intentionally read-only. Cross-layer validation should not be mislabeled as manual merely because it is outside the current report; the other evidence exporters cover those layers.

The following activities remain live/manual or review-based:

- IAM Identity Center end-user login and effective-access testing
- live EC2 isolation testing
- live EC2 rollback testing
- live IP enrichment execution
- tamper-detection simulation
- break-glass role assumption
- destroy-safety review and approved teardown execution
- actual ECS task placement/replacement and application target/transaction checks
- controlled RDS failover, completed restore execution, application validation and temporary-resource cleanup
- custom-CIDR deployment/destroy regression and a final no-change plan with matching inputs
- separate production Stage-1, durable cleanup, readiness and approved destroy records
- policy/procedure review
- formal audit evidence review

Track these separately in the validation checklist or assurance documentation.

---

## PASS, WARN, and FAIL

### PASS

An individual `[PASS]` line confirms its stated assertion. A whole-script PASS means the process exited successfully through its applicable branches. It may coexist with warnings, optional omissions, or no running application. A suite `16/16` result is therefore not an exhaustive security or recovery acceptance decision.

### WARN

A `WARN` means the condition should be reviewed but does not necessarily invalidate the deployment.

Examples:

- optional resources not enabled
- optional Identity Center groups not configured
- intentionally relaxed strictness checks during transitional troubleshooting
- environment-specific exceptions
- an ECS operational alarm in `INSUFFICIENT_DATA`
- no Restore Testing job yet, in-progress restore, or failed application validation/cleanup reported as warnings by the current Backup validator

Retain the exact warning and disposition; do not change a generated result to hide it. Reviewer acceptance can remain outstanding even when all scripts exit successfully.

### FAIL

A `FAIL` means a required validation check did not pass.

Examples:

- wrong AWS account
- missing required Terraform output from a remote-backed stack
- missing AWS resource
- missing GitHub OIDC role
- required Image Publisher role missing when `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true`
- Image Publisher trust has an unexpected principal, action, condition, audience, repository, or branch subject
- Image Publisher permissions differ from the exact Terraform-defined ECR publication/query contract or use repository scope broader than `<name-prefix>-*`
- backend missing `use_lockfile = true`
- state stack S3 object missing, unreadable, or sharing another root's backend key while `REQUIRE_STATE_STACK_REMOTE=true`
- state bucket encryption missing
- current workload Lambda or Secrets Manager CMK policy reference missing from the GitHub Apply role when strict workload CMK policy checks are enabled

Failures should be fixed before using the environment as validated evidence.

---

## Safety Notes

The validation entry points inspect AWS and Terraform without intentionally changing deployed resources. Evidence exporters and Terraform reads can create local files containing sensitive configuration. Their use of an existing credential chain does not guarantee that the caller has only read permissions.

They should not:

- run `terraform apply`
- run `terraform destroy`
- run `terraform init`
- migrate state
- modify IAM policies
- explicitly run privileged role-assumption tests (credential-chain resolution is separate)
- trigger live security automation
- delete or replay DLQ messages

Review each script before extending it to ensure this read-only safety property is preserved.

Backend initialization/migration, reconciliation apply, SSM sessions, SQS `receive-message`, CloudTrail stop/start, role-assumption tests, and retirement cleanup are separate operator/workflow actions, not part of the read-only validator contract. In particular, receiving an SQS message affects visibility/receive state even without deleting it. Keep those operations explicitly approved and separate from evidence-only runs.

---

## Troubleshooting

### Missing or mismatched service Region

For workload validation, first confirm the selected root is initialized against its intended backend and has an applied `primary_region` output. A stale `AWS_REGION` must be corrected or unset; an explicitly empty value is still a mismatch. Do not “fix” the comparison by changing backend Region or masking errors with a different profile. Administrative validators/exporters require explicit service `AWS_REGION`; `AWS_DEFAULT_REGION` alone is insufficient.

### Normal validation fails during retirement

The normal production ECS checks are not designed to accept zero-capacity retirement as healthy production. Use the Stage-1 saved-plan and live readiness validators in the retirement runbook. Preserve the last normal-state evidence from before retirement; do not rerun normal validation after destruction and interpret missing resources as a release regression.

### Backend Configuration Changed

If Terraform reports:

```text
Backend configuration changed
```

only use `terraform init -migrate-state` when intentionally moving state from one backend location to another.

Use `terraform init -reconfigure` only when the state location did not change and the current backend configuration should be accepted as-is.

Before running either command, confirm the intended S3 bucket and key.

### Wrong State Key

If Terraform suddenly wants to create many existing resources, stop.

This usually means the backend is pointed at the wrong state object.

Check the bucket keys:

```bash
aws s3api list-objects-v2 \
  --bucket "<state-bucket>" \
  --profile "<profile>" \
  --query 'Contents[].[Key,Size,LastModified]' \
  --output table
```

Point the backend at the correct state key before applying.

### Bootstrap Validation Cannot Read Terraform Outputs

`validate-bootstrap.sh` reads the migrated state stack to validate backend readability and compare `tf_state_bucket_name`; it also reads outputs from the account and workload stacks.

Before running bootstrap validation from a fresh checkout, select the correct profile/account/service Region, materialize the reviewed state backend without overwriting an existing one, and verify an **already-migrated** state root:

```bash
ENVIRONMENT="dev"  # Choose dev, staging, or prod in its configured account shell.
: "${AWS_PROFILE:?Set the matching local profile}"
: "${AWS_REGION:?Set the explicit service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the expected workload account ID}"
STATE_DIR="bootstrap/${ENVIRONMENT}/state"
if [[ ! -e "${STATE_DIR}/backend.tf" ]]; then
  cp "${STATE_DIR}/backend.tf.migrated.example" "${STATE_DIR}/backend.tf"
fi
./scripts/bootstrap/migrate-state-stack.sh "${ENVIRONMENT}" --verify-only
terraform -chdir="bootstrap/${ENVIRONMENT}/account" init -input=false
terraform -chdir="environments/${ENVIRONMENT}" init -input=false
```

`--verify-only` is not a state migration but does initialize/read local backend files. On GitHub evidence runners, the workflow performs its own backend materialization and initialization. Do not set a local profile on the OIDC runner.

If output reads still fail, confirm that the selected AWS principal has access to the configured S3 backend bucket, state object key, `.tflock` object, and state CMK.

### Missing Workload CMK Policy References

If `validate-bootstrap.sh` fails because the GitHub Apply role does not reference `lambda_cmk_arn` or `secrets_manager_cmk_arn`, re-apply the corresponding `bootstrap/<env>/account` stack after passing in the current workload-created CMK ARNs from `environments/<env>`.

For transitional validation only, set:

```bash
export STRICT_WORKLOAD_CMK_POLICY_CHECKS=false
```

This keeps the checks enabled but reports stale/missing workload CMK policy references as warnings instead of failures.

### Image Publisher Validation Fails

If `validate-bootstrap.sh` fails in the Image Publisher trust or policy section, first confirm that the account stack actually exposes the role and that the expected branch configuration matches Terraform:

```bash
terraform -chdir="bootstrap/${ENVIRONMENT:?Select dev, staging, or prod}/account" output -json | \
  jq -r '.image_publisher_role_github_arn.value // "<not enabled>"'
```

For a publisher-enabled workload, confirm `bootstrap/<env>/account` is configured with the intended `enable_image_publisher_role_github = true` and `branches_image_publisher_github` values, then run validation with the same branch set through `EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES`. The Image Publisher role uses branch-based GitHub OIDC subjects, not GitHub Environment subjects.

Do not use `deploy-application.sh` to repair bootstrap IAM validation. The deployment helper builds and publishes application images; bootstrap IAM drift should be corrected by reconciling or applying `bootstrap/<env>/account`, then rerunning `validate-bootstrap.sh` / `export-bootstrap.sh`.

For release/client-facing evidence where the publisher is expected, use:

```bash
AWS_PROFILE="${AWS_PROFILE:?Set the workload profile}" \
AWS_REGION="${AWS_REGION:?Set the service Region}" \
EXPECTED_ACCOUNT_ID="${EXPECTED_ACCOUNT_ID:?Set the workload account ID}" \
EXPECTED_GITHUB_REPOSITORY="${EXPECTED_GITHUB_REPOSITORY:?Set owner/repo}" \
REQUIRE_STATE_STACK_REMOTE=true \
REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true \
EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES='["main"]' \
./scripts/validation/export-bootstrap.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

---

## Related Documentation

Recommended companion docs:

```text
docs/validation-checklist.md
docs/assurance/validation-report-template.md
docs/assurance/validation-evidence-guide.md
docs/quickstart.md
```
