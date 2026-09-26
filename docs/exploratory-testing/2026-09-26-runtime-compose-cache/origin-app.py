import http.server, json, itertools, urllib.parse
ctr = itertools.count(1)
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle_any(self):
        n = next(ctr)
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        ln = int(self.headers.get("Content-Length") or 0)
        body_in = self.rfile.read(ln) if ln else b""
        status = int(q.get("status", 200))
        body = json.dumps({"n": n, "method": self.command, "path": self.path,
            "headers": dict(self.headers), "body": body_in.decode(errors="replace")}).encode() + b"\n"
        self.send_response(status)
        for k, v in q.items():
            if k.startswith("h_"):
                self.send_header(k[2:].replace("_", "-"), v)
        self.send_header("X-Origin-N", str(n))
        self.send_header("Content-Type", q.get("ct", "application/json"))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = handle_any
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
