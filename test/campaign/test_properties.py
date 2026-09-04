#!/usr/bin/env python3
"""Phase 2: Coverage-guided Property-based Testing (CGPT) & Metamorphic Testing."""

import http.client
import json
import os
import random
import string
import time
import urllib.parse
import urllib.request

class Finding:
    def __init__(self, category, name, description, reproducer, severity="HIGH"):
        self.category = category
        self.name = name
        self.description = description
        self.reproducer = reproducer
        self.severity = severity

    def to_dict(self):
        return {
            "category": self.category,
            "name": self.name,
            "description": self.description,
            "reproducer": self.reproducer,
            "severity": self.severity,
        }

findings = []

def raw_http_request(host, port, method, path, headers=None, body=None, timeout=5):
    """Perform raw HTTP request using http.client to preserve exact headers."""
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    hdrs = headers or {}
    conn.request(method, path, body=body, headers=hdrs)
    resp = conn.getresponse()
    resp_body = resp.read()
    resp_headers = {k.title(): v for k, v in resp.getheaders()}
    conn.close()
    return {
        "status": resp.status,
        "headers": resp_headers,
        "body": resp_body.decode("utf-8", errors="replace"),
        "x_cache": resp_headers.get("X-Cache", ""),
        "backend_req_id": resp_headers.get("X-Backend-Request-Id", ""),
        "set_cookie": resp_headers.get("Set-Cookie", None),
    }

def purge_url(varnish_host, varnish_port, path):
    try:
        res = raw_http_request(varnish_host, varnish_port, "PURGE", path)
        return res["status"] == 200
    except Exception:
        return False

