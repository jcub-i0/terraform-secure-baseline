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

`tf-secure-baseline` has three validation layers:

```text
Workload bootstrap validation  -> validate-bootstrap.sh <dev|staging|prod>
Workload baseline validation   -> validate-baseline.sh <dev|staging|prod>
Control-plane validation       -> validate-control-plane.sh
```

Each layer validates a different part of the platform.

| Layer | Scope | Script |
|---|---|---|
| Workload bootstrap | `bootstrap/<env>/state` and `bootstrap/<env>/account` | `validate-bootstrap.sh` |
| Workload baseline | deployed workload environment under `environments/<env>` | `validate-baseline.sh` |
| Control plane | control-plane state, GitHub OIDC, Organizations, and Identity Center | `validate-control-plane.sh` |

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
| `ENV_NAME` | Environment the validation script applies to | Recommended |
| `EXPECTED_ACCOUNT_ID` | Expected AWS account ID for safety checks | Recommended |
| `NAME_PREFIX` | Resource name prefix override | Optional |
| `CLOUD_NAME` | Cloud/project prefix, defaults to `tf-secure-baseline` | Optional |

Recommended defaults:

```bash
export AWS_PAGER=""
export AWS_REGION="us-east-1"
export CLOUD_NAME="tf-secure-baseline"
```

---

## Workload Bootstrap Validation

Use `validate-bootstrap.sh` to validate the bootstrap resources for a workload account.

This script validates:

- `bootstrap/<env>/state` exists
- `bootstrap/<env>/account` exists
- the active AWS account matches `EXPECTED_ACCOUNT_ID`
- the state stack exposes required Terraform outputs
- the state S3 bucket exists
- the state S3 bucket has versioning enabled
- the state S3 bucket has public access block enabled
- the state S3 bucket uses SSE-KMS
- the state CMK exists, is enabled, and is customer-managed
- `bootstrap/<env>/account/backend.tf` uses `use_lockfile = true`
- `environments/<env>/backend.tf` uses `use_lockfile = true`
- GitHub OIDC provider exists
- GitHub Plan and Apply roles exist
- GitHub trust policies reference the expected repository and subjects
- GitHub role policies reference the Terraform state bucket and state CMK
- GitHub Apply role references workload-created Lambda and Secrets Manager CMKs when required

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

DynamoDB state locking is not expected for the current architecture.

### Dev

```bash
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh dev
```

### Staging

```bash
AWS_PROFILE=staging \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh staging
```

### Prod

```bash
AWS_PROFILE=prod \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh prod
```

### Early Bootstrap Mode

If the workload environment has not been applied yet, the workload-created CMKs may not exist.

Use this mode before the workload stack has produced `lambda_cmk_arn` and `secrets_manager_cmk_arn` outputs:

```bash
REQUIRE_WORKLOAD_CMK_PERMS=false \
AWS_PROFILE=dev \
AWS_REGION=us-east-1 \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" \
./scripts/validation/validate-bootstrap.sh dev
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

## Exporting Workload Validation Evidence

Use `export-report.sh` to export a timestamped workload validation evidence package.

Example:

```bash
ENV_NAME="dev"

AWS_PROFILE="dev" \
AWS_REGION="us-east-1" \
EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" \
NAME_PREFIX="tf-secure-baseline-${ENV_NAME}" \
./scripts/validation/export-report.sh "${ENV_NAME}"
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

Generated evidence is environment-specific and should generally not be committed to the repository.

---

## Recommended Full Validation Order

For a full post-deployment validation run:

```bash
# Dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh dev
AWS_PROFILE=dev AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<DEV-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh dev

# Staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh staging
AWS_PROFILE=staging AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<STAGING-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh staging

# Prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ./scripts/validation/validate-bootstrap.sh prod
AWS_PROFILE=prod AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<PROD-ACCOUNT-ID>" ./scripts/validation/validate-baseline.sh prod

# Control plane
AWS_PROFILE=control-plane AWS_REGION=us-east-1 EXPECTED_ACCOUNT_ID="<CONTROL-PLANE-ACCOUNT-ID>" EXPECTED_GITHUB_REPOSITORY="<GITHUB-OWNER>/<GITHUB-REPO>" ACCOUNT_ID_DEV="<DEV-ACCOUNT-ID>" ACCOUNT_ID_STAGING="<STAGING-ACCOUNT-ID>" ACCOUNT_ID_PROD="<PROD-ACCOUNT-ID>" ./scripts/validation/validate-control-plane.sh
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
- local state file missing from a fresh checkout
- environment-specific exceptions

### FAIL

A `FAIL` means a required validation check did not pass.

Examples:

- wrong AWS account
- missing required Terraform output
- missing AWS resource
- missing GitHub OIDC role
- backend missing `use_lockfile = true`
- state bucket encryption missing
- required workload CMK permission missing from the GitHub Apply role

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

### Missing Workload CMK Permissions

If `validate-bootstrap.sh` fails because the GitHub Apply role does not reference `lambda_cmk_arn` or `secrets_manager_cmk_arn`, re-apply the corresponding `bootstrap/<env>/account` stack after passing in the workload-created CMK ARNs from `environments/<env>`.

---

## Related Documentation

Recommended companion docs:

```text
docs/validation-checklist.md
docs/assurance/validation-report-template.md
docs/assurance/validation-evidence-guide.md
docs/quickstart.md
```