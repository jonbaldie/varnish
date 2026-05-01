#!/usr/bin/env python3

import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from itertools import count


REQUEST_IDS = count(1)


def parse_client_identity(cookie_header: str | None) -> str:
    if not cookie_header:
        return "anonymous"

    for part in cookie_header.split(";"):
        name, sep, value = part.strip().partition("=")
        if sep and name == "client":
            return value or "anonymous"

    return "anonymous"


class Handler(BaseHTTPRequestHandler):
    server_version = "hostile-backend/1.0"

    def do_GET(self) -> None:
        cookie_header = self.headers.get("Cookie")

        if self.path == "/ready":
            self.respond(200, "ready=ok\n")
            return

        if self.path == "/static/app.css":
            cookie_state = "present" if cookie_header else "none"
            body = f"asset=app.css\ncookie={cookie_state}\n"
            self.respond(
                200,
                body,
                content_type="text/css; charset=utf-8",
                extra_headers={"Cache-Control": "public, max-age=86400"},
            )
            return

        if self.path == "/account":
            client = parse_client_identity(cookie_header)
            body = f"route=account\nclient={client}\n"
            self.respond(200, body)
            return

        if self.path == "/set-cookie":
            client = parse_client_identity(cookie_header)
            body = f"route=set-cookie\nclient={client}\n"
            self.respond(
                200,
                body,
                extra_headers={"Set-Cookie": f"session={client}; Path=/"},
            )
            return

        self.respond(404, "route=not-found\n")

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