# -------------------------------------------------------------
# Property 1: Static Asset Extensions, Query Strings & Casing
# -------------------------------------------------------------
def test_static_asset_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 1] Static Asset Caching, Cookie Stripping & Query Strings ---")
    
    extensions = [
        "css", "js", "png", "jpg", "jpeg", "gif", "ico", "svg", 
        "webp", "avif", "woff", "woff2", "ttf", "eot", "otf", 
        "mp3", "ogg", "webm", "gz", "tgz", "bz2", "tbz"
    ]

    # Test 1.1: Standard static assets without query strings (Base property)
    print("Testing base static asset extensions...")
    for ext in extensions:
        path = f"/test-base-{ext}.{ext}"
        purge_url(varnish_host, varnish_port, path)
        
        # First request with a cookie
        r1 = raw_http_request(varnish_host, varnish_port, "GET", path, headers={"Cookie": "session=secret_tracker"})
        r2 = raw_http_request(varnish_host, varnish_port, "GET", path, headers={"Cookie": "session=secret_tracker"})

        # Check if cookie reached backend
        backend_history = [h for h in backend.get_history() if h["path"] == path]
        if backend_history:
            recv_cookie = backend_history[0]["headers"].get("Cookie", None)
            if recv_cookie:
                print(f"[BUG] Cookie was NOT stripped for standard static asset {path}")
                findings.append(Finding(
                    category="Cookie Stripping / Privacy",
                    name=f"Static asset {ext} leaked Cookie to origin",
                    description=f"Request to {path} with Cookie header forwarded the cookie to backend: {recv_cookie}",
                    reproducer=f"curl -H 'Cookie: session=secret' http://{varnish_host}:{varnish_port}{path}",
                    severity="HIGH"
                ))

        if "HIT" not in r2["x_cache"]:
            print(f"[BUG] Static asset {path} was not cached on second request: X-Cache={r2['x_cache']}")
            findings.append(Finding(
                category="Caching Logic",
                name=f"Static asset {ext} not cached",
                description=f"Consecutive requests to {path} produced X-Cache='{r2['x_cache']}' instead of HIT",
                reproducer=f"curl -i http://{varnish_host}:{varnish_port}{path} && curl -i http://{varnish_host}:{varnish_port}{path}",
                severity="HIGH"
            ))

    # Test 1.2: Metamorphic Property - Static assets WITH Query Parameters (?v=123, ?hash=...)
    print("Testing static assets with query strings (metamorphic mutation)...")
    query_permutations = [
        "?v=1",
        "?v=1.0.0",
        "?hash=a9b8c7",
        "?cachebust=12345",
        "?w=200&h=100",
        "?ver=4.2",
    ]

    for ext in ["css", "js", "png", "svg", "jpg"]:
        for q in query_permutations:
            path = f"/static-query-{ext}.{ext}{q}"
            purge_url(varnish_host, varnish_port, path)

            # Request 1 with Cookie
            r1 = raw_http_request(varnish_host, varnish_port, "GET", path, headers={"Cookie": "session=user_identity_123"})
            # Request 2 with Cookie
            r2 = raw_http_request(varnish_host, varnish_port, "GET", path, headers={"Cookie": "session=user_identity_123"})

            # Check if cookie reached backend
            backend_reqs = [h for h in backend.get_history() if h["path"] == path]
            cookie_leaked = any(h["headers"].get("Cookie") for h in backend_reqs)

            if cookie_leaked:
                print(f"[CRITICAL BUG] Static asset with query string '{path}' leaked Cookie to backend!")
                findings.append(Finding(
                    category="Cookie Stripping / Privacy",
                    name="Static asset with query parameter leaks Cookie and bypasses cache",
                    description=(
                        f"When requesting static asset with query string '{path}', "
                        f"the regex in cache-policy.vcl ('\\.(css|js...)$') fails to match due to the '$' anchor. "
                        f"Consequently, Cookie header is NOT stripped, and 'if (req.http.Cookie) return (pass);' "
                        f"causes the request to PASS to origin, leaking private cookies and completely bypassing cache!"
                    ),
                    reproducer=f"curl -v -H 'Cookie: session=secret' http://{varnish_host}:{varnish_port}{path}",
                    severity="HIGH"
                ))
                break # Reported for category

            if "HIT" not in r2["x_cache"]:
                print(f"[CRITICAL BUG] Static asset with query string '{path}' was NOT cached: {r2['x_cache']}")
                findings.append(Finding(
                    category="Caching Inefficiency",
                    name="Static assets with query parameters are not cached when Cookie is present",
                    description=(
                        f"Static asset '{path}' was not served from cache on second request (got '{r2['x_cache']}'). "
                        "Websites widely use query parameters for cache-busting (e.g. style.css?v=2); this defect causes origin overload."
                    ),
                    reproducer=f"curl -i -H 'Cookie: test=1' http://{varnish_host}:{varnish_port}{path} && curl -i -H 'Cookie: test=1' http://{varnish_host}:{varnish_port}{path}",
                    severity="HIGH"
                ))
                break

    # Test 1.3: Case Sensitivity (.CSS, .PNG, .Js)
    print("Testing uppercase / mixed-case static asset extensions...")
    cased_paths = [
        "/test-upper.CSS",
        "/test-upper.PNG",
        "/test-upper.JPG",
        "/test-upper.Js",
    ]
    for path in cased_paths:
        purge_url(varnish_host, varnish_port, path)
        r1 = raw_http_request(varnish_host, varnish_port, "GET", path, headers={"Cookie": "auth=token123"})
        backend_reqs = [h for h in backend.get_history() if h["path"] == path]
        if backend_reqs and backend_reqs[0]["headers"].get("Cookie"):
            print(f"[BUG] Uppercase static extension '{path}' is not recognized: Cookie was not stripped")
            findings.append(Finding(
                category="Regex Case Sensitivity",
                name="Static asset regex is case-sensitive (ignores uppercase extensions)",
                description=(
                    f"Request for '{path}' did not match static asset regex because VCL regex '~' is case-sensitive. "
                    "Cookie was not stripped and request bypassed cache."
                ),
                reproducer=f"curl -H 'Cookie: test=1' http://{varnish_host}:{varnish_port}{path}",
                severity="MEDIUM"
            ))
            break


