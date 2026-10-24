"""Scriptable origin. Query params h_<Name>=v set response headers, status=N
sets status. POST /__set?path=/p&status=N&h_X=v overrides later responses for
path /p (any query) until /__clear. Each response carries X-Origin-N."""
import http.server, itertools, json, threading, urllib.parse

ctr = itertools.count(1)
overrides = {}
lock = threading.Lock()

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def any(self):
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query, keep_blank_values=True)
        ln = int(self.headers.get("Content-Length") or 0)
        if ln:
            self.rfile.read(ln)
        if u.path == "/__set":
            with lock:
                overrides[q["path"][0]] = q
            return self.reply(200, {}, b"set\n")
        if u.path == "/__clear":
            with lock:
                overrides.clear()
            return self.reply(200, {}, b"clear\n")
        with lock:
            o = overrides.get(u.path)
        if o:
            q = {**q, **o}
        n = next(ctr)
        status = int(q.get("status", [200])[0])
        hdrs = {k[2:].replace("_", "-"): v[0] for k, v in q.items() if k.startswith("h_")}
        body = json.dumps({"n": n, "method": self.command, "path": self.path,
                           "status": status,
                           "headers": dict(self.headers)}).encode() + b"\n"
        self.reply(status, hdrs, body, n)

    def reply(self, status, hdrs, body, n=0):
        self.send_response(status)
        for k, v in hdrs.items():
            self.send_header(k, v)
        self.send_header("X-Origin-N", str(n))
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = do_PURGE = any
    def log_message(self, *a): pass

http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
