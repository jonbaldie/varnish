#!/usr/bin/env python3
"""Exhaust short credential sequences against the checked-out VCL and real Varnish."""

import http.client
import http.server
import itertools
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass


ROOT = Path(__file__).resolve().parents[2]
POLICY = ROOT / "cache-policy.vcl"
IMAGE = "varnish-cache-isolation:7.1.1"
VARNISH_VERSION = "varnish-7.1.1 revision 7cee1c581bead20e88d101ab3d72afb29f14d87a"


@dataclass(frozen=True)
class Credentials:
    name: str
    authorization: str | None = None
    cookie: str | None = None


CREDENTIALS = (
    Credentials("anonymous"),
    Credentials("alice-authorization", authorization="Bearer alice"),
    Credentials("bob-authorization", authorization="Bearer bob"),
    Credentials("alice-cookie", cookie="client=alice"),
    Credentials("bob-cookie", cookie="client=bob"),
    Credentials("alice-both", authorization="Bearer alice", cookie="client=alice"),
    Credentials("bob-both", authorization="Bearer bob", cookie="client=bob"),
)


class Origin(http.server.BaseHTTPRequestHandler):
    """A real HTTP origin that makes credential exposure visible to the client."""

    counter = itertools.count(1)

    def log_message(self, format, *args):
        pass

    def do_HEAD(self):
        self.respond()

    def do_GET(self):
        self.respond()

    def respond(self):
        body = b"cache-isolation origin\n"
        self.send_response(200)
        self.send_header("Cache-Control", "public, max-age=3600")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Origin-Id", str(next(self.counter)))
        self.send_header("X-Origin-Authorization", self.headers.get("Authorization", "none"))
        self.send_header("X-Origin-Cookie", self.headers.get("Cookie", "none"))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


class Violation(Exception):
    pass


def docker(*arguments, check=True):
    return subprocess.run(
        ("docker", *arguments), text=True, capture_output=True, check=check
    )


def prepare_image():
    if docker("image", "inspect", IMAGE, check=False).returncode:
        print(f"Building {IMAGE} from the repository Dockerfile (first run).", flush=True)
        subprocess.run(("docker", "build", "-t", IMAGE, str(ROOT)), check=True)
    result = docker("run", "--rm", "--entrypoint", "varnishd", IMAGE, "-V")
    version = result.stdout + result.stderr
    if VARNISH_VERSION not in version:
        raise RuntimeError(
            f"{IMAGE} must contain {VARNISH_VERSION}; got:\n{version}"
        )
    print(f"Varnish: {VARNISH_VERSION}", flush=True)


def request(port, method, path, credentials):
    headers = {"Host": "cache-isolation.test"}
    if credentials.authorization:
        headers["Authorization"] = credentials.authorization
    if credentials.cookie:
        headers["Cookie"] = credentials.cookie
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    try:
        connection.request(method, path, headers=headers)
        response = connection.getresponse()
        response.read()
        return response.status, {key.lower(): value for key, value in response.getheaders()}
    finally:
        connection.close()


def path_for(kind, number):
    if kind == "dynamic":
        return f"/verify/account/{number}"
    if kind == "query-suffix":
        return f"/verify/account/{number}?q=jquery.js"
    if kind == "static-css":
        return f"/verify/asset/{number}.css?rev=2"
    if kind == "static-mixed-case":
        return f"/verify/asset/{number}.Js?rev=2"
    raise ValueError(f"unknown path kind: {kind}")


