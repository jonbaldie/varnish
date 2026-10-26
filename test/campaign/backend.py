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

        # Record before sending any response, including readiness responses.
        content_length = int(self.headers.get("Content-Length", 0))
        req_body = self.rfile.read(content_length) if content_length > 0 else b""
        server.record_request({
            "request_id": req_id,
            "method": method,
            "path": self.path,
            "headers": dict(self.headers),
            "body": req_body.decode("utf-8", errors="replace"),
        })

        # Health check
        if self.path in ("/", "/ready", "/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("X-Backend-Request-Id", str(req_id))
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(b"OK\n")
            return

        # Check configured routes
        clean_path = self.path.split("?")[0]
        route_config = server.routes.get(clean_path, server.routes.get(self.path, None))
        
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
        self._requests = {}
        self._sequence = 0
        self.lock = threading.Lock()

    def record_request(self, req):
        with self.lock:
            self.history.append(req)
            self._sequence += 1
            self._requests[str(req["request_id"])] = (self._sequence, req)

    def get_request(self, request_id=None):
        """Look up an origin ID; no-argument calls retain TCPServer's accept hook."""
        if request_id is None:
            return super().get_request()
        with self.lock:
            try:
                return self._requests[str(request_id)][1]
            except KeyError:
                raise KeyError(f"Unknown origin request ID: {request_id!r}") from None

    def checkpoint(self):
        """Mark the start of an observation window; resets do not rewind it."""
        with self.lock:
            return self._sequence

    def requests_since(self, checkpoint):
        """Snapshot origin interactions recorded after this server's checkpoint."""
        with self.lock:
            return [req for sequence, req in self._requests.values() if sequence > checkpoint]

    def request_for_response(self, response, *, since=None):
        """Correlate a forwarded response, optionally within an observation window.

        HITs retain the old origin ID but did not dispatch a new origin request.
        Synthetic responses have no origin ID. Both return None. Unknown IDs
        raise KeyError, rather than quietly using an unrelated history entry.
        """
        if "HIT" in response.get("x_cache", ""):
            return None
        request_id = response.get("backend_request_id", response.get("backend_req_id"))
        if not request_id:
            return None
        with self.lock:
            try:
                sequence, request = self._requests[str(request_id)]
            except KeyError:
                raise KeyError(f"Unknown origin request ID: {request_id!r}") from None
            return request if since is None or sequence > since else None

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
            self._requests.clear()

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
