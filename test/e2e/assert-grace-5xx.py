#!/usr/bin/env python3
"""Real HTTP regression: failed refreshes must not evict a graced page."""
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

ROOT = Path(__file__).resolve().parents[2]


def docker(*args):
    return subprocess.check_output(["docker", *map(str, args)], text=True).strip()


def request(base, path):
    try:
        response = urllib.request.urlopen(base + path, timeout=5)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def main():
    prefix = "grace-5xx-" + uuid.uuid4().hex[:10]
    origin, cache = prefix + "-origin", prefix + "-cache"
    image = os.environ.get("IMAGE", "jonbaldie/varnish:latest")
    docker("network", "create", prefix)
    try:
        docker("run", "-d", "--name", origin, "--network", prefix,
               "-p", "127.0.0.1::8080", "-v",
               f"{ROOT}/test/e2e/fixtures/scriptable-origin.py:/origin.py:ro",
               "python:3.13-alpine", "python", "-u", "/origin.py")
        docker("run", "-d", "--name", cache, "--network", prefix,
               "-p", "127.0.0.1::80", "-e", f"VARNISH_BACKEND_HOST={origin}",
               "-e", "VARNISH_BACKEND_PORT=8080", "-e", "VARNISH_BACKEND_PROBE_PATH=/probe",
               "-v", f"{ROOT}/cache-policy.vcl:/etc/varnish/cache-policy.vcl:ro", image)
        def base(name, port):
            binding = json.loads(docker("inspect", name))[0]["NetworkSettings"]["Ports"][port][0]
            return "http://127.0.0.1:" + binding["HostPort"]
        backend, frontend = base(origin, "8080/tcp"), base(cache, "80/tcp")
        for _ in range(60):
            try:
                if request(frontend, "/ready")[0] == 200:
                    break
            except (OSError, urllib.error.URLError):
                pass
            time.sleep(0.25)
        else:
            raise AssertionError("Varnish never became ready")

        def configure(path, status, ttl=1, **headers):
            query = urllib.parse.urlencode({"path": path, "status": status,
                                           "h_Cache-Control": f"max-age={ttl}", **headers})
            assert request(backend, "/__set?" + query)[0] == 200

        for status in (500, 502, 503):
            path = f"/news-{status}"
            configure(path, 200)
            code, headers, body = request(frontend, path)
            assert code == 200
            origin_id = headers["X-Origin-N"]
            assert request(frontend, path)[1]["X-Cache"] == "HIT"
            # Error-only storage headers must not bypass stale preservation.
            error_headers = ({"h_Cache-Control": "no-store"} if status == 502 else
                             {"h_Set-Cookie": "outage=1"} if status == 503 else {})
            configure(path, status, **error_headers)
            time.sleep(2)
            for attempt in range(5):
                code, headers, actual_body = request(frontend, path)
                print(f"origin={status} attempt={attempt} response={code} "
                      f"cache={headers['X-Cache']} age={headers['Age']}", flush=True)
                assert code == 200, f"{status} refresh replaced graced 200 with {code}"
                assert headers["X-Cache"] == "HIT"
                assert headers["X-Origin-N"] == origin_id and actual_body == body
                assert int(headers["Age"]) >= 2
                time.sleep(0.25)
            # Recovery must replace the old page, not freeze it indefinitely.
            configure(path, 200, ttl=60)
            for _ in range(40):
                code, headers, _ = request(frontend, path)
                if code == 200 and headers["X-Origin-N"] != origin_id:
                    break
                time.sleep(0.1)
            else:
                raise AssertionError("recovered origin never refreshed the cached page")
            cold = f"/cold-{status}"
            configure(cold, status)
            first = request(frontend, cold)
            second = request(frontend, cold)
            assert first[0] == second[0] == status, "cold error must reach client"
            assert first[1]["X-Origin-N"] != second[1]["X-Origin-N"], "5xx was cached"
        # A page that prohibits stale serving must still expose an origin 5xx.
        path = "/must-revalidate"
        configure(path, 200, **{"h_Cache-Control": "max-age=1, must-revalidate"})
        assert request(frontend, path)[0] == 200
        configure(path, 503)
        time.sleep(2)
        assert request(frontend, path)[0] == 503, "served stale despite must-revalidate"
        print("OK: 500/502/503 preserve grace, recover, and are not cached on cold misses")
    except Exception:
        for name in (origin, cache):
            subprocess.run(["docker", "logs", name], check=False)
        raise
    finally:
        for name in (cache, origin):
            subprocess.run(["docker", "rm", "-fv", name], check=False, stdout=subprocess.DEVNULL)
        docker("network", "rm", prefix)


if __name__ == "__main__":
    main()
