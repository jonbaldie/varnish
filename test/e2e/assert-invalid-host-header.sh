#!/usr/bin/env bash

set -euo pipefail

VARNISH_HOST="${VARNISH_HOST:-127.0.0.1}"
VARNISH_PORT="${VARNISH_PORT:-8081}"

python3 - "$VARNISH_HOST" "$VARNISH_PORT" << 'EOF'
import socket
import sys

host = sys.argv[1]
port = int(sys.argv[2])


def send_request(raw_bytes):
    with socket.create_connection((host, port), timeout=5) as sock:
        sock.sendall(raw_bytes)
        response = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            response += chunk
    return response


def parse_response(raw_resp):
    if not raw_resp:
        return 0, {}

    header_section = raw_resp.split(b"\r\n\r\n", 1)[0]
    lines = header_section.decode("iso-8859-1").split("\r\n")
    status_code = int(lines[0].split(" ")[1])
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            key, value = line.split(":", 1)
            headers[key.strip().lower()] = value.strip()
    return status_code, headers


def assert_vcl_rejection(label, host_value):
    request = (
        b"GET / HTTP/1.1\r\nHost: "
        + host_value
        + b"\r\nConnection: close\r\n\r\n"
    )
    for attempt in range(1, 4):
        code, headers = parse_response(send_request(request))
        server = headers.get("server", "")
        backend = headers.get("x-backend")
        print(
            f"{label} attempt {attempt}: status={code}, "
            f"server={server!r}, x-backend={backend!r}"
        )
        if code != 400 or server.lower() != "varnish" or backend is not None:
            print(
                f"FAIL: {label} should be rejected by Varnish with 400; "
                f"the request reached the backend or returned another status"
            )
            sys.exit(1)


print(f"=== Asserting invalid Host values against {host}:{port} ===")
assert_vcl_rejection("userinfo in Host", b"user@example.com")
assert_vcl_rejection("space in Host", b"foo bar.com")
assert_vcl_rejection("non-numeric port in Host", b"example.com:abc")

# HTTP/1.0 is outside RFC 9112's mandatory Host validation requirement.
code_10, headers_10 = parse_response(
    send_request(
        b"GET / HTTP/1.0\r\n"
        b"Host: user@example.com\r\n"
        b"Connection: close\r\n\r\n"
    )
)
print(
    f"HTTP/1.0 invalid Host control: status={code_10}, "
    f"server={headers_10.get('server', '')!r}, "
    f"x-backend={headers_10.get('x-backend')!r}"
)
if code_10 != 200 or headers_10.get("x-backend") != "hostile":
    print("FAIL: HTTP/1.0 control should still reach the hostile backend")
    sys.exit(1)

# A syntactically valid HTTP/1.1 Host must remain accepted.
code_valid, headers_valid = parse_response(
    send_request(
        b"GET / HTTP/1.1\r\n"
        b"Host: localhost\r\n"
        b"Connection: close\r\n\r\n"
    )
)
print(
    f"valid HTTP/1.1 Host control: status={code_valid}, "
    f"server={headers_valid.get('server', '')!r}, "
    f"x-backend={headers_valid.get('x-backend')!r}"
)
if code_valid != 200 or headers_valid.get("x-backend") != "hostile":
    print("FAIL: valid HTTP/1.1 Host control should reach the hostile backend")
    sys.exit(1)

# RFC 3986 defines port as zero or more decimal digits, so an empty optional
# port remains a valid URI authority component (for example, "localhost:").
code_empty_port, headers_empty_port = parse_response(
    send_request(
        b"GET / HTTP/1.1\r\n"
        b"Host: localhost:\r\n"
        b"Connection: close\r\n\r\n"
    )
)
print(
    f"empty numeric port control: status={code_empty_port}, "
    f"server={headers_empty_port.get('server', '')!r}, "
    f"x-backend={headers_empty_port.get('x-backend')!r}"
)
if code_empty_port != 200 or headers_empty_port.get("x-backend") != "hostile":
    print("FAIL: an empty optional port should reach the hostile backend")
    sys.exit(1)

print("=== ALL INVALID HOST ASSERTIONS PASSED ===")
EOF
