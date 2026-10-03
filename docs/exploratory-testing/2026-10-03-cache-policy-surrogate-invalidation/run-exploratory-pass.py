#!/usr/bin/env python3
"""
Exploratory Testing Pass: 2026-10-03
Targets:
- Journey 1: Surrogate-Control & Freshness Hierarchy
- Journey 2: Backend Sickness, Health Probes, and Graceful Stale Serving
- Journey 3: Unsafe Mutations and Invalidation Reference Resolution
"""

import http.client
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time
import urllib.parse

EVIDENCE_DIR = os.path.dirname(os.path.abspath(__file__))
PORT = 18780
VARNISH_CONTAINER = "vx-et-varnish"
ORIGIN_CONTAINER = "vx-et-origin"
NETWORK = "vx-et-net"

def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

def raw_http(method, path, headers=None, body=None, host=f"localhost:{PORT}"):
    s = socket.create_connection(("127.0.0.1", PORT))
    req = f"{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n"
    if headers:
        for k, v in headers.items():
            req += f"{k}: {v}\r\n"
    if body:
        req += f"Content-Length: {len(body)}\r\n\r\n{body}"
    else:
        req += "Content-Length: 0\r\n\r\n"
    s.sendall(req.encode("latin1"))
    
    resp_bytes = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        resp_bytes += chunk
    s.close()
    
    resp_text = resp_bytes.decode("latin1", errors="replace")
    parts = resp_text.split("\r\n\r\n", 1)
    header_lines = parts[0].split("\r\n")
    status_line = header_lines[0]
    status_code = int(status_line.split()[1]) if len(status_line.split()) > 1 else 0
    resp_headers = {}
    for line in header_lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            resp_headers[k.strip().lower()] = v.strip()
    resp_body = parts[1] if len(parts) > 1 else ""
    return status_code, resp_headers, resp_body, resp_text

def get_vcl_errors():
    out = subprocess.check_output(
        ["docker", "exec", VARNISH_CONTAINER, "varnishlog", "-d", "-g", "raw", "-i", "VCL_Error"],
        text=True, errors="replace"
    )
    return [l for l in out.splitlines() if "VCL_Error" in l]

