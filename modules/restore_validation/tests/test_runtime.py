#!/usr/bin/env python3
"""Offline coordinator + worker contract tests; no AWS credentials or network."""
from __future__ import annotations

import io
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest import TestCase, main, mock

MODULE = Path(__file__).resolve().parents[1]
LAMBDA = MODULE / "lambda"
sys.path.insert(0, str(LAMBDA))
import coordinator as c  # noqa: E402
import worker as w  # noqa: E402

ACCOUNT = "123456789012"
REGION = "us-east-1"
SOURCE = f"arn:aws:rds:{REGION}:{ACCOUNT}:db:source-db"
RESTORE = f"arn:aws:rds:{REGION}:{ACCOUNT}:db:awsbackup-restore-1"
PLAN = f"arn:aws:backup:{REGION}:{ACCOUNT}:restore-testing-plan:plan1"
ENDPOINT = "test.abcdefghijkl.us-east-1.rds.amazonaws.com"
CFG = {
    "EXPECTED_ACCOUNT_ID": ACCOUNT,
    "EXPECTED_REGION": REGION,
    "SOURCE_RDS_ARN": SOURCE,
    "RESTORE_TESTING_PLAN_ARN": PLAN,
    "EXPECTED_RESTORE_TEST_DB_SG_ID": "sg-0123456789abcdef0",
    "EXPECTED_VPC_ID": "vpc-0123456789abcdef0",
    "WORKER_FUNCTION_NAME": "restore-validation-worker",
}
WCFG = {"AWS_REGION": REGION, "VALIDATION_SECRET_ARN": f"arn:aws:secretsmanager:{REGION}:{ACCOUNT}:secret:canary-123", "DB_NAME": "app", "DB_PORT": "5432"}
JOBID = "ABCDEF01-2345-6789-ABCD-123456789ABC"


def event(**detail):
    d = {"status": "COMPLETED", "resourceType": "RDS", "restoreTestingPlanArn": PLAN, "restoreJobId": JOBID}
    d.update(detail)
    return {"source": "aws.backup", "detail-type": "Restore Job State Change", "account": ACCOUNT, "region": REGION, "detail": d}


def job(**fields):
    d = {"RestoreJobId": JOBID, "AccountId": ACCOUNT, "CreatedBy": {"RestoreTestingPlanArn": PLAN},
         "SourceResourceArn": SOURCE, "ResourceType": "RDS", "Status": "COMPLETED", "CreatedResourceArn": RESTORE}
    d.update(fields)
    return d


def instance(**fields):
    d = {"DBInstanceArn": RESTORE, "DBInstanceStatus": "available", "Engine": "postgres",
         "PubliclyAccessible": False, "StorageEncrypted": True, "MultiAZ": False,
         "DBSubnetGroup": {"VpcId": "vpc-0123456789abcdef0"},
         "VpcSecurityGroups": [{"VpcSecurityGroupId": "sg-0123456789abcdef0", "Status": "active"}],
         "Endpoint": {"Address": ENDPOINT, "Port": 5432}}
    d.update(fields)
    return d


def invoke(status="PASS", code="SQL_CANARY_VERIFIED", count=3):
    return {"StatusCode": 200, "Payload": io.BytesIO(json.dumps({"status": status, "code": code, "checked_rows": count}).encode())}


def clients(db=None, backup_job=None, worker_result=None):
    b, r, worker = mock.Mock(), mock.Mock(), mock.Mock()
    b.describe_restore_job.return_value = job() if backup_job is None else backup_job
    r.describe_db_instances.return_value = {"DBInstances": [instance() if db is None else db]}
    worker.invoke.return_value = invoke() if worker_result is None else worker_result
    return b, r, worker


