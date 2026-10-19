#!/usr/bin/env python3
"""Exercise the campaign transport over real sockets (no Varnish required)."""
import json
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from http_client import CampaignHttpClient


class Origin(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/truncated":
            self.send_response(200)
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"short")
            return
        self.send_response(200)
        self.send_header("Set-Cookie", "session=alice; Path=/; HttpOnly")
        self.send_header("set-cookie", "csrf=xyz; Path=/")
        self.send_header("ETag", '"v1"')
        self.send_header("x-cache", "MISS")
        self.send_header("X-Backend-Request-Id", "42")
        self.end_headers()
        self.wfile.write(b"hello\xff")

    def do_PURGE(self):
        self.send_response(200 if self.path == "/ok" else 405)
        self.end_headers()
        self.wfile.write(b"purge-result")

    def log_message(self, *args):
        pass


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Origin)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.client = CampaignHttpClient(*self.server.server_address)

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()

    def test_response_preserves_headers_and_normalizes_accessors(self):
        response = self.client.request("GET", "/")
        self.assertEqual(response.headers.get_all("SET-cookie"), [
            "session=alice; Path=/; HttpOnly", "csrf=xyz; Path=/"])
        for name in ("etag", "ETag", "ETAG"):
            self.assertEqual(response.headers.get(name), '"v1"')
        self.assertEqual(response.headers["X-CACHE"], "MISS")
        self.assertIn("eTAG", response.headers)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.body, "hello\ufffd")
        self.assertEqual(response.x_cache, "MISS")
        self.assertEqual(response.backend_request_id, "42")

    def test_raw_wire_uses_the_same_response_model(self):
        response = self.client.send_raw(b"GET / HTTP/1.0\r\n\r\n")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.headers.get_all("set-cookie"), [
            "session=alice; Path=/; HttpOnly", "csrf=xyz; Path=/"])
        self.assertEqual(response.body, "hello\ufffd")
        self.assertTrue(response.raw_response.startswith("HTTP/1.0 200 OK\r\n"))
        self.assertIn("Set-Cookie: session=alice; Path=/; HttpOnly\r\n", response.raw_response)
        self.assertTrue(response.raw_response.endswith("\r\n\r\nhello\xff"))

    def test_truncated_responses_are_errors_not_observations(self):
        with self.assertRaisesRegex(RuntimeError, "GET.*IncompleteRead"):
            self.client.request("GET", "/truncated")
        with self.assertRaisesRegex(RuntimeError, "raw HTTP.*IncompleteRead"):
            self.client.send_raw(b"GET /truncated HTTP/1.0\r\n\r\n")

    def test_campaign_phases_share_observations_and_report_evidence(self):
        from test_properties import raw_http_request, purge_url
        from test_stateful import Action, StatefulHarness
        from http_client import CampaignResponse

        host, port = self.server.server_address
        phase2 = raw_http_request(host, port, "GET", "/")
        harness = StatefulHarness(host, port, backend=None)
        phase3 = harness.execute_action(Action("CLIENT_REQUEST", client_id="alice", path="/"))
        for response in (phase2, phase3):
            self.assertIsInstance(response, CampaignResponse)
            self.assertEqual(response.backend_request_id, "42")
            self.assertEqual(response.headers.get_all("set-cookie"), [
                "session=alice; Path=/; HttpOnly", "csrf=xyz; Path=/"])
            evidence = json.loads(json.dumps(response))
            self.assertEqual(evidence["headers"]["Set-Cookie"],
                             "session=alice; Path=/; HttpOnly\ncsrf=xyz; Path=/")
            restored = CampaignResponse.from_report(evidence)
            self.assertEqual(restored.headers.get_all("SET-COOKIE"), [
                "session=alice; Path=/; HttpOnly", "csrf=xyz; Path=/"])
            self.assertEqual(restored.body, "hello\ufffd")
        self.assertEqual(purge_url(host, port, "/ok").status, 200)
        self.assertEqual(harness.execute_action(Action("PURGE", path="/ok")).status, 200)
        with self.assertRaisesRegex(RuntimeError, "405"):
            purge_url(host, port, "/denied")
        with self.assertRaisesRegex(RuntimeError, "405"):
            harness.execute_action(Action("PURGE", path="/denied"))

    def test_purge_checks_status_and_reports_failure(self):
        self.assertEqual(self.client.purge("/ok").status, 200)
        with self.assertRaisesRegex(RuntimeError, "PURGE.*405.*purge-result"):
            self.client.purge("/denied")
        self.server.shutdown()
        self.server.server_close()
        with self.assertRaisesRegex(RuntimeError, "PURGE.*ConnectionRefusedError"):
            self.client.purge("/ok")


if __name__ == "__main__":
    unittest.main()
