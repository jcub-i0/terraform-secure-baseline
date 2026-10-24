"""Read-only PostgreSQL synthetic canary checks on a temporary restored RDS DB."""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
import re
import ssl
from typing import Any

LOG = logging.getLogger(__name__)
LOG.setLevel(logging.INFO)
HERE = Path(__file__).resolve().parent
CANARY_PATH = HERE / "canary_contract.json"
CA_BUNDLE_PATH = HERE / "rds-ca-bundle.pem"


class PermanentCheckFailure(Exception):
    pass


class RetryableCheckFailure(Exception):
    pass


def verify_event(event: dict[str, Any], expected_port: int, region: str) -> tuple[str, int]:
    if not isinstance(event, dict):
        raise PermanentCheckFailure("INVALID_PAYLOAD")
    host, port = event.get("host"), event.get("port")
    if not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9.-]{10,253}", host):
        raise PermanentCheckFailure("INVALID_ENDPOINT")
    # AWS-issued RDS DNS names only; no generic host, IPv4, localhost or URL.
    if not re.fullmatch(r"[a-z0-9-]{5,32}", region):
        raise PermanentCheckFailure("INVALID_REGION")
    if not host.endswith((".rds.amazonaws.com", f".rds-{region}.amazonaws.com")):
        raise PermanentCheckFailure("INVALID_RDS_DNS_SUFFIX")
    if type(port) is not int or port != expected_port:
        raise PermanentCheckFailure("WRONG_DATABASE_PORT")
    if not isinstance(event.get("restore_job_id"), str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9-]{7,127}", event["restore_job_id"]
    ):
        raise PermanentCheckFailure("INVALID_RESTORE_JOB_ID")
    if not isinstance(event.get("db_instance_arn"), str) or ":rds:" not in event["db_instance_arn"]:
        raise PermanentCheckFailure("INVALID_RDS_ARN")
    return host, port


def read_contract(path: Path) -> list[tuple[str, str]]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("version") != 1 or not isinstance(data.get("records"), list):
        raise RuntimeError("Unsupported or missing synthetic canary contract")
    records = [(r["id"], r["value"]) for r in data["records"]]
    if len(records) != 3 or len({r[0] for r in records}) != 3:
        raise RuntimeError("Invalid synthetic canary contract")
    return sorted(records)


def read_credentials(secrets: Any, secret_arn: str) -> tuple[str, str]:
    response = secrets.get_secret_value(SecretId=secret_arn)
    payload = response.get("SecretString")
    if not isinstance(payload, str):
        raise RetryableCheckFailure("SECRET_NOT_TEXT")
    try:
        value = json.loads(payload)
    except (TypeError, json.JSONDecodeError) as exc:
        raise RetryableCheckFailure("SECRET_MALFORMED") from exc
    if not isinstance(value, dict) or not all(
        isinstance(value.get(k), str) and value[k] for k in ("username", "password")
    ):
        raise RetryableCheckFailure("SECRET_MISSING_KEYS")
    return value["username"], value["password"]


def check_sql(connection: Any, expected: list[tuple[str, str]]) -> None:
    cursor = connection.cursor()
    try:
        # Defense in depth: even a misconfigured credential uses a read-only session.
        cursor.execute("SET TRANSACTION READ ONLY")
        cursor.execute("SET statement_timeout = '10000ms'")
        cursor.execute("SET lock_timeout = '2000ms'")
        cursor.execute("SELECT marker_id, marker_value FROM restore_validation.canary ORDER BY marker_id")
        actual = sorted(tuple(row) for row in cursor.fetchall())
        if actual != expected:
            raise PermanentCheckFailure("SYNTHETIC_CANARY_MISMATCH")
        # Credential must not be privileged or able to mutate the sentinel.
        cursor.execute(
            "SELECT rolsuper, rolcreaterole, rolcreatedb, rolreplication, rolbypassrls "
            "FROM pg_roles WHERE rolname = current_user"
        )
        flags = cursor.fetchone()
        if flags is None or any(flags):
            raise PermanentCheckFailure("VALIDATION_ROLE_PRIVILEGED")
        cursor.execute(
            "SELECT has_table_privilege(current_user, "
            "'restore_validation.canary', 'INSERT,UPDATE,DELETE,TRUNCATE')"
        )
        privileged = cursor.fetchone()
        if privileged is None or privileged[0] is not False:
            raise PermanentCheckFailure("VALIDATION_ROLE_CAN_MODIFY_CANARY")
    finally:
        cursor.close()


def run(event: dict[str, Any], env: dict[str, str], secrets: Any, connect: Any,
        contract_path: Path = CANARY_PATH, ca_path: Path = CA_BUNDLE_PATH) -> dict[str, Any]:
    try:
        secret_arn = env["VALIDATION_SECRET_ARN"]
        dbname = env["DB_NAME"]
        port = int(env["DB_PORT"])
        if not secret_arn or not dbname:
            raise RuntimeError("Missing DB or secret configuration")
        host, _ = verify_event(event, port, env.get("AWS_REGION", "us-east-1"))
        expected = read_contract(contract_path)
        if not ca_path.is_file():
            raise RuntimeError("Missing pinned RDS CA certificate bundle")
        username, password = read_credentials(secrets, secret_arn)
        tls = ssl.create_default_context(cafile=str(ca_path))
        tls.check_hostname = True
        tls.verify_mode = ssl.CERT_REQUIRED
        connection = connect(
            host=host,
            port=port,
            database=dbname,
            user=username,
            password=password,
            ssl_context=tls,
            timeout=10,
        )
        try:
            check_sql(connection, expected)
        finally:
            connection.close()
        LOG.info("Restore SQL canary and role privilege checks passed")
        return {"status": "PASS", "code": "SQL_CANARY_VERIFIED", "checked_rows": len(expected)}
    except PermanentCheckFailure as exc:
        LOG.warning("Definitive restore SQL validation failure: %s", exc)
        return {"status": "FAIL", "code": str(exc), "checked_rows": 0}
    except Exception as exc:
        # pg8000 DatabaseError stores SQLSTATE in args[0]["C"]. A missing
        # canary/schema or denied SELECT is definitive, not a network retry.
        first_arg = exc.args[0] if getattr(exc, "args", ()) else None
        sqlstate = first_arg.get("C") if isinstance(first_arg, dict) else None
        if sqlstate in {"42P01", "42703", "42501", "3D000", "28P01", "28000"}:
            LOG.warning("Definitive database schema/privilege/authentication failure: %s", sqlstate)
            return {"status": "FAIL", "code": "SQL_SCHEMA_OR_ACCESS_ERROR", "checked_rows": 0}
        # No credentials, endpoint or traceback contents are serialized or logged.
        LOG.warning("Restore SQL validation could not reach a conclusion")
        return {"status": "RETRY", "code": "WORKER_UNAVAILABLE", "checked_rows": 0}


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    import boto3
    from pg8000.dbapi import connect
    region = os.environ.get("AWS_REGION", "us-east-1")
    secrets = boto3.client("secretsmanager", region_name=region)
    return run(event, os.environ, secrets, connect)
