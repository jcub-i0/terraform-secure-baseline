# Validation Scripts

## Purpose

This directory contains safe, read-only validation scripts for `tf-secure-baseline`.

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

`tf-secure-baseline` has three validation layers and matching evidence exporters:

```text
Workload bootstrap validation  -> validate-bootstrap.sh <dev|staging|prod>
Workload baseline validation   -> validate-baseline.sh <dev|staging|prod>
Control-plane validation       -> validate-control-plane.sh

Workload bootstrap evidence    -> export-bootstrap.sh <dev|staging|prod>
Workload baseline evidence     -> export-baseline.sh <dev|staging|prod>
Control-plane evidence         -> export-control-plane.sh
```

Each layer validates a different part of the platform.

| Layer | Scope | Validation script | Evidence exporter |
|---|---|---|---|
| Workload bootstrap | `bootstrap/<env>/state` and `bootstrap/<env>/account` | `validate-bootstrap.sh` | `export-bootstrap.sh` |
| Workload baseline | deployed workload environment under `environments/<env>` | `validate-baseline.sh` | `export-baseline.sh` |
| Control plane | control-plane state, GitHub OIDC, Organizations, and Identity Center | `validate-control-plane.sh` | `export-control-plane.sh` |

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

---

## Common Environment Variables

Most scripts use the following environment variables:

| Variable | Purpose | Required |
|---|---|---|
| `AWS_PROFILE` | AWS CLI profile for the target account | Recommended |
| `AWS_REGION` | AWS region to validate | Recommended |
| `ENV_NAME` | Environment the validation script applies to. Most environment-specific scripts also accept this as the first positional argument. | Recommended |
| `EXPECTED_ACCOUNT_ID` | Expected AWS account ID for safety checks | Recommended |
| `CLOUD_NAME` | Cloud/project prefix, defaults to `tf-secure-baseline` | Optional |
| `NAME_PREFIX` | Resource name prefix override. Defaults to `${CLOUD_NAME}-${ENV_NAME}` for environment-specific scripts. | Optional |

Recommended defaults:

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

---

## Workload Bootstrap Validation

Use `validate-bootstrap.sh` to validate the bootstrap resources for a workload account.

This script validates:

- `bootstrap/<env>/state` exists
- `bootstrap/<env>/account` exists
- the active AWS account matches `EXPECTED_ACCOUNT_ID`
- `bootstrap/<env>/state` preserves the local-state bootstrap pattern by not defining `backend.tf`
- `bootstrap/<env>/account/backend.tf` uses `use_lockfile = true`
- `environments/<env>/backend.tf` uses `use_lockfile = true`
- backend files resolve a shared Terraform state bucket, region, and distinct state keys
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

### Architecture Assumption

The workload bootstrap architecture uses:

```text
bootstrap/<env>/state
  - local Terraform state
  - creates the S3 state bucket
  - creates the KMS CMK for state encryption

bootstrap/<env>/account
  - S3 backend
  - use_lockfile = true

environments/<env>
  - S3 backend
  - use_lockfile = true
```

`validate-bootstrap.sh` does not require local `terraform.tfstate` from `bootstrap/<env>/state`. This keeps the script compatible with fresh checkouts and manual GitHub workflow runs.

For bootstrap validation, the remote backend files are the source of truth for:

```text
state bucket name
state backend region
state object keys
use_lockfile = true
```

The script derives the state bucket from the backend files, then validates the live S3 bucket and KMS encryption configuration through AWS APIs.

DynamoDB state locking is not expected for the current architecture. This project uses Terraform S3 native locking with `use_lockfile = true`; DynamoDB-based locking for the S3 backend is deprecated.

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

### Dev

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
ENV_NAME="dev" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh dev
```

### Staging

```bash
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
ENV_NAME="staging" \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh staging
```

### Prod

```bash
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
ENV_NAME="prod" \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh prod
```

### Advisory Workload CMK Mode

If the workload environment has not been applied yet, or if `bootstrap/<env>/account` has not yet been re-applied with the current workload-created CMK ARNs, strict workload CMK policy validation may fail.

Use advisory mode only when stale/missing workload CMK policy references should be warnings rather than failures:

```bash
STRICT_WORKLOAD_CMK_POLICY_CHECKS=false \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
ENV_NAME="<ENV-NAME>" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh dev
```

For validated client handoff evidence, leave `STRICT_WORKLOAD_CMK_POLICY_CHECKS` unset so it defaults to `true`.

### GitHub Workflow Usage

`validate-bootstrap.sh` is read-only and does not run `terraform init`. For manual GitHub workflow usage, initialize the remote-backed stacks first so Terraform outputs can be read from the S3 backend:

```bash
terraform -chdir=bootstrap/dev/account init -input=false
terraform -chdir=environments/dev init -input=false

AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh dev
```

Repeat with the matching profile, account ID, and environment name for `staging` and `prod`.

For strict workload CMK evidence, the expected deployment sequence is:

```text
1. Apply bootstrap/<env>/state.
2. Apply bootstrap/<env>/account.
3. Apply environments/<env>.
4. Capture current workload outputs for lambda_cmk_arn and secrets_manager_cmk_arn.
5. Re-apply bootstrap/<env>/account with those current CMK ARNs.
6. Run validate-bootstrap.sh or export-bootstrap.sh with the default strict behavior.
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

Run once per deployed workload environment:

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
validate-logging.sh
validate-security-services.sh
validate-kms.sh
validate-backup.sh
validate-sns.sh
validate-sqs.sh
validate-eventbridge.sh
validate-lambda.sh
validate-ssm.sh
validate-compute.sh
validate-iam.sh
```

A successful run should end with:

```text
Validation scripts passed:  14/14
Validation scripts failed:  0/14
```

---

## Individual Workload Validation Scripts

Individual scripts can be run directly for focused troubleshooting.

Examples:

```bash
./scripts/validation/validate-networking.sh dev
./scripts/validation/validate-vpc-endpoints.sh dev
./scripts/validation/validate-logging.sh dev
./scripts/validation/validate-security-services.sh dev
./scripts/validation/validate-kms.sh dev
./scripts/validation/validate-backup.sh dev
./scripts/validation/validate-sns.sh dev
./scripts/validation/validate-sqs.sh dev
./scripts/validation/validate-eventbridge.sh dev
./scripts/validation/validate-lambda.sh dev
./scripts/validation/validate-ssm.sh dev
./scripts/validation/validate-compute.sh dev
./scripts/validation/validate-iam.sh dev
```

Use individual scripts when validating a specific area after a targeted change.

---

## Control-Plane Validation

Use `validate-control-plane.sh` to validate control-plane bootstrap and governance resources.

This script validates:

- control-plane AWS caller identity
- control-plane Terraform state backend resources
- control-plane state bucket, CMK, and lock configuration
- GitHub OIDC provider
- control-plane GitHub Plan and Apply roles
- GitHub OIDC trust conditions
- AWS Organizations root and expected OU structure
- IAM Identity Center instance
- expected SecOps groups
- Identity Center permission sets
- optional Identity Center account assignments

Example:

```bash
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

### Optional SecOps Groups

To require optional SecOps groups:

```bash
CHECK_OPTIONAL_SECOPS_GROUPS=true \
AWS_PROFILE=control-plane \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
./scripts/validation/validate-control-plane.sh
```

### AWS Organizations Account Placement Warnings

The control-plane script may warn if workload accounts are under the AWS Organizations root rather than the expected OUs.

Example:

```text
[WARN] dev account parent mismatch. Expected NonProd, got root
[WARN] staging account parent mismatch. Expected NonProd, got root
[WARN] prod account parent mismatch. Expected Prod, got root
```

These warnings are non-blocking unless account placement is explicitly managed and required.

---

## Exporting Validation Evidence

Evidence exporters generate timestamped report packages with:

```text
summary.md
summary.json
per-script validation logs
```

Generated evidence is environment-specific and should generally not be committed to the repository.

### Workload Bootstrap Evidence

Use `export-bootstrap.sh` to export workload bootstrap evidence.