def check_sequence(port, kind, number, sequence):
    path = path_for(kind, number)
    is_static = kind.startswith("static-")
    seen_ids = set()
    trace = []
    for method, credentials in sequence:
        status, headers = request(port, method, path, credentials)
        origin_id = headers.get("x-origin-id")
        auth = headers.get("x-origin-authorization")
        cookie = headers.get("x-origin-cookie")
        cache = headers.get("x-cache")
        trace.append(
            f"  {method} {credentials.name}: status={status}, X-Cache={cache}, "
            f"origin-id={origin_id}, origin-authorization={auth}, origin-cookie={cookie}"
        )
        expected_auth = credentials.authorization or "none"
        expected_cookie = (
            credentials.cookie
            if credentials.cookie and (not is_static or credentials.authorization)
            else "none"
        )
        must_pass = bool(credentials.authorization or (credentials.cookie and not is_static))
        if status != 200:
            problem = f"expected status 200, got {status}"
        elif not origin_id:
            problem = "origin request ID is missing"
        elif auth != expected_auth or cookie != expected_cookie:
            problem = (
                f"expected origin authorization={expected_auth!r} and cookie={expected_cookie!r}; "
                f"got authorization={auth!r} and cookie={cookie!r}"
            )
        elif must_pass and origin_id in seen_ids:
            problem = "credential-bearing request did not reach the origin independently"
        else:
            seen_ids.add(origin_id)
            continue
        raise Violation(f"{kind}: {path}\n{problem}\n" + "\n".join(trace))


def verify(port):
    kinds = ("dynamic", "query-suffix", "static-css", "static-mixed-case")
    get_actions = tuple(("GET", credentials) for credentials in CREDENTIALS)
    all_actions = tuple((method, credentials) for method in ("GET", "HEAD") for credentials in CREDENTIALS)
    sequences = requests = 0
    for kind in kinds:
        for actions, length in ((get_actions, 3), (all_actions, 2)):
            for sequence in itertools.product(actions, repeat=length):
                sequences += 1
                requests += length
                check_sequence(port, kind, sequences, sequence)
    print(f"PASS: {sequences} sequences, {requests} requests across {len(kinds)} URL kinds")


def main():
    prepare_image()
    origin = http.server.ThreadingHTTPServer(("0.0.0.0", 0), Origin)
    thread = threading.Thread(target=origin.serve_forever, daemon=True)
    thread.start()
    name = f"varnish-isolation-{uuid.uuid4().hex[:12]}"
    try:
        with tempfile.TemporaryDirectory(prefix="varnish-isolation-") as directory:
            config = Path(directory) / "default.vcl"
            config.write_text(
                'vcl 4.0;\nbackend default { .host = "host.docker.internal"; '
                f'.port = "{origin.server_port}"; }}\n'
                'include "/verification/cache-policy.vcl";\n',
                encoding="utf-8",
            )
            result = docker(
                "run", "-d", "--name", name,
                "--add-host=host.docker.internal:host-gateway",
                "-p", "127.0.0.1::8080",
                "-v", f"{POLICY}:/verification/cache-policy.vcl:ro",
                "-v", f"{config}:/verification/default.vcl:ro",
                "--entrypoint", "varnishd", IMAGE,
                "-F", "-a", "0.0.0.0:8080", "-f", "/verification/default.vcl",
                "-s", "malloc,64m",
            )
            if not result.stdout.strip():
                raise RuntimeError("Docker did not return a container ID")
            port_output = docker("port", name, "8080/tcp").stdout.strip()
            port = int(port_output.rsplit(":", 1)[1])
            deadline = time.monotonic() + 20
            while True:
                try:
                    status, _ = request(port, "GET", "/verify/ready", CREDENTIALS[0])
                    if status == 200:
                        break
                except (OSError, http.client.HTTPException):
                    pass
                if time.monotonic() >= deadline:
                    logs = docker("logs", name, check=False)
                    raise RuntimeError(f"Varnish or origin did not become ready:\n{logs.stdout}{logs.stderr}")
                time.sleep(0.1)
            verify(port)
    finally:
        docker("rm", "-f", name, check=False)
        origin.shutdown()
        origin.server_close()
        thread.join()


if __name__ == "__main__":
    try:
        main()
    except Violation as error:
        print(f"FAIL: cache isolation violation\n{error}", file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, RuntimeError, http.client.HTTPException, subprocess.CalledProcessError) as error:
        print(f"ERROR: verification did not complete: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stdout or "", error.stderr or "", file=sys.stderr)
        sys.exit(2)
