# RDS Restore Validation — M1-B2 runtime

This module orchestrates **AWS Backup Restore Testing** (which creates a temporary
RDS instance) and **Restore Validation** (which independently checks isolation
and a synthetic PostgreSQL fixture). It does not read or connect to the
production database. Keep `restore_validation_enabled = false` until the signed
artifact pipeline and first nonproduction recovery exercise are qualified.

## Trust boundaries and validation sequence

1. EventBridge accepts completed RDS restore-testing jobs from the exact plan.
2. `coordinator.py` checks account, Region, plan and event fields; calls
   `DescribeRestoreJob` to verify the **authoritative** source database and
   created resource. A mismatched source is rejected without publishing a result.
3. The coordinator reads restored RDS metadata and checks DB ARN, state,
   engine (`postgres`), encryption, public accessibility, single-AZ, VPC,
   dedicated SG (sole and active), and endpoint before invoking the SQL worker.
4. The VPC worker retrieves only its named Secrets Manager credential,
   connects over TLS using a verified RDS CA certificate and hostname,
   begins a **read-only transaction**, and checks three fixed, synthetic rows
   and the role's inability to modify the canary.
5. The coordinator publishes `SUCCESSFUL` or `FAILED` only for definite results.
   Retryable API, DB-not-ready or invocation failures are *not* recorded as
   conclusive restore failures. Lambda retries/DLQ preserve those failures.
6. A preexisting `ValidationStatus` is not overwritten (AWS Backup statuses
   cannot be changed once recorded).

This tests the snapshot's canary integrity; it does **not** independently prove
full application recovery, arbitrary PII accuracy, RTO/RPO, or data currency.

## Provision synthetic source data

Execute `sql/seed_canary.sql` against the **source** PostgreSQL database, using
an operator account. It is idempotent and does not contain PII. The worker
expects *exactly* these three rows, specified in `lambda/canary_contract.json`.
Create a separate login role, e.g. `restore_validation_reader`, with only:

```sql
GRANT CONNECT ON DATABASE your_database TO restore_validation_reader;
GRANT USAGE ON SCHEMA restore_validation TO restore_validation_reader;
GRANT SELECT ON restore_validation.canary TO restore_validation_reader;
```

No INSERT, UPDATE, DELETE, TRUNCATE, CREATE, or other schema privileges should
be granted. Store the role's password in a dedicated AWS Secrets Manager secret,
encrypted by the baseline's Secrets Manager CMK:

```json
{"username":"restore_validation_reader","password":"<redacted>"}
```

Set `restore_validation_secret_arn` to that **exact** secret ARN. Never pass the
master RDS secret and never store the password in Terraform tfvars or Git.
After seeding, take a **new** AWS Backup recovery point. Older snapshots may
lack the fixture and are expected to fail the integrity test.

## Runtime packaging

The coordinator uses pinned boto3/botocore, because the managed Lambda SDK
may lag the AWS Backup API. The worker uses pinned, pure-Python `pg8000` for
PostgreSQL. Both packages are Python 3.12-compatible ZIP archives.

1. Obtain the AWS-maintained RDS root certificate bundle, e.g.:
   `https://truststore.pki.rds.amazonaws.com/us-east-1/us-east-1-bundle.pem`.
2. Review its SHA-256 and set a pinned `RDS_CA_SHA256` in the protected Plan
   environment. CI checks the downloaded bytes against this exact hash.
3. Run `python3 scripts/restore_validation/build.py --rds-ca-bundle ./us-east-1-bundle.pem`.
   The resulting unsigned ZIPs and `unsigned-manifest.json` are under
   `modules/restore_validation/lambda/dist/`.
4. Sign the ZIPs with a **pre-existing** AWS Signer profile (platform
   `AWSLambda-SHA384-ECDSA`) and versioned S3 bucket using
   `RESTORE_VALIDATION_RELEASE=true RESTORE_SIGNING_PROFILE_NAME=... RESTORE_SIGNING_BUCKET=... bash scripts/restore_validation/sign.sh`.
5. The signing script verifies S3 versioning and signing-job completion and
   downloads the signed ZIPs to `lambda/dist/signed/`, with a SHA-256 manifest.
6. Configure Terraform Lambda `filename` and `source_code_hash` to use these
   **signed** ZIPs and attach an enforcing Lambda Code Signing configuration.
   `archive_file` alone produces **unsigned** ZIPs and must not be used as the
   deployment package when `Enforce` is enabled.

Only the Plan job can sign artifacts. Its signed packages are bound into the
saved-plan SHA-256 manifest; the Apply job restores exactly those verified
packages and does not sign again. New signed ZIPs require a **new** reviewed
Terraform plan.

**Bootstrap requirement:** An AWS Signer signing profile and a versioned,
private S3 signing bucket must exist in Terraform **before** enabling
Restore Validation, and the protected Plan role must be authorized to call
Signer and the relevant S3 object APIs. Prefer provisioning these once in a
separate baseline/control-plane Terraform change. `code_signing_config_arn` must
use the matching profile version ARN with `Enforce`.

## CI and testing

Offline regression tests run with:

```bash
python3 -m unittest discover -s scripts/tests -p 'test_restore_validation_*.py' -v
```

They cover valid and forged EventBridge events, AWS Backup job identity,
network isolation, duplicate delivery, recoverable failures, synthetic data
corruption, excessive SQL permissions, TLS, archive reproducibility and the
saved-plan artifact staging contract. No AWS credentials or live DB required.

`python3 scripts/restore_validation/integrate_ci.py --check` inspects the
repository workflow anchors; run without `--check` to integrate the tests and
protected Plan/Apply signing steps.

The `terraform-apply.yml` workflow provides an explicit, default-false
`restore_validation_enabled` input. The protected `*-plan` environment must
configure `RESTORE_VALIDATION_SECRET_ARN`, `RESTORE_SIGNING_PROFILE_NAME`,
`RESTORE_SIGNING_BUCKET`, and `RDS_CA_SHA256` before opting in. The temporary
CA file is downloaded from AWS's official trust store only in that opt-in path.

## Outstanding qualification requirements

- Terraform resources must be wired to the **signed** ZIPs and AWS Signer
  Code Signing configuration. These Terraform changes remain with the IaC
  owner (do not attach `Enforce` to an unsigned source archive).
- An isolated positive **enabled** Terraform plan must succeed. Default-disabled
  root `terraform validate` is insufficient to prove this.
- The RDS canary must be seeded before the selected recovery point is made.
- Validate AWS Backup `DescribeRestoreJob` fields and cleanup lifecycle with a
  real controlled dev recovery test; the current tests are mock-only.
- Add CloudWatch alarms for DLQ depth, function failures, and missed Restore
  Validation results to the existing `secops_topic_arn`. This input is currently
  reserved; SNS alarm resources are not yet implemented.
- AWS Backup's result is immutable. Never manually change a `FAILED` result to
  `SUCCESSFUL` or suppress a real synthetic-data failure.
