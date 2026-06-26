#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8084/static/app.css"

echo "Purging any existing cached asset..."
http_request purge-post-asset "$url" -X PURGE
assert_http_status purge-post-asset 200 "POST asset PURGE"

echo "Priming cache with GET (first request, expect MISS)..."
http_request post-get-first "$url"
assert_cache_state post-get-first MISS "first GET before POST"
first_request_id="$(assert_origin_request_id_present post-get-first "first GET before POST")"

echo "Confirming GET is cached (second request, expect HIT)..."
http_request post-get-second "$url"
assert_cache_state post-get-second HIT "second GET before POST"
assert_same_origin_request_id post-get-second "$first_request_id" "second GET before POST"
echo "OK: GET response is cached"

echo "Sending POST same cached URL..."
http_request post-request "$url" -X POST
assert_cache_state post-request MISS "POST request"
assert_body_field_equals post-request asset app.css "POST request"
assert_different_origin_request_id post-request "$first_request_id" "POST request"
echo "OK: POST bypassed cached GET object and reached origin"
