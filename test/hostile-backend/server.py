#!/usr/bin/env python3
"""Hostile backend test fixture for Varnish E2E testing.

This HTTP server implements the hostile backend contract documented in README.md.
It exposes behaviors that prove Varnish correctly handles cookie stripping and
cache isolation in ways that a standard nginx backend cannot demonstrate clearly.

The fixture provides three critical test endpoints:
- /static/app.css: Proves cookies are stripped from cacheable static assets
- /account: Proves cookie-bearing dynamic requests are passed, not cached
- /set-cookie: Proves responses with Set-Cookie are isolated per client

Every response includes X-Backend-Request-Id to prove cache hits vs origin hits.
"""

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import count


REQUEST_IDS = count(1)


def parse_client_identity(cookie_header: str | None) -> str:
    """Extract client identity from Cookie header for test scenario tracking.
    
    Parses the test cookie 'client=<identity>' to enable E2E tests to prove
    that different clients receive isolated responses and that Varnish does
    not leak cached responses across client boundaries.
    
    Args:
        cookie_header: Raw Cookie header value, may be None
        
    Returns:
        Client identity string (e.g., "alice", "bob") or "anonymous"
    """
    if not cookie_header:
        return "anonymous"

    for part in cookie_header.split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name == "client":
            return value or "anonymous"

    return "anonymous"


class Handler(BaseHTTPRequestHandler):
    """HTTP request handler implementing the hostile backend test contract.
    
    Provides three test endpoints that prove Varnish cookie handling and cache
    isolation semantics. Each response includes X-Backend-Request-Id to enable
    tests to distinguish cache hits from origin hits.
    """
    server_version = "hostile-backend/1.0"

    def do_GET(self) -> None:
        cookie_header = self.headers.get("Cookie")
        clean_path = self.path.split("?")[0].lower()

        # Health check endpoints for container readiness probes.
        # "/" is used by the main VCL backend probe; "/ready" by the hostile
        # compose healthcheck. Both must return 200 so Varnish marks the
        # backend as healthy before any test assertions run.
        if clean_path in ("/", "/ready"):
            self.respond(200, "ready=ok\n")
            return

        if clean_path == "/error":
            body = "route=error\n"
            self.respond(500, body)
            return

        if clean_path == "/short-cache":
            body = "route=short-cache\n"
            self.respond(
                200,
                body,
                extra_headers={"Cache-Control": "public, max-age=10"},
            )
            return

        if clean_path == "/static/app.css":
            cookie_state = "present" if cookie_header else "none"
            body = f"asset=app.css\ncookie={cookie_state}\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Cache-Control": "public, max-age=86400"},
            )
            return

        if clean_path == "/account":
            client = parse_client_identity(cookie_header)
            body = f"route=account\nclient={client}\n"
            self.respond(200, body)
            return

        if clean_path == "/set-cookie":
            client = parse_client_identity(cookie_header)
            body = f"route=set-cookie\nclient={client}\n"
            self.respond(
                200,
                body,
                extra_headers={"Set-Cookie": f"session={client}; Path=/"},
            )
            return

        if clean_path == "/private":
            body = "route=private\n"
            self.respond(
                200,
                body,
                extra_headers={"Cache-Control": "private, no-store"},
            )
            return

        self.respond(404, "route=not-found\n")

    def do_POST(self) -> None:
        """Handle POST requests identically to GET.

        POST requests must never be served from Varnish's cache.  This handler
        lets the test verify that a POST to a previously-cached URL actually
        reaches the origin (producing a distinct X-Backend-Request-Id) rather
        than being served silently from the GET cache.
        """
        self.do_GET()

    def log_message(self, format: str, *args) -> None:
        return

    def respond(
        self,
        status: int,
        body: str,
        *,
        content_type: str = "text/plain; charset=utf-8",
        extra_headers: dict[str, str] | None = None,
    ) -> None:
        """Send HTTP response with test contract headers.
        
        Appends X-Backend-Request-Id to every response, which is critical for
        E2E tests to prove whether a response came from cache (same request_id
        across requests) or origin (different request_id per request).
        
        Args:
            status: HTTP status code
            body: Response body content (request_id will be appended)
            content_type: Content-Type header value
            extra_headers: Additional headers like Cache-Control or Set-Cookie
        """
        request_id = str(next(REQUEST_IDS))
        payload = (body + f"request_id={request_id}\n").encode("utf-8")

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Backend", "hostile")
        self.send_header("X-Backend-Request-Id", request_id)
        for name, value in (extra_headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(payload)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
