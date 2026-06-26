#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8082/error"

echo "Purging any existing cached error response..."
http_request purge-error "$url" -X PURGE
assert_http_status purge-error 200 "error PURGE"

echo "Requesting /error (first request)..."
http_request error-first "$url"
assert_http_status error-first 500 "first error request"
assert_cache_state error-first MISS "first error request"
assert_body_field_equals error-first route error "first error request"
first_request_id="$(assert_origin_request_id_present error-first "first error request")"
echo "OK: First error response was MISS from origin"

echo "Requesting /error again immediately (second request)..."
http_request error-second "$url"
assert_http_status error-second 500 "second error request"
assert_cache_state error-second MISS "second error request"
assert_body_field_equals error-second route error "second error request"
assert_different_origin_request_id error-second "$first_request_id" "second error request"
echo "OK: Distinct backend request IDs confirm origin was hit twice, error was not cached"
