"""Disposable M3 PostgreSQL canary HTTP service; not a production application."""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

LOG = logging.getLogger("m3-canary")
CANARY_ID = re.compile(r"[a-zA-Z0-9._-]{1,64}\Z")
MAX_REQUEST_BYTES = 2048
MAX_VALUE_BYTES = 1024


class PgCanaryStore:
    """Use fresh, short-lived connections so failover/DNS recovery is observable."""

    def __init__(self, config: dict[str, str]):
        self.config = config

    def _connect(self):
        # Import at connection time so the HTTP contract can be unit-tested
        # without any third-party packages or AWS access.
        import psycopg

        return psycopg.connect(
            host=self.config["M3_DB_HOST"],
            port=int(self.config.get("M3_DB_PORT", "5432")),
            dbname=self.config["M3_DB_NAME"],
            user=self.config["M3_DB_USER"],
            password=self.config["M3_DB_PASSWORD"],
            sslmode="verify-full",
            sslrootcert="/app/rds-ca.pem",
            connect_timeout=3,
            options="-c statement_timeout=5000",
        )

    def ready(self) -> bool:
        with self._connect() as connection, connection.cursor() as cursor:
            cursor.execute("SELECT 1")
            return cursor.fetchone() == (1,)

    def read(self, canary_id: str) -> str | None:
        with self._connect() as connection, connection.cursor() as cursor:
            cursor.execute(
                "SELECT payload_sha256 FROM public.m3_canary WHERE canary_id = %s",
                (canary_id,),
            )
            result = cursor.fetchone()
            return result[0] if result else None

    def put(self, canary_id: str, digest: str) -> tuple[bool, str]:
        with self._connect() as connection, connection.cursor() as cursor:
            cursor.execute(
                "INSERT INTO public.m3_canary (canary_id, payload_sha256) "
                "VALUES (%s, %s) ON CONFLICT (canary_id) DO NOTHING",
                (canary_id, digest),
            )
            inserted = cursor.rowcount == 1
            cursor.execute(
                "SELECT payload_sha256 FROM public.m3_canary WHERE canary_id = %s",
                (canary_id,),
            )
            existing = cursor.fetchone()
            if existing is None:
                raise RuntimeError("Inserted canary could not be read back")
            return inserted, existing[0]


class CanaryServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store, token: str):
        self.store = store
        self.token = token
        super().__init__(address, CanaryHandler)


class CanaryHandler(BaseHTTPRequestHandler):
    server: CanaryServer

    def log_message(self, fmt, *args):
        # Avoid logging request content, query strings, tokens, or error details.
        LOG.info("http request from client")

    def _send(self, status: HTTPStatus, body: dict):
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _path(self) -> str:
        parsed = urlsplit(self.path)
        return parsed.path if not parsed.query and not parsed.fragment else ""

    def _canary_id(self, path: str) -> str | None:
        if not path.startswith("/canary/"):
            return None
        candidate = path.removeprefix("/canary/")
        return candidate if CANARY_ID.fullmatch(candidate) else None

    def _authorized(self) -> bool:
        provided = self.headers.get("Authorization", "")
        expected = "Bearer " + self.server.token
        return hmac.compare_digest(provided, expected)

    def do_GET(self):
        path = self._path()
        if path == "/health":
            return self._send(HTTPStatus.OK, {"status": "alive"})
        if path == "/ready":
            try:
                ready = self.server.store.ready()
            except Exception as error:
                LOG.warning("database readiness unavailable: %s", type(error).__name__)
                ready = False
            return self._send(
                HTTPStatus.OK if ready else HTTPStatus.SERVICE_UNAVAILABLE,
                {"status": "ready" if ready else "unavailable"},
            )

        canary_id = self._canary_id(path)
        if canary_id is None:
            return self._send(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        if not self._authorized():
            return self._send(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        try:
            digest = self.server.store.read(canary_id)
        except Exception as error:
            LOG.warning("canary read unavailable: %s", type(error).__name__)
            return self._send(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "database_unavailable"})
        if digest is None:
            return self._send(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        return self._send(HTTPStatus.OK, {"id": canary_id, "sha256": digest})

    def do_PUT(self):
        canary_id = self._canary_id(self._path())
        if canary_id is None:
            return self._send(HTTPStatus.NOT_FOUND, {"error": "not_found"})
        if not self._authorized():
            return self._send(HTTPStatus.UNAUTHORIZED, {"error": "unauthorized"})
        if self.headers.get("Content-Type", "").split(";")[0].strip().lower() != "application/json":
            return self._send(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, {"error": "invalid_content_type"})
        if self.headers.get("Transfer-Encoding"):
            return self._send(HTTPStatus.BAD_REQUEST, {"error": "chunked_not_supported"})
        try:
            size = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._send(HTTPStatus.LENGTH_REQUIRED, {"error": "content_length_required"})
        if size < 1 or size > MAX_REQUEST_BYTES:
            return self._send(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "invalid_size"})
        try:
            data = json.loads(self.rfile.read(size).decode("utf-8"))
            if not isinstance(data, dict) or set(data) != {"value"}:
                raise ValueError("Expected a value field")
            value = data["value"]
            if not isinstance(value, str) or not 1 <= len(value.encode("utf-8")) <= MAX_VALUE_BYTES:
                raise ValueError("Canary value must be a nonempty short string")
        except (ValueError, UnicodeDecodeError):
            return self._send(HTTPStatus.BAD_REQUEST, {"error": "invalid_json_value"})
        digest = hashlib.sha256(value.encode("utf-8")).hexdigest()
        try:
            inserted, observed = self.server.store.put(canary_id, digest)
        except Exception as error:
            LOG.warning("canary write unavailable: %s", type(error).__name__)
            return self._send(HTTPStatus.SERVICE_UNAVAILABLE, {"error": "database_unavailable"})
        if not hmac.compare_digest(observed, digest):
            return self._send(HTTPStatus.CONFLICT, {"error": "immutable_canary_conflict"})
        return self._send(HTTPStatus.CREATED if inserted else HTTPStatus.OK, {"id": canary_id, "sha256": observed})


def main() -> None:
    # Refuse to serve write endpoints with missing/weak credentials.
    names = ("M3_DB_HOST", "M3_DB_NAME", "M3_DB_USER", "M3_DB_PASSWORD", "M3_CANARY_TOKEN")
    config = {name: os.environ.get(name, "") for name in names}
    if any(not config[name] for name in names) or len(config["M3_CANARY_TOKEN"]) < 32:
        raise SystemExit("Missing database configuration or canary authentication secret")
    config["M3_DB_PORT"] = os.environ.get("M3_DB_PORT", "5432")
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    with CanaryServer(("0.0.0.0", 8080), PgCanaryStore(config), config["M3_CANARY_TOKEN"]) as server:
        LOG.info("m3 canary started on port 8080")
        server.serve_forever()


if __name__ == "__main__":
    main()
