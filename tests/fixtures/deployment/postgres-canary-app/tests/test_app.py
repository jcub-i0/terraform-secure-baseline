"""Offline M3 fixture tests; no psycopg installation, Docker, or AWS needed."""

import hashlib
import importlib.util
import json
import sys
import threading
import unittest
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("m3_canary_app", Path(__file__).resolve().parents[1] / "app.py")
app = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(app)
TOKEN = "test-only-token-that-is-more-than-thirty-two-characters"


class FakeStore:
    def __init__(self):
        self.items = {}
        self.broken = False

    def ready(self):
        if self.broken:
            raise ConnectionError("do-not-leak-fake-password")
        return True

    def put(self, key, digest):
        if self.broken:
            raise ConnectionError("do-not-leak-fake-password")
        if key in self.items:
            return False, self.items[key]
        self.items[key] = digest
        return True, digest

    def read(self, key):
        if self.broken:
            raise ConnectionError("do-not-leak-fake-password")
        return self.items.get(key)


class HandlerTests(unittest.TestCase):
    def setUp(self):
        self.store = FakeStore()
        self.server = app.CanaryServer(("127.0.0.1", 0), self.store, TOKEN)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    def request(self, path, method="GET", *, token=None, body=None, content_type="application/json"):
        headers = {}
        if token is not None:
            headers["Authorization"] = "Bearer " + token
        if body is not None:
            headers["Content-Type"] = content_type
            data = json.dumps(body).encode() if not isinstance(body, bytes) else body
        else:
            data = None
        req = Request(self.base + path, data=data, headers=headers, method=method)
        try:
            with urlopen(req, timeout=5) as response:
                return response.status, json.loads(response.read())
        except HTTPError as response:
            return response.code, json.loads(response.read())

    def test_liveness_is_independent_of_db(self):
        self.store.broken = True
        self.assertEqual(self.request("/health"), (200, {"status": "alive"}))
        status, body = self.request("/ready")
        self.assertEqual((status, body), (503, {"status": "unavailable"}))
        self.assertNotIn("password", json.dumps(body))

    def test_readiness_is_database_backed(self):
        self.assertEqual(self.request("/ready"), (200, {"status": "ready"}))

    def test_canary_requires_authentication(self):
        for method, payload in (("GET", None), ("PUT", {"value": "test"})):
            self.assertEqual(self.request("/canary/test", method, body=payload)[0], 401)
            self.assertEqual(self.request("/canary/test", method, token="wrong", body=payload)[0], 401)
        self.assertEqual(self.store.items, {})

    def test_non_ascii_auth_header_is_rejected_without_exception(self):
        self.assertEqual(self.request("/canary/test", token="non-ascii-é")[0], 401)

    def test_canary_is_idempotent_and_immutable(self):
        digest = hashlib.sha256(b"committed-v1").hexdigest()
        created = self.request("/canary/record-01", "PUT", token=TOKEN, body={"value": "committed-v1"})
        self.assertEqual(created, (201, {"id": "record-01", "sha256": digest}))
        self.assertEqual(self.request("/canary/record-01", token=TOKEN), (200, {"id": "record-01", "sha256": digest}))
        self.assertEqual(self.request("/canary/record-01", "PUT", token=TOKEN, body={"value": "committed-v1"})[0], 200)
        self.assertEqual(self.request("/canary/record-01", "PUT", token=TOKEN, body={"value": "different"})[0], 409)
        self.assertEqual(self.store.items["record-01"], digest)

    def test_missing_canary_is_not_a_db_outage(self):
        self.assertEqual(self.request("/canary/absent", token=TOKEN)[0], 404)

    def test_db_outage_never_exposes_exception_detail(self):
        self.store.broken = True
        for method, body in (("GET", None), ("PUT", {"value": "test"})):
            status, response = self.request("/canary/test", method, token=TOKEN, body=body)
            self.assertEqual(status, 503)
            self.assertNotIn("password", json.dumps(response))

    def test_reject_invalid_body_and_paths(self):
        invalid_paths = ["/canary/../evil", "/canary/a%2Fb", "/canary/x?test=1", "/canary/a" + "a" * 65]
        for path in invalid_paths:
            self.assertIn(self.request(path, "PUT", token=TOKEN, body={"value": "a"})[0], (400, 404))
        for value in ("", "a" * 1025, {"nested": "invalid"}):
            self.assertEqual(self.request("/canary/test", "PUT", token=TOKEN, body={"value": value})[0], 400)
        self.assertEqual(self.request("/canary/test", "PUT", token=TOKEN, body={"unexpected": "key"})[0], 400)
        self.assertEqual(self.request("/canary/test", "PUT", token=TOKEN, body=b"not-json")[0], 400)
        self.assertEqual(self.request("/canary/test", "PUT", token=TOKEN, body=b"x", content_type="text/plain")[0], 415)
        self.assertEqual(self.store.items, {})

    def test_oversized_request_is_rejected(self):
        self.assertEqual(self.request("/canary/test", "PUT", token=TOKEN, body=b"x" * 2100)[0], 413)

    def test_unknown_paths_fail(self):
        self.assertEqual(self.request("/missing")[0], 404)


class SQLTests(unittest.TestCase):
    def test_database_connect_is_tls_verified_and_bounded(self):
        config = {
            "M3_DB_HOST": "db.example.rds.amazonaws.com",
            "M3_DB_PORT": "5432",
            "M3_DB_NAME": "appdb",
            "M3_DB_USER": "app",
            "M3_DB_PASSWORD": "private-secret",
        }

        class FakePsycopg:
            called = None

            @classmethod
            def connect(cls, **kwargs):
                cls.called = kwargs
                return "connection-stub"

        with patch.dict(sys.modules, {"psycopg": FakePsycopg}):
            self.assertEqual(app.PgCanaryStore(config)._connect(), "connection-stub")
        self.assertEqual(FakePsycopg.called["sslmode"], "verify-full")
        self.assertEqual(FakePsycopg.called["sslrootcert"], "/app/rds-ca.pem")
        self.assertEqual(FakePsycopg.called["connect_timeout"], 3)
        self.assertEqual(FakePsycopg.called["password"], "private-secret")

    def test_missing_token_rejected_at_startup(self):
        with patch.dict("os.environ", {}, clear=True):
            with self.assertRaises(SystemExit):
                app.main()


if __name__ == "__main__":
    unittest.main()