# -------------------------------------------------------------
# Property 2: Origin Set-Cookie & Cache-Control Security Invariant
# -------------------------------------------------------------
def test_origin_security_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 2] Origin Set-Cookie & Cache-Control Poisoning / Isolation ---")

    # Test 2.1: CRITICAL SECURITY TEST: Unauthenticated user gets Set-Cookie from origin
    print("Testing origin Set-Cookie caching for unauthenticated first visitor...")
    path = "/api/login-anonymous"
    purge_url(varnish_host, varnish_port, path)

    backend.set_route(
        path,
        status=200,
        headers={
            "Set-Cookie": "session_id=ALICE_SECRET_SESSION_TOKEN; Path=/; HttpOnly",
            "Content-Type": "application/json",
            "Cache-Control": "public, max-age=3600"
        },
        body='{"user": "alice", "token": "secret"}'
    )

    # Alice visits without a Cookie (e.g. anonymous visitor receiving new session)
    r1 = raw_http_request(varnish_host, varnish_port, "GET", path)
    
    # Bob visits the same URL, also without a cookie
    r2 = raw_http_request(varnish_host, varnish_port, "GET", path)

    print(f"Alice request: status={r1['status']}, X-Cache={r1['x_cache']}, Set-Cookie={r1['set_cookie']}")
    print(f"Bob request:   status={r2['status']}, X-Cache={r2['x_cache']}, Set-Cookie={r2['set_cookie']}")

    if "HIT" in r2["x_cache"] and r2["set_cookie"] == "session_id=ALICE_SECRET_SESSION_TOKEN; Path=/; HttpOnly":
        print("[CRITICAL SECURITY VULNERABILITY] Varnish cached Set-Cookie and served Alice's session to Bob!")
        findings.append(Finding(
            category="Security / Session Leakage",
            name="Cache Poisoning: Origin Set-Cookie cached and leaked to other users",
            description=(
                "When an unauthenticated client sends GET to an endpoint where the origin returns 'Set-Cookie', "
                "cache-policy.vcl's vcl_backend_response executes 'return (deliver);', bypassing Varnish's built-in "
                "protection (vcl_beresp_cookie / beresp.uncacheable). As a result, the response AND the Set-Cookie header "
                "are stored in cache. Subsequent visitors receive X-Cache: HIT and are handed another user's session cookie!"
            ),
            reproducer=(
                f"1. Configure backend to return Set-Cookie: session=secret\n"
                f"2. curl -i http://{varnish_host}:{varnish_port}{path} (Alice)\n"
                f"3. curl -i http://{varnish_host}:{varnish_port}{path} (Bob sees Alice's Set-Cookie and X-Cache: HIT!)"
            ),
            severity="CRITICAL"
        ))

    # Test 2.2: Cache-Control: private & no-store honoring
    print("Testing Cache-Control: private & no-store honoring...")
    for cc_directive in ["private", "no-store", "no-cache"]:
        path = f"/private-data-{cc_directive}"
        purge_url(varnish_host, varnish_port, path)

        backend.set_route(
            path,
            status=200,
            headers={
                "Cache-Control": f"{cc_directive}, max-age=3600",
                "Content-Type": "text/plain",
            },
            body=f"Confidential data with {cc_directive}"
        )

        r1 = raw_http_request(varnish_host, varnish_port, "GET", path)
        r2 = raw_http_request(varnish_host, varnish_port, "GET", path)

        if "HIT" in r2["x_cache"]:
            print(f"[CRITICAL RFC VIOLATION] Varnish cached response with 'Cache-Control: {cc_directive}'!")
            findings.append(Finding(
                category="RFC 9111 Compliance / Privacy",
                name=f"Varnish caches response despite Cache-Control: {cc_directive}",
                description=(
                    f"Origin returned 'Cache-Control: {cc_directive}', but Varnish cached the response (X-Cache: HIT). "
                    "This occurs because vcl_backend_response explicitly returns 'deliver' before Varnish built-in "
                    "checks (vcl_beresp_control) can inspect Cache-Control and mark the object uncacheable."
                ),
                reproducer=(
                    f"curl -i http://{varnish_host}:{varnish_port}{path} (returns Cache-Control: {cc_directive})\n"
                    f"curl -i http://{varnish_host}:{varnish_port}{path} (returns X-Cache: HIT!)"
                ),
                severity="CRITICAL"
            ))


