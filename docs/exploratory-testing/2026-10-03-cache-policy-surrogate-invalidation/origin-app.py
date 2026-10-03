import http.server
import json
import itertools
import urllib.parse
import collections

global_ctr = itertools.count(1)
path_ctrs = collections.defaultdict(itertools.count)
sick = False

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_any(self):
        global sick
        u = urllib.parse.urlsplit(self.path)
        q = urllib.parse.parse_qs(u.query, keep_blank_values=True)

        if u.path == "/control/healthy":
            sick = False
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"healthy\n")
            return
        elif u.path == "/control/sick":
            sick = True
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"sick\n")
            return

        if sick:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"backend is sick\n")
            return

        n = next(global_ctr)
        pn = next(path_ctrs[u.path])

        ln = int(self.headers.get("Content-Length") or 0)
        body_in = self.rfile.read(ln) if ln else b""
        status = int(q.get("status", [200])[0])

        resp_dict = {
            "n": n,
            "pn": pn,
            "method": self.command,
            "path": self.path,
            "url_path": u.path,
            "headers": dict(self.headers),
            "body": body_in.decode(errors="replace")
        }
        body = json.dumps(resp_dict).encode() + b"\n"

        self.send_response(status)
        for k, vals in q.items():
            if k.startswith("h_"):
                header_name = k[2:].replace("_", "-")
                for val in vals:
                    for part in val.split("||"):
                        self.send_header(header_name, part)
        for k, val in self.headers.items():
            if k.lower().startswith("x-set-"):
                header_name = k[6:].replace("_", "-")
                for part in val.split("||"):
                    self.send_header(header_name, part)
        self.send_header("X-Origin-N", str(n))
        self.send_header("X-Origin-Path-N", str(pn))
        self.send_header("Content-Type", q.get("ct", ["application/json"])[0])
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = do_TRACE = handle_any

    def log_message(self, *a):
        pass

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), H)
    server.serve_forever()
