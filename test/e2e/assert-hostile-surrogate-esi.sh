#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:${HOSTILE_SCENARIO_PORT:-8089}"

# Surrogate-Control is a directive aimed at surrogate/CDN caches. It only
# relaxes the Cache-Control handling for the shared cache when it actually
# grants surrogate freshness (max-age). A bare ESI capability advertisement
# (content="ESI/1.0") must NOT disable Cache-Control: private/no-store.

assert_zero_surrogate_freshness_is_uncacheable() {
  local label="$1"
  local path="$2"
  local url="${base_url}${path}"
  local first_id

  http_request "purge-${label}" "$url" -X PURGE
  assert_http_status "purge-${label}" 200 "${label} PURGE"

  http_request "${label}-1" "$url"
  assert_http_status "${label}-1" 200 "${label} first request"
  assert_cache_state "${label}-1" MISS "${label} first request"
  first_id="$(assert_origin_request_id_present "${label}-1" "${label} first request")"

  http_request "${label}-2" "$url"
  assert_http_status "${label}-2" 200 "${label} second request"
  assert_cache_state "${label}-2" MISS "${label} second request"
  assert_different_origin_request_id "${label}-2" "$first_id" "${label} second request"
  echo "OK: ${label} stayed hit-for-miss"
}

# The origin marks the response private + no-store and advertises ESI
# capability. The shared cache must still treat it as uncacheable.
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

assert_surrogate_freshness_extension() {
  local url="${base_url}/surrogate-short-extended"
  local first_id

  http_request purge-extended "$url" -X PURGE
  assert_http_status purge-extended 200 "extended surrogate freshness PURGE"
  http_request extended-1 "$url"
  assert_http_status extended-1 200 "extended surrogate freshness first request"
  assert_cache_state extended-1 MISS "extended surrogate freshness first request"
  first_id="$(assert_origin_request_id_present extended-1 "extended surrogate freshness first request")"

  http_request extended-2 "$url"
  assert_http_status extended-2 200 "extended surrogate freshness within max-age"
  assert_cache_state extended-2 HIT "extended surrogate freshness within max-age"
  assert_same_origin_request_id extended-2 "$first_id" "extended surrogate freshness within max-age"

  sleep 3
  http_request extended-3 "$url"
  assert_http_status extended-3 200 "stale response within freshness extension"
  assert_cache_state extended-3 HIT "stale response within freshness extension"
  assert_same_origin_request_id extended-3 "$first_id" "stale response within freshness extension"

  sleep 5
  http_request extended-4 "$url"
  assert_http_status extended-4 200 "request after freshness extension"
  assert_cache_state extended-4 MISS "request after freshness extension"
  assert_different_origin_request_id extended-4 "$first_id" "request after freshness extension"
  echo "OK: Surrogate-Control freshness extension permits stale delivery only for its duration"
}

assert_positive_surrogate_freshness_expires() {
  local label="$1"
  local path="$2"
  local url="${base_url}${path}"
  local first_id

  http_request "purge-${label}" "$url" -X PURGE
  assert_http_status "purge-${label}" 200 "${label} PURGE"

  http_request "${label}-1" "$url"
  assert_http_status "${label}-1" 200 "${label} first request"
  assert_cache_state "${label}-1" MISS "${label} first request"
  first_id="$(assert_origin_request_id_present "${label}-1" "${label} first request")"

  http_request "${label}-2" "$url"
  assert_http_status "${label}-2" 200 "${label} request within surrogate max-age"
  assert_cache_state "${label}-2" HIT "${label} request within surrogate max-age"
  assert_same_origin_request_id "${label}-2" "$first_id" "${label} request within surrogate max-age"

  echo "Waiting 3s for ${label} Surrogate-Control max-age=2 to expire..."
  sleep 3
  http_request "${label}-3" "$url"
  assert_http_status "${label}-3" 200 "${label} request after surrogate max-age"
  assert_cache_state "${label}-3" MISS "${label} request after surrogate max-age"
  assert_different_origin_request_id "${label}-3" "$first_id" "${label} request after surrogate max-age"
}

# Positive Surrogate-Control freshness sets beresp.ttl even when a private
# Cache-Control policy or a longer downstream max-age would otherwise apply.
assert_positive_surrogate_freshness_expires short-private /surrogate-short-private
assert_positive_surrogate_freshness_expires short-public /surrogate-short-public
assert_positive_surrogate_freshness_expires short-normalized /surrogate-short-normalized
assert_positive_surrogate_freshness_expires short-static /static/surrogate-short.css
assert_surrogate_freshness_extension

echo "OK: positive Surrogate-Control max-age controls the surrogate TTL"

# Positive Surrogate-Control freshness overrides an invalid Expires value.
url_invalid_expires="${base_url}/surrogate-fresh-invalid-expires"
http_request purge-invalid-expires "$url_invalid_expires" -X PURGE
assert_http_status purge-invalid-expires 200 "surrogate-fresh-invalid-expires PURGE"
http_request invalid-expires-1 "$url_invalid_expires"
assert_http_status invalid-expires-1 200 "surrogate-fresh-invalid-expires first request"
assert_cache_state invalid-expires-1 MISS "surrogate-fresh-invalid-expires first request"
invalid_expires_id="$(assert_origin_request_id_present invalid-expires-1 "surrogate-fresh-invalid-expires first request")"
http_request invalid-expires-2 "$url_invalid_expires"
assert_cache_state invalid-expires-2 HIT "surrogate-fresh-invalid-expires second request"
assert_same_origin_request_id invalid-expires-2 "$invalid_expires_id" "surrogate-fresh-invalid-expires second request"

echo "OK: Surrogate-Control max-age overrides invalid Expires"

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

# Zero surrogate freshness must keep objects out of the shared cache even
# when downstream Cache-Control grants freshness or is omitted.
assert_zero_surrogate_freshness_is_uncacheable zero-public /surrogate-zero-maxage
assert_zero_surrogate_freshness_is_uncacheable zero-plain /surrogate-zero-maxage-plain
assert_zero_surrogate_freshness_is_uncacheable zero-no-cache-control /surrogate-zero-maxage-no-cache-control
assert_zero_surrogate_freshness_is_uncacheable zero-plus-zero /surrogate-zero-maxage-plus-zero
assert_zero_surrogate_freshness_is_uncacheable zero-padded /surrogate-zero-maxage-zero-padded
assert_zero_surrogate_freshness_is_uncacheable zero-esi-after /surrogate-zero-maxage-esi-after
assert_zero_surrogate_freshness_is_uncacheable zero-esi-before /surrogate-zero-maxage-esi-before

echo "=== All hostile Surrogate-Control tests passed ==="