# -------------------------------------------------------------
# Property 3: Accept-Encoding Metamorphic Properties
# -------------------------------------------------------------
def test_accept_encoding_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 3] Accept-Encoding Normalization & RFC Compliance ---")

    # Test 3.1: Client explicitly forbids gzip via gzip;q=0
    path = "/echo-headers/test-ae-q0"
    r = raw_http_request(
        varnish_host, varnish_port, "GET", path,
        headers={"Accept-Encoding": "gzip;q=0, deflate"}
    )
    data = json.loads(r["body"])
    backend_ae = data.get("accept_encoding_received")

    if backend_ae == "gzip":
        print(f"[BUG] Client sent 'gzip;q=0' (refusing gzip), but Varnish rewritten to '{backend_ae}'!")
        findings.append(Finding(
            category="HTTP RFC Compliance",
            name="Accept-Encoding: gzip;q=0 incorrectly normalized to gzip",
            description=(
                "RFC 9110 specifies that 'q=0' means the encoding is not acceptable to the client. "
                "In cache-policy.vcl, 'elsif (req.http.Accept-Encoding ~ \"gzip\")' matches 'gzip;q=0' "
                "and rewrites it to 'gzip'. If the origin compresses the response with gzip, the client cannot decode it."
            ),
            reproducer=f"curl -H 'Accept-Encoding: gzip;q=0, deflate' http://{varnish_host}:{varnish_port}{path}",
            severity="HIGH"
        ))

    # Test 3.2: Static asset with query string: does Accept-Encoding get stripped?
    path = "/echo-headers/asset.css?v=2"
    r = raw_http_request(
        varnish_host, varnish_port, "GET", path,
        headers={"Accept-Encoding": "gzip, deflate"}
    )
    data = json.loads(r["body"])
    backend_ae = data.get("accept_encoding_received")
    if backend_ae is not None:
        print(f"[BUG] Static asset with query string '{path}' did NOT have Accept-Encoding stripped: received '{backend_ae}'")
        findings.append(Finding(
            category="Cache Efficiency",
            name="Static asset with query parameter retains Accept-Encoding header",
            description=(
                f"For static assets, cache-policy.vcl is intended to unset Accept-Encoding so the cache is not fragmented. "
                f"However, with query string '{path}', Accept-Encoding was forwarded as '{backend_ae}'."
            ),
            reproducer=f"curl -H 'Accept-Encoding: gzip' http://{varnish_host}:{varnish_port}{path}",
            severity="MEDIUM"
        ))


# -------------------------------------------------------------
# Property 4: HTTP Methods & Verbs
# -------------------------------------------------------------
def test_http_methods_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 4] HTTP Methods Caching & Cache Invalidation ---")

    # Prime a URL with GET
    path = "/api/resource-item"
    purge_url(varnish_host, varnish_port, path)
    backend.set_route(path, status=200, body="initial GET state")

    r_get1 = raw_http_request(varnish_host, varnish_port, "GET", path)
    r_get2 = raw_http_request(varnish_host, varnish_port, "GET", path)
    assert "HIT" in r_get2["x_cache"], f"Expected GET to be cached: {r_get2['x_cache']}"

    # Non-GET/HEAD methods must bypass cache
    for method in ["POST", "PUT", "DELETE", "PATCH"]:
        r_mut = raw_http_request(varnish_host, varnish_port, method, path, body=f"data for {method}")
        if "HIT" in r_mut["x_cache"]:
            print(f"[CRITICAL BUG] {method} request was served from cache: {r_mut['x_cache']}")
            findings.append(Finding(
                category="HTTP Method Safety",
                name=f"{method} served from cache",
                description=f"HTTP method {method} was served from cache with X-Cache: HIT instead of passing to origin",
                reproducer=f"curl -X {method} http://{varnish_host}:{varnish_port}{path}",
                severity="CRITICAL"
            ))
        else:
            print(f"[+] {method} correctly bypassed cache (X-Cache: {r_mut['x_cache']})")


