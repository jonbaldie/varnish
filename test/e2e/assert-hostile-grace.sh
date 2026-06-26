#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8083/short-cache"

echo "Priming cache (first request, expect MISS)..."
http_request grace-first "$url"
assert_cache_state grace-first MISS "first grace request"
assert_body_field_equals grace-first route short-cache "first grace request"
first_request_id="$(assert_origin_request_id_present grace-first "first grace request")"

echo "Confirming object is cached (second request, expect HIT)..."
http_request grace-second "$url"
assert_cache_state grace-second HIT "second grace request"
assert_same_origin_request_id grace-second "$first_request_id" "second grace request"
echo "OK: Object cached with short TTL and grace"

echo "Stopping backend..."
docker compose -p "${TEST_PROJECT:?TEST_PROJECT must be set}" -f "$repo_root/docker-compose.grace-test.yml" stop web

echo "Waiting 22s for TTL expiry and backend sickness..."
sleep 22

echo "Requesting stale object while backend is sick..."
http_request grace-stale "$url"
assert_http_status grace-stale 200 "stale grace request"
assert_body_field_equals grace-stale route short-cache "stale grace request"
assert_same_origin_request_id grace-stale "$first_request_id" "stale grace request"
echo "OK: Grace served stale cached object while backend was unavailable"
