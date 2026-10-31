# RDS Restore Validation

Optional, default-disabled SQL verification for RDS recovery points restored by AWS Backup Restore Testing.

**Restore Testing** creates a temporary RDS instance from a recovery point.
**Restore Validation** checks that this particular restored instance is private and
isolated, and that three synthetic PostgreSQL canary records are intact. It does
not connect to the live production database.

This is a technical recovery check, **not** a guarantee of application recovery,
data correctness outside the canary, RTO/RPO achievement, SOC 2 compliance, or
ISO 27001 certification.

## How it works

1. AWS Backup completes a Restore Testing job using the dedicated restore-test
   database security group.
2. EventBridge invokes the coordinator Lambda, which checks the event against
   authoritative AWS Backup job metadata and verifies the restored RDS network,
   engine, encryption, and isolation settings.
3. The private VPC worker Lambda retrieves a restricted PostgreSQL credential
   from Secrets Manager, connects to the restored instance over verified TLS,
   and checks the synthetic canary and read-only SQL role.
4. The coordinator submits an AWS Backup validation result only for a conclusive
   outcome. Transient failures are retried; exhausted asynchronous failures
   are delivered to the validation DLQ.

The coordinator cannot reach the database. The worker cannot access the live
database security group. AWS Backup controls the temporary restore lifecycle.

## Enablement prerequisites

1. Enable AWS Backup and RDS Restore Testing in the workload environment.
   Restore Validation is a separate opt-in: `restore_validation_enabled = true`.
   Deployment profiles are independent of environment names.
2. Run `sql/seed_canary.sql` as a database operator on the **source**
   PostgreSQL database. Its three records are synthetic, with no customer data.
3. Create a dedicated LOGIN role (for example, `restore_validation_reader`)
   without database-administrator or write permissions, and grant only the
   access needed to read the fixture:

   ```sql
   GRANT CONNECT ON DATABASE your_database TO restore_validation_reader;
   GRANT USAGE ON SCHEMA restore_validation TO restore_validation_reader;
   GRANT SELECT ON restore_validation.canary TO restore_validation_reader;
   ```

4. Store that role's credentials in a dedicated Secrets Manager secret encrypted
   with the baseline Secrets Manager CMK. The secret contains:

   ```json
   {"username":"restore_validation_reader","password":"<redacted>"}
   ```

   Pass the **exact secret ARN** as `restore_validation_secret_arn`.
   Do not use RDS master credentials or put the password in Terraform variables.
5. Take a **new** AWS Backup recovery point after creating the canary. Older
   recovery points will not contain it and should fail the integrity check.
6. Configure the protected Plan environment with
   `RESTORE_VALIDATION_SECRET_ARN` (Terraform receives it as an ARN) and
   `RDS_CA_SHA256` (the reviewed SHA-256 of the official regional RDS
   CA bundle). The protected workflow downloads and hash-verifies the bundle.

Enable `restore_validation_enabled` in the existing **Terraform Apply**
workflow only when these prerequisites are satisfied. The Plan and Apply jobs
remain protected by the repository's existing AWS OIDC roles and approvals.

## Packaging and deployment

The Plan job in the **Terraform Apply** workflow prepares Restore Validation packages only when `restore_validation_enabled` is enabled. The separate informational **Terraform Plan** workflow does not prepare these packages:

- `prepare.py` installs the pinned pure-Python dependencies and stages
  `lambda/build/coordinator/` and `lambda/build/worker/`.
  The latter contains the verified RDS CA bundle and canary contract.
- The module's existing Terraform `archive_file` data sources produce
  `lambda/coordinator.zip` and `lambda/worker.zip`.
- That Plan job appends both ZIPs to its saved-plan SHA-256 manifest.
  The Apply job in the same workflow verifies the manifest and restores
  those exact ZIPs at the original paths **before** applying the approved plan.
  Apply does not install dependencies or rebuild archives.

