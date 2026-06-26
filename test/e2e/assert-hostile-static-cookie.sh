#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8081/static/app.css"

echo "Purging any existing cached asset..."
http_request purge-static-cookie "$url" -X PURGE
assert_http_status purge-static-cookie 200 "static asset PURGE"

echo "Requesting static asset with Cookie (first request)..."
http_request static-cookie-first "$url" -H 'Cookie: client=alice'
assert_cache_state static-cookie-first MISS "first static asset request"
assert_header_contains static-cookie-first Content-Type "text/css" "first static asset request"
assert_body_field_equals static-cookie-first asset "app.css" "first static asset request"
assert_body_field_equals static-cookie-first cookie "none" "first static asset request"
first_request_id="$(assert_origin_request_id_present static-cookie-first "first static asset request")"
echo "OK: First request was cache miss against origin request ${first_request_id}"

echo "Requesting static asset with Cookie (second request)..."
http_request static-cookie-second "$url" -H 'Cookie: client=alice'
assert_cache_state static-cookie-second HIT "second static asset request"
assert_header_contains static-cookie-second Content-Type "text/css" "second static asset request"
assert_body_field_equals static-cookie-second asset "app.css" "second static asset request"
assert_body_field_equals static-cookie-second cookie "none" "second static asset request"
assert_same_origin_request_id static-cookie-second "$first_request_id" "second static asset request"
echo "OK: Second request was cache hit reusing origin request ${first_request_id}"