def run_pass():
    report_lines = []
    run_id = secrets.token_hex(4)
    def record(text):
        log(text)
        report_lines.append(text)

    record(f"=== Starting Exploratory Testing Pass (2026-10-03, run {run_id}) ===")
    
    # -------------------------------------------------------------
    # Journey 1: Surrogate-Control & Freshness Hierarchy
    # -------------------------------------------------------------
    record("\n--- Journey 1: Surrogate-Control & Freshness Hierarchy ---")
    
    # 1.1 Positive Surrogate-Control
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/surrogate-pos?h_Surrogate-Control=max-age=10")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/surrogate-pos?h_Surrogate-Control=max-age=10")
    record(f"1.1 Surrogate-Control: max-age=10 -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "HIT", "Failed positive Surrogate-Control"

    # 1.2 Surrogate-Control overrides Cache-Control: private, no-store
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/surrogate-override?h_Surrogate-Control=max-age=10&h_Cache-Control=private,%20no-store")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/surrogate-override?h_Surrogate-Control=max-age=10&h_Cache-Control=private,%20no-store")
    record(f"1.2 Surrogate overrides CC private/no-store -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "HIT", "Failed surrogate override"

    # 1.3 Surrogate-Control with freshness extension +20
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/surrogate-ext?h_Surrogate-Control=max-age=2%2B10")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/surrogate-ext?h_Surrogate-Control=max-age=2%2B10")
    record(f"1.3 Surrogate-Control: max-age=2+10 -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "HIT", "Failed surrogate extension"

    # 1.4 Surrogate-Control: max-age=0 (zero freshness uncacheable)
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/surrogate-zero?h_Surrogate-Control=max-age=0")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/surrogate-zero?h_Surrogate-Control=max-age=0")
    record(f"1.4 Surrogate-Control: max-age=0 -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "MISS", "Failed surrogate zero freshness"

    # 1.5 Surrogate-Control: max-age=0+10 (zero freshness with extension)
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/surrogate-zero-ext?h_Surrogate-Control=max-age=0%2B10")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/surrogate-zero-ext?h_Surrogate-Control=max-age=0%2B10")
    record(f"1.5 Surrogate-Control: max-age=0+10 -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "MISS", "Failed surrogate zero with extension"

    # 1.6 Surrogate-Control: content="ESI/1.0" with CC: private
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/esi-private?h_Surrogate-Control=content%3D%22ESI/1.0%22&h_Cache-Control=private")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/esi-private?h_Surrogate-Control=content%3D%22ESI/1.0%22&h_Cache-Control=private")
    record(f"1.6 Surrogate ESI advertisement with CC private -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "MISS", "Failed ESI advertisement with private"

    # 1.7 Static asset default TTL (1d) and grace (7d)
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/style.css")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/style.css")
    record(f"1.7 Static asset default policy -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "HIT", "Failed static asset default"

    # 1.8 Static asset with zero freshness (max-age=0) stays uncacheable
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/zero.css?h_Cache-Control=max-age=0")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/zero.css?h_Cache-Control=max-age=0")
    record(f"1.8 Static asset with CC max-age=0 -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "MISS", "Failed static asset zero freshness"

    # 1.9 Expires invalid string / epoch
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j1/expires-epoch?h_Expires=Thu,%2001%20Jan%201970%2000:00:00%20GMT")
    st2, hd2, bd2, _ = raw_http("GET", f"/{run_id}/j1/expires-epoch?h_Expires=Thu,%2001%20Jan%201970%2000:00:00%20GMT")
    record(f"1.9 Expires: 1970 Epoch -> Req1: {hd.get('x-cache')}, Req2: {hd2.get('x-cache')}")
    assert hd.get("x-cache") == "MISS" and hd2.get("x-cache") == "MISS", "Failed epoch expires"

    # -------------------------------------------------------------
    # Journey 2: Backend Sickness, Health Probes, and Grace
    # -------------------------------------------------------------
    record("\n--- Journey 2: Backend Sickness, Health Probes, and Grace ---")
    
    # 2.1 Prime a normal resource with 1s TTL and 1h grace
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j2/normal-grace?h_Cache-Control=max-age=1")
    # 2.2 Prime a must-revalidate resource
    st, hd, bd, _ = raw_http("GET", f"/{run_id}/j2/must-reval?h_Cache-Control=max-age=1,%20must-revalidate")
    # Wait for TTLs to expire
    time.sleep(1.5)

    # 2.3 Stop origin to simulate backend outage
    log("Stopping origin container...")
    subprocess.check_call(["docker", "stop", "-t", "2", ORIGIN_CONTAINER])
    
    try:
        # Request normal resource: should be served from grace!
        st_norm, hd_norm, bd_norm, _ = raw_http("GET", f"/{run_id}/j2/normal-grace?h_Cache-Control=max-age=1")
        record(f"2.1 Normal resource with expired TTL during backend outage -> Status: {st_norm}, X-Cache: {hd_norm.get('x-cache')}")
        assert st_norm == 200 and hd_norm.get("x-cache") == "HIT", f"Expected 200 HIT from grace, got status={st_norm} cache={hd_norm.get('x-cache')}"
        
        # Request must-revalidate resource: must NOT serve stale, must return 503!
        st_reval, hd_reval, bd_reval, _ = raw_http("GET", f"/{run_id}/j2/must-reval?h_Cache-Control=max-age=1,%20must-revalidate")
        record(f"2.2 must-revalidate resource during backend outage -> Status: {st_reval}, X-Cache: {hd_reval.get('x-cache')}")
        assert st_reval == 503, f"Expected 503 for must-revalidate, got {st_reval}"

        # Request uncached resource: must return 503
        st_uncached, hd_uncached, bd_uncached, _ = raw_http("GET", f"/{run_id}/j2/uncached-outage")
        record(f"2.3 Uncached resource during backend outage -> Status: {st_uncached}")
        assert st_uncached == 503, f"Expected 503 for uncached outage, got {st_uncached}"
    finally:
        log("Restarting origin container...")
        subprocess.check_call(["docker", "start", ORIGIN_CONTAINER])
        # Wait for origin to accept connections
        time.sleep(2)

    # -------------------------------------------------------------
    # Journey 3: Unsafe Mutations and Reference Invalidation
    # -------------------------------------------------------------
    record("\n--- Journey 3: Unsafe Mutations and Invalidation Reference Resolution ---")

    # 3.1 Basic POST invalidation of request URL
    raw_http("GET", f"/{run_id}/j3/post-target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/post-target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("POST", f"/{run_id}/j3/post-target", body="mutate=1")
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/post-target")
    record(f"3.1 POST self-invalidation -> After: {hd_after.get('x-cache')}")
    assert hd_after.get("x-cache") == "MISS", "POST self-invalidation failed"

    # 3.2 POST with relative Location invalidation
    raw_http("GET", f"/{run_id}/j3/loc-target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/loc-target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("POST", f"/{run_id}/j3/create?h_Location=/{run_id}/j3/loc-target", body="create=1")
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/loc-target")
    record(f"3.2 POST with Location: /{run_id}/j3/loc-target -> After: {hd_after.get('x-cache')}")
    assert hd_after.get("x-cache") == "MISS", "Location invalidation failed"

    # 3.3 PUT with Content-Location invalidation
    raw_http("GET", f"/{run_id}/j3/cl-target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/cl-target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("PUT", f"/{run_id}/j3/update?h_Content-Location=/{run_id}/j3/cl-target", body="update=1")
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/cl-target")
    record(f"3.3 PUT with Content-Location: /{run_id}/j3/cl-target -> After: {hd_after.get('x-cache')}")
    assert hd_after.get("x-cache") == "MISS", "Content-Location invalidation failed"

    # 3.4 POST with space in Location URL (fixed in PR #114)
    raw_http("GET", f"/{run_id}/j3/space%20target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/space%20target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("POST", f"/{run_id}/j3/create-space?h_Location=/{run_id}/j3/space%20target", body="create=1")
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/space%20target")
    record(f"3.4 POST with space in Location: /{run_id}/j3/space target -> After: {hd_after.get('x-cache')}")
    assert hd_after.get("x-cache") == "MISS", "Space in Location invalidation failed"

    # 3.5 POST with horizontal tab (HTAB / \t) in Location URL
    errors_before = get_vcl_errors()
    raw_http("GET", f"/{run_id}/j3/tab%09target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/tab%09target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("POST", f"/{run_id}/j3/create-tab?h_Location=/{run_id}/j3/tab%09target", body="create=1")
    errors_after = get_vcl_errors()
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/tab%09target")
    
    tab_bug_found = False
    if len(errors_after) > len(errors_before):
        new_err = errors_after[-1]
        record(f"3.5 [CONFIRMED BUG] Varnish VCL_Error on HTAB in Location: {new_err}")
        record(f"    Target after POST: X-Cache: {hd_after.get('x-cache')} (Expected: MISS, Actual: {hd_after.get('x-cache')})")
        tab_bug_found = True
    else:
        record(f"3.5 HTAB in Location -> After: {hd_after.get('x-cache')}")

    # 3.6 PUT with horizontal tab (HTAB / \t) in Content-Location
    errors_before_cl = get_vcl_errors()
    raw_http("GET", f"/{run_id}/j3/cl-tab%09target")
    _, hd_prime_cl, _, _ = raw_http("GET", f"/{run_id}/j3/cl-tab%09target")
    assert hd_prime_cl.get("x-cache") == "HIT"
    raw_http("PUT", f"/{run_id}/j3/create-cl-tab?h_Content-Location=/{run_id}/j3/cl-tab%09target", body="create=1")
    errors_after_cl = get_vcl_errors()
    _, hd_after_cl, _, _ = raw_http("GET", f"/{run_id}/j3/cl-tab%09target")

    if len(errors_after_cl) > len(errors_before_cl):
        new_err_cl = errors_after_cl[-1]
        record(f"3.6 [CONFIRMED BUG] Varnish VCL_Error on HTAB in Content-Location: {new_err_cl}")
        record(f"    Target after PUT: X-Cache: {hd_after_cl.get('x-cache')} (Expected: MISS, Actual: {hd_after_cl.get('x-cache')})")

    # 3.7 PRG pattern: POST returning 303 See Other with Location
    raw_http("GET", f"/{run_id}/j3/prg-target")
    _, hd_prime, _, _ = raw_http("GET", f"/{run_id}/j3/prg-target")
    assert hd_prime.get("x-cache") == "HIT"
    raw_http("POST", f"/{run_id}/j3/form-submit?status=303&h_Location=/{run_id}/j3/prg-target", body="form=1")
    _, hd_after, _, _ = raw_http("GET", f"/{run_id}/j3/prg-target")
    record(f"3.7 POST with 303 Location PRG invalidation -> After: {hd_after.get('x-cache')}")
    assert hd_after.get("x-cache") == "MISS", "PRG 303 invalidation failed"

    # Save output log
    with open(os.path.join(EVIDENCE_DIR, "pass-output.txt"), "w") as f:
        f.write("\n".join(report_lines) + "\n")

    record("\n=== Exploratory Testing Pass Complete ===")
    return tab_bug_found

if __name__ == "__main__":
    success = run_pass()
    sys.exit(0 if success else 1)
