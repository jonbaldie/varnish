#!/usr/bin/env bash
set -euo pipefail

VARNISH_HOST="${VARNISH_HOST:-127.0.0.1}"
VARNISH_PORT="${VARNISH_PORT:-80}"

python3 - "$VARNISH_HOST" "$VARNISH_PORT" << 'EOF'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])

def send_request(raw_bytes):
    s = socket.create_connection((host, port), timeout=5)
    s.sendall(raw_bytes)
    resp = b""
    while True:
        try:
            chunk = s.recv(4096)
            if not chunk:
                break
            resp += chunk
        except socket.timeout:
            break
    s.close()
    return resp

def parse_response(raw_resp):
    if not raw_resp:
        return 0, {}, ""
    parts = raw_resp.split(b"\r\n\r\n", 1)
    header_section = parts[0].decode("iso-8859-1")
    body = parts[1].decode("iso-8859-1") if len(parts) > 1 else ""
    lines = header_section.split("\r\n")
    status_line = lines[0]
    status_code = int(status_line.split(" ")[1])
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    return status_code, headers, body

print(f"=== Asserting Host Header Behavior against {host}:{port} ===")

# Test 1: HTTP/1.1 request without Host header must return 400 Bad Request
print("1. Testing HTTP/1.1 request without Host header...")
resp1 = send_request(b"GET / HTTP/1.1\r\nConnection: close\r\n\r\n")
code1, hdrs1, body1 = parse_response(resp1)
print(f"   Response status: {code1}, Server: {hdrs1.get('server')}")
if code1 != 400 or hdrs1.get("server", "").lower() != "varnish":
    print(f"FAIL: Expected HTTP 400 from Varnish for HTTP/1.1 without Host header, got {code1} (server: {hdrs1.get('server')})")
    sys.exit(1)
print("   OK: HTTP/1.1 without Host header returned 400 Bad Request from Varnish")

# Test 2: HTTP/1.1 request with empty Host header must return 400 Bad Request
print("2. Testing HTTP/1.1 request with empty Host header...")
resp2 = send_request(b"GET / HTTP/1.1\r\nHost: \r\nConnection: close\r\n\r\n")
code2, hdrs2, body2 = parse_response(resp2)
print(f"   Response status: {code2}, Server: {hdrs2.get('server')}")
if code2 != 400 or hdrs2.get("server", "").lower() != "varnish":
    print(f"FAIL: Expected HTTP 400 from Varnish for HTTP/1.1 with empty Host header, got {code2} (server: {hdrs2.get('server')})")
    sys.exit(1)
print("   OK: HTTP/1.1 with empty Host header returned 400 Bad Request from Varnish")

# Test 2b: HTTP/1.1 request with whitespace-only Host header must return 400 Bad Request
print("2b. Testing HTTP/1.1 request with whitespace-only Host header...")
resp2b = send_request(b"GET / HTTP/1.1\r\nHost:   \r\nConnection: close\r\n\r\n")
code2b, hdrs2b, body2b = parse_response(resp2b)
print(f"   Response status: {code2b}, Server: {hdrs2b.get('server')}")
if code2b != 400 or hdrs2b.get("server", "").lower() != "varnish":
    print(f"FAIL: Expected HTTP 400 from Varnish for HTTP/1.1 with whitespace-only Host header, got {code2b} (server: {hdrs2b.get('server')})")
    sys.exit(1)
print("   OK: HTTP/1.1 with whitespace-only Host header returned 400 Bad Request from Varnish")

# Test 2d: HTTP/1.1 request with tab whitespace Host header must return 400 Bad Request
print("2d. Testing HTTP/1.1 request with tab Host header...")
resp2d = send_request(b"GET / HTTP/1.1\r\nHost: \t\r\nConnection: close\r\n\r\n")
code2d, hdrs2d, body2d = parse_response(resp2d)
print(f"   Response status: {code2d}, Server: {hdrs2d.get('server')}")
if code2d != 400 or hdrs2d.get("server", "").lower() != "varnish":
    print(f"FAIL: Expected HTTP 400 from Varnish for HTTP/1.1 with tab Host header, got {code2d} (server: {hdrs2d.get('server')})")
    sys.exit(1)
