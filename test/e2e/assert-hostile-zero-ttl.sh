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
  "${base_url}/static/expires-garbage.css"
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

# Control: a genuinely fresh static asset is still cached and served as HIT.
url_fresh="${base_url}/static/app.css"
http_request purge-fresh "$url_fresh" -X PURGE
assert_http_status purge-fresh 200 "fresh static PURGE"

echo "Requesting /static/app.css for the first time (expects MISS)..."
http_request fresh-1 "$url_fresh"
assert_http_status fresh-1 200 "fresh static first request"
assert_cache_state fresh-1 MISS "fresh static first request"
fresh_id="$(assert_origin_request_id_present fresh-1 "fresh static first request")"

echo "Requesting /static/app.css again (expects HIT)..."
http_request fresh-2 "$url_fresh"
assert_http_status fresh-2 200 "fresh static second request"
assert_cache_state fresh-2 HIT "fresh static second request"
assert_same_origin_request_id fresh-2 "$fresh_id" "fresh static second request"
echo "OK: Fresh static asset still cached and served as HIT"

# Control: a valid Expires date in the future still grants freshness, so the
# invalid-Expires rule must not swallow well-formed dates.
url_future="${base_url}/static/future-expires.css"
http_request purge-future "$url_future" -X PURGE
assert_http_status purge-future 200 "future-expires PURGE"

echo "Requesting /static/future-expires.css for the first time (expects MISS)..."
http_request future-1 "$url_future"
assert_http_status future-1 200 "future-expires first request"
assert_cache_state future-1 MISS "future-expires first request"
future_id="$(assert_origin_request_id_present future-1 "future-expires first request")"

echo "Requesting /static/future-expires.css again (expects HIT)..."
http_request future-2 "$url_future"
assert_http_status future-2 200 "future-expires second request"
assert_cache_state future-2 HIT "future-expires second request"
assert_same_origin_request_id future-2 "$future_id" "future-expires second request"
echo "OK: Valid future Expires still cached and served as HIT"

echo "=== All hostile zero-TTL tests passed ==="