"""AWS Backup RDS restore-testing coordinator.

The restore result is effectively immutable. Never publish SUCCESSFUL unless
trusted job metadata, restored DB isolation and the SQL canary all pass.
"""
from __future__ import annotations

import json
import logging
import os
import re
from typing import Any

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)
JOB_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]{7,127}$")


class RejectedEvent(Exception):
    """Untrusted or unrelated event: do not report to AWS Backup."""


class DefinitiveFailure(Exception):
    """Confirmed isolation or synthetic-data violation."""


class RetryableFailure(Exception):
    """No integrity conclusion is possible; let Lambda retry/DLQ."""


def required(env: dict[str, str], key: str) -> str:
    value = env.get(key, "").strip()
    if not value:
        raise RuntimeError(f"Missing required configuration: {key}")
    return value


def event_identity(event: dict[str, Any], env: dict[str, str]) -> str:
    """Check the full envelope before making any mutable Backup API call."""
    if not isinstance(event, dict):
        raise RejectedEvent("Invalid event type")
    detail = event.get("detail", {})
    if not isinstance(detail, dict):
        raise RejectedEvent("Invalid detail type")
    fields = {
        "source": "aws.backup",
        "detail-type": "Restore Job State Change",
        "account": required(env, "EXPECTED_ACCOUNT_ID"),
        "region": required(env, "EXPECTED_REGION"),
    }
    if any(event.get(k) != v for k, v in fields.items()):
        raise RejectedEvent("Unexpected event envelope")
    if any(detail.get(k) != v for k, v in {
        "status": "COMPLETED",
        "resourceType": "RDS",
        "restoreTestingPlanArn": required(env, "RESTORE_TESTING_PLAN_ARN"),
    }.items()):
        raise RejectedEvent("Unexpected restore testing event")
    job_id = detail.get("restoreJobId", "")
    if not isinstance(job_id, str) or not JOB_ID.fullmatch(job_id):
        raise RejectedEvent("Invalid restore job identifier")
    return job_id


def check_job(job: dict[str, Any], job_id: str, env: dict[str, str]) -> str:
    """DescribeRestoreJob is authoritative; event fields aren't sufficient."""
    if job.get("RestoreJobId") != job_id:
        raise RejectedEvent("Restore job ID mismatch")
    if job.get("AccountId") != required(env, "EXPECTED_ACCOUNT_ID"):
        raise RejectedEvent("Restore job account mismatch")
    if job.get("CreatedBy", {}).get("RestoreTestingPlanArn") != required(env, "RESTORE_TESTING_PLAN_ARN"):
        raise RejectedEvent("Restore testing plan mismatch")
    if job.get("SourceResourceArn") != required(env, "SOURCE_RDS_ARN"):
        raise RejectedEvent("Source database mismatch")
    if job.get("ResourceType") != "RDS":
        raise RejectedEvent("Unexpected restore resource type")
    if job.get("Status") != "COMPLETED":
        raise RetryableFailure("Restore job is not yet completed")

    arn = job.get("CreatedResourceArn", "")
    partition = required(env, "SOURCE_RDS_ARN").split(":", 2)[1]
    expected_prefix = (
        f"arn:{partition}:rds:{required(env, 'EXPECTED_REGION')}:"
        f"{required(env, 'EXPECTED_ACCOUNT_ID')}:db:"
    )
    if (not isinstance(arn, str) or not arn.startswith(expected_prefix)
            or not re.fullmatch(r"[A-Za-z0-9-]{1,63}", arn[len(expected_prefix):])
            or arn == required(env, "SOURCE_RDS_ARN")):
        raise RejectedEvent("Created resource does not identify a distinct RDS instance")
    return arn