print("   OK: HTTP/1.1 with tab Host header returned 400 Bad Request from Varnish")

# Test 2c: HTTP/1.1 HEAD and POST requests without Host header must return 400 Bad Request
print("2c. Testing HTTP/1.1 HEAD and POST requests without Host header...")
for method in [b"HEAD", b"POST"]:
    resp_m = send_request(method + b" / HTTP/1.1\r\nConnection: close\r\n\r\n")
    code_m, hdrs_m, _ = parse_response(resp_m)
    print(f"   {method.decode()} without Host response status: {code_m}, Server: {hdrs_m.get('server')}")
    if code_m != 400 or hdrs_m.get("server", "").lower() != "varnish":
        print(f"FAIL: Expected HTTP 400 from Varnish for HTTP/1.1 {method.decode()} without Host header, got {code_m} (server: {hdrs_m.get('server')})")
        sys.exit(1)
print("   OK: HTTP/1.1 HEAD and POST without Host header returned 400 Bad Request from Varnish")

# Test 3: HTTP/1.1 request with valid Host header must succeed (HTTP 200)
print("3. Testing HTTP/1.1 request with valid Host header...")
resp3 = send_request(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
code3, hdrs3, body3 = parse_response(resp3)
print(f"   Response status: {code3}")
if code3 != 200:
    print(f"FAIL: Expected HTTP 200 for HTTP/1.1 with valid Host header, got {code3}")
    sys.exit(1)
print("   OK: HTTP/1.1 with valid Host header returned 200 OK")

# Test 4: HTTP/1.0 request without Host header must succeed (HTTP 200)
print("4. Testing HTTP/1.0 request without Host header...")
resp4 = send_request(b"GET / HTTP/1.0\r\nConnection: close\r\n\r\n")
code4, hdrs4, body4 = parse_response(resp4)
print(f"   Response status: {code4}")
if code4 != 200:
    print(f"FAIL: Expected HTTP 200 for HTTP/1.0 without Host header, got {code4}")
    sys.exit(1)
print("   OK: HTTP/1.0 without Host header returned 200 OK")

# Test 5: Host header casing normalization (RFC 9110 §7.2)
# Requests differing only in Host casing should share cache entries
import random
nonce = random.randint(100000, 999999)
path = f"/?host_casing_test={nonce}"
print(f"5. Testing Host casing cache sharing on {path}...")

# First request with UPPERCASE host
resp5_upper = send_request(f"GET {path} HTTP/1.1\r\nHost: EXAMPLE.COM\r\nConnection: close\r\n\r\n".encode())
code5_upper, hdrs5_upper, _ = parse_response(resp5_upper)
xcache_upper = hdrs5_upper.get("x-cache", "")
print(f"   First request (Host: EXAMPLE.COM): status {code5_upper}, X-Cache: {xcache_upper}")
if code5_upper != 200:
    print(f"FAIL: Expected HTTP 200 for uppercase Host, got {code5_upper}")
    sys.exit(1)

# Second request with lowercase host
resp5_lower = send_request(f"GET {path} HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n".encode())
code5_lower, hdrs5_lower, _ = parse_response(resp5_lower)
xcache_lower = hdrs5_lower.get("x-cache", "")
print(f"   Second request (Host: example.com): status {code5_lower}, X-Cache: {xcache_lower}")
if code5_lower != 200:
    print(f"FAIL: Expected HTTP 200 for lowercase Host, got {code5_lower}")
    sys.exit(1)
if "HIT" not in xcache_lower:
    print(f"FAIL: Expected X-Cache HIT for lowercase Host matching uppercase cached entry, got '{xcache_lower}'")
    sys.exit(1)
print("   OK: Uppercase and lowercase Host headers share cache entry (X-Cache: HIT)")

print("=== ALL HOST HEADER ASSERTIONS PASSED ===")
EOF
