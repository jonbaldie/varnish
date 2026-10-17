#!/usr/bin/env python3
"""Origin used by the 2026-10-17 exploratory replay."""

import gzip
import json
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROUTES = {
    "/health": {
        "status": 200,
        "headers": {"Content-Type": "text/plain", "Cache-Control": "no-store"},
        "body": "ok",
    }
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _send(self, status, headers, body):
        data = body if isinstance(body, bytes) else body.encode()
        self.send_response(status)
        for key, value in headers.items():
            self.send_header(key, value)
        self.send_header("X-Origin-AE", self.headers.get("Accept-Encoding", ""))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return self.rfile.read(length) if length else b""

    def _route(self):
        raw = self._body()
        path = self.path.split("?", 1)[0]
        if path == "/__control":
            payload = json.loads(raw.decode() or "{}")
            ROUTES[payload["path"]] = {
                "status": int(payload.get("status", 200)),
                "headers": payload.get("headers", {}),
                "body": payload.get("body", ""),
                "negotiate": payload.get("negotiate"),
            }
            self._send(200, {"Content-Type": "application/json", "Cache-Control": "no-store"}, '{"stored":true}')
            return
        route = ROUTES.get(path)
        if route is None:
            self._send(404, {"Content-Type": "text/plain", "Cache-Control": "no-store"}, "missing")
            return
        headers = dict(route["headers"])
        body = route["body"]
        if route.get("negotiate") == "encoding":
            ae = self.headers.get("Accept-Encoding", "")
            plain = body.encode()
            headers["Vary"] = "Accept-Encoding"
            if "gzip" in ae:
                headers["Content-Encoding"] = "gzip"
                body = gzip.compress(plain)
            elif "deflate" in ae:
                headers["Content-Encoding"] = "deflate"
                body = zlib.compress(plain)
            else:
                body = plain
        self._send(route["status"], headers, body)

    def do_GET(self):
        self._route()

    def do_POST(self):
        self._route()

    def do_PUT(self):
        self._route()


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
