#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8086"

# Test Case 1: Standard Vary: * must not be cached (RFC 9111 §4.1)
echo "=== Test 1: Standard Vary: * ==="
url_star="${base_url}/vary-star"
http_request purge-star "$url_star" -X PURGE
assert_http_status purge-star 200 "vary-star PURGE"

echo "Requesting /vary-star (first request)..."
http_request vary-star-1 "$url_star"
assert_http_status vary-star-1 200 "first vary-star request"
assert_cache_state vary-star-1 MISS "first vary-star request"
assert_header_contains vary-star-1 Vary "*" "first vary-star request"
assert_body_field_equals vary-star-1 route vary-star "first vary-star request"
id_star_1="$(assert_origin_request_id_present vary-star-1 "first vary-star request")"
echo "OK: First /vary-star request was MISS from origin (ID: ${id_star_1})"

echo "Requesting /vary-star again immediately (second request)..."
http_request vary-star-2 "$url_star"
assert_http_status vary-star-2 200 "second vary-star request"
assert_cache_state vary-star-2 MISS "second vary-star request"
assert_header_contains vary-star-2 Vary "*" "second vary-star request"
assert_body_field_equals vary-star-2 route vary-star "second vary-star request"
assert_different_origin_request_id vary-star-2 "$id_star_1" "second vary-star request"
echo "OK: Second /vary-star request was MISS with new origin request ID"

echo "Requesting /vary-star with different User-Agent (third request)..."
http_request vary-star-3 "$url_star" -H "User-Agent: AgentTest/1.0"
assert_http_status vary-star-3 200 "third vary-star request"
assert_cache_state vary-star-3 MISS "third vary-star request"
assert_different_origin_request_id vary-star-3 "$id_star_1" "third vary-star request"
echo "OK: Third /vary-star request with custom header was also MISS from origin"

# Test Case 2: Multi-value Vary header with wildcard (e.g. Vary: Accept-Encoding, *)
echo "=== Test 2: Multi-value Vary containing wildcard ==="
url_multi="${base_url}/vary-multi-star"
http_request purge-multi "$url_multi" -X PURGE
assert_http_status purge-multi 200 "vary-multi-star PURGE"

echo "Requesting /vary-multi-star (first request)..."
http_request vary-multi-1 "$url_multi"
assert_http_status vary-multi-1 200 "first vary-multi request"
assert_cache_state vary-multi-1 MISS "first vary-multi request"
id_multi_1="$(assert_origin_request_id_present vary-multi-1 "first vary-multi request")"

echo "Requesting /vary-multi-star again immediately (second request)..."
http_request vary-multi-2 "$url_multi"
assert_http_status vary-multi-2 200 "second vary-multi request"
assert_cache_state vary-multi-2 MISS "second vary-multi request"
assert_different_origin_request_id vary-multi-2 "$id_multi_1" "second vary-multi request"
echo "OK: Multi-value Vary with wildcard was not cached (stayed MISS)"

# Test Case 3: Vary header with whitespace around wildcard (Vary:   *  )
echo "=== Test 3: Vary wildcard with surrounding whitespace ==="
url_ws="${base_url}/vary-star-whitespace"
http_request purge-ws "$url_ws" -X PURGE
assert_http_status purge-ws 200 "vary-star-whitespace PURGE"

echo "Requesting /vary-star-whitespace (first request)..."
http_request vary-ws-1 "$url_ws"
assert_http_status vary-ws-1 200 "first vary-ws request"
assert_cache_state vary-ws-1 MISS "first vary-ws request"
id_ws_1="$(assert_origin_request_id_present vary-ws-1 "first vary-ws request")"

echo "Requesting /vary-star-whitespace again immediately (second request)..."
http_request vary-ws-2 "$url_ws"
assert_http_status vary-ws-2 200 "second vary-ws request"
assert_cache_state vary-ws-2 MISS "second vary-ws request"
assert_different_origin_request_id vary-ws-2 "$id_ws_1" "second vary-ws request"
echo "OK: Vary wildcard with whitespace was not cached (stayed MISS)"

# Test Case 4: Static asset with Vary: * must not be cached despite static URL pattern
echo "=== Test 4: Static asset with Vary: * ==="
url_static="${base_url}/static/vary-star.css"
http_request purge-static "$url_static" -X PURGE
assert_http_status purge-static 200 "static vary-star PURGE"

echo "Requesting /static/vary-star.css (first request)..."
http_request static-star-1 "$url_static"
assert_http_status static-star-1 200 "first static vary-star request"
assert_cache_state static-star-1 MISS "first static vary-star request"
id_static_1="$(assert_origin_request_id_present static-star-1 "first static vary-star request")"

echo "Requesting /static/vary-star.css again immediately (second request)..."
http_request static-star-2 "$url_static"
assert_http_status static-star-2 200 "second static vary-star request"
assert_cache_state static-star-2 MISS "second static vary-star request"
assert_different_origin_request_id static-star-2 "$id_static_1" "second static vary-star request"
echo "OK: Static asset with Vary: * was not cached (stayed MISS)"

# Test Case 5: Normal non-wildcard Vary header (Vary: Accept-Encoding) MUST continue to cache
echo "=== Test 5: Normal non-wildcard Vary (Vary: Accept-Encoding) ==="
url_normal="${base_url}/vary-normal"
http_request purge-normal "$url_normal" -X PURGE
assert_http_status purge-normal 200 "vary-normal PURGE"

echo "Requesting /vary-normal (first request)..."
http_request vary-normal-1 "$url_normal" -H "Accept-Encoding: gzip"
assert_http_status vary-normal-1 200 "first vary-normal request"
assert_cache_state vary-normal-1 MISS "first vary-normal request"
id_normal_1="$(assert_origin_request_id_present vary-normal-1 "first vary-normal request")"

echo "Requesting /vary-normal again with same Accept-Encoding (second request)..."
http_request vary-normal-2 "$url_normal" -H "Accept-Encoding: gzip"
assert_http_status vary-normal-2 200 "second vary-normal request"
assert_cache_state vary-normal-2 HIT "second vary-normal request"
assert_same_origin_request_id vary-normal-2 "$id_normal_1" "second vary-normal request"
echo "OK: Normal Vary: Accept-Encoding correctly cached and served as HIT"

echo "=== ALL VARY: * ASSERTIONS PASSED ==="
