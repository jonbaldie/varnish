#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

purge_query="purge_test=$(openssl rand -hex 8)"
purge_url="http://localhost:8085/short-cache?${purge_query}"

echo "Priming a cacheable hostile response before authorized PURGE..."
http_request purge-target-first "$purge_url"
assert_http_status purge-target-first 200 "first purge target request"
assert_cache_state purge-target-first MISS "first purge target request"
first_request_id="$(assert_origin_request_id_present purge-target-first "first purge target request")"

http_request purge-target-second "$purge_url"
assert_http_status purge-target-second 200 "second purge target request"
assert_cache_state purge-target-second HIT "second purge target request"
assert_same_origin_request_id purge-target-second "$first_request_id" "second purge target request"

echo "Verifying authorized PURGE host (IP in ACL) succeeds and evicts the object..."
http_request purge-authorized "$purge_url" -X PURGE
assert_http_status purge-authorized 200 "authorized PURGE"
echo "OK: Authorized PURGE returns 200"

http_request purge-target-after "$purge_url"
assert_http_status purge-target-after 200 "purge target after PURGE"
assert_cache_state purge-target-after MISS "purge target after PURGE"
assert_different_origin_request_id purge-target-after "$first_request_id" "purge target after PURGE"
echo "OK: Authorized PURGE evicted the cached response"

echo "Testing unauthorized PURGE from a real Compose-network peer..."
peer_net="$(
  docker network ls \
    --filter "name=${TEST_PROJECT:?TEST_PROJECT must be set}_backend" \
    --format '{{.Name}}' \
    | grep '_backend$' \
    | head -n 1
)"

if [ -z "$peer_net" ]; then
  echo "FAIL: Could not find backend test network project $TEST_PROJECT"
  docker network ls --filter "name=$TEST_PROJECT"
  exit 1
fi

peer_status="$(
  docker run --rm \
    --network "$peer_net" \
    alpine \
    sh -c "apk add -q curl && curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X PURGE http://varnish/"
)"

if [ "$peer_status" != "405" ]; then
  echo "FAIL: Expected 405 unauthorized PURGE from a Compose-network peer, got $peer_status"
  exit 1
fi

echo "OK: Compose-network peer PURGE returns 405"

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