class CoordinatorTests(TestCase):
    def test_success_reports_only_after_sql_verification(self):
        b, r, worker = clients()
        response = c.run(event(), CFG, b, r, worker)
        self.assertEqual(response["status"], "SUCCESSFUL")
        worker.invoke.assert_called_once()
        self.assertEqual(worker.invoke.call_args.kwargs["InvocationType"], "RequestResponse")
        self.assertEqual(json.loads(worker.invoke.call_args.kwargs["Payload"])["host"], ENDPOINT)
        b.put_restore_validation_result.assert_called_once_with(
            RestoreJobId=JOBID, ValidationStatus="SUCCESSFUL",
            ValidationStatusMessage="RDS restore isolation and synthetic SQL canary verified")

    def test_all_untrusted_event_cases_are_rejected_before_api_calls(self):
        cases = [event(status="FAILED"), event(resourceType="EC2"), event(restoreTestingPlanArn="other"),
                 event(restoreJobId="bad"), {**event(), "account": "000000000000"},
                 {**event(), "region": "us-west-2"}, {**event(), "source": "other"},
                 {**event(), "detail-type": "other"}]
        for candidate in cases:
            with self.subTest(candidate=candidate), self.assertRaises(c.RejectedEvent):
                b, r, worker = clients()
                c.run(candidate, CFG, b, r, worker)
                b.describe_restore_job.assert_not_called()

    def test_mismatched_authoritative_job_never_reports(self):
        for info in (job(SourceResourceArn="other"), job(CreatedBy={}), job(AccountId="111111111111"),
                     job(CreatedResourceArn=SOURCE), job(ResourceType="EC2")):
            with self.subTest(info=info), self.assertRaises(c.RejectedEvent):
                b, r, worker = clients(backup_job=info)
                try: c.run(event(), CFG, b, r, worker)
                finally: b.put_restore_validation_result.assert_not_called()

    def test_duplicate_delivery_is_idempotent(self):
        for status in ("SUCCESSFUL", "FAILED", "TIMED_OUT"):
            with self.subTest(status=status):
                b, r, worker = clients(backup_job=job(ValidationStatus=status))
                self.assertEqual(c.run(event(), CFG, b, r, worker)["status"], "ALREADY_RECORDED")
                worker.invoke.assert_not_called()
                b.put_restore_validation_result.assert_not_called()

    def test_validating_is_not_terminal_and_reports_conclusive_result(self):
        b, r, worker = clients(backup_job=job(ValidationStatus="VALIDATING"))
        self.assertEqual(c.run(event(), CFG, b, r, worker)["status"], "SUCCESSFUL")
        worker.invoke.assert_called_once()
        b.put_restore_validation_result.assert_called_once()

    def test_unexpected_validation_status_does_not_report(self):
        b, r, worker = clients(backup_job=job(ValidationStatus="UNRECOGNIZED"))
        with self.assertRaises(c.RetryableFailure):
            c.run(event(), CFG, b, r, worker)
        worker.invoke.assert_not_called()
        b.put_restore_validation_result.assert_not_called()

    def test_wrong_isolation_is_definitive_failure(self):
        bad = [instance(VpcSecurityGroups=[]), instance(PubliclyAccessible=True),
               instance(StorageEncrypted=False), instance(MultiAZ=True),
               instance(Engine="mysql"), instance(DBSubnetGroup={"VpcId": "vpc-other"}),
               instance(DBInstanceArn=SOURCE)]
        for db in bad:
            with self.subTest(db=db):
                b, r, worker = clients(db=db)
                self.assertEqual(c.run(event(), CFG, b, r, worker)["status"], "FAILED")
                worker.invoke.assert_not_called()
                self.assertEqual(b.put_restore_validation_result.call_args.kwargs["ValidationStatus"], "FAILED")

    def test_rds_not_ready_is_retryable_no_report(self):
        b, r, worker = clients(db=instance(DBInstanceStatus="creating"))
        with self.assertRaises(c.RetryableFailure): c.run(event(), CFG, b, r, worker)
        b.put_restore_validation_result.assert_not_called()

    def test_worker_integrity_failure_is_reported(self):
        b, r, worker = clients(worker_result=invoke("FAIL", "SYNTHETIC_CANARY_MISMATCH", 0))
        self.assertEqual(c.run(event(), CFG, b, r, worker)["status"], "FAILED")
        self.assertIn("SYNTHETIC_CANARY_MISMATCH", b.put_restore_validation_result.call_args.kwargs["ValidationStatusMessage"])

    def test_worker_transient_failure_is_retryable_no_report(self):
        for result in (invoke("RETRY", "WORKER_UNAVAILABLE", 0),
                       {"StatusCode": 200, "FunctionError": "Unhandled", "Payload": io.BytesIO(b"{}")},
                       {"StatusCode": 200, "Payload": io.BytesIO(b"not json")}):
            with self.subTest(result=result):
                b, r, worker = clients(worker_result=result)
                if result.get("Payload") and hasattr(result["Payload"], "seek"):
                    result["Payload"].seek(0)
                with self.assertRaises((c.RetryableFailure, c.DefinitiveFailure)):
                    c.run(event(), CFG, b, r, worker)
                b.put_restore_validation_result.assert_not_called()

    def test_backup_report_error_propagates_for_retry(self):
        b, r, worker = clients()
        b.put_restore_validation_result.side_effect = RuntimeError("throttled")
        with self.assertRaises(RuntimeError): c.run(event(), CFG, b, r, worker)


class MockCursor:
    def __init__(self, rows=None, flags=None, writable=False):
        self.rows = rows
        self.flags = (False,) * 5 if flags is None else flags
        self.writable = writable
        self.calls = []

    def execute(self, sql): self.calls.append(sql)
    def fetchall(self): return self.rows
    def fetchone(self):
        return (self.writable,) if "has_table_privilege" in self.calls[-1] else self.flags
    def close(self): pass