# -------------------------------------------------------------
# Property 5: PURGE ACL & IP Spoofing
# -------------------------------------------------------------
def test_purge_acl_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 5] PURGE ACL Security & IP Spoofing Invariance ---")

    path = "/purge-target-test"
    # Prime
    raw_http_request(varnish_host, varnish_port, "GET", path)

    # Try spoofing headers from localhost connection
    spoofed_headers = [
        {"X-Forwarded-For": "203.0.113.195"},
        {"Client-IP": "203.0.113.195"},
        {"X-Real-IP": "203.0.113.195"},
    ]

    for hdrs in spoofed_headers:
        r = raw_http_request(varnish_host, varnish_port, "PURGE", path, headers=hdrs)
        # Because connection is from localhost (127.0.0.1), client.ip is 127.0.0.1.
        # It should succeed even if X-Forwarded-For is present, proving client.ip is used, not X-Forwarded-For.
        if r["status"] != 200:
            print(f"[!] Note: PURGE with {hdrs} returned {r['status']}")

    # What about PURGE on static asset with query string:
    q_path = "/static-test.css?v=1"
    raw_http_request(varnish_host, varnish_port, "GET", q_path)
    r_purge = raw_http_request(varnish_host, varnish_port, "PURGE", q_path)
    if r_purge["status"] != 200:
        print(f"[!] PURGE on path with query string returned {r_purge['status']}")


# -------------------------------------------------------------
# Property 6: 5xx Error Resilience & Grace Behavior
# -------------------------------------------------------------
def test_5xx_and_grace_properties(varnish_host, varnish_port, backend):
    print("\n--- [CGPT Property 6] 5xx Backend Response & Grace Interaction ---")

    path = "/test-500-error-flow"
    purge_url(varnish_host, varnish_port, path)

    backend.set_route(path, status=500, body="Origin Internal Error\n")
    
    # First request: 500 from origin
    r1 = raw_http_request(varnish_host, varnish_port, "GET", path)
    r2 = raw_http_request(varnish_host, varnish_port, "GET", path)

    print(f"500 request 1: status={r1['status']}, X-Cache={r1['x_cache']}, backend_id={r1['backend_req_id']}")
    print(f"500 request 2: status={r2['status']}, X-Cache={r2['x_cache']}, backend_id={r2['backend_req_id']}")

    if r1["backend_req_id"] == r2["backend_req_id"] and "HIT" in r2["x_cache"]:
        print("[CRITICAL BUG] 500 error was cached and served as HIT!")
        findings.append(Finding(
            category="Error Caching",
            name="500 Internal Server Error cached and served from cache",
            description="Origin 500 error was cached and served to subsequent request as X-Cache: HIT",
            reproducer=f"curl -i http://{varnish_host}:{varnish_port}{path} && curl -i http://{varnish_host}:{varnish_port}{path}",
            severity="CRITICAL"
        ))


def run_all(varnish_host="127.0.0.1", varnish_port=80, backend=None):
    print("==========================================================")
    print("PHASE 2: Coverage-Guided Property-Based Testing (CGPT)")
    print("==========================================================")
    test_static_asset_properties(varnish_host, varnish_port, backend)
    test_origin_security_properties(varnish_host, varnish_port, backend)
    test_accept_encoding_properties(varnish_host, varnish_port, backend)
    test_http_methods_properties(varnish_host, varnish_port, backend)
    test_purge_acl_properties(varnish_host, varnish_port, backend)
    test_5xx_and_grace_properties(varnish_host, varnish_port, backend)
    print(f"\nPhase 2 Complete. Findings: {len(findings)}")
    return [f.to_dict() for f in findings]

if __name__ == "__main__":
    from backend import start_backend
    backend = start_backend(8080)
    res = run_all("127.0.0.1", 80, backend)
    print(json.dumps(res, indent=2))
