#!/usr/bin/env python3
"""Configurable HTTP backend for the Varnish bug-finding campaign.

Supports dynamic control endpoints to simulate different origin behaviors:
- Returning specific status codes (200, 404, 500, 502, 503)
- Returning Cache-Control headers (public, private, no-store, no-cache, max-age)
- Returning Set-Cookie headers
- Simulating backend downtime / recovery
- Logging exact received headers (to verify cookie stripping, Accept-Encoding normalization)
"""

import http.server
import json
import os
import sys
import threading
from itertools import count

REQUEST_COUNTER = count(1)

class CampaignBackendHandler(http.server.BaseHTTPRequestHandler):
    server_version = "CampaignBackend/1.0"

    def do_GET(self):
        self.handle_all("GET")

    def do_POST(self):
        self.handle_all("POST")

    def do_PUT(self):
        self.handle_all("PUT")

    def do_DELETE(self):
        self.handle_all("DELETE")

    def do_HEAD(self):
        self.handle_all("HEAD")

    def do_OPTIONS(self):
        self.handle_all("OPTIONS")

    def do_PATCH(self):
        self.handle_all("PATCH")

    def log_message(self, format, *args):
        # Suppress default noisy stderr logging
        pass

    def handle_all(self, method: str):
        server = self.server
        if server.is_down:
            # Backend simulated as down/unresponsive
            self.close_connection = True
            return

        req_id = next(REQUEST_COUNTER)

        # Health check
        if self.path in ("/", "/ready", "/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Backend-Request-Id", str(req_id))
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(b"OK\n")
            return

        # Special probe endpoint to echo what headers the backend actually received
        if self.path.startswith("/echo-headers"):
            headers_dict = {k: v for k, v in self.headers.items()}
            payload = json.dumps({
                "request_id": req_id,
                "method": method,
                "path": self.path,
                "headers": headers_dict,
                "cookie_received": self.headers.get("Cookie", None),
                "accept_encoding_received": self.headers.get("Accept-Encoding", None),
            }).encode("utf-8")

            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("X-Backend-Request-Id", str(req_id))
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(payload)
            return

        # Check configured routes
        clean_path = self.path.split("?")[0]
        route_config = server.routes.get(clean_path, server.routes.get(self.path, None))
        
        # Read body if any
        content_length = int(self.headers.get("Content-Length", 0))
        req_body = self.rfile.read(content_length) if content_length > 0 else b""

        # Record request in server history
        server.record_request({
            "request_id": req_id,
            "method": method,
            "path": self.path,
            "headers": dict(self.headers),
            "body": req_body.decode("utf-8", errors="replace"),
        })

        if route_config:
            status = route_config.get("status", 200)
            headers = route_config.get("headers", {})
            body = route_config.get("body", f"response for {self.path}\n").encode("utf-8")
        else:
            # Default behavior based on path
            status = 200
            headers = {"Content-Type": "text/plain"}
            body = f"default-route={self.path}\nrequest_id={req_id}\n".encode("utf-8")

        self.send_response(status)
        self.send_header("X-Backend", "campaign-backend")
        self.send_header("X-Backend-Request-Id", str(req_id))
        self.send_header("Content-Length", str(len(body)))
        for k, v in headers.items():
            if k.lower() == "set-cookie":
                v = v.replace("{req_id}", str(req_id)).replace("{client}", f"req-{req_id}")
            self.send_header(k, v)
        self.end_headers()

        if method != "HEAD":
            self.wfile.write(body)


class CampaignBackendServer(http.server.ThreadingHTTPServer):
    def __init__(self, addr):
        super().__init__(addr, CampaignBackendHandler)
        self.is_down = False
        self.routes = {}
        self.history = []
        self.lock = threading.Lock()

    def record_request(self, req):
        with self.lock:
            self.history.append(req)

    def set_route(self, path: str, status: int = 200, headers: dict = None, body: str = ""):
        with self.lock:
            self.routes[path] = {
                "status": status,
                "headers": headers or {},
                "body": body,
            }

    def clear_routes(self):
        with self.lock:
            self.routes.clear()
            self.history.clear()

    def get_history(self):
        with self.lock:
            return list(self.history)


def start_backend(port: int = 8080) -> CampaignBackendServer:
    server = CampaignBackendServer(("0.0.0.0", port))
    t = threading.Thread(target=server.serve_forever, daemon=True)
    t.start()
    return server


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    srv = CampaignBackendServer(("0.0.0.0", port))
    print(f"Backend listening on port {port}")
    srv.serve_forever()