Disabled plans do not need RDS CA downloads, Python packages, or extra ZIPs.

For local enabled planning, first supply a CA bundle whose SHA-256 you have
independently verified, then run:

```bash
python3 modules/restore_validation/prepare.py --rds-ca-bundle /path/to/region-bundle.pem
```

The protected GitHub workflow performs those steps automatically.

## Testing and operational qualification

Offline tests (no AWS credentials or live database required):

```bash
python3 -m unittest discover -s modules/restore_validation/tests -p 'test_*.py' -v
```

They exercise event/job identity checks, read-only canary verification, failure
handling, dependency preparation, and exact Plan/Apply ZIP staging. Mock tests
are not evidence of a successful live restore.

Before production use, perform a controlled nonproduction restore and verify
the AWS Backup result, read-only credentials, VPC endpoint access, retry/DLQ
behavior, expected failures, and temporary-resource cleanup.

### Strict recovery qualification (opt-in)

The ordinary `validate-backup.sh` check validates deployed AWS Backup and
Restore Testing configuration and reports the latest execution result. It
intentionally does **not** fail solely because no restore has run yet, SQL
validation failed, or temporary-resource cleanup has not finished. This
preserves the existing behavior of routine baseline evidence exports.

To require a successful **live** recovery exercise, run from the repository
root after initializing the workload's remote backend:

```bash
AWS_PROFILE=dev AWS_REGION=us-east-1 \
REQUIRE_RESTORE_QUALIFICATION=true \
./scripts/validation/validate-backup.sh dev
```

`REQUIRE_RESTORE_QUALIFICATION` defaults to `false` and accepts only the
literal values `true` and `false`. In strict mode, the validator fails unless:

- AWS Backup and the RDS Restore Testing and SQL Restore Validation modules are
  currently enabled in Terraform.
- At least one Restore Testing job exists for the configured plan, and the
  **latest** job has `Status=COMPLETED`, `ValidationStatus=SUCCESSFUL`, and
  `DeletionStatus=SUCCESSFUL`. Pending jobs, failed/timed-out SQL validation,
  failed cleanup, and missing outcomes **fail** qualification.
- An independent `DescribeRestoreJob` read agrees with the expected account,
  Restore Testing plan, source RDS ARN, resource type, and distinct restored RDS
  instance; a recovery point and completion time are recorded.
- AWS Backup's validation message is exactly
  `RDS restore isolation and synthetic SQL canary verified`, submitted by the
  existing coordinator only after the SQL worker verifies all three canary
  records and the restricted reader role.

The strict check is **read-only**: it neither creates a restore nor invokes the
validator Lambdas. It evaluates the latest job rather than an operator-selected
historical success; it does not enforce a maximum evidence age or establish an
application-level RTO/RPO. Preserve the job ID, source commit, validation and
cleanup timestamps, and private evidence separately. The GitHub **Export
Baseline Evidence** workflow remains in its normal non-strict mode unless
explicitly configured to pass the strict environment variable.

### Failure monitoring

When Restore Validation is enabled, `alarms.tf` creates four CloudWatch alarms
routed through the existing `secops_topic_arn` (no separate SNS topic):

- `validation_dlq_messages`: one or more visible messages in the validation DLQ.
- `lambda_errors["coordinator"]` and `lambda_errors["worker"]`: one or more
  Lambda invocation errors in a five-minute period.
- `validation_failed`: a CloudWatch Logs metric filter counts the coordinator's
  `validation submitted: FAILED` log message when definitive SQL verification
  fails. A legitimate worker `FAIL` result may not increment Lambda `Errors`.

These alarms do not independently detect absent Restore Testing executions,
AWS Backup validation timeouts without a Lambda error, or failed AWS-managed
restore cleanup. Strict qualification checks the latest observed result; an
operational owner must also review schedule execution and notifications. Verify
SNS subscription confirmation, alarm action history, and actual recipient
delivery before claiming end-to-end alerting.
