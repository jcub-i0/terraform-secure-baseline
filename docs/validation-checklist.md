# Validation Checklist - tf-secure-baseline

## Purpose

This checklist describes deployment inspection and separately approved live qualification for `tf-secure-baseline`. Automated results establish selected configuration/health assertions, not exhaustive control effectiveness or completion of every live test.

Use this checklist after completing the deployment steps in:

```text
docs/quickstart.md
```

This checklist validates:

- AWS account and profile correctness
- Terraform state backend resources
- Workload bootstrap resources
- GitHub OIDC roles
- Control-plane resources
- Environment baseline infrastructure
- Deployment profile resolution
- Egress mode behavior
- Networking and private connectivity
- Dedicated VPC endpoint subnet placement
- Logging and monitoring
- Security services
- IAM Identity Center access
- Event-driven security automation
- Lambda workflows
- SNS, SQS, EventBridge, and DLQ-based alert delivery paths
- Alerting
- ECS scaling ownership, deployment health, and operational alarms
- GuardDuty ECS/Fargate Runtime Monitoring enrollment, injected-agent state, coverage health, and SecOps coverage notifications
- Profile-aware AWS Backup enabled/disabled state
- Exact subnet/CIDR/gateway relationships and production availability settings
- RDS resilience, Restore Testing configuration, and separate recovery/cleanup results
- Destroy/cleanup readiness

---

## Validation Scope

Run workload checks for each deployed environment:

```text
dev
staging
prod
```

The complete platform also has two centralized validation targets:

```text
control-plane
security-operations
```

Recommended validation order:

1. Confirm AWS profile/account variables.
2. Verify each migrated state stack with `scripts/bootstrap/migrate-state-stack.sh <target> --verify-only` where applicable.
3. Run and export control-plane validation.
4. Run and export security-operations validation.
5. After each workload baseline is deployed, complete workload-account reconciliation.
6. Run and export workload bootstrap validation for each workload account.
7. Run and export workload baseline validation for each deployed workload account.
8. Review the four evidence layers together; do not treat a single layer as proof of the full platform.
9. Validate IAM Identity Center end-user access where required.
10. Run live Lambda, tamper, and break-glass tests only in approved environments.
11. Review destroy safety requirements before teardown.

A completed earlier qualification remains valid evidence for its own commit and tested configuration; do not silently call it an RC1 execution. Record which changes were assessed by targeted regression versus earlier behavioral tests. RC1's shipped sample digest is null, whereas qualification of a running production service used a selected image. No further test is required merely because this documentation changes; investigate implementation changes and evidence gaps on their own merits.

### Inspection, live tests, and acceptance

The 16 workload validators inspect deployed state. This checklist also includes **separate stateful or privileged operations**: backend initialization/migration, reconciliation apply, SSM sessions, SQS message receipt, CloudTrail stop/start, role assumption, and approved retirement/destruction. Do not execute the entire document as a read-only script. Establish target identity, authorization, rollback, evidence retention and cleanup before a live test.

Run Bash examples from the repository root unless a block explicitly runs inside an instance. Replace placeholders before execution. `ENVIRONMENT` below is an operator convenience variable; workload scripts require `dev`, `staging`, or `prod` as their first positional argument. A shell variable assigned without `export` is not automatically passed to a child validator.

The `--profile` examples assume local named profiles. On a GitHub OIDC runner, leave `AWS_PROFILE` unset and omit named-profile arguments. Reset account, Region and naming variables whenever switching layers; do not carry a workload account's settings into the control plane.

---

## Required Variables

Because validation crosses five AWS accounts, separate terminals or clearly isolated CLI profiles are recommended for `control-plane`, `security-operations`, `dev`, `staging`, and `prod`.

### Dev

```bash
export AWS_PAGER=""
export AWS_PROFILE="dev"
export ENVIRONMENT="dev"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<DEV-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Staging

```bash
export AWS_PAGER=""
export AWS_PROFILE="staging"
export ENVIRONMENT="staging"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<STAGING-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Prod

```bash
export AWS_PAGER=""
export AWS_PROFILE="prod"
export ENVIRONMENT="prod"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<PROD-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Control-Plane

```bash
export AWS_PAGER=""
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Security-Operations

```bash
export AWS_PAGER=""
export AWS_PROFILE="security-operations"
export ENVIRONMENT="security-operations"
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
export ACCOUNT_ID="<SECURITY-OPERATIONS-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
```

### Naming Convention

Validation scripts now use `CLOUD_NAME` to derive `NAME_PREFIX` when a direct `NAME_PREFIX` override is not supplied.

Environment-specific scripts use this pattern:

```bash
ENV_NAME="${1:-}"
CLOUD_NAME="${CLOUD_NAME:-tf-secure-baseline}"
NAME_PREFIX="${NAME_PREFIX:-${CLOUD_NAME}-${ENV_NAME}}"
```

Use `CLOUD_NAME` for normal project/client naming customization. Use `NAME_PREFIX` only when validating a deployment that intentionally does not follow the default `${CLOUD_NAME}-${ENV_NAME}` naming convention.

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

### Preflight for local workload spot checks

After selecting one workload account shell above and initializing its intended backend, resolve resource identities from the applied outputs rather than the first result of an account-wide list:

```bash
case "${ENVIRONMENT:?Select a workload environment}" in
  dev|staging|prod) ;;
  *) echo "Select dev, staging, or prod for workload checks" >&2; exit 1 ;;
esac
: "${AWS_PROFILE:?Set the matching local AWS profile}"
: "${EXPECTED_ACCOUNT_ID:?Set the expected 12-digit account ID}"
: "${AWS_REGION:?Set the expected workload service Region}"
[[ "${EXPECTED_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || exit 1
CALLER_ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || exit 1
[[ "${CALLER_ACCOUNT}" == "${EXPECTED_ACCOUNT_ID}" ]] || {
  echo "AWS account mismatch; stop" >&2; exit 1;
}
ENV_DIR="environments/${ENVIRONMENT}"
WORKLOAD_OUTPUTS_JSON="$(terraform -chdir="${ENV_DIR}" output -json)" || exit 1
APPLIED_REGION="$(jq -er '.primary_region.value | select(type == "string" and length > 0)' <<<"${WORKLOAD_OUTPUTS_JSON}")" || exit 1
[[ "${AWS_REGION}" == "${APPLIED_REGION}" ]] || {
  echo "Service Region differs from applied workload primary_region; stop" >&2; exit 1;
}
export AWS_DEFAULT_REGION="${APPLIED_REGION}"
VPC_ID="$(jq -er '.vpc_id.value | select(type == "string" and length > 0)' <<<"${WORKLOAD_OUTPUTS_JSON}")" || exit 1
CENTRALIZED_LOGS_BUCKET_NAME="$(jq -er '.centralized_logs_bucket_name.value | select(type == "string" and length > 0)' <<<"${WORKLOAD_OUTPUTS_JSON}")" || exit 1
export VPC_ID CENTRALIZED_LOGS_BUCKET_NAME
```

Stop on a missing required output. Re-resolve these values after a redeployment or a switch of account/environment. The administrative sections require their own explicit profile, expected account, service Region and root initialization.

---

## Automated Workload Bootstrap Validation

For deployed workload environments, bootstrap validation checks the foundational state and CI/CD execution-plane resources in:

```text
bootstrap/<env>/state
bootstrap/<env>/account
```

The primary command is:

```bash
./scripts/validation/validate-bootstrap.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

This script validates the workload bootstrap layer separately from the workload baseline because the bootstrap stacks manage Terraform state storage, state encryption, backend locking configuration, and GitHub OIDC roles.

### Dev

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh dev
```

### Staging

```bash
AWS_PAGER="" \
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh staging
```

### Prod

```bash
AWS_PAGER="" \
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-bootstrap.sh prod
```

### Workload Bootstrap Validation Coverage

`validate-bootstrap.sh` performs safe, read-only validation for:

- AWS caller identity and expected workload account ID
- `bootstrap/<env>/state`, `bootstrap/<env>/account`, and `environments/<env>` directory structure
- active post-migration `bootstrap/<env>/state/backend.tf` configuration
- S3 backend declarations and `use_lockfile = true` for state, account, and workload stacks
- state, account, and workload backend files resolving the same state bucket and region
- distinct Terraform state object keys for all three Terraform roots
- migrated state object existence and readability in S3
- successful `terraform state pull` through the state stack's configured backend
- state backend bucket matching the state stack's `tf_state_bucket_name` output
- Terraform state S3 bucket existence, versioning, encryption, and public access block settings
- Terraform state KMS CMK resolution from the live bucket encryption configuration
- Terraform state KMS CMK existence, key state, and customer-managed status
- GitHub OIDC provider existence
- workload GitHub plan/apply role existence
- GitHub OIDC trust policy conditions for the expected repository and GitHub environments
- GitHub role policy access to the Terraform state bucket, state objects including `.tflock` objects, and state CMK
- GitHub Apply role access to current workload-created Lambda and Secrets Manager CMKs

The state stack is applied with local state only during initial bootstrap. After the backend resources exist, `scripts/bootstrap/migrate-state-stack.sh` creates the ignored active `backend.tf`, migrates the state to S3, and verifies the result.

The tracked file:

```text
bootstrap/<env>/state/backend.tf.migrated.example
```

describes the intended post-migration backend. The active file:

```text
bootstrap/<env>/state/backend.tf
```

is generated locally or materialized by a GitHub evidence workflow and is ignored by Git.

The workload bootstrap architecture uses S3 native state locking with `use_lockfile = true`. DynamoDB locking is not part of the current architecture.

### State Stack Remote-Backend Validation

State-stack migration validation is controlled by:

```bash
REQUIRE_STATE_STACK_REMOTE="${REQUIRE_STATE_STACK_REMOTE:-false}"
```

| Value | Behavior |
|---|---|
| `true` | Missing, mismatched, or unreadable state-stack remote backend findings fail validation. This is recommended for post-migration and client-readiness evidence. |
| `false` | The remote-state checks still run, but their findings are advisory warnings. This is the direct-script default for transitional use. |

The GitHub workload bootstrap evidence workflow defaults its `require_state_stack_remote` input to `true`.

Verify an already-migrated workload state stack directly with:

```bash
AWS_PROFILE=dev \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh dev --verify-only
```

A tracked `backend.tf.migrated.example` file alone is not proof of migration. The active backend configuration, readable S3 state object, successful `terraform state pull`, and matching bucket output provide the migration evidence.

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

| Value | Behavior |
|---|---|
| `true` | Stale or missing workload Lambda / Secrets Manager CMK policy references fail validation. This is the default and is recommended for client-readiness evidence. |
| `false` | Stale or missing workload CMK policy references are reported as warnings. The checks still run; they become advisory rather than skipped. |

Use `STRICT_WORKLOAD_CMK_POLICY_CHECKS=false` only for transitional runs, early/manual GitHub workflow testing, or environments where the workload stack has not yet been reconciled back into `bootstrap/<env>/account`.

For strict workload CMK and remote-state evidence, the expected deployment sequence is:

```text
1. Initialize and apply bootstrap/<env>/state locally.
2. Run scripts/bootstrap/migrate-state-stack.sh <env>.
3. Apply bootstrap/<env>/account.
4. Apply environments/<env>.
5. Generate and review the workload-account reconciliation plan.
6. Approve and apply the exact saved reconciliation plan.
7. Run validate-bootstrap.sh or export-bootstrap.sh with REQUIRE_STATE_STACK_REMOTE=true and the default strict CMK behavior.
```

For GitHub Actions, select `plan-and-apply` in the `Reconcile Workload Account` workflow. The Plan job runs through `<env>-plan`, publishes the plan, and uploads the saved artifact. The Apply job waits on the protected `<env>` environment, verifies the artifact and expected account, applies the exact plan, and runs strict bootstrap validation.

For a two-step local exact-plan review:

```bash
# Run only in the selected workload account shell; apply mode changes IAM.
: "${ENVIRONMENT:?Select dev, staging, or prod}"
: "${AWS_PROFILE:?Set the matching local profile}"
: "${AWS_REGION:?Set the explicit service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the expected workload account ID}"
umask 077
RECONCILIATION_DIR="$(mktemp -d)"
RECONCILIATION_PLAN="${RECONCILIATION_DIR}/account-reconciliation.tfplan"

./scripts/bootstrap/reconcile-workload-account.sh "${ENVIRONMENT}" \
  --plan-file="${RECONCILIATION_PLAN}"

# Inspect the readable plan and obtain approval before this separate mutation.
./scripts/bootstrap/reconcile-workload-account.sh "${ENVIRONMENT}" \
  --apply-plan="${RECONCILIATION_PLAN}"
```

The one-step `--apply` mode generates, displays, confirms, and applies a saved plan within the same invocation. It does not reuse a plan from a previous plan-only invocation unless that plan was retained with `--plan-file`.

Run the two commands as separate reviewed steps, not an unattended copy/paste batch. Retain the protected plan only for the approved review/apply window and remove it according to your evidence-retention policy. `AWS_REGION` selects service execution; reconciliation reports backend Region separately.

The reconciliation helper reads `lambda_cmk_arn` and `secrets_manager_cmk_arn` directly from the workload Terraform state, validates the resolved account-stack inputs from the saved plan, applies the current or explicitly supplied saved plan, and runs strict bootstrap validation after apply unless `--skip-validation` is used.

### GitHub Workflow Usage

The deployment workflows use paired GitHub environments:

```text
dev-plan / dev
staging-plan / staging
prod-plan / prod
```

The `*-plan` environment allows the plan to complete before approval. Protected environments gate the applicable mutation jobs. Production retirement uses additional durable-cleanup and Identity Center approvals; the full sequence is described in the retirement runbook.

Configure the same generic `ACCOUNT_ID` in both members of each pair. The Plan and Apply jobs validate:

- `ACCOUNT_ID` is present and contains exactly 12 digits;
- the configured Plan or Apply role ARN belongs to that account;
- the active AWS OIDC caller is operating in that account; and
- saved-plan metadata identifies the same account, repository, commit, workflow run, and Terraform version; and
- workload Plan environments provide `ISOLATION_ALLOWED` as exactly `true` or `false`.

Example deliberately selected isolation policy (these GitHub settings are not proved by the source tree):

```text
dev-plan      ISOLATION_ALLOWED=true
staging-plan  ISOLATION_ALLOWED=false
prod-plan     ISOLATION_ALLOWED=false
```