Example:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-bootstrap.sh dev
```

The report package is written to:

```text
validation-results/<environment>/bootstrap/<timestamp>/
```

Expected files include:

```text
summary.md
summary.json
validate-bootstrap.log
```

### Workload Baseline Evidence

Use `export-baseline.sh` to export workload baseline evidence.

Example:

```bash
AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-baseline.sh dev
```

The report package is written to:

```text
validation-results/<environment>/<timestamp>/
```

Expected files include:

```text
summary.md
summary.json
validate-env.log
validate-networking.log
validate-vpc-endpoints.log
validate-logging.log
validate-security-services.log
validate-kms.log
validate-backup.log
validate-sns.log
validate-sqs.log
validate-eventbridge.log
validate-lambda.log
validate-ssm.log
validate-compute.log
validate-iam.log
```

### Control-Plane Evidence

Use `export-control-plane.sh` to export control-plane validation evidence.

Example:

```bash
AWS_PROFILE="control-plane" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" \
ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" \
ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" \
CLOUD_NAME="tf-secure-baseline" \
./scripts/validation/export-control-plane.sh
```

The report package is written to:

```text
validation-results/control-plane/<timestamp>/
```

Expected files include:

```text
summary.md
summary.json
validate-control-plane.log
```

---

## Recommended Full Validation Order

For a full post-deployment validation run:

```bash
# Dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/export-bootstrap.sh dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" ./scripts/validation/export-baseline.sh dev

# Staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/export-bootstrap.sh staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" ./scripts/validation/export-baseline.sh staging

# Prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/export-bootstrap.sh prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" ./scripts/validation/export-baseline.sh prod

# Control plane
AWS_PROFILE=control-plane AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" ./scripts/validation/validate-control-plane.sh
AWS_PROFILE=control-plane AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" ./scripts/validation/export-control-plane.sh
```

---

## What Remains Manual

The validation scripts are intentionally read-only.

They do not perform:

- GitHub Actions workflow execution
- end-user SSO login testing
- live EC2 isolation testing
- live EC2 rollback testing
- live IP enrichment execution
- tamper detection simulation
- break-glass role assumption
- destroy workflow execution
- policy/procedure review
- formal audit evidence review

Track these activities separately in the validation checklist or assurance documentation.

---

## PASS, WARN, and FAIL

### PASS

A `PASS` means the script confirmed the expected condition.

### WARN

A `WARN` means the condition should be reviewed but does not necessarily invalidate the deployment.

Examples:

- optional resources not enabled
- optional Identity Center groups not configured
- AWS Organizations account placement not managed by Terraform
- environment-specific exceptions

### FAIL

A `FAIL` means a required validation check did not pass.

Examples:

- wrong AWS account
- missing required Terraform output from a remote-backed stack
- missing AWS resource
- missing GitHub OIDC role
- backend missing `use_lockfile = true`
- state bucket encryption missing
- current workload Lambda or Secrets Manager CMK policy reference missing from the GitHub Apply role when strict workload CMK policy checks are enabled

Failures should be fixed before using the environment as validated evidence.

---

## Safety Notes

The validation scripts are designed to be safe and read-only.

They should not:

- run `terraform apply`
- run `terraform destroy`
- run `terraform init`
- migrate state
- modify IAM policies
- assume privileged roles
- trigger live security automation
- delete or replay DLQ messages

Review each script before extending it to ensure this read-only safety property is preserved.

---

## Troubleshooting

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

`validate-bootstrap.sh` does not read Terraform outputs from `bootstrap/<env>/state`, but it does read outputs from the remote-backed account and workload stacks.

Before running bootstrap validation from a fresh checkout or GitHub workflow, initialize the remote-backed stacks:

```bash
terraform -chdir=bootstrap/<env>/account init -input=false
terraform -chdir=environments/<env> init -input=false
```

If output reads still fail, confirm that the selected AWS principal has access to the configured S3 backend bucket, state object key, `.tflock` object, and state CMK.

### Missing Workload CMK Policy References

If `validate-bootstrap.sh` fails because the GitHub Apply role does not reference `lambda_cmk_arn` or `secrets_manager_cmk_arn`, re-apply the corresponding `bootstrap/<env>/account` stack after passing in the current workload-created CMK ARNs from `environments/<env>`.

For transitional validation only, set:

```bash
STRICT_WORKLOAD_CMK_POLICY_CHECKS=false
```

This keeps the checks enabled but reports stale/missing workload CMK policy references as warnings instead of failures.

---

## Related Documentation

Recommended companion docs:

```text
docs/validation-checklist.md
docs/assurance/validation-report-template.md
docs/assurance/validation-evidence-guide.md
docs/quickstart.md
```