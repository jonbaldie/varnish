#!/usr/bin/env python3
"""Hostile backend test fixture for Varnish E2E testing.

This HTTP server implements the hostile backend contract documented in README.md.
It exposes behaviors that prove Varnish correctly handles cookie stripping and
cache isolation in ways that a standard nginx backend cannot demonstrate clearly.

The fixture provides three critical test endpoints:
- /static/app.css: Proves cookies are stripped from cacheable static assets
- /account: Proves cookie-bearing dynamic requests are passed, not cached
- /set-cookie: Proves responses with Set-Cookie are isolated per client
- /echo-headers: Proves request header normalization at the origin

Every response includes X-Backend-Request-Id to prove cache hits vs origin hits.
"""

import email.utils
import os
import time
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


def parse_auth_identity(auth_header: str | None) -> str:
    """Extract client identity from Authorization header for test scenario tracking.

    Parses Bearer, Basic, or custom tokens to enable E2E tests to prove
    that authenticated responses are never cached or leaked across clients.

    Args:
        auth_header: Raw Authorization header value, may be None

    Returns:
        Client identity string or "anonymous"
    """
    if not auth_header:
        return "anonymous"

    parts = auth_header.strip().split()
    if len(parts) >= 2:
        return parts[1]

    return auth_header.strip()


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

        if clean_path == "/echo-headers":
            accept_encoding = self.headers.get("Accept-Encoding") or "none"
            self.respond(200, f"accept_encoding={accept_encoding}\n")
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

        # Zero-freshness static assets: the origin allows storage (no
        # no-store/no-cache/private) but grants zero freshness. Builtin
        # Varnish treats beresp.ttl <= 0s as hit-for-miss; the shared cache
        # policy must not overwrite that with a static-extension TTL.
        if clean_path == "/static/zero-maxage.css":
            body = "asset=zero-maxage.css\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Cache-Control": "max-age=0"},
            )
            return

        if clean_path == "/static/zero-smaxage.css":
            body = "asset=zero-smaxage.css\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Cache-Control": "s-maxage=0"},
            )
            return

        if clean_path == "/static/past-expires.css":
            body = "asset=past-expires.css\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={
                    # An hour ago. Never the epoch (00:00:00 UTC 1 Jan 1970):
                    # Varnish's RFC2616_Ttl treats a parsed Expires of 0 as
                    # an absent header and falls back to default_ttl.
                    "Expires": email.utils.formatdate(
                        time.time() - 3600, usegmt=True
                    ),
                },
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

        if clean_path == "/auth":
            client = parse_auth_identity(self.headers.get("Authorization"))
            body = f"route=auth\nclient={client}\n"
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

        # Surrogate-Control used as an ESI capability advertisement: it
        # declares the origin's ESI processing level, it is NOT a storage or
        # freshness grant. The Cache-Control directives must stay in force
        # for the shared cache (W3C Edge Architecture, Surrogate-Control).
        if clean_path == "/private-esi":
            body = "route=private-esi\n"
            self.respond(
                200,
                body,
                extra_headers={
                    "Surrogate-Control": 'content="ESI/1.0"',
                    "Cache-Control": "private, no-store",
                },
            )
            return

        # Genuine surrogate freshness grant: Surrogate-Control with max-age
        # overrides Cache-Control for the shared cache by design.
        if clean_path == "/surrogate-fresh":
            body = "route=surrogate-fresh\n"
            self.respond(
                200,
                body,
                extra_headers={
                    "Surrogate-Control": "max-age=60",
                    "Cache-Control": "private, no-store",
                },
            )
            return

        # Zero surrogate freshness: max-age=0 grants the surrogate nothing,
        # so Cache-Control: private stays in force.
        if clean_path == "/surrogate-zero-maxage":
            body = "route=surrogate-zero-maxage\n"
            self.respond(
                200,
                body,
                extra_headers={
                    "Surrogate-Control": "max-age=0",
                    "Cache-Control": "private, max-age=3600",
                },
            )
            return

        # Surrogate-Control no-store: the surrogate itself must not store,
        # even though Cache-Control grants public freshness.
        if clean_path == "/surrogate-nostore":
            body = "route=surrogate-nostore\n"
            self.respond(
                200,
                body,
                extra_headers={
                    "Surrogate-Control": "no-store",
                    "Cache-Control": "public, max-age=60",
                },
            )
            return

        if clean_path == "/vary-star":
            body = "route=vary-star\n"
            self.respond(
                200,
                body,
                extra_headers={"Vary": "*"},
            )
            return

        if clean_path == "/vary-multi-star":
            body = "route=vary-multi-star\n"
            self.respond(
                200,
                body,
                extra_headers={"Vary": "Accept-Encoding, *"},
            )
            return

        if clean_path == "/vary-star-whitespace":
            body = "route=vary-star-whitespace\n"
            self.respond(
                200,
                body,
                extra_headers={"Vary": "  *  "},
            )
            return

        if clean_path == "/vary-normal":
            body = "route=vary-normal\n"
            self.respond(
                200,
                body,
                extra_headers={"Vary": "Accept-Encoding", "Cache-Control": "public, max-age=60"},
            )
            return

        if clean_path == "/static/vary-star.css":
            body = "asset=vary-star.css\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Vary": "*", "Cache-Control": "public, max-age=86400"},
            )
            return

        if clean_path == "/static/auth.css":
            client = parse_auth_identity(self.headers.get("Authorization"))
            body = f"asset=auth.css\nclient={client}\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Cache-Control": "public, max-age=86400"},
            )
            return

        self.respond(404, "route=not-found\n")

    def do_HEAD(self) -> None:
        self.do_GET()

    def do_POST(self) -> None:
        """Handle POST requests identically to GET.

        POST requests must never be served from Varnish's cache.  This handler
        lets the test verify that a POST to a previously-cached URL actually
        reaches the origin (producing a distinct X-Backend-Request-Id) rather
        than being served silently from the GET cache.
        """
        self.do_GET()

    def do_PUT(self) -> None:
        self.do_GET()

    def do_DELETE(self) -> None:
        self.do_GET()

    def do_PATCH(self) -> None:
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
        if self.command != "HEAD":
            self.wfile.write(payload)


def main() -> None:
    port = int(os.environ.get("PORT", "8080"))
    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
