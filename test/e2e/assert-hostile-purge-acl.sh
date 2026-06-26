#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

echo "Verifying authorized PURGE host (IP in ACL) succeeds..."
http_request purge-authorized "http://localhost:8085/" -X PURGE
assert_http_status purge-authorized 200 "authorized PURGE"
echo "OK: Authorized PURGE returns 200"

echo "Testing unauthorized PURGE 203.0.113.100 (outside ACL)..."
net="$(
  docker network ls \
    --filter "name=${TEST_PROJECT:?TEST_PROJECT must be set}" \
    --format '{{.Name}}' \
    | grep "_external$"
)"

if [ -z "$net" ]; then
  echo "FAIL: Could not find external test network project $TEST_PROJECT"
  docker network ls --filter "name=$TEST_PROJECT"
  exit 1
fi

status="$(
  docker run --rm \
    --network "$net" \
    --ip 203.0.113.100 \
    alpine \
    sh -c "apk add -q curl && curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE http://203.0.113.2/"
)"

if [ "$status" != "405" ]; then
  echo "FAIL: Expected 405 unauthorized PURGE from 203.0.113.100, got $status"
  exit 1
fi

echo "OK: Unauthorized PURGE 203.0.113.100 returns 405"