class WorkerTests(TestCase):
    def setUp(self):
        self.contract = w.read_contract(w.CANARY_PATH)
        self.mock_secrets = mock.Mock()
        self.mock_secrets.get_secret_value.return_value = {"SecretString": json.dumps({"username": "readonly", "password": "synthetic-password"})}
        self.cur = MockCursor(rows=self.contract)
        self.conn = mock.Mock()
        self.conn.cursor.return_value = self.cur
        self.connect = mock.Mock(return_value=self.conn)
        self.payload = {"host": ENDPOINT, "port": 5432, "db_instance_arn": RESTORE, "restore_job_id": JOBID}
        self.fake_ca = Path(tempfile.mkstemp(prefix="restore-rds-ca-")[1])
        self.addCleanup(lambda: self.fake_ca.unlink(missing_ok=True))
        self.fake_ca.write_text("-----BEGIN CERTIFICATE-----\nplaceholder\n-----END CERTIFICATE-----\n")

    def run_worker(self, **kw):
        with mock.patch("worker.ssl.create_default_context", return_value=mock.Mock()) as ssl_ctx:
            return w.run(kw.get("payload", self.payload), WCFG, self.mock_secrets, self.connect,
                         ca_path=self.fake_ca)

    def test_positive_read_only_tls_verified(self):
        result = self.run_worker()
        self.assertEqual(result, {"status": "PASS", "code": "SQL_CANARY_VERIFIED", "checked_rows": 3})
        self.assertTrue(self.cur.calls[0].startswith("SET TRANSACTION READ ONLY"))
        self.assertIn("SELECT marker_id", " ".join(self.cur.calls))
        self.assertEqual(self.connect.call_args.kwargs["user"], "readonly")
        self.assertTrue(self.connect.call_args.kwargs["ssl_context"].check_hostname)
        self.assertEqual(self.connect.call_args.kwargs["ssl_context"].verify_mode, __import__("ssl").CERT_REQUIRED)
        self.conn.close.assert_called_once()

    def test_corrupted_deleted_or_extra_rows_fail(self):
        for rows in ([], self.contract[:2], self.contract + [("extra", "garbage")],
                     [("alpha", "bad")] + self.contract[1:]):
            with self.subTest(rows=rows):
                self.cur.rows = rows
                self.assertEqual(self.run_worker()["code"], "SYNTHETIC_CANARY_MISMATCH")

    def test_privileged_role_fails(self):
        self.cur.flags = (True, False, False, False, False)
        self.assertEqual(self.run_worker()["code"], "VALIDATION_ROLE_PRIVILEGED")

    def test_writable_role_fails(self):
        self.cur.writable = True
        self.assertEqual(self.run_worker()["code"], "VALIDATION_ROLE_CAN_MODIFY_CANARY")

    def test_invalid_rds_hostname_and_port_fail_before_secret(self):
        for change in ({"host": "127.0.0.1"}, {"host": "db.example.com"}, {"port": 80}):
            with self.subTest(change=change):
                result = self.run_worker(payload={**self.payload, **change})
                self.assertEqual(result["status"], "FAIL")
                self.mock_secrets.get_secret_value.assert_not_called()

    def test_missing_schema_or_credential_denial_is_definitive(self):
        for sqlstate in ("42P01", "42703", "42501", "3D000", "28P01"):
            with self.subTest(sqlstate=sqlstate):
                self.connect.side_effect = RuntimeError({"C": sqlstate, "M": "redacted"})
                response = self.run_worker()
                self.assertEqual(response["status"], "FAIL")
                self.assertEqual(response["code"], "SQL_SCHEMA_OR_ACCESS_ERROR")

    def test_missing_credentials_or_db_failure_is_retryable(self):
        self.mock_secrets.get_secret_value.return_value = {"SecretString": "{}"}
        self.assertEqual(self.run_worker()["status"], "RETRY")
        self.mock_secrets.get_secret_value.return_value = {"SecretString": json.dumps({"username": "u", "password": "p"})}
        self.connect.side_effect = OSError("db unavailable")
        self.assertEqual(self.run_worker()["status"], "RETRY")

    def test_missing_ca_is_retryable(self):
        self.fake_ca.unlink()
        self.assertEqual(self.run_worker()["status"], "RETRY")

    def test_fixture_values_match_sql_seed(self):
        sql = (MODULE / "sql/seed_canary.sql").read_text()
        for key, value in self.contract:
            self.assertIn("'" + key + "', '" + value + "'", sql)


if __name__ == "__main__":
    main(verbosity=2)