Do not infer those values from the workload root defaults: the reusable baseline defaults `isolation_allowed=false`, but the production root defaults it to `true`. Select and align the effective local and CI value explicitly. The actual `IsolationAllowed` tag, not the environment name, gates containment.

Apply uses the reviewed saved plan and does not re-resolve this variable. Destroy uses a safe `false` fallback when the value is absent.

`Terraform Apply` publishes and uploads its own saved baseline plan, waits for approval, then applies that exact artifact. Its optional reconciliation input invokes `Reconcile Workload Account` with `plan-and-apply`.

`Reconcile Workload Account` supports:

- `plan-only`: publish and upload the reconciliation plan, then stop;
- `plan-and-apply`: publish and upload the plan, wait for approval, apply the exact saved plan, and run strict bootstrap validation.

The workload bootstrap evidence workflow remains read-only. It:

1. materializes the ignored state-stack `backend.tf`;
2. initializes the state, account, and workload Terraform roots;
3. runs the exporter with `REQUIRE_STATE_STACK_REMOTE=true` by default; and
4. uploads the generated validation package as a GitHub Actions artifact.

For a manual run from a fresh checkout of an already-migrated environment, materialize and verify the state backend before initializing the other roots:

```bash
export AWS_PROFILE="dev"
export AWS_REGION="us-east-1"
export EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>"
# Confirm identity and the reviewed template; do not overwrite an active backend.
aws sts get-caller-identity
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

To generate workload bootstrap evidence, run `export-bootstrap.sh` after the same initialization:

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/export-bootstrap.sh dev
```

## Automated Workload Baseline Validation

For deployed workload environments, most safe, read-only workload baseline validation is automated by the scripts in:

```text
scripts/validation/
```

The primary command is:

```bash
./scripts/validation/validate-baseline.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

Set `EXPECTED_ACCOUNT_ID` when running validation so the scripts can confirm that the selected AWS profile is pointed at the correct workload account.

### Dev

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
./scripts/validation/validate-baseline.sh dev
```

### Staging

```bash
AWS_PAGER="" \
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
./scripts/validation/validate-baseline.sh staging
```

### Prod

```bash
AWS_PAGER="" \
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-baseline.sh prod
```

If a custom client/project prefix is used, pass `CLOUD_NAME`:

```bash
AWS_PAGER="" \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="<CLIENT-OR-PROJECT-NAME>" \
./scripts/validation/validate-baseline.sh dev
```

Pass `NAME_PREFIX` explicitly only when the deployed resource prefix does not follow `${CLOUD_NAME}-${ENV_NAME}`.

### Automated Validation Coverage

`validate-baseline.sh` runs the following workload inspection scripts sequentially, continuing after individual failures and returning a final failing exit status when any child failed or was unavailable:

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

To validate a specific architecture area, you can also run individual validation scripts directly.

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

These scripts validate:

- AWS account identity and expected account ID
- Terraform outputs and effective environment settings
- VPC, subnets, route tables, NAT Gateway, and Network Firewall expectations, including an exact order-independent comparison of the live stateful domain rule-group targets with Terraform output `effective_allowed_egress_domains`. Terraform owns allowlist composition; `validate-networking.sh` does not reconstruct it. The effective set must be empty when Network Firewall is not instantiated.
- canonical VPC endpoint inventory, state, VPC, private DNS, exact endpoint-private subnet and Interface Endpoint SG placement, exact live-vs-Terraform endpoint IDs, unique Terraform-owned `guardduty-data` reuse, and exact S3 Gateway Endpoint coverage of endpoint, compute, and serverless private route tables
- ECR repository identity, immutable tags, exact `ecr_cmk_arn` encryption, and exact 30-day untagged-only lifecycle cleanup, using `ecr_repositories` as the inventory
- CloudTrail, VPC Flow Logs, CloudWatch log groups, metric filters, and alarms
- workload-local AWS Config and Inspector state plus GuardDuty, Security Hub CSPM, and Security Hub V2 ownership/administrator relationships based on effective Terraform outputs
- KMS aliases, CMKs, key state, key manager, and rotation status, including the retained Backup CMK
- the exact AWS Backup contract: encrypted vault retained in both enabled and disabled states; plan/selection, effective schedule/retention, and EC2/RDS `Backup` tags matching `effective_backup_enabled`; plus recent jobs and recovery points when enabled
- SNS topics, subscriptions, pending confirmations, and encryption mode
- SQS queues, SNS-to-SQS delivery paths, queue policies, encryption mode, redrive policies, DLQ status, visible messages, and not-visible messages
- EventBridge default-bus and SecOps-bus rules, state, targets, target DLQs, retry policies, rollback rule coverage, and exact GuardDuty ECS Runtime coverage-state notification configuration
- Lambda functions, runtime, state, execution role, timeout, memory, KMS config, VPC config, environment variables, resource policies, and EventBridge permissions
- SSM managed instance registration, online status, associations, maintenance windows, and patch baseline visibility
- EC2 compute instances, private placement, public IP absence, IMDSv2, detailed monitoring, instance profiles, security groups, required tags, isolation eligibility, and EBS encryption
- ECS cluster identity and state; deployment-profile Runtime Monitoring intent and exact `GuardDutyManaged` tag; injected GuardDuty agent state; GuardDuty ECS coverage management/status/issues; fixed-versus-autoscaled desired-count ownership; exact Application Auto Scaling targets and CPU/memory/conditional ALB target-tracking policies; deployment-health settings; Fargate service placement and deployment safeguards; application-only task-definition contract, digest-pinned ECR image, port, and `awslogs` contracts; Terraform-owned application log groups; runtime task-SG relationships; conditional shared-ALB state; and Terraform-owned task-deficit / ingress unhealthy-target operational alarms
- IAM roles, service trust policies, key service roles, GitHub OIDC roles where present, break-glass MFA conditions, shared log access policies, and per-service ECS task/execution role separation with exact application and GuardDuty-agent ECR authority

A successful run should end with:

```text
Validation scripts passed:  16/16
Validation scripts failed:  0/16
```

This counts top-level script exits, not every assertion. Warnings and inapplicable branches can coexist with `16/16`. The runner does not write a timestamped package; `export-baseline.sh` reruns the same scripts and writes one. Use the exporter for an evidence-producing pass rather than assuming it packages a prior runner log.

### Configuration coverage and separate acceptance

The topology comparison includes the exact VPC CIDR, full seven-family subnet inventory/CIDRs, IGW, NAT/firewall identities, same-AZ routing and deletion-protection intent. RDS/Backup checks include `rds_configuration`, `backup_vault_configuration`, `lifecycle_protection`, and `restore_testing`; they do not constitute SQL, failover or completed restore validation. See section 19 for exact boundaries.

Normal production ECS validation checks the production two-task floor, deployment health policy and enabled AZ rebalancing. Capture actual per-task AZs and target health separately. A configuration with no deployable service can pass without running tasks, GuardDuty agents or application transactions. Normal production validation is not the zero-capacity retirement gate.

## Automated Control-Plane Validation

Control-plane validation proves organization topology and prerequisites rather than workload baseline state.

Use the consolidated Identity Center configuration expected by the Terraform stack:

```bash
IDENTITY_CENTER_WORKLOADS='<JSON-WORKLOAD-CONFIGURATION-MAP>' \
IDENTITY_CENTER_SECOPS='<JSON-SECURITY-OPERATIONS-CONFIGURATION>' \
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

The validator covers:

- control-plane AWS identity, state outputs, backend locking, and optional strict remote-state proof
- state bucket and state CMK protections
- control-plane GitHub OIDC provider and Plan/Apply roles
- AWS Organizations ALL-features mode
- `Workloads`, `NonProd`, `Prod`, and `Security` OU topology
- active `dev`, `staging`, `prod`, and `security-operations` accounts
- strict account placement under the expected OUs
- Security Hub / GuardDuty trusted service access and delegated-administrator registration
- Security Hub V2 `SECURITYHUB_POLICY` prerequisite
- IAM Identity Center required groups, permission sets, and assignments

`STRICT_ACCOUNT_OU_CHECKS` and `STRICT_IDENTITY_CENTER_ASSIGNMENTS` default to `true`; required mismatches fail the current validator unless a run explicitly relaxes those settings.

---

## Automated Security-Operations Validation

Run centralized-security validation from the `security-operations` account:

```bash
AWS_PAGER="" \
AWS_PROFILE=security-operations \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<SECURITY-OPERATIONS-ACCOUNT-ID>" \
./scripts/validation/validate-security-operations.sh
```

The validator covers:

- security-operations AWS identity and applied `security_services` Terraform state
- directly required trusted-access and delegated-administrator dependencies
- Security Hub CSPM administrator state and finding aggregation
- Security Hub CSPM `CENTRAL` organization configuration
- configuration policies and workload account associations
- GuardDuty administrator detector and organization member enrollment
- GuardDuty organization protection plans and Runtime Monitoring configuration
- Security Hub V2 administrator state
- Security Hub V2 organization policy attachment to `Workloads`
- effective Security Hub V2 policy for the configured workload accounts

This layer does not replace full organization topology validation or workload-local security validation.

---

## Exporting Validation Evidence

Evidence exporters create timestamped `summary.md`, `summary.json`, and supporting logs.

| Layer | Export command | Package location |
|---|---|---|
| Workload bootstrap | `export-bootstrap.sh <env>` | `validation-results/<env>/bootstrap/<timestamp>/` |
| Workload baseline | `export-baseline.sh <env>` | `validation-results/<env>/baseline/<timestamp>/` |
| Control plane | `export-control-plane.sh` | `validation-results/control-plane/<timestamp>/` |
| Security operations | `export-security-operations.sh` | `validation-results/security-operations/security-services/<timestamp>/` |

The current workload baseline package contains `validate-security-workload.log`.

Review `summary.md`, `summary.json` and each raw log together. The exporter's static remaining-test list is not a completed-test tracker; warnings are not all promoted into the top-level verdict. Preserve generated files unchanged and add a companion record for validator/deployment SHAs, image digests, effective profile, service/backend Regions, toolchain/lockfile identity, workflow run/attempt, exceptions and reviewer acceptance. These fields are not automatically a signed manifest in the baseline summary.

An exporter can fail before a complete report is written. Match the artifact to the actual run; an older “latest” directory is not evidence that a new failed invocation passed. The reported credential-source string is inferred from environment settings, not independent proof of OIDC authentication.

Use the [evidence guide](assurance/validation-evidence-guide.md) and [report template](assurance/validation-report-template.md) for per-run provenance and acceptance records.

GitHub evidence workflows use the corresponding Plan GitHub Environment and OIDC credentials. A blank AWS profile in generated GitHub evidence is expected when the report identifies the credential source as `GitHub OIDC environment credentials`.

---

## Validation Still Required Outside Each Report

The exporters are layer-specific. Control-plane, security-operations, workload-bootstrap, and workload-baseline checks may be outside one report while still being automated by another workflow.

The activities that remain live/manual by design are:

- IAM Identity Center end-user login and effective-access testing
- live EC2 isolation testing
- live EC2 rollback testing
- live IP enrichment testing
- tamper-detection simulation
- break-glass role assumption testing
- destroy-safety review and approved teardown execution
- actual ECS placement/replacement and application/target/SQL tests
- controlled RDS failover, completed Backup restore execution, application validation and temporary-resource cleanup
- custom-CIDR apply/destroy regression and final no-change plan with the same effective inputs
- production Stage-1, durable cleanup, readiness, Identity Center and exact destroy-plan evidence

Use the remaining sections for manual spot checks, troubleshooting, and approved live tests.

---

# 1. Validate AWS CLI Identity

## Purpose

Confirm that the AWS CLI is authenticated to the correct AWS account before validating resources.

## Command

```bash
aws sts get-caller-identity --profile "${AWS_PROFILE}" --region "${AWS_REGION}"
```

## Expected Outcome

- The returned `Account` matches the expected account ID.
- The profile corresponds to the environment being validated.
- No SSO, credential, or profile errors occur.

---

# 2. Validate Terraform State Backends

## Purpose

Confirm that each state stack created its backend resources, was migrated to its intended S3 backend, and can read its remote state safely.

The state stacks create:

- an S3 bucket for Terraform state;
- a customer-managed KMS key for state encryption.

They are initialized and applied locally once, then migrated with:

```bash
./scripts/bootstrap/migrate-state-stack.sh "${ENVIRONMENT:?Choose a supported migration target}"
```

The repository tracks the post-migration template:

```text
backend.tf.migrated.example
```

The active runtime file:

```text
backend.tf
```

is created after migration and ignored by Git.

All remote-backed stacks use Terraform S3 native locking with:

```hcl
use_lockfile = true
```

DynamoDB state locking is not part of the current architecture.

## Verify a Migrated State Stack

For a workload environment:

```bash
AWS_PROFILE="${ENVIRONMENT}" \
EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}" \
./scripts/bootstrap/migrate-state-stack.sh "${ENVIRONMENT}" --verify-only
```

For the control plane:

```bash
AWS_PROFILE="control-plane" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
./scripts/bootstrap/migrate-state-stack.sh control-plane --verify-only
```

Expected:

- AWS identity resolves to the intended account.
- Active `backend.tf` matches `backend.tf.migrated.example`.
- The configured S3 state object exists and is readable.
- `terraform state pull` succeeds.
- The configured bucket matches the `tf_state_bucket_name` Terraform output.

## Check State Bucket

Resolve the state bucket and its Region from the selected, initialized state root and reviewed backend configuration. This is separate from service `AWS_REGION`; the following local example works for the five documented target names:

```bash
case "${ENVIRONMENT:?Select the state target}" in
  control-plane) STATE_DIR="bootstrap/control_plane/state" ;;
  security-operations) STATE_DIR="bootstrap/security_operations/state" ;;
  dev|staging|prod) STATE_DIR="bootstrap/${ENVIRONMENT}/state" ;;
  *) echo "Unknown state target" >&2; exit 1 ;;
esac
STATE_BUCKET="$(terraform -chdir="${STATE_DIR}" output -raw tf_state_bucket_name)" || exit 1
STATE_REGION="<REGION-FROM-REVIEWED-STATE-BACKEND>"
# Replace STATE_REGION before the AWS commands; do not substitute a workload Region.
```

```bash
aws s3api head-bucket \
  --bucket "${STATE_BUCKET}" \
  --region "${STATE_REGION}" \
  --profile "${AWS_PROFILE}"
```

## Check State Bucket Encryption

```bash
aws s3api get-bucket-encryption \
  --bucket "${STATE_BUCKET}" \
  --region "${STATE_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
```

If the deployment uses a custom bucket name, use the value declared in the applicable backend template or returned by `tf_state_bucket_name`.

## Check S3 Native State Locking

For a workload environment, confirm all three active backend configurations use S3 native locking:

```bash
grep -H "use_lockfile" \
  "bootstrap/${ENVIRONMENT}/state/backend.tf" \
  "bootstrap/${ENVIRONMENT}/account/backend.tf" \
  "environments/${ENVIRONMENT}/backend.tf"
```

Expected for each file:

```text
use_lockfile = true
```

For the control plane:

```bash
grep -H "use_lockfile" \
  bootstrap/control_plane/state/backend.tf \
  bootstrap/control_plane/account/backend.tf \
  bootstrap/control_plane/organizations/backend.tf \
  bootstrap/control_plane/identity_center/backend.tf
```

## Check State Object Separation

Review the configured backend keys:

```bash
grep -H -E '^[[:space:]]*key[[:space:]]*=' \
  "bootstrap/${ENVIRONMENT}/state/backend.tf" \
  "bootstrap/${ENVIRONMENT}/account/backend.tf" \
  "environments/${ENVIRONMENT}/backend.tf"
```

Expected:

- every Terraform root uses a distinct object key;
- state, account, and workload roots do not share a state object;
- the keys match the intended environment.

## Terraform Read Check

From each initialized workload Terraform root:

```bash
terraform -chdir="bootstrap/${ENVIRONMENT}/state" state pull >/dev/null
terraform -chdir="bootstrap/${ENVIRONMENT}/account" state pull >/dev/null
terraform -chdir="environments/${ENVIRONMENT}" state pull >/dev/null
```

Expected:

- each backend initializes successfully;
- each state is readable;
- no state lock or access errors occur.

## Expected Outcome

- State bucket exists.
- KMS encryption is configured.
- The state stack has been migrated to the intended S3 object.
- State, account, and workload stacks use distinct state keys.
- All remote-backed stacks use `use_lockfile = true`.
- `terraform state pull` succeeds for each initialized root.

These checks prove configured locking/state readability, not a live contention test. `--verify-only` can initialize local Terraform metadata; it does not repeat state migration. The destination-existence check in the migration helper is not a general guarantee that an inaccessible object is absent. Retiring a workload does not authorize deleting its state bucket, and moving state away does not remove literal `prevent_destroy` guards.

---

# 3. Validate GitHub OIDC Roles

## Purpose

Confirm workload GitHub OIDC roles exist and that their authority boundaries match the intended workflow model.

Each workload account may include:

- GitHub Plan role
- GitHub Apply role
- GitHub Image Publisher role

## Check IAM Roles

```bash
aws iam list-roles \
  --profile "${AWS_PROFILE}" \
  --query "Roles[?contains(RoleName, 'github')].[RoleName, Arn]" \
  --output table
```

## Expected Outcome

A workload account with all three capabilities enabled should show roles similar to:

```text
tf-secure-baseline-dev-github-plan-role
tf-secure-baseline-dev-github-apply-role
tf-secure-baseline-dev-github-image-publisher-role
```

The Image Publisher role must use branch-based GitHub OIDC trust for the configured `BRANCHES_IMAGE_PUBLISHER_GITHUB` values. Its AWS policy should be limited to ECR publication/query operations for the intended repositories, except for the registry-wide `ecr:GetAuthorizationToken` action.

`validate-bootstrap.sh` also validates the optional Image Publisher role whenever `image_publisher_role_github_arn` is present. For publisher-enabled release/client evidence, set `REQUIRE_BOOTSTRAP_GITHUB_IMAGE_PUBLISHER_ROLE=true`, provide `EXPECTED_GITHUB_REPOSITORY`, and set `EXPECTED_GITHUB_IMAGE_PUBLISHER_BRANCHES` to the approved branch JSON. The validator then checks the exact branch-based OIDC subjects and exact Terraform-defined ECR publication/query policy boundary.

## GitHub Workflow Validation

The Plan role trusts the matching `<env>-plan` GitHub Environment subject; the Image Publisher trusts approved branch subjects. A role name or successful list call does not validate that trust. “Plan” does not mean its IAM policy is entirely read-only; inspect actual policy/state authority and configured reviewer protections separately.

For `Terraform Apply`, confirm the internal Plan job publishes a readable plan plus saved binary plan, metadata, and checksum before protected approval. Confirm the Apply job verifies and applies that exact artifact without replanning. The standalone `Terraform Plan` workflow is not the source of the Apply artifact.

For `Deploy Application`, confirm the publisher job uses the expected Image Publisher role, runs only from an authorized branch, has no repository write permission, publishes the image, and re-checks the authoritative ECR digest. Confirm the separate release/PR job has repository write authority but no AWS credentials or OIDC token and changes only `ecs_services.<service>.image_digest` in the tracked workload configuration.

After the release PR is merged, run `Terraform Apply` separately, confirm ECS reaches steady state, and run workload validation/evidence separately.

# 4. Validate Control Plane

## Purpose

Confirm that control-plane resources were deployed correctly.

The preferred validation path is the automated read-only control-plane validation script:

```bash
# Export the approved consolidated JSON inputs before this command.
: "${IDENTITY_CENTER_WORKLOADS:?Set the approved workload JSON map}"
: "${IDENTITY_CENTER_SECOPS:?Set the approved security-operations JSON object}"
AWS_PAGER="" \
AWS_PROFILE=control-plane \
AWS_REGION="<CONTROL-PLANE-SERVICE-REGION>" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
IDENTITY_CENTER_WORKLOADS="${IDENTITY_CENTER_WORKLOADS}" \
IDENTITY_CENTER_SECOPS="${IDENTITY_CENTER_SECOPS}" \
REQUIRE_STATE_STACK_REMOTE=true \
./scripts/validation/validate-control-plane.sh
```

This validates the control-plane state backend, GitHub OIDC execution plane, AWS Organizations OU structure, and IAM Identity Center basics.

The validator derives workload/security-operations account IDs from those JSON inputs (or their `TF_VAR_identity_center_*` aliases). The old `ACCOUNT_ID_DEV`, `ACCOUNT_ID_STAGING`, and `ACCOUNT_ID_PROD` inputs do not replace them. Supply all three workload accounts/Regions and the security-operations account as required by the consolidated schema.

The manual commands below can be used for spot checks, troubleshooting, or deeper review.

Run manual spot checks using the control-plane profile:

```bash
export AWS_PROFILE="control-plane"
export ENVIRONMENT="control-plane"
export AWS_REGION="<CONTROL-PLANE-SERVICE-REGION>"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
aws sts get-caller-identity
```

---

## 4.1 Validate AWS Organizations

```bash
aws organizations describe-organization \
  --profile "${AWS_PROFILE}"
```

Expected:

- Organization exists.
- The Organization's `MasterAccountId` equals that of the `control-plane` account ID.

## List OUs

```bash
aws organizations list-roots \
  --profile "${AWS_PROFILE}"
```

Then list OUs under the root:

```bash
ROOT_ID="$(aws organizations list-roots \
  --profile "${AWS_PROFILE}" \
  --query 'Roots[0].Id' \
  --output text)"

aws organizations list-organizational-units-for-parent \
  --parent-id "${ROOT_ID}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected root-level OUs:

```text
Workloads
Security
```

Then verify child OUs under `Workloads`:

```bash
WORKLOADS_OU_ID="$(aws organizations list-organizational-units-for-parent \
  --parent-id "${ROOT_ID}" \
  --profile "${AWS_PROFILE}" \
  --query "OrganizationalUnits[?Name=='Workloads'].Id | [0]" \
  --output text)"

aws organizations list-organizational-units-for-parent \
  --parent-id "${WORKLOADS_OU_ID}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected child OUs:

```text
NonProd
Prod
```

Also confirm account placement:

```text
dev                 -> Workloads/NonProd
staging             -> Workloads/NonProd
prod                -> Workloads/Prod
security-operations -> Security
```

---

## 4.2 Validate IAM Identity Center Instance

```bash
aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- IAM Identity Center instance exists.
- Instance ARN and Identity Store ID are returned.

---

## 4.3 Validate Identity Center Groups

```bash
IDENTITY_STORE_ID="$(aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Instances[0].IdentityStoreId' \
  --output text)"

aws identitystore list-groups \
  --identity-store-id "${IDENTITY_STORE_ID}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Groups[].DisplayName' \
  --output table
```

Required groups include:

```text
SecOps-Operator-Dev
SecOps-Operator-Staging
SecOps-Operator-Prod
SecOps-Administrator
```

Optional groups may include:

```text
SecOps-Analyst-Dev
SecOps-Engineer-Dev
SecOps-Analyst-Staging
SecOps-Engineer-Staging
SecOps-Analyst-Prod
SecOps-Engineer-Prod
```

---

## 4.4 Validate Identity Center Permission Sets and Assignments

The automated control-plane validation script checks for permission set outputs, permission set existence, and account assignment presence.

For manual troubleshooting, list permission sets:

```bash
INSTANCE_ARN="$(aws sso-admin list-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Instances[0].InstanceArn' \
  --output text)"

aws sso-admin list-permission-sets \
  --instance-arn "${INSTANCE_ARN}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

To inspect assignments for a target account and permission set:

```bash
aws sso-admin list-account-assignments \
  --instance-arn "${INSTANCE_ARN}" \
  --account-id "<TARGET-ACCOUNT-ID>" \
  --permission-set-arn "<PERMISSION-SET-ARN>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- Expected permission sets exist.
- Expected account assignments exist for enabled SecOps roles.
- Customer-managed policy attachments are present only when the required workload-account policy names have been provided and the policies exist in the target account.

---

# 5. Validate Environment Baseline

## Purpose

Confirm that the baseline deployed into the selected workload account.

Run this section for each environment:

```text
dev
staging
prod
```

Run these checks for each environment, ensuring the appropriate environment profile is set beforehand.

```bash
# Re-run the chosen workload setup and preflight above after control-plane checks.
export AWS_PROFILE="dev"  # Example; use the profile for the selected workload.
export ENVIRONMENT="dev"
export AWS_REGION="<WORKLOAD-SERVICE-REGION>"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export ACCOUNT_ID="<WORKLOAD-ACCOUNT-ID>"
export EXPECTED_ACCOUNT_ID="${ACCOUNT_ID}"
export NAME_PREFIX="${CLOUD_NAME}-${ENVIRONMENT}"
# Re-resolve ENV_DIR, VPC_ID and other identities with the workload preflight.
```

---

## 5.1 Validate Terraform Outputs

From the repository root:

```bash
terraform -chdir="environments/${ENVIRONMENT}" output
```

Expected outputs include:

```text
primary_region
network_topology
lifecycle_protection
rds_configuration
backup_vault_configuration
restore_testing
deployment_profile
egress_mode
effective_egress_mode
effective_cloudwatch_retention_days
effective_enable_config
effective_enable_rules
effective_backup_enabled
effective_backup_schedule
effective_delete_backups_after_days
effective_inspector_enabled
ecs_cluster
guardduty_ecs_runtime_coverage_notification
```

Expected profile behavior:

| `deployment_profile` | Default `effective_egress_mode` | AWS Config | Backup scheduling | Inspector | GuardDuty Fargate Runtime Monitoring | CloudWatch retention |
|---|---|---:|---:|---:|---:|---:|
| `production` | `network_firewall` | Enabled | Enabled | Enabled | Enabled | 90 days |
| `development` | `nat_only` | Enabled | Disabled | Enabled | Enabled | 30 days |
| `minimal` | `vpc_endpoints_only` | Disabled | Disabled | Disabled | Disabled | 14 days |

If `egress_mode`, `enable_config`, `backup_enabled`, `backup_schedule`, `delete_backups_after_days`, `cloudwatch_retention_days`, or related overrides are explicitly set, the effective outputs should reflect those overrides. Runtime Monitoring is not independently overridden; it follows `deployment_profile`. When backups are disabled, `effective_backup_schedule` and `effective_delete_backups_after_days` resolve to `null` and may be omitted from `terraform output -json` because Terraform omits root outputs whose evaluated value is null.

---

## 5.2 Validate VPC

Use `VPC_ID` from the applied workload output, not an arbitrary first tag match. The expected main CIDR is `network_topology.main_vpc_cidr`, including a non-default `/16` used for a portability test.

```bash
aws ec2 describe-vpcs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --vpc-ids "${VPC_ID}" \
  --query 'Vpcs[].[VpcId,CidrBlock,State]' \
  --output table
```

Expected:

- VPC exists.
- VPC state is `available`.

---

## 5.3 Validate Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Expected:

- Both `ingress_public` and `egress_public` exist as separate families.
- Compute, data, serverless, endpoint, and firewall private families exist in every selected AZ, even when the firewall service is absent.
- All seven families disable public IPv4 auto-assignment.
- Default production has three AZs (21 subnets); default development/minimal has two (14). Supported explicit topology overrides must be compared with applied `network_topology`, not these example counts alone.
- Live per-AZ IDs/CIDRs and the entire VPC subnet inventory match Terraform; no unexpected subnet is accepted by the automated topology check.

Run `validate-networking.sh` for the exact comparison. A manual listing is supporting inspection, not equivalent to passing its assertions.

---

## 5.4 Validate EC2 Instances

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Reservations[].Instances[].[InstanceId,State.Name,PrivateIpAddress,PublicIpAddress,Tags[?Key==`Name`].Value|[0]]' \
  --output table
```

Expected:

- Workload instances exist if enabled.
- Private workload instances do not have public IPs.
- Instances are in the expected state.

---

## 5.5 Validate First-Boot Patching and Isolation Policy

The source grep below demonstrates configured bootstrap logic, not that a particular instance completed it. Review that instance's cloud-init/bootstrap logs separately; online SSM alone is not patch-completion evidence.

Confirm the bootstrap source contains the strict APT controls:

```bash
grep -nE \
  'Acquire::ForceIPv4=true|APT::Update::Error-Mode=any|dist-upgrade|user_data_replace_on_change' \
  modules/compute/user_data/bootstrap.sh \
  modules/compute/main.tf
```

For a fresh instance, review:

```text
/var/log/instance-bootstrap.log
/var/log/cloud-init-output.log
```

Expected:

- APT metadata refresh completes without unresolved repository errors.
- The distribution upgrade and required package installation complete.
- Relevant package versions and reboot-required state are recorded.
- A bootstrap or repository failure prevents a successful cloud-init completion.
- The `IsolationAllowed` tag matches the deliberately selected effective Terraform/CI input. Do not infer it from the environment name; production-root and reusable-baseline defaults differ.

Verify the policy tag:

```bash
aws ec2 describe-instances \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`IsolationAllowed`].Value|[0]]' \
  --output table
```

---

# 6. Validate Private Access and SSM

## Purpose

Confirm that private instances can be accessed through SSM Session Manager without SSH.

## List SSM-Managed Instances

```bash
aws ssm describe-instance-information \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "InstanceInformationList[].[InstanceId,PingStatus,PlatformName,AgentVersion]" \
  --output table
```

Expected:

- Target EC2 instances appear.
- `PingStatus` is `Online`.

## Start SSM Session

This is an interactive privileged access test, not a read-only validator operation. Use an approved target and session permissions; any commands run inside the session are your responsibility.

```bash
aws ssm start-session \
  --target "<INSTANCE_ID>" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Session starts successfully.
- No SSH is required.
- No public IP is required.

---

# 7. Validate VPC Endpoints

## Purpose

Confirm that VPC endpoints exist for private AWS service access.

Interface VPC Endpoints should be deployed into dedicated endpoint private subnets.

The S3 Gateway Endpoint should be associated with the private route tables that need S3 access.

## List VPC Endpoints

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'VpcEndpoints[].[VpcEndpointId,ServiceName,VpcEndpointType,State,PrivateDnsEnabled]' \
  --output table
```

Expected:

- Required endpoints exist.
- Interface endpoints are `available`.
- Private DNS is enabled where expected.
- S3 Gateway Endpoint exists.

Common endpoints include:

```text
sts
ssm
ssmmessages
logs
kms
secretsmanager
ec2
ecr.api
ecr.dkr
events
sns
sqs
config
securityhub
lambda
guardduty-data
s3
```

For the implemented Fargate runtime, private ECR pulls use the `ecr.api` and `ecr.dkr` Interface Endpoints, image layers use the existing S3 Gateway Endpoint, and GuardDuty Runtime Monitoring telemetry uses the Terraform-owned `guardduty-data` Interface Endpoint. `validate-vpc-endpoints.sh` requires the live Interface Endpoint ID map to exactly match Terraform and requires exactly one `guardduty-data` endpoint.

The automated validator treats the Interface Endpoint inventory as platform-owned and non-overridable. It requires exact endpoint-private subnet and shared Interface Endpoint SG placement for every Interface Endpoint, requires private DNS, and requires the S3 Gateway Endpoint route-table set to equal the union of endpoint-private, compute-private, and serverless-private route tables.

## Validate ECR Prerequisites

```bash
./scripts/validation/validate-ecr.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

The validator reads `ecr_repositories` from the workload root. An empty `{}` is a valid configuration and skips live ECR repository inspection; identity/Region prerequisites still apply. Configured repositories must match their Terraform name, ARN, and registry ID; use `IMMUTABLE` tags; use KMS encryption with a live key exactly equal to the workload-root `ecr_cmk_arn`; and have exactly one lifecycle rule that expires only untagged images older than 30 days. `validate-kms.sh` separately owns KMS alias/key inventory, key-state, customer-managed, and rotation checks.

## Validate ECS/Fargate Runtime

```bash
./scripts/validation/validate-ecs-runtime.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

The validator uses resource-backed workload outputs as the authoritative expected state. Empty `ecs_services = {}` is valid; the environment cluster is still validated and per-service/ALB checks are skipped.

For deployable services, validation covers Fargate launch type, compute-private placement, no public IP, exact task security group, resource-backed platform version, deployment circuit breaker/rollback, service steady state, completed primary rollout, separate task/execution roles, one essential service container, digest-pinned ECR image, TCP port mapping, and exact `awslogs` configuration.

Desired-count validation follows the canonical ownership contract: fixed services (`scaling = null`) must match Terraform `desired_count` exactly, while autoscaled services may differ from the bootstrap count but must remain within their configured minimum and maximum capacities.

For autoscaled services, the validator requires the exact Application Auto Scaling target inventory and exact target fields. It also requires the exact CPU, memory, and conditional ALB request-count target-tracking policies, including target values, cooldowns, predefined metric types, and the resource-backed ALB request resource label. `ALBRequestCountPerTarget` is valid only for ingress-enabled services.

The service's deployment `minimum_healthy_percent`, `maximum_percent`, and `health_check_grace_period_seconds` must match Terraform exactly. The health-check grace period is the task-startup interval during which ECS ignores unhealthy load-balancer, VPC Lattice, and container health checks.

Per-service application log groups must match the Terraform output, use `/aws/ecs/<name-prefix>/<service>`, use the effective retention period, and use the exact workload `logs_cmk_arn`.

Cluster validation also checks the exact Container Insights setting and, when enabled, the Terraform-owned performance log group `/aws/ecs/containerinsights/<cluster-name>/performance`, including exact resource identity, retention, and KMS encryption.

The same validator checks task-SG relationships to Interface Endpoints and the S3 prefix list, effective-mode HTTPS egress, database SG presence/absence, and conditional shared-ALB relationships. It validates Terraform-owned task-deficit alarms for deployable services when Container Insights is enabled and ingress unhealthy-target alarms for deployable ingress services. AWS-managed target-tracking alarms are not treated as Terraform operational alarms. Operational alarm state is interpreted as `OK` = pass, `INSUFFICIENT_DATA` = warning, and `ALARM` = failure.

Runtime Monitoring validation derives the expected state directly from `deployment_profile`. `production` and `development` require `GuardDutyManaged=true`; `minimal` requires `GuardDutyManaged=false`. The Terraform task definition must remain application-only even when GuardDuty injects a live agent.

For protected running tasks, live ECS must contain exactly one GuardDuty agent container and that agent must be `RUNNING`. AWS may report the agent as the exact name `aws-gd-agent` or as an AWS-generated name beginning `aws-guardduty-agent-`; both are valid. The canonical application container must remain valid and unexpected extra containers fail validation.

For an enabled protected cluster with running tasks, the GuardDuty coverage record must identify the expected ECS cluster, report Fargate `ManagementType = AUTO_MANAGED`, `CoverageStatus = HEALTHY`, and contain no unresolved Fargate or top-level issues. For `minimal`, a missing coverage record is valid; if one exists it must report Fargate `ManagementType = DISABLED`.

`validate-iam.sh` separately requires the exact regional `aws-guardduty-agent-fargate` repository pull scope for each protected service and rejects that scope for `minimal` or any broad/unexpected ECR authority. `validate-eventbridge.sh` verifies the GuardDuty Runtime coverage rule, its single SecOps SNS target, shared EventBridge DLQ, three retry attempts, 3600-second maximum age, and required coverage-status evidence fields.

ECS IAM assertions remain in `validate-iam.sh`. It verifies restricted task/execution trust, scoped execution-policy ECR/log/secret/parameter permissions, absence of `iam:PassRole`, initially empty application task-role authority, and exact `task_execution_kms_key_arns` behavior. If the configured KMS-key set is empty, the execution policy must not grant `kms:Decrypt`; if populated, live policy resources must match the configured set exactly.

### Production ECS acceptance and actual placement

For normal production, deployable fixed services require at least two tasks and autoscaled services a minimum of at least two. The runtime validator also requires minimum healthy percent 100, maximum percent at least 200, and AZ rebalancing `ENABLED`. Three configured AZs do not prove a running task in each; the sample's three-task selection is not a universal minimum.

Capture actual task placement for the selected service after steady state. This example is read-only, handles zero tasks explicitly, and batches `describe-tasks` requests. Set `SERVICE_KEY` to an entry in the **deployable** output map:

```bash
SERVICE_KEY="test"
CLUSTER_ARN="$(terraform -chdir="environments/${ENVIRONMENT}" output -json ecs_cluster | jq -er '.arn')" || exit 1
SERVICE_NAME="$(terraform -chdir="environments/${ENVIRONMENT}" output -json ecs_services | jq -er --arg key "${SERVICE_KEY}" '.[$key].name // empty')" || exit 1
TASKS_JSON="$(aws ecs list-tasks \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --cluster "${CLUSTER_ARN}" --service-name "${SERVICE_NAME}" \
  --desired-status RUNNING --output json)" || exit 1
TASK_LIST="$(jq -er '.taskArns | select(length > 0) | .[]' <<<"${TASKS_JSON}")" || {
  echo "No running tasks returned; no live placement evidence" >&2; exit 1;
}
mapfile -t TASK_ARNS <<<"${TASK_LIST}"
for ((i=0; i<${#TASK_ARNS[@]}; i+=100)); do
  aws ecs describe-tasks \
    --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
    --cluster "${CLUSTER_ARN}" --tasks "${TASK_ARNS[@]:i:100}" \
    --query '{Failures:failures,Tasks:tasks[].{Task:taskArn,Definition:taskDefinitionArn,AZ:availabilityZone,Status:lastStatus,Health:healthStatus,Platform:platformVersion}}' \
    --output json || exit 1
done
```

Require no API `Failures`, the expected task definition/status/count, and the AZ distribution required by the particular qualification. For the three-task/three-AZ scenario, record one running task in each selected AZ. The listing itself does not enforce those assertions or prove task replacement under failure.

For an ingress-enabled service, capture target health separately:

```bash
TARGET_GROUP_ARN="$(terraform -chdir="environments/${ENVIRONMENT}" output -json application_load_balancer | jq -er --arg key "${SERVICE_KEY}" '.target_groups[$key].arn // empty')" || exit 1
aws elbv2 describe-target-health \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --target-group-arn "${TARGET_GROUP_ARN}" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table
```

Compare the expected target membership and healthy count, not merely an empty command exit. ALB health checks are HTTP and the frontend is HTTPS. ECS application-container `UNKNOWN` can be accepted when no ECS-native health check is defined; it is not proof of an application transaction, SQL access, or end-to-end TLS.

With no deployable services, GuardDuty live coverage is not required. With no protected running tasks, protected healthy coverage is not required yet. Record those branches as not exercised rather than presenting a `16/16` result as live instrumentation evidence. Use the retirement-readiness gate, not normal production runtime acceptance, for deliberately zero-capacity retirement.

## Validate Application Publication and Release PR

For a controlled non-production service, verify the implemented release path:

- the service exists in `environments/<env>/container-workloads.auto.tfvars.json`;
- `image_digest = null` is accepted for a registered-but-unreleased service and the service-required ECR repository remains present;
- `Deploy Application` resolves repository/platform from tracked canonical configuration;
- the publisher job assumes the expected branch-trusted Image Publisher role;
- Docker push uses the required ECR credential helper, temporary push-only Docker configuration and disabled helper token-file cache; the old unencrypted `docker login` path is not used;
- the image digest recorded in publication metadata matches the authoritative ECR digest;
- the release/PR job has no AWS credentials and changes only the selected service digest;
- the generated release PR is reviewed and merged by an authorized human;
- `Terraform Apply` is invoked separately and applies its own exact reviewed saved plan;
- the ECS service converges to steady state; and
- workload baseline validation/evidence is run separately after convergence.

Successful image publication alone is not proof of application deployment.

A bootstrap IAM pass does not exercise Docker authentication on the runner. Retain a separate post-change publication run; absence of a warning alone is not proof that every credential store or historical token was removed.

## Validate Endpoint Private Subnets

```bash
aws ec2 describe-subnets \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-*" \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch]' \
  --output table
```

Expected:

- Endpoint private subnets exist in each configured Availability Zone.
- Endpoint private subnets use the expected CIDR ranges.
- `MapPublicIpOnLaunch` is `false`.

---

## Validate Interface Endpoint Subnet Placement

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=vpc-endpoint-type,Values=Interface" \
  --query 'VpcEndpoints[].[ServiceName,State,SubnetIds]' \
  --output table
```

Expected:

- Interface Endpoints are deployed into endpoint private subnets.
- Interface Endpoint state is `available`.
- Interface Endpoint subnet IDs match the dedicated endpoint private subnet IDs.

---

## Validate Endpoint Private Route Tables

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Endpoint-Private-RT-*" \
  --query 'RouteTables[].[Tags[?Key==`Name`]|[0].Value,RouteTableId,Routes]' \
  --output json
```

Expected:

- Endpoint private route tables exist.
- Endpoint private route tables are associated with endpoint private subnets.
- No `0.0.0.0/0` default route is required.
- Route tables should contain the implicit local VPC route.

---

## Validate S3 Gateway Endpoint Route Tables

```bash
aws ec2 describe-vpc-endpoints \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=service-name,Values=com.amazonaws.${AWS_REGION}.s3" \
  --query 'VpcEndpoints[0].RouteTableIds' \
  --output table
```

Expected:

- S3 Gateway Endpoint exists.
- Route table IDs include the private route tables intentionally passed to the VPC endpoints module.
- The S3 association set must equal the union of endpoint-private, compute-private, and serverless-private route tables. Mere inclusion of some compute/serverless tables is insufficient.

---

## Validate Endpoint DNS from Instance

Run from inside an SSM session:

```bash
export AWS_REGION="us-east-1"
getent hosts sts.${AWS_REGION}.amazonaws.com
getent hosts ssm.${AWS_REGION}.amazonaws.com
getent hosts secretsmanager.${AWS_REGION}.amazonaws.com
getent hosts logs.${AWS_REGION}.amazonaws.com
getent hosts kms.${AWS_REGION}.amazonaws.com
```

Expected:

- Commands return private RFC1918 IPs where interface endpoints and Private DNS are used.

---

## Validate 443 Connectivity to AWS Services

Run from inside an SSM session:

```bash
export AWS_REGION="us-east-1"
for h in sts ssm secretsmanager logs kms; do
  host="${h}.${AWS_REGION}.amazonaws.com"
  timeout 3 bash -c "cat < /dev/null > /dev/tcp/${host}/443" \
    && echo "OK  ${host}:443" || echo "FAIL ${host}:443"
done
```

Expected:

- The tested service hostnames accept TCP/443 connections. This does not prove API authorization or a successful service operation.

---

# 8. Validate Controlled Egress

## Purpose

Confirm that outbound traffic behaves according to the selected `deployment_profile` and effective `egress_mode`.

The baseline supports three egress modes:

| `egress_mode` | Network Firewall | NAT Gateway | Compute private default route |
|---|---:|---:|---|
| `network_firewall` | Yes | Yes | Network Firewall endpoint |
| `nat_only` | No | Yes | NAT Gateway |
| `vpc_endpoints_only` | No | No | No default route |

## Check Route Tables

Use `validate-networking.sh` for exact same-AZ identities/associations. These manual listings support review; a matching default-route type without the correct AZ-local target is not enough. Ingress-public must have its IGW default and no compute-to-firewall return override; that override belongs only to the matching egress-public NAT route table. Data, endpoint and serverless private route tables have no general internet default route.

Run from your local CLI:

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].[RouteTableId,Routes]' \
  --output json
```

Expected:

- Private subnet routes follow the intended egress path.
- Workloads do not route directly to the Internet Gateway.
- If Network Firewall is enabled, private egress routes should pass through firewall endpoints before NAT/IGW.
- If `nat_only` is enabled, compute private route tables should route `0.0.0.0/0` to NAT Gateway.
- If `vpc_endpoints_only` is enabled, compute private route tables should not have a `0.0.0.0/0` route.

---

## Check Network Firewall Presence

```bash
aws network-firewall list-firewalls \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Firewalls[?contains(FirewallName, `'"${NAME_PREFIX}"'`)].[FirewallName,FirewallArn]' \
  --output table
```

Expected:

- `network_firewall`: matching firewall exists.
- `nat_only`: no matching firewall exists.
- `vpc_endpoints_only`: no matching firewall exists.

---

## Check NAT Gateway Presence

```bash
aws ec2 describe-nat-gateways \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filter "Name=vpc-id,Values=${VPC_ID}" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId,NatGatewayAddresses[0].PublicIp]' \
  --output table
```

Expected:

- `network_firewall`: NAT Gateways exist and are `available`.
- `nat_only`: NAT Gateways exist and are `available`.
- `vpc_endpoints_only`: no NAT Gateways are expected.

Compare current NAT IDs and their same-AZ egress-public subnets with `network_topology`. The automated NAT inventory includes `pending` as well as `available`; a separate manual availability check matters before treating egress as usable.

---

## Check Compute Private Default Routes

```bash
aws ec2 describe-route-tables \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Name,Values=${NAME_PREFIX}-Compute-Private-RT-*" \
  --query 'RouteTables[].{Name:Tags[?Key==`Name`]|[0].Value,Routes:Routes[?DestinationCidrBlock==`0.0.0.0/0`]}' \
  --output json
```

Expected:

- `network_firewall`: default route points to a Network Firewall endpoint.
- `nat_only`: default route points to a NAT Gateway.
- `vpc_endpoints_only`: no default route is present.

---

## Optional Internet Egress Test

Run from inside an SSM session:

```bash
timeout 5 bash -c "cat < /dev/null > /dev/tcp/example.com/443" \
  && echo "TCP connection succeeded" || echo "TCP connection did not complete"
```

Expected result depends on your egress design:

- If `network_firewall` or `nat_only` is enabled, internet access may succeed depending on route tables, firewall policy, and security group rules.
- If using `vpc_endpoints_only`, internet egress should fail.

A TCP handshake is not an HTTP-host/TLS-SNI allowlist test, and a failed connection can have causes other than correct isolation. For firewall behavioral evidence, use an approved application-layer request to a reviewed allowed destination and a separately approved non-allowlisted destination, record expected and observed results, and correlate firewall logs. Do not change the allowlist merely to make a test pass.

---

# 9. Validate Logging

## Purpose

Confirm that logging resources exist and receive data.

---

## 9.1 Validate CloudTrail

```bash
aws cloudtrail describe-trails \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'trailList[].[Name,TrailARN,LogFileValidationEnabled,IsMultiRegionTrail]' \
  --output table
```

Check logging status:

```bash
TRAIL_NAME="<EXACT-REVIEWED-BASELINE-TRAIL-ARN>"
# Select the trail belonging to this workload; never the first account-wide result.

aws cloudtrail get-trail-status \
  --name "${TRAIL_NAME}" \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- CloudTrail exists.
- Logging is enabled.
- Log file validation is enabled if configured.
- Trail delivers to the centralized logs bucket.

---

## 9.2 Validate Centralized Logs Bucket

```bash
aws s3api list-buckets \
  --profile "${AWS_PROFILE}" \
  --query "Buckets[?contains(Name, 'logs')].Name" \
  --output table
```

For the target logs bucket:

```bash
aws s3api get-bucket-encryption \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"

aws s3api get-bucket-versioning \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"

aws s3api get-object-lock-configuration \
  --bucket "${CENTRALIZED_LOGS_BUCKET_NAME}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- Bucket exists.
- Encryption is enabled.
- Versioning is enabled.
- The baseline sets Object Lock disabled, `force_destroy=true`, and `prevent_destroy=false` on this workload logs bucket. An absent Object Lock configuration is an implementation limitation, not evidence of immutable storage. Do not treat lifecycle retention as a guarantee that logs survive workload teardown.

---

## 9.3 Validate VPC Flow Logs

```bash
aws ec2 describe-flow-logs \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'FlowLogs[].[FlowLogId,ResourceId,FlowLogStatus,LogDestinationType,LogDestination]' \
  --output table
```

Expected:

- Flow logs exist.
- Status is `ACTIVE`.
- Destination is the expected logs destination.

---

## 9.4 Validate CloudWatch Log Retention

```bash
aws logs describe-log-groups \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'logGroups[?contains(logGroupName, `'"${NAME_PREFIX}"'`) || contains(logGroupName, `/aws/lambda/`) || contains(logGroupName, `/aws/cloudtrail/`) || contains(logGroupName, `/aws/vpc-flow-logs/`)].[logGroupName,retentionInDays]' \
  --output table
```

Expected:

- Relevant baseline log groups have retention configured.
- `production` defaults to 90 days unless overridden.
- `development` defaults to 30 days unless overridden.
- `minimal` defaults to 14 days unless overridden.

---

# 10. Validate Security Services

## Purpose

Confirm that workload-local security controls are active and that centrally governed services have the expected administrator relationship.

The preferred check is:

```bash
./scripts/validation/validate-security-workload.sh "${ENVIRONMENT:?Select dev, staging, or prod}"
```

That script reads these effective ownership outputs before deciding which AWS state is expected:

```text
effective_manage_guardduty_locally
effective_manage_securityhub_cspm_locally
effective_manage_securityhub_v2_locally
```

For the centrally governed workload environments, those values are expected to be `false`.

## 10.1 GuardDuty

When GuardDuty is centrally governed, the workload account should have an enabled detector/member state associated with the `security-operations` delegated administrator; organization feature policy is validated from the security-operations account rather than recreated locally.

The centralized Runtime Monitoring contract is:

```text
RUNTIME_MONITORING           = ALL
ECS_FARGATE_AGENT_MANAGEMENT = ALL
EC2_AGENT_MANAGEMENT         = ALL
EKS_ADDON_MANAGEMENT         = NONE
```

`validate-security-operations.sh` compares the Terraform-managed organization feature subset exactly with live AWS. AWS may return other supported organization features that Terraform does not manage; those are allowed only when the feature and every additional configuration are disabled with `NONE`. Any unmanaged enabled feature fails validation.

Workload-level ECS enrollment, agent IAM/networking, injected-agent state, and coverage health remain workload validation responsibilities.

## 10.2 Security Hub CSPM and Security Hub V2

When Security Hub CSPM is centrally governed, the member account should resolve to the `security-operations` administrator and receive its configuration policy from central governance. Do not infer central-policy health solely from a local `get-enabled-standards` command.

Security Hub V2 workload enablement is likewise governed by the Organizations `SECURITYHUB_POLICY`; validate its direct `Workloads` attachment and effective workload policy from the security-operations evidence layer.

## 10.3 AWS Config

```bash
aws configservice describe-configuration-recorders \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"

aws configservice describe-configuration-recorder-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}"
```

Expected:

- If `effective_enable_config = true`, the configuration recorder exists and is recording.
- If `effective_enable_config = false`, Config resources may be absent or disabled.
- Centrally associated Security Hub CSPM standards depend on Config being available in workload accounts where those controls require it.

## 10.4 Inspector

```bash
aws inspector2 batch-get-account-status \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --account-ids "${ACCOUNT_ID}" \
  --query 'accounts[0].{AccountStatus:state.status,EC2:resourceState.ec2.status,ECR:resourceState.ecr.status,Lambda:resourceState.lambda.status,LambdaCode:resourceState.lambdaCode.status,CodeRepository:resourceState.codeRepository.status}' \
  --output table
```

Expected:

- If `effective_inspector_enabled = true`, Inspector status exactly matches `effective_inspector_resource_types`, including EC2, ECR, Lambda, Lambda code, and code-repository scanning.
- If disabled by profile or override, Inspector may report disabled resource states.

The validator uses the effective Terraform output and does not infer ECR from the repository map. The baseline and workload roots propagate `local.effective_inspector_resource_types`, so automatic ECR inclusion is validated through that authoritative effective output.

ECS runtime service identities, role maps, task SGs, and conditional ALB metadata are validated by `validate-ecs-runtime.sh` and `validate-iam.sh`. The runtime validator uses workload-root `ecs_service_configuration` to prove database SG relationships are present when `database_access = true` and absent when it is false. IAM and security-policy readiness IDs remain internal dependency inputs rather than public validator outputs. ECR repository keys are not used as substitutes for ECS service identities.

---

# 11. Validate KMS

## Purpose

Confirm that KMS keys exist for key platform functions.

```bash
aws kms list-aliases \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "Aliases[?contains(AliasName, '${CLOUD_NAME}')].[AliasName,TargetKeyId]" \
  --output table
```

Expected aliases may include keys for:

```text
state
logs
lambda
ebs
backup_vault
secrets_manager
ecr
```

Note:

The Backup CMK and `backup-cmk` alias are retained regardless of `effective_backup_enabled` because the environment backup vault is also retained when scheduled backups are disabled.

---

# 12. Validate SNS, SQS, and Notification DLQs

`validate-sqs.sh` reports approximate queue depths and redrive configuration; it does not fail merely because a reported DLQ depth is nonzero. It accepts configured SSE-KMS or SQS-managed encryption and does not prove exact key identity or every redrive/policy setting. Distinguish configured design expectations below from the assertions that actually block the script.

## Purpose

Confirm that security and compliance notification paths are deployed, encrypted, subscribed, and protected with the expected DLQs.

Most of this validation is automated by:

```bash
./scripts/validation/validate-sns.sh "${ENVIRONMENT}"
./scripts/validation/validate-sqs.sh "${ENVIRONMENT}"
./scripts/validation/validate-eventbridge.sh "${ENVIRONMENT}"
```

These scripts should be the primary validation path. The commands below are useful for spot checks, troubleshooting, or manual release review.

---

## 12.1 Validate SNS Topics and Subscriptions

List expected notification topics:

```bash
aws sns list-topics \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'Topics[?contains(TopicArn, `security-notifications`) || contains(TopicArn, `compliance-notifications`)].TopicArn' \
  --output table
```

Expected topics:

```text
${NAME_PREFIX}-security-notifications
${NAME_PREFIX}-compliance-notifications
```

For each expected topic, check attributes and subscriptions:

```bash
aws sns get-topic-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "<SNS_TOPIC_ARN>" \
  --query 'Attributes.{TopicArn:TopicArn,KmsMasterKeyId:KmsMasterKeyId,SubscriptionsConfirmed:SubscriptionsConfirmed,SubscriptionsPending:SubscriptionsPending}' \
  --output table

aws sns list-subscriptions-by-topic \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --topic-arn "<SNS_TOPIC_ARN>" \
  --query 'Subscriptions[].[Protocol,Endpoint,SubscriptionArn]' \
  --output table
```

Expected:

- SNS topics are encrypted with the logs CMK.
- The compliance topic has an SQS subscription to the compliance queue.
- The security notifications topic has expected email subscriptions and an SQS subscription to the security notifications queue.
- Confirmed subscriptions show real subscription ARNs.
- Unconfirmed email subscriptions show `PendingConfirmation`.

---

## 12.2 Validate SQS Notification Queues and DLQs

List environment queues:

```bash
aws sqs list-queues \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name-prefix "${NAME_PREFIX}" \
  --output table
```

Expected queues include:

```text
${NAME_PREFIX}-compliance-queue
${NAME_PREFIX}-security-notifications-queue
${NAME_PREFIX}-security-notifications-dlq
${NAME_PREFIX}-security-notifications-eventbridge-dlq
${NAME_PREFIX}-ec2-isolation-dlq
${NAME_PREFIX}-ec2-rollback-dlq
${NAME_PREFIX}-ip-enrichment-dlq
```

Meaning:

| Queue | Purpose |
|---|---|
| `compliance-queue` | Durable compliance notification subscriber |
| `security-notifications-queue` | Durable security notification subscriber |
| `security-notifications-dlq` | Redrive DLQ for repeated processing failures from the security notifications queue |
| `security-notifications-eventbridge-dlq` | EventBridge target DLQ for failed EventBridge deliveries to the security notifications SNS topic |
| `ec2-isolation-dlq` | EC2 Isolation automation failure-retention queue |
| `ec2-rollback-dlq` | EC2 Rollback automation failure-retention queue |
| `ip-enrichment-dlq` | IP Enrichment automation failure-retention queue |

Check queue attributes:

```bash
QUEUE_URL="$(aws sqs get-queue-url \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name "${NAME_PREFIX}-security-notifications-queue" \
  --query 'QueueUrl' \
  --output text)"

aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names All \
  --query 'Attributes.{QueueArn:QueueArn,KmsMasterKeyId:KmsMasterKeyId,RedrivePolicy:RedrivePolicy,Messages:ApproximateNumberOfMessages,NotVisible:ApproximateNumberOfMessagesNotVisible}' \
  --output json
```

Expected:

- `KmsMasterKeyId` is configured.
- Security notifications queue has a redrive policy to `security-notifications-dlq`.
- Queue policy allows the security notifications SNS topic to send messages.
- Visible messages may accumulate if no downstream consumer is configured.
- DLQ visible message counts should normally be `0`.

---

## 12.3 Validate EventBridge Notification DLQ

Check the shared EventBridge DLQ for security notification delivery failures:

```bash
EVENTBRIDGE_DLQ_URL="$(aws sqs get-queue-url \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name "${NAME_PREFIX}-security-notifications-eventbridge-dlq" \
  --query 'QueueUrl' \
  --output text)"

aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${EVENTBRIDGE_DLQ_URL}" \
  --attribute-names All \
  --query 'Attributes.{QueueArn:QueueArn,KmsMasterKeyId:KmsMasterKeyId,Policy:Policy,Messages:ApproximateNumberOfMessages,NotVisible:ApproximateNumberOfMessagesNotVisible}' \
  --output json
```

Expected:

- `KmsMasterKeyId` is configured.
- Queue policy allows `events.amazonaws.com` to send messages from expected EventBridge rule ARNs.
- Visible message count is normally `0`.

---

## 12.4 Validate Notification DLQ Alarms

Check CloudWatch alarms related to notification DLQs:

```bash
aws cloudwatch describe-alarms \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --alarm-name-prefix "${NAME_PREFIX}" \
  --query 'MetricAlarms[?contains(AlarmName, `DLQ`) || contains(AlarmName, `dlq`)].[AlarmName,StateValue,MetricName,Namespace]' \
  --output table
```

Expected alarms include:

```text
${NAME_PREFIX}-security-notifications-dlq-visible-messages
${NAME_PREFIX}-Security-Notifications-EventBridge-DLQ-Messages
```

Automation workflow DLQ alarms may also appear depending on module configuration.

---

## 12.5 DLQ Operational Follow-Up

DLQs are terminal failure-retention queues. They retain failed events for review and do not automatically replay messages.

If a DLQ alarm fires:

1. Identify which DLQ has visible messages.
2. Capture approximate visible/not-visible counts and, separately, available CloudWatch oldest-message age.
3. Review recent CloudWatch alarm state changes.
4. Only with operational approval, receive one message without deleting it; this changes its visibility/receive state.
5. Determine whether the failure is caused by EventBridge delivery, SNS/SQS policy, KMS permissions, Lambda processing, or downstream consumer behavior.
6. Fix the underlying issue.
7. Replay, archive, or discard the message only after review.

Inspect queue counts:

Choose the intended DLQ explicitly; do not reuse the primary security-notifications queue URL from an earlier example. For this example:

```bash
QUEUE_URL="${EVENTBRIDGE_DLQ_URL:?Resolve the intended EventBridge DLQ URL first}"
```

`ApproximateAgeOfOldestMessage` is an `AWS/SQS` CloudWatch metric, not an attribute accepted by `get-queue-attributes`. Query only supported queue attributes below. For age, inspect the CloudWatch metric with the intended `QueueName`, period and time window; missing metrics are not proof of zero age.

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --output table
```

The next command is an **approved stateful inspection**, not a read-only check. Receiving a message temporarily hides it and affects receive state even without deletion; coordinate with consumers and protect the returned body/receipt handle. Inspect at most one message:

```bash
aws sqs receive-message \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --max-number-of-messages 1 \
  --visibility-timeout 30 \
  --attribute-names All \
  --message-attribute-names All \
  --output json
```

Do not delete the message until the failure has been understood and the operator has decided whether to replay, archive, or discard it.

For `security-notifications-eventbridge-dlq`, check:

- EventBridge target exists and points to the security notifications SNS topic.
- EventBridge target has the expected DLQ and retry policy.
- Security notifications SNS topic exists.
- SNS topic policy allows the source EventBridge rule ARN to publish.
- EventBridge DLQ queue policy allows the source EventBridge rule ARN to send messages.
- KMS permissions allow encrypted SNS/SQS delivery.

For `security-notifications-dlq`, check:

- Whether a downstream consumer is configured.
- Consumer logs, permissions, timeouts, and parsing errors.
- Message schema compatibility.
- Queue redrive policy and max receive count.
- KMS permissions for the consumer.

Messages in the primary compliance or security notification queues may accumulate when no downstream consumer is configured. Messages in a DLQ should be treated as a failure signal.

# 13. Validate EventBridge Rules

## Purpose

Confirm that EventBridge rules exist for security automation across all expected event buses.

Check the default bus:

```bash
aws events list-rules \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --event-bus-name default \
  --query 'Rules[].[Name,State,EventBusName]' \
  --output table
```

Expected rules may include:

- Amazon Inspector rules, if enabled
- Security Hub finding routing, including HIGH/CRITICAL events where configured
- Tamper detection
- Break-glass detection (`break-glass-admin-assumed`)
- EC2 isolation trigger (`${NAME_PREFIX}-securityhub-ec2-high-critical`), which receives only `HIGH`/`CRITICAL`, `NEW`, `ACTIVE` GuardDuty findings for `AwsEc2Instance`; the Lambda independently revalidates GuardDuty product and applies the configured `ec2_auto_isolation_severities` set (default `CRITICAL`)
- GuardDuty ECS Runtime coverage status (`${NAME_PREFIX}-guardduty-ecs-runtime-coverage`), matching both `GuardDuty Runtime Protection Unhealthy` and `GuardDuty Runtime Protection Healthy` for ECS resources in the workload account

Validate `secops` custom event bus:

```bash
aws events list-event-buses \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query 'EventBuses[].[Name,Arn]' \
  --output table
```

Expected:

```text
default
secops-bus
```

Check the customer `SecOps` bus:

```bash
aws events list-rules \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --event-bus-name "${CLOUD_NAME}-${ENVIRONMENT}-secops-bus" \
  --query 'Rules[].[Name,State,EventBusName]' \
  --output table
```

Expected rules may include:

- EC2 Rollback

Confirm EventBridge targets and target DLQs:

```bash
aws events list-targets-by-rule \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --rule "${CLOUD_NAME}-${ENVIRONMENT}-securityhub-high-critical" \
  --event-bus-name default \
  --query 'Targets[].{Id:Id,Arn:Arn,DLQ:DeadLetterConfig.Arn,MaxAttempts:RetryPolicy.MaximumRetryAttempts,MaxAge:RetryPolicy.MaximumEventAgeInSeconds}' \
  --output table
```

Expected targets may include:

- `IpEnrichmentLambda`
- `sec-hub-to-secops-sns`

Expected:

- Security notification SNS targets use the shared `security-notifications-eventbridge-dlq`.
- Automation Lambda targets use workflow-specific DLQs.
- Protected EventBridge targets use retry attempts of `3`.
- Protected EventBridge targets use max event age of `3600` seconds.
- The GuardDuty ECS Runtime coverage rule has exactly one target with ID `guardduty-ecs-runtime-coverage-to-secops-sns`.
- That target points to the Terraform SecOps SNS topic, uses the shared EventBridge DLQ, and preserves account, Region, cluster, current/previous status, issue, GuardDuty update time, and event time through the input transformer.

The EC2 isolation and IP-enrichment rules are intentionally different. `${NAME_PREFIX}-securityhub-ec2-high-critical` is GuardDuty- and EC2-scoped for automatic isolation. `${NAME_PREFIX}-securityhub-high-critical` remains the broader HIGH/CRITICAL Security Hub rule used by IP enrichment and the SecOps SNS notification target.

---

# 14. Validate Lambda Functions

## Purpose

Confirm that Lambda automation functions exist. `list-functions` is an inventory read, not a complete function-state response; use a per-function configuration read for `State` and update status.

```bash
aws lambda list-functions \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --query "Functions[?contains(FunctionName, '${CLOUD_NAME}-${ENVIRONMENT}')].[FunctionName,Runtime]" \
  --output table
```

Expected functions include:

```text
ec2-isolation
ec2-rollback
ip-enrichment
```

Resolve the full approved function name from that inventory, then inspect selected non-secret configuration fields (do not dump environment-variable values into public evidence):

```bash
FUNCTION_NAME="<EXACT-WORKLOAD-FUNCTION-NAME>"
aws lambda get-function-configuration \
  --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
  --function-name "${FUNCTION_NAME}" \
  --query '{Name:FunctionName,Runtime:Runtime,State:State,StateReasonCode:StateReasonCode,LastUpdateStatus:LastUpdateStatus,Role:Role,Timeout:Timeout,MemorySize:MemorySize,KMSKeyArn:KMSKeyArn}' \
  --output json
```

Expect the applied function to be active and its update to have completed; a populated inventory row is not equivalent to a successful invocation.

Then run the detailed Lambda test docs:

```text
docs/lambda_tests/ec2_isolation.md
docs/lambda_tests/ec2_rollback.md
docs/lambda_tests/ip_enrichment.md
```

---

# 15. Validate EC2 Isolation and Rollback

## Purpose

Confirm that automated containment and controlled rollback work end-to-end.

## EC2 Isolation

Follow:

```text
docs/lambda_tests/ec2_isolation.md
```

Expected:

- A `CRITICAL`, `NEW`, `ACTIVE` GuardDuty finding for an `AwsEc2Instance` isolates an eligible development instance by default.
- A non-GuardDuty Security Hub finding does not enter the EC2 isolation EventBridge path and is also rejected by direct Lambda revalidation.
- A `HIGH` GuardDuty finding is skipped by the Lambda unless the canonical `ec2_auto_isolation_severities` configuration explicitly includes `HIGH`; the secure default is `CRITICAL` only.
- Any otherwise eligible instance is skipped while `IsolationAllowed=false`; verify the actual tag rather than assuming staging/production opt out automatically.
- Attached EBS snapshots are requested before the quarantine security group is applied.
- Isolation evidence tags are added while `IsolationAllowed` remains Terraform-managed.
- A routine Terraform plan does not attempt to restore the normal security group or remove active isolation evidence.
- SNS notification is sent after successful isolation.

## EC2 Rollback

Follow:

```text
docs/lambda_tests/ec2_rollback.md
```

Expected:

- SecOps-Operator can submit rollback event.
- Rollback Lambda restores original security groups.
- SNS notification is sent.

---

# 16. Validate IP Enrichment

## Purpose

Confirm that Security Hub findings containing public IPs are enriched.

Follow:

```text
docs/lambda_tests/ip_enrichment.md
```

Expected:

- Public IPv4 and IPv6 addresses are extracted.
- AbuseIPDB enrichment succeeds.
- SNS notification is sent.
- Security Hub writeback occurs if enabled and valid finding IDs are used.

---

# 17. Validate Tamper Detection

## Purpose

Confirm that attempts to modify or disable protected security services generate alerts.

Tamper detection monitors actions defined in:

```text
modules/security/tamper_detection/main.tf
```

Examples may include attempts to modify or disable:

- CloudTrail
- GuardDuty
- Security Hub
- AWS Config
- KMS

## Controlled CloudTrail Test

This test deliberately interrupts a security control. Run it only in an approved non-production environment (or a separately approved production change window), with a recovery operator and a verified exact workload trail. It is not part of the read-only suite. Do not choose `trailList[0]`, which can target an unrelated or organization trail.

First set the reviewed ARN and verify that logging is currently enabled:

```bash
TRAIL_NAME="<EXACT-REVIEWED-BASELINE-TRAIL-ARN>"
: "${AWS_PROFILE:?Set the approved test profile}"
: "${AWS_REGION:?Set the test service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the approved account ID}"
CALLER_ACCOUNT="$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query Account --output text)" || exit 1
[[ "${CALLER_ACCOUNT}" == "${EXPECTED_ACCOUNT_ID}" ]] || exit 1
aws cloudtrail get-trail-status \
  --name "${TRAIL_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}"
```

Confirm `IsLogging=true` and that the ARN belongs to the approved test. Execute the following as a separate authorized step; it restarts logging immediately instead of leaving it stopped while waiting for an alert:

```bash
(
  set -euo pipefail
  restore_logging() {
    aws cloudtrail start-logging \
      --name "${TRAIL_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}"
  }
  # Best-effort recovery on ordinary shell exit; not a guarantee under SIGKILL,
  # lost connectivity, expired credentials, or an AWS service failure.
  trap restore_logging EXIT
  aws cloudtrail stop-logging \
    --name "${TRAIL_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}"
  restore_logging
  trap - EXIT
  aws cloudtrail get-trail-status \
    --name "${TRAIL_NAME}" --region "${AWS_REGION}" --profile "${AWS_PROFILE}" \
    --query 'IsLogging' --output json
)
```

Require logging to be restored and verify delivery resumes. If restoration cannot be confirmed, stop the test and escalate to the recovery operator; do not report success. Separately record the matching CloudTrail/API event, EventBridge rule/target behavior and received SNS notification. Event arrival is asynchronous; a configured rule alone is not delivery evidence. Inspect the exact tamper-event pattern in `modules/security/tamper_detection/main.tf` before selecting a test.

---

# 18. Validate Break-Glass Monitoring

## Purpose

Confirm that use of the break-glass role generates an alert.

If safe to test, use one of the principal ARNs included in the `break_glass_trusted_principal_arns` variable to assume or simulate use of the configured break-glass role.

The IAM-user example below requires a trusted MFA-capable caller and a matching role trust policy. It is not a universal Identity Center/federated-role login recipe. A simulation or trust-policy read does not prove a live role assumption generated an alert.

Confirm your account is configured with an MFA device:

```bash
aws iam list-mfa-devices \
  --user-name baseline-admin \
  --profile "${AWS_PROFILE}" \
  --query 'MFADevices[].[SerialNumber,EnableDate]' \
  --output table
```

Expected output:

```text
arn:aws:iam::<ACCOUNT_ID>:mfa/<DEVICE_NAME>
```

Then set the MFA serial:

```bash
export MFA_SERIAL="$(aws iam list-mfa-devices \
  --user-name baseline-admin \
  --profile "${AWS_PROFILE}" \
  --query 'MFADevices[0].SerialNumber' \
  --output text)"
```

Assume the `BreakGlass-Admin` role, replacing `<MFA_CODE>` with the six digit code from your authentication device:

```bash
export BREAK_GLASS_ROLE_ARN="<EXACT-REVIEWED-BREAK-GLASS-ROLE-ARN>"
# Verify the approved target role/account; do not select the first substring match.

aws sts assume-role \
  --role-arn "${BREAK_GLASS_ROLE_ARN}" \
  --role-session-name "break-glass-validation-test" \
  --serial-number "${MFA_SERIAL}" \
  --token-code "<MFA_CODE>" \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --query '{AssumedRoleArn:AssumedRoleUser.Arn,Expiration:Credentials.Expiration}' \
  --output json
```

Expected output contains only the assumed-role identity and expiration, not the temporary access key, secret or session token:

```json
{
  "AssumedRoleArn": "arn:aws:sts::<ACCOUNT_ID>:assumed-role/<ROLE_NAME>/break-glass-validation-test",
  "Expiration": "<EXPIRATION-TIME>"
}
```

This call still obtains credentials inside the AWS CLI; the projection only keeps them out of displayed evidence. Do not enable shell tracing or AWS CLI debug logging for this test, and do not publish MFA codes or credential responses.

Expected behavior after assuming the role:

- CloudTrail records the role assumption.
- EventBridge rule matches the activity.
- Break-Glass SNS alert is sent.

If testing role assumption is not appropriate, validate that:

- Break-glass role exists.
- EventBridge rule exists.
- SNS target is configured.
- CloudTrail is logging management events.

---

# 19. Validate Backup and Patch Management

## Purpose

Confirm RDS resilience, the profile-aware AWS Backup contract, configured Restore Testing and patch-management resources. Keep configuration checks separate from executed failover/recovery and application/cleanup evidence.

## AWS Backup

Use the dedicated validator as the authoritative automated check:

```bash
./scripts/validation/validate-backup.sh "${ENVIRONMENT}"
```

Review the effective Terraform state first:

```bash
terraform -chdir="environments/${ENVIRONMENT}" output effective_backup_enabled
terraform -chdir="environments/${ENVIRONMENT}" output -json | jq '{
  effective_backup_enabled: .effective_backup_enabled.value,
  effective_backup_schedule: (.effective_backup_schedule.value // null),
  effective_delete_backups_after_days: (.effective_delete_backups_after_days.value // null)
}'
```

Terraform may omit a root output from `terraform output -json` when its evaluated value is `null`. `validate-backup.sh` accounts for that behavior for the disabled schedule and retention outputs.

The environment backup vault is retained regardless of scheduled-backup enablement and must remain encrypted with the workload Backup CMK.

### Expected when backups are enabled

- `effective_backup_enabled = true`.
- `effective_backup_schedule` is a non-empty AWS Backup schedule expression.
- `effective_delete_backups_after_days` is a positive integer.
- The environment backup vault exists and is KMS-encrypted.
- Exactly one environment backup plan exists.
- The plan contains the `daily-backups` rule.
- Rule schedule and retention exactly match the effective Terraform outputs.
- Exactly one backup selection exists and selects `<backup_tag_key> = "true"`.
- Environment EC2 and RDS resources use `Backup=true`.
- Recovery points and recent backup-job health are reported by the validator.

Profile defaults are:

```text
production -> enabled, cron(0 5 * * ? *), 30 days
```

If backup is explicitly enabled for `development` or `minimal`, the default schedule remains `cron(0 5 * * ? *)` and retention defaults to 7 days unless overridden.

### Expected when backups are disabled

- `effective_backup_enabled = false`.
- Effective backup schedule and retention resolve to `null`.
- The encrypted environment backup vault remains present.
- No environment backup plan exists.
- No backup selection exists.
- Environment EC2 and RDS resources use `Backup=false`.

`development` and `minimal` disable scheduled backups by default. Disabled scheduling does **not** mean the backup vault or Backup CMK should be absent.

## RDS Resilience and Restore Testing Evidence

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

A `validate-backup.sh` PASS may therefore coexist with an unexecuted restore, failed application validation, or unresolved cleanup. Keep the raw log and record the reviewer's recovery/cleanup acceptance separately. See the [Backup module](../modules/backup/README.md), [storage reference](../modules/storage/README.md), and [evidence guide](assurance/validation-evidence-guide.md).

### Scoped read-only RDS inspection

Read the resource-backed identifier first, then inspect only that DB instance. The fields below include operator spot checks beyond the automated RDS equality subset; their presence in this command does not add them to `validate-backup.sh`:

```bash
RDS_CONFIG_JSON="$(terraform -chdir="environments/${ENVIRONMENT}" output -json rds_configuration)" || exit 1
RDS_IDENTIFIER="$(jq -er '.identifier' <<<"${RDS_CONFIG_JSON}")" || exit 1
aws rds describe-db-instances \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --db-instance-identifier "${RDS_IDENTIFIER}" \
  --query 'DBInstances[].{Identifier:DBInstanceIdentifier,ARN:DBInstanceArn,Status:DBInstanceStatus,Engine:Engine,Version:EngineVersion,Class:DBInstanceClass,AZ:AvailabilityZone,SecondaryAZ:SecondaryAvailabilityZone,MultiAZ:MultiAZ,SubnetGroup:DBSubnetGroup.DBSubnetGroupName,SecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId,DeletionProtection:DeletionProtection,BackupRetention:BackupRetentionPeriod,Public:PubliclyAccessible,Encrypted:StorageEncrypted}' \
  --output json
```

Normal production expects enforced Multi-AZ and native deletion protection; retirement deliberately relaxes deletion protection while preserving final-snapshot and automated-backup intent. A DB subnet-group name comparison is not a live exact member-subnet comparison. Retain separate subnet-group membership evidence when the qualification requires it.

### Restore execution and cleanup record

When `restore_testing.enabled` is true, query jobs for that exact plan:

```bash
RESTORE_JSON="$(terraform -chdir="environments/${ENVIRONMENT}" output -json restore_testing)" || exit 1
RESTORE_PLAN_ARN="$(jq -er 'select(.enabled == true) | .plan.arn' <<<"${RESTORE_JSON}")" || {
  echo "No enabled Restore Testing plan in applied output" >&2; exit 1;
}
aws backup list-restore-jobs \
  --profile "${AWS_PROFILE}" --region "${AWS_REGION}" \
  --by-restore-testing-plan-arn "${RESTORE_PLAN_ARN}" \
  --query 'RestoreJobs[].{Job:RestoreJobId,Status:Status,RecoveryPoint:RecoveryPointArn,RestoredResource:CreatedResourceArn,Created:CreationDate,Completed:CompletionDate,Validation:ValidationStatus,Deletion:DeletionStatus}' \
  --output json
```

Record job ID, selected recovery point, restored ARN, execution completion, application/data validation method and result, and verified cleanup. No job is not a restore success. A completed restore is not a business recovery-time/data-loss guarantee. Preserve earlier behavioral qualification under its actual SHA/configuration rather than claiming a new restore ran on every final candidate.

## SSM Patch Manager

```bash
aws ssm describe-patch-baselines \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table

aws ssm describe-maintenance-windows \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --output table
```

Expected:

- AWS-managed default patch baselines are visible.
- If custom patch baselines are enabled, project-specific baselines appear.
- If no custom patch baselines are configured, seeing only `AWS-*DefaultPatchBaseline` entries is acceptable.
- Maintenance window exists if enabled.
# 20. Validate GitHub Actions Workflows

## Purpose

Confirm that CI/CD workflows operate successfully and preserve the plan-before-approval boundary.

Run or review the following workflows:

- Terraform Static Analysis
- Docs Validation
- Terraform Plan
- Terraform Apply
- Reconcile Workload Account
- Workload Bootstrap Evidence Export
- Workload Baseline Evidence Export
- Control-Plane Evidence Export
- Security Operations Evidence Export
- Terraform Destroy in an approved non-production regression, and the separately authorized production retirement/destroy qualification when that is in scope

Before testing workload deployment workflows, confirm that:

- `ACCOUNT_ID` is configured in both `<env>-plan` and `<env>`;
- the two values match the intended workload account;
- `PLAN_ROLE_GITHUB_ARN` is configured in `<env>-plan`;
- `APPLY_ROLE_GITHUB_ARN` is configured in `<env>`;
- shared region, naming, and state-backend values match across the pair; and
- the Apply environment has the intended required-reviewer protection.

Expected:

- Static analysis workflow succeeds.
- Docs validation workflow succeeds.
- Independent Plan workflow succeeds for expected stacks.
- `Terraform Apply` produces readable plan output before approval.
- The protected Apply job waits for approval and applies the exact saved baseline plan.
- Saved-plan metadata and checksum validation succeed.
- `Reconcile Workload Account` `plan-only` stops after publishing the plan.
- `Reconcile Workload Account` `plan-and-apply` waits for approval, applies the exact saved account plan, and completes strict bootstrap validation.
- The Plan and Apply jobs validate the configured role ARN account and active AWS caller against `ACCOUNT_ID`.
- Evidence workflows assume the intended GitHub Plan role through OIDC.
- Bootstrap and control-plane evidence workflows materialize their ignored state-stack `backend.tf`; do not assume every evidence workflow initializes every state/account root.
- Workload bootstrap and control-plane evidence workflows complete with `REQUIRE_STATE_STACK_REMOTE=true` when strict migration evidence is requested.
- Security Operations Evidence runs through `security-operations-plan` and validates centralized Security Hub CSPM, GuardDuty, and Security Hub V2 governance.
- Evidence packages are uploaded as GitHub Actions artifacts.
- A blank `AWS_PROFILE` in GitHub is expected; AWS CLI and validation commands should use the OIDC-provided default credential chain.
- Destroy preserves the implemented separate approvals: production durable cleanup precedes workload destroy planning; Identity Center cleanup has its own plan/apply approval before final workload-destroy approval. Exact artifacts are verified before application.
- No OIDC role assumption errors occur.
- No Terraform state lock conflicts occur.

---

# 21. Destroy Safety Check

## Purpose

Confirm that destroy operations are understood before running them.

Before destroying anything, review:

```text
docs/quickstart.md
```

Specifically review:

```text
Destruction / Cleanup Procedure
```

Important rules:

- Do not destroy `bootstrap/<env>/account` before `environments/<env>`.
- Do not destroy `bootstrap/<env>/state` before all stacks using that backend are destroyed.
- Do not destroy `bootstrap/control_plane/account` before other control-plane substacks.
- Destroy `bootstrap/control_plane/state` last.
- Treat `bootstrap/security_operations/security_services`, `account`, and `state` as long-lived centralized-security/bootstrap infrastructure; do not include them in routine workload Destroy operations.
- For single-environment teardown, clean up Identity Center attachments before destroying the environment baseline.

## Production retirement evidence

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

Use the [production retirement runbook](production-retirement.md) for the exact approval chain. Retain separate Stage-1, cleanup, readiness, Identity Center, and destroy evidence. Moving a state stack to an independent backend does not remove the state module's literal `prevent_destroy` guards; whole-platform retirement is not established by successful workload destruction.

## Final convergence and qualification record

Before retirement, retain a normal no-change plan using the same effective variables, tracked workload JSON and provider lockfiles as the applied environment. This is a separate Terraform operation, not an assertion produced by the read-only baseline suite:

```bash
# Existing, initialized workload root; restore the exact applied input context.
(
  set +e
  terraform -chdir="environments/${ENVIRONMENT}" plan -detailed-exitcode
  rc=$?
  case "${rc}" in
    0) echo "No changes" ;;
    2) echo "Changes present; review before acceptance" >&2; exit 2 ;;
    *) echo "Terraform plan failed (${rc})" >&2; exit "${rc}" ;;
  esac
)
```

Record each applicable behavioral test separately: three-AZ task placement, ECS replacement, RDS failover, Backup restore/application validation/cleanup, custom-CIDR development regression, and staged production destruction. Mark reused earlier evidence with its actual commit/configuration and the reason it remains relevant. Do not automatically restart an entire qualification merely to fill a documentation table.

State/backend and Organizations resources remain long-lived administrative assets with separate guards. A successful workload destroy is not proof that they can be destroyed safely or that retained RDS snapshots, automated backups, logs, encryption keys and external dependencies have completed their approved disposition.

---

# 22. Quick Failure Triage Guide

## Profile or Egress Mode Looks Wrong

Check:

- Environment `deployment_profile` value.
- Environment `egress_mode` value.
- Terraform output `effective_egress_mode`.
- Any explicit override variables such as `enable_config`, `backup_enabled`, `cloudwatch_retention_days`, or `egress_mode`.

Useful command from the repository root:

```bash
terraform -chdir="environments/${ENVIRONMENT}" output
```

Expected:

- `deployment_profile` shows the selected profile.
- `egress_mode` shows the selected input.
- `effective_egress_mode` shows the resolved routing mode.

---

## SSM Session Fails

Check:

- Instance has SSM agent installed and running.
- Instance IAM role includes SSM permissions.
- Interface endpoints exist for:
  - `sts`
  - `logs`
  - `ssm`
  - `ssmmessages`
  - `secretsmanager`
  - `kms`
  - `config`
  - `sns`
  - `ec2`
  - `events`
  - `securityhub`
  - `lambda`
- Endpoint security group allows inbound 443 from workload security group.
- Workload security group allows outbound 443 to endpoint security group.
- Instance has network path to SSM endpoints.
- Interface Endpoints are deployed into endpoint private subnets.

---

## VPC Endpoint DNS Fails

Check:

- Private DNS is enabled on the endpoint.
- VPC DNS hostnames are enabled.
- VPC DNS resolution is enabled.
- Endpoint exists in the expected VPC and endpoint private subnets.
- Security groups allow traffic.

---

## AWS Service 443 Checks Fail

Check:

- Endpoint security group allows traffic.
- Workload security group egress allows 443.
- Route tables are correct.
- Interface Endpoints are deployed into endpoint private subnets.
- Network Firewall rules allow required egress if applicable.
- NAT Gateway exists if internet egress is expected.

---

## Internet Egress Is Unexpected

Check:

- Effective egress mode.
- Route tables.
- NAT Gateway routes.
- Network Firewall policy.
- Security group egress.
- NACLs.
- Whether the selected environment is intended to allow controlled internet egress.

Expected by mode:

- `network_firewall`: internet egress may be available through Network Firewall and NAT, depending on firewall policy.
- `nat_only`: internet egress may be available through NAT.
- `vpc_endpoints_only`: general internet egress should not be available.

---

## CloudTrail Is Not Logging

Check:

- Trail status.
- S3 bucket policy.
- KMS key policy.
- CloudTrail service permissions.
- CloudWatch Logs delivery role if configured.

---

## Security Hub or GuardDuty Is Missing

First inspect the workload ownership outputs:

```text
effective_manage_securityhub_cspm_locally
effective_manage_guardduty_locally
effective_manage_securityhub_v2_locally
```

If an ownership value is `false`, do not troubleshoot the service as though workload Terraform owns its organization configuration. Check:

- workload account and Region are correct
- `validate-security-workload.sh <env>` output
- the expected Security Hub / GuardDuty administrator relationship
- `validate-security-operations.sh` results
- Security Hub CSPM configuration-policy association status
- GuardDuty organization member enrollment and protection-plan state
- Security Hub V2 effective workload policy
- AWS Config availability when Security Hub standards depend on it

If an ownership value is `true`, troubleshoot the corresponding workload-local Terraform resources instead.

---

## GuardDuty ECS Runtime Monitoring Is Unhealthy or Agent Is Missing

Check:

- `deployment_profile` and the workload `ecs_cluster` Terraform output.
- The live ECS cluster has exactly one `GuardDutyManaged` tag matching Terraform.
- `production` / `development` resolve to `GuardDutyManaged=true`; `minimal` resolves to `false`.
- Central security-operations validation passes the exact Runtime Monitoring organization contract.
- Each protected service execution role has the exact regional GuardDuty agent ECR repository scope and no broad ECR authority.
- `ecr.api`, `ecr.dkr`, and `guardduty-data` Interface Endpoints plus the S3 Gateway Endpoint are present.
- `validate-vpc-endpoints.sh` confirms exactly one Terraform-owned `guardduty-data` endpoint.
- The task security group has HTTPS access to the Interface Endpoint security group and S3 prefix-list path.
- A protected service was deployed after the Runtime Monitoring prerequisites and cluster intent converged.
- `validate-ecs-runtime.sh` reports one running GuardDuty agent per protected running task.
- GuardDuty coverage reports the expected cluster as `AUTO_MANAGED` and `HEALTHY` with no unresolved issues.
- `validate-eventbridge.sh` passes the GuardDuty coverage-state notification contract.

Do not add the GuardDuty agent to the Terraform task definition manually. GuardDuty owns the live injected agent lifecycle.

---

## AWS Config Is Missing

Check:

- `effective_enable_config` output.
- `enable_config` override value.
- `deployment_profile`.

Expected:

- `production` and `development` enable AWS Config by default.
- `minimal` disables AWS Config by default unless explicitly overridden.

---

## Backup State Looks Wrong

For RDS and Restore Testing, inspect the exact contract objects and `validate-backup.log`. Distinguish a live mismatch from Terraform deletion-time intent, an absent/unfinished restore job, application-validation warnings and cleanup warnings. A warning-only script exit is not complete recovery acceptance. Disabled Restore Testing does not prove no stale live plan exists.

Check:

- `effective_backup_enabled`.
- `effective_backup_schedule`.
- `effective_delete_backups_after_days`.
- `backup_enabled`, `backup_schedule`, and `delete_backups_after_days` overrides.
- `deployment_profile`.
- `validate-backup.sh <env>` output.

Expected:

- The encrypted environment backup vault exists regardless of scheduled-backup enablement.
- `production` enables scheduled backup by default.
- `development` and `minimal` disable scheduled backup by default unless explicitly overridden.
- When disabled, effective schedule/retention are null, no backup plan/selection exists, and workload EC2/RDS resources use `Backup=false`.
- When enabled, the plan/selection exist and workload EC2/RDS resources use `Backup=true`.

---

## Workload Bootstrap Validation Fails

Confirm explicit non-empty service `AWS_REGION` first. The state bucket/CMK checks use the backend Region separately; changing the backend Region is not a remedy for a service-region mismatch.

Check:

- `AWS_PROFILE` is set to the target workload account profile.
- `EXPECTED_ACCOUNT_ID` matches the target workload account ID.
- `EXPECTED_GITHUB_REPOSITORY` matches the repository trusted by the workload GitHub OIDC roles.
- `bootstrap/<env>/state` was applied locally at least once to create the state bucket and state CMK.
- `scripts/bootstrap/migrate-state-stack.sh <env>` completed successfully.
- `bootstrap/<env>/state/backend.tf.migrated.example` contains the intended bucket, key, region, and `use_lockfile = true`.
- the ignored active `bootstrap/<env>/state/backend.tf` exists for local validation and matches the tracked template.
- `scripts/bootstrap/migrate-state-stack.sh <env> --verify-only` succeeds.
- state, account, and workload backend files use the intended shared bucket and region with distinct state keys.
- all three backend files include `use_lockfile = true`.
- the state S3 bucket exists, has versioning enabled, has public access block enabled, and uses SSE-KMS.
- the state CMK can be resolved from the bucket encryption configuration, is enabled, and is customer-managed.
- all remote-backed roots have been initialized before running validation from a fresh checkout.
- `REQUIRE_STATE_STACK_REMOTE=true` is set when missing or unreadable migrated state should fail validation.
- workload-account reconciliation completed successfully after workload deployment, either through `plan-and-apply` or a local exact saved-plan apply.

If strict workload CMK policy checks fail, first run the `Reconcile Workload Account` workflow with `plan-and-apply`, or use an exact local saved-plan handoff:

```bash
# Run only in the selected workload account shell; apply mode changes IAM.
: "${ENVIRONMENT:?Select dev, staging, or prod}"
: "${AWS_PROFILE:?Set the matching local profile}"
: "${AWS_REGION:?Set the explicit service Region}"
: "${EXPECTED_ACCOUNT_ID:?Set the expected workload account ID}"
umask 077
RECONCILIATION_DIR="$(mktemp -d)"
RECONCILIATION_PLAN="${RECONCILIATION_DIR}/account-reconciliation.tfplan"

./scripts/bootstrap/reconcile-workload-account.sh "${ENVIRONMENT}" \
  --plan-file="${RECONCILIATION_PLAN}"

# Inspect the readable plan and obtain approval before this separate mutation.
./scripts/bootstrap/reconcile-workload-account.sh "${ENVIRONMENT}" \
  --apply-plan="${RECONCILIATION_PLAN}"
```

For GitHub failures before OIDC configuration, confirm `ACCOUNT_ID` exists in both `<env>-plan` and `<env>` and contains the same 12-digit workload account ID.

If reconciliation cannot be completed yet, run validation temporarily with:

```bash
export STRICT_WORKLOAD_CMK_POLICY_CHECKS=false
```

This keeps the checks enabled but reports stale/missing workload CMK policy references as warnings instead of failures.

If Terraform suddenly wants to create existing bootstrap/account resources, stop and confirm the S3 backend bucket and key point to the intended state object before applying.

---

## Bootstrap Validation Cannot Read Terraform Outputs

`validate-bootstrap.sh` reads outputs from the account and workload roots. Its state-stack remote validation also reads `tf_state_bucket_name` from the migrated state stack.

For a manual run from a fresh checkout of an already-migrated environment:

```bash
# In the selected workload account shell, with AWS_PROFILE/AWS_REGION and
# EXPECTED_ACCOUNT_ID exported and the backend template already reviewed.
: "${ENVIRONMENT:?Select dev, staging, or prod}"
STATE_DIR="bootstrap/${ENVIRONMENT}/state"
if [[ ! -e "${STATE_DIR}/backend.tf" ]]; then
  cp "${STATE_DIR}/backend.tf.migrated.example" "${STATE_DIR}/backend.tf"
fi
./scripts/bootstrap/migrate-state-stack.sh "${ENVIRONMENT}" --verify-only
terraform -chdir="bootstrap/${ENVIRONMENT}/account" init -input=false
terraform -chdir="environments/${ENVIRONMENT}" init -input=false
```

The GitHub workload bootstrap evidence workflow performs the backend materialization and Terraform initialization steps automatically.

If output reads still fail, confirm that the selected AWS principal has access to:

- the configured state bucket;
- each required state object key;
- the corresponding `.tflock` objects;
- the state CMK.

Also confirm that the active `backend.tf` matches `backend.tf.migrated.example` and points to the intended environment.

---

## Control-Plane Validation Fails

Check:

- `AWS_PROFILE` is set to the control-plane profile.
- `EXPECTED_ACCOUNT_ID` matches the control-plane account ID.
- `EXPECTED_GITHUB_REPOSITORY` matches the repository trusted by the GitHub OIDC role, using the exact owner/repo spelling.
- `IDENTITY_CENTER_WORKLOADS` and `IDENTITY_CENTER_SECOPS` contain the expected workload and security-operations account IDs and role settings.
- `bootstrap/control_plane/state` was applied locally and migrated with `scripts/bootstrap/migrate-state-stack.sh control-plane`.
- `bootstrap/control_plane/state/backend.tf` exists locally, matches `backend.tf.migrated.example`, and uses `use_lockfile = true`.
- `scripts/bootstrap/migrate-state-stack.sh control-plane --verify-only` succeeds.
- the state, account, Organizations, and Identity Center roots have been initialized before manual validation from a fresh checkout.
- `REQUIRE_STATE_STACK_REMOTE=true` is set when strict control-plane migration evidence is required.
- `bootstrap/control_plane/account` has been applied with GitHub OIDC enabled.
- `bootstrap/control_plane/organizations` has been applied.
- `bootstrap/control_plane/identity_center` has been applied after workload baseline policy names were available, if optional policy-backed roles are enabled.

With the current default `STRICT_ACCOUNT_OU_CHECKS=true`, an account-placement mismatch is a validation failure. Verify `dev` and `staging` are under `Workloads/NonProd`, `prod` is under `Workloads/Prod`, and `security-operations` is under `Security`.

---

## Security-Operations Validation Fails

Set explicit service `AWS_REGION` and initialize the `security_services` root. This layer does not certify the complete security-operations state/account bootstrap merely because governance validation passes.

Check:

- `AWS_PROFILE` points to the `security-operations` account.
- `EXPECTED_ACCOUNT_ID` matches that account.
- `bootstrap/security_operations/security_services` has been applied with central rollout flags enabled as intended.
- Security Hub and GuardDuty delegated administrators still point to `security-operations`.
- the CSPM configuration-policy association is `SUCCESS` for each deployed workload account.
- the GuardDuty detector and organization feature configuration match Terraform state.
- the Security Hub V2 organization policy remains attached to `Workloads` and resolves correctly for the workload accounts.
- workload AWS Config is running before treating a CSPM standards-association failure as a central-policy defect.

---

## Identity Center Assignment Fails

Check:

- Target account is a member of the organization.
- IAM Identity Center is enabled in the control-plane account.
- Account ID variables are correct.
- Permission set exists.
- Group exists.
- Customer-managed policy names exist in the target account if being attached.

---

## IAM Policy DeleteConflict During Destroy

Cause:

- Identity Center still has a customer-managed policy attached to a permission set provisioned into the target account.

Fix:

- Re-apply the Identity Center stack with that environment's optional Analyst/Engineer attachments disabled.
- After approved cleanup and refreshed readiness, generate/review a new exact destroy plan through the appropriate workflow. For production, retain the staged retirement contract; do not bypass it with a direct `terraform destroy` or reuse a stale saved plan.

---

## Terraform State Lock Error

Check:

- No other Terraform job is currently running for the same backend key.
- GitHub Actions did not cancel a job while a lock was held.
- Backend key is unique per stack, including the migrated state stack.
- The active state-stack `backend.tf` points to the intended bucket and key.
- Remote-backed stacks include `use_lockfile = true`.
- The AWS principal running Terraform has S3 permissions for both the state object and the `.tflock` lock object.
- Use `terraform force-unlock` only after confirming no active operation is running.

---

## Notification or Automation DLQ Has Messages

Choose the intended DLQ URL explicitly. The count queries are inspection; the later `receive-message` command is a stateful operator action that changes visibility/receive state. Protect message contents and do not infer message age from unsupported queue attributes.

Check:

- Which DLQ has visible messages.
- Whether the DLQ is an EventBridge target DLQ, SQS redrive DLQ, or workflow automation DLQ.
- EventBridge target DLQ and retry policy configuration.
- SNS topic policy and SQS queue policy.
- KMS key policy permissions for SNS, SQS, EventBridge, Lambda, or the downstream consumer.
- Lambda function logs and async/EventBridge delivery behavior for workflow-specific DLQs.
- Whether the message still needs to be replayed, archived, or discarded.

Useful commands:

```bash
aws sqs list-queues \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-name-prefix "${NAME_PREFIX}" \
  --output table
```

```bash
aws sqs get-queue-attributes \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
  --output table
```

```bash
aws sqs receive-message \
  --region "${AWS_REGION}" \
  --profile "${AWS_PROFILE}" \
  --queue-url "${QUEUE_URL}" \
  --max-number-of-messages 1 \
  --visibility-timeout 30 \
  --attribute-names All \
  --message-attribute-names All \
  --output json
```

Do not delete DLQ messages until the root cause has been understood and the operator has decided whether to replay, archive, or discard them.

---

# Summary

For release acceptance, record both generated verdicts and remaining review items. In addition to the four layers, retain exact topology, RDS/Restore Testing and lifecycle evidence, normal-state no-change plans, and applicable separately approved behavioral/retirement records. None of these documentation fields implies the exporter automatically ran those operations.

A complete validation pass means the applicable evidence layers agree with one another:

- control-plane validation confirms state/OIDC foundations, AWS Organizations topology, centralized-security prerequisites, and IAM Identity Center
- security-operations validation confirms centralized Security Hub CSPM, GuardDuty, Runtime Monitoring, and Security Hub V2 governance
- workload bootstrap validation confirms workload state/OIDC foundations
- workload baseline validation confirms networking, exact Terraform-owned VPC endpoint reuse, workload-security realization, KMS, the enabled/disabled Backup contract, messaging, automation, SSM, compute, ECS fixed/autoscaled runtime ownership, GuardDuty Fargate Runtime Monitoring enrollment/agent/coverage state, operational alarms, and IAM controls
- generated evidence packages identify the actual local-profile or workflow credential context and contain the supporting logs
- live isolation, rollback, enrichment, tamper, break-glass, end-user SSO, and destroy-safety tests are completed where appropriate

Passing automated validation demonstrates selected deployed control presence and configuration. It does not by itself establish SOC 2 or ISO 27001 compliance, operating effectiveness over time, or completion of organizational controls.

## Implementation and CLI references

Repository behavior in this checklist is grounded in the frozen implementation: [workload runner](../scripts/validation/validate-baseline.sh), [validation Region helper](../scripts/validation/lib/common.sh), [networking validator](../scripts/validation/validate-networking.sh), [RDS/Backup validator](../scripts/validation/validate-backup.sh), [SQS validator](../scripts/validation/validate-sqs.sh), and [retirement runbook](production-retirement.md). The [validation script reference](../scripts/validation/README.md) describes the entry points and strictness settings.

External AWS documentation is used only to verify CLI/API semantics, not to replace RC1's implementation: [SQS queue attributes](https://docs.aws.amazon.com/cli/latest/reference/sqs/get-queue-attributes.html), [SQS CloudWatch metrics](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-available-cloudwatch-metrics.html), [SQS message receipt](https://docs.aws.amazon.com/cli/latest/reference/sqs/receive-message.html), and [Lambda configuration reads](https://docs.aws.amazon.com/cli/latest/reference/lambda/get-function-configuration.html).