def check_instance(db: dict[str, Any], arn: str, env: dict[str, str]) -> tuple[str, int]:
    """Only pass an isolated, available, encrypted, nonpublic PostgreSQL DB."""
    if db.get("DBInstanceArn") != arn:
        raise DefinitiveFailure("RDS_ARN_MISMATCH")
    if db.get("DBInstanceStatus") != "available":
        raise RetryableFailure("RDS_NOT_AVAILABLE")
    if db.get("Engine") != "postgres":
        raise DefinitiveFailure("UNEXPECTED_DB_ENGINE")
    if db.get("PubliclyAccessible") is not False:
        raise DefinitiveFailure("RDS_PUBLIC_ACCESS")
    if db.get("StorageEncrypted") is not True:
        raise DefinitiveFailure("RDS_STORAGE_NOT_ENCRYPTED")
    if db.get("MultiAZ") is not False:
        raise DefinitiveFailure("RESTORE_NOT_SINGLE_AZ")
    if db.get("DBSubnetGroup", {}).get("VpcId") != required(env, "EXPECTED_VPC_ID"):
        raise DefinitiveFailure("RDS_WRONG_VPC")
    sg = db.get("VpcSecurityGroups")
    if (not isinstance(sg, list) or len(sg) != 1
            or sg[0].get("VpcSecurityGroupId") != required(env, "EXPECTED_RESTORE_TEST_DB_SG_ID")
            or sg[0].get("Status") != "active"):
        raise DefinitiveFailure("RDS_WRONG_SECURITY_GROUP")
    endpoint = db.get("Endpoint", {})
    host = endpoint.get("Address", "")
    port = endpoint.get("Port")
    if not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9.-]{10,253}", host):
        raise RetryableFailure("RDS_ENDPOINT_UNAVAILABLE")
    if type(port) is not int or not 1 <= port <= 65535:
        raise RetryableFailure("RDS_PORT_UNAVAILABLE")
    return host, port


def check_worker(invocation: dict[str, Any]) -> tuple[str, str]:
    if invocation.get("StatusCode") != 200 or invocation.get("FunctionError"):
        raise RetryableFailure("WORKER_INVOCATION_ERROR")
    stream = invocation.get("Payload")
    try:
        body = stream.read(16385) if hasattr(stream, "read") else stream
        if isinstance(body, bytes):
            body = body.decode("utf-8")
        if len(body) > 16384:
            raise ValueError("Worker payload too large")
        result = json.loads(body)
        status, code = result.get("status"), result.get("code")
        if status not in {"PASS", "FAIL", "RETRY"} or not isinstance(code, str):
            raise ValueError("Malformed worker status")
        if not re.fullmatch(r"[A-Z0-9_]{1,64}", code):
            raise ValueError("Malformed worker code")
        if status == "RETRY":
            raise RetryableFailure(f"WORKER_{code}")
        if status == "FAIL":
            raise DefinitiveFailure(f"WORKER_{code}")
        if result.get("checked_rows") != 3:
            raise DefinitiveFailure("WORKER_INCOMPLETE_VERIFICATION")
        return status, code
    except (ValueError, TypeError, UnicodeDecodeError, AttributeError) as exc:
        raise RetryableFailure("MALFORMED_WORKER_RESPONSE") from exc


def run(event: dict[str, Any], env: dict[str, str], backup: Any, rds: Any, worker: Any) -> dict[str, str]:
    job_id = event_identity(event, env)
    job = backup.describe_restore_job(RestoreJobId=job_id)
    arn = check_job(job, job_id, env)
    if job.get("ValidationStatus") is not None:
        LOG.info("Validation already recorded for job %s; no mutation", job_id)
        return {"status": "ALREADY_RECORDED", "job_id": job_id}
    try:
        rows = rds.describe_db_instances(DBInstanceIdentifier=arn).get("DBInstances", [])
        if len(rows) != 1:
            raise RetryableFailure("RDS_LOOKUP_NOT_UNIQUE")
        host, port = check_instance(rows[0], arn, env)
        payload = {"restore_job_id": job_id, "db_instance_arn": arn, "host": host, "port": port}
        response = worker.invoke(
            FunctionName=required(env, "WORKER_FUNCTION_NAME"),
            InvocationType="RequestResponse",
            Payload=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        )
        check_worker(response)
        status, message = "SUCCESSFUL", "RDS restore isolation and synthetic SQL canary verified"
    except DefinitiveFailure as exc:
        status, message = "FAILED", str(exc)
    except RetryableFailure:
        # Do NOT permanently mark a restore failed for transient invocation,
        # propagation or network failures. Lambda retry/DLQ retains evidence.
        raise
    backup.put_restore_validation_result(
        RestoreJobId=job_id,
        ValidationStatus=status,
        ValidationStatusMessage=message[:1024],
    )
    LOG.info("Restore job %s validation submitted: %s", job_id, status)
    return {"status": status, "job_id": job_id}


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, str]:
    import boto3
    from botocore.config import Config

    cfg = os.environ
    region = required(cfg, "EXPECTED_REGION")
    common = Config(connect_timeout=5, read_timeout=20, retries={"mode": "standard", "max_attempts": 3})
    backup = boto3.client("backup", region_name=region, config=common)
    rds = boto3.client("rds", region_name=region, config=common)
    invoke_cfg = Config(connect_timeout=5, read_timeout=145, retries={"mode": "standard", "max_attempts": 2})
    worker = boto3.client("lambda", region_name=region, config=invoke_cfg)
    return run(event, cfg, backup, rds, worker)
