#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8088"

# Static assets whose origin grants zero freshness (max-age=0, s-maxage=0, or
# an Expires date in the past) are storable but never fresh. The shared cache
# policy must not overwrite the origin's zero TTL with a static-extension TTL,
# so every repeat request must be served as hit-for-miss (MISS) with a fresh
# origin request id.

zero_freshness_urls=(
  "${base_url}/static/zero-maxage.css"
  "${base_url}/static/zero-smaxage.css"
  "${base_url}/static/past-expires.css"
  "${base_url}/static/expires-zero.css"
  "${base_url}/static/expires-minus-one.css"
  "${base_url}/static/expires-invalid.css"
)

for url in "${zero_freshness_urls[@]}"; do
  asset="$(basename "$url")"

  http_request purge-"$asset" "$url" -X PURGE
  assert_http_status purge-"$asset" 200 "$asset PURGE"

  echo "Requesting $asset for the first time (expects MISS from origin)..."
  http_request "$asset"-1 "$url"
  assert_http_status "$asset"-1 200 "$asset first request"
  assert_cache_state "$asset"-1 MISS "$asset first request"
  assert_body_field_equals "$asset"-1 asset "$asset" "$asset first request"
  first_id="$(assert_origin_request_id_present "$asset"-1 "$asset first request")"
  echo "OK: $asset first request was MISS (ID: ${first_id})"

  echo "Requesting $asset again (must not be a fresh HIT)..."
  http_request "$asset"-2 "$url"
  assert_http_status "$asset"-2 200 "$asset second request"
  assert_cache_state "$asset"-2 MISS "$asset second request"
  assert_different_origin_request_id "$asset"-2 "$first_id" "$asset second request"
  echo "OK: $asset stayed hit-for-miss, origin contacted again"

  echo "Requesting $asset a third time (hit-for-miss persists)..."
  http_request "$asset"-3 "$url"
  assert_http_status "$asset"-3 200 "$asset third request"
  assert_cache_state "$asset"-3 MISS "$asset third request"
  assert_different_origin_request_id "$asset"-3 "$first_id" "$asset third request"
  echo "OK: $asset third request also went to origin"
done

# Controls: static assets that genuinely are fresh must still be cached. Each
# exercises a freshness form the invalid-Expires rule must not swallow.
fresh_urls=(
  "${base_url}/static/app.css"
  "${base_url}/static/future-expires.css"
  "${base_url}/static/maxage-over-invalid-expires.css"
)

for url in "${fresh_urls[@]}"; do
  asset="$(basename "$url")"

  http_request purge-fresh-"$asset" "$url" -X PURGE
  assert_http_status purge-fresh-"$asset" 200 "$asset PURGE"

  echo "Requesting $asset for the first time (expects MISS)..."
  http_request fresh-"$asset"-1 "$url"
  assert_http_status fresh-"$asset"-1 200 "$asset fresh first request"
  assert_cache_state fresh-"$asset"-1 MISS "$asset fresh first request"
  cached_id="$(assert_origin_request_id_present fresh-"$asset"-1 "$asset fresh first request")"

  echo "Requesting $asset again (expects HIT)..."
  http_request fresh-"$asset"-2 "$url"
  assert_http_status fresh-"$asset"-2 200 "$asset fresh second request"
  assert_cache_state fresh-"$asset"-2 HIT "$asset fresh second request"
  assert_same_origin_request_id fresh-"$asset"-2 "$cached_id" "$asset fresh second request"
  echo "OK: $asset still cached and served as HIT"
done

# Invalid Expires on a non-static URL. RFC 9111 §5.3 requires an unparseable
# date, especially "0", to be read as already expired, so an HTML page carrying
# one must stay hit-for-miss instead of inheriting default_ttl.

invalid_expires_pages=(
  "${base_url}/page/expires-zero"
  "${base_url}/page/expires-minus-one"
  "${base_url}/page/expires-invalid"
)

for url in "${invalid_expires_pages[@]}"; do
  page="$(basename "$url")"

  http_request purge-page-"$page" "$url" -X PURGE
  assert_http_status purge-page-"$page" 200 "$page PURGE"

  echo "Requesting page $page for the first time (expects MISS from origin)..."
  http_request page-"$page"-1 "$url"
  assert_http_status page-"$page"-1 200 "$page first request"
  assert_cache_state page-"$page"-1 MISS "$page first request"
  assert_body_field_equals page-"$page"-1 page "$page" "$page first request"
  first_id="$(assert_origin_request_id_present page-"$page"-1 "$page first request")"
  echo "OK: $page first request was MISS (ID: ${first_id})"

  echo "Requesting page $page again (must not be a fresh HIT)..."
  http_request page-"$page"-2 "$url"
  assert_http_status page-"$page"-2 200 "$page second request"
  assert_cache_state page-"$page"-2 MISS "$page second request"
  assert_different_origin_request_id page-"$page"-2 "$first_id" "$page second request"
  echo "OK: $page stayed hit-for-miss, origin contacted again"

  echo "Requesting page $page a third time (hit-for-miss persists)..."
  http_request page-"$page"-3 "$url"
  assert_http_status page-"$page"-3 200 "$page third request"
  assert_cache_state page-"$page"-3 MISS "$page third request"
  assert_different_origin_request_id page-"$page"-3 "$first_id" "$page third request"
  echo "OK: $page third request also went to origin"
done

# Controls: non-static pages that genuinely are fresh must still be cached.
fresh_pages=(
  "${base_url}/page/future-expires"
  "${base_url}/page/maxage-over-invalid-expires"
)

for url in "${fresh_pages[@]}"; do
  page="$(basename "$url")"

  http_request purge-fresh-page-"$page" "$url" -X PURGE
  assert_http_status purge-fresh-page-"$page" 200 "$page PURGE"

  echo "Requesting page $page for the first time (expects MISS)..."
  http_request fresh-page-"$page"-1 "$url"
  assert_http_status fresh-page-"$page"-1 200 "$page fresh first request"
  assert_cache_state fresh-page-"$page"-1 MISS "$page fresh first request"
  cached_id="$(assert_origin_request_id_present fresh-page-"$page"-1 "$page fresh first request")"

  echo "Requesting page $page again (expects HIT)..."
  http_request fresh-page-"$page"-2 "$url"
  assert_http_status fresh-page-"$page"-2 200 "$page fresh second request"
  assert_cache_state fresh-page-"$page"-2 HIT "$page fresh second request"
  assert_same_origin_request_id fresh-page-"$page"-2 "$cached_id" "$page fresh second request"
  echo "OK: $page still cached and served as HIT"
done

echo "=== All hostile zero-TTL tests passed ==="