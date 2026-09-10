#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8089"

# Surrogate-Control is a directive aimed at surrogate/CDN caches. It only
# relaxes the Cache-Control handling for the shared cache when it actually
# grants surrogate freshness (max-age). A bare ESI capability advertisement
# (content="ESI/1.0") must NOT disable Cache-Control: private/no-store.

# The exact bug scenario from the issue: the origin marks the response
# private + no-store and also advertises ESI capability. The shared cache
# must still treat it as uncacheable (hit-for-miss).
url_private_esi="${base_url}/private-esi"

http_request purge-private-esi "$url_private_esi" -X PURGE
assert_http_status purge-private-esi 200 "private-esi PURGE"

echo "Requesting /private-esi for the first time (expects MISS from origin)..."
http_request private-esi-1 "$url_private_esi"
assert_http_status private-esi-1 200 "private-esi first request"
assert_cache_state private-esi-1 MISS "private-esi first request"
assert_body_field_equals private-esi-1 route private-esi "private-esi first request"
assert_header_contains private-esi-1 "Cache-Control" "no-store" "private-esi first request"
assert_header_contains private-esi-1 "Surrogate-Control" 'content="ESI/1.0"' "private-esi first request"
first_id="$(assert_origin_request_id_present private-esi-1 "private-esi first request")"
echo "OK: /private-esi first request was MISS (ID: ${first_id})"

echo "Requesting /private-esi again (must not be served from cache)..."
http_request private-esi-2 "$url_private_esi"
assert_http_status private-esi-2 200 "private-esi second request"
assert_cache_state private-esi-2 MISS "private-esi second request"
assert_different_origin_request_id private-esi-2 "$first_id" "private-esi second request"
echo "OK: /private-esi stayed hit-for-miss, origin contacted again"

echo "Requesting /private-esi a third time (hit-for-miss persists)..."
http_request private-esi-3 "$url_private_esi"
assert_http_status private-esi-3 200 "private-esi third request"
assert_cache_state private-esi-3 MISS "private-esi third request"
assert_different_origin_request_id private-esi-3 "$first_id" "private-esi third request"
echo "OK: /private-esi third request also went to origin"

# Control: a genuine Surrogate-Control freshness grant (max-age) overrides
# Cache-Control for the shared cache, so this response IS cacheable.
url_grant="${base_url}/surrogate-fresh"
http_request purge-grant "$url_grant" -X PURGE
assert_http_status purge-grant 200 "surrogate-fresh PURGE"

echo "Requesting /surrogate-fresh for the first time (expects MISS)..."
http_request grant-1 "$url_grant"
assert_http_status grant-1 200 "surrogate-fresh first request"
assert_cache_state grant-1 MISS "surrogate-fresh first request"
grant_id="$(assert_origin_request_id_present grant-1 "surrogate-fresh first request")"

echo "Requesting /surrogate-fresh again (expects HIT)..."
http_request grant-2 "$url_grant"
assert_http_status grant-2 200 "surrogate-fresh second request"
assert_cache_state grant-2 HIT "surrogate-fresh second request"
assert_same_origin_request_id grant-2 "$grant_id" "surrogate-fresh second request"
echo "OK: Surrogate-Control max-age grant still cacheable and served as HIT"

# Control: Surrogate-Control no-store keeps the response uncacheable even
# when Cache-Control grants public freshness.
url_no_store="${base_url}/surrogate-nostore"
http_request purge-no-store "$url_no_store" -X PURGE
assert_http_status purge-no-store 200 "surrogate-nostore PURGE"

echo "Requesting /surrogate-nostore for the first time (expects MISS)..."
http_request no-store-1 "$url_no_store"
assert_http_status no-store-1 200 "surrogate-nostore first request"
assert_cache_state no-store-1 MISS "surrogate-nostore first request"
no_store_id="$(assert_origin_request_id_present no-store-1 "surrogate-nostore first request")"

echo "Requesting /surrogate-nostore again (must not be served from cache)..."
http_request no-store-2 "$url_no_store"
assert_http_status no-store-2 200 "surrogate-nostore second request"
assert_cache_state no-store-2 MISS "surrogate-nostore second request"
assert_different_origin_request_id no-store-2 "$no_store_id" "surrogate-nostore second request"
echo "OK: Surrogate-Control no-store stayed hit-for-miss"

# Control: a zero Surrogate-Control max-age grants the surrogate nothing,
# so Cache-Control: private stays in force despite the origin's own
# max-age=3600.
url_zero="${base_url}/surrogate-zero-maxage"
http_request purge-zero "$url_zero" -X PURGE
assert_http_status purge-zero 200 "surrogate-zero-maxage PURGE"

echo "Requesting /surrogate-zero-maxage for the first time (expects MISS)..."
http_request zero-1 "$url_zero"
assert_http_status zero-1 200 "surrogate-zero-maxage first request"
assert_cache_state zero-1 MISS "surrogate-zero-maxage first request"
zero_id="$(assert_origin_request_id_present zero-1 "surrogate-zero-maxage first request")"

echo "Requesting /surrogate-zero-maxage again (must not be served from cache)..."
http_request zero-2 "$url_zero"
assert_http_status zero-2 200 "surrogate-zero-maxage second request"
assert_cache_state zero-2 MISS "surrogate-zero-maxage second request"
assert_different_origin_request_id zero-2 "$zero_id" "surrogate-zero-maxage second request"
echo "OK: Surrogate-Control max-age=0 stayed hit-for-miss"

echo "=== All hostile Surrogate-Control tests passed ==="