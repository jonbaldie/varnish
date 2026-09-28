#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "Checking HTTP 200..."
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost)"
if [ "$status" != "200" ]; then
  echo "FAIL: Expected HTTP 200, got $status"
  exit 1
fi
echo "OK: HTTP 200"

test_url="http://localhost/?cachebust=$(openssl rand -hex 8)"
echo "Checking X-Cache MISS on first request..."
cache="$(curl -sI --max-time 10 "$test_url" | grep -i x-cache)"
if ! echo "$cache" | grep -qi MISS; then
  echo "FAIL: Expected X-Cache MISS, got: $cache"
  exit 1
fi
echo "OK: X-Cache MISS"

echo "Checking X-Cache HIT on second request..."
cache="$(curl -sI --max-time 10 "$test_url" | grep -i x-cache)"
if ! echo "$cache" | grep -qi HIT; then
  echo "FAIL: Expected X-Cache HIT, got: $cache"
  exit 1
fi
echo "OK: X-Cache HIT"

echo "Checking Host header compliance (RFC 9112 / RFC 9110)..."
"$repo_root/test/e2e/assert-host-header.sh"
