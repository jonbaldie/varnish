#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8090"

# Under RFC 9111 §5.2.2.2, §5.2.2.8, and §5.2.2.10:
# Once a response carrying must-revalidate, proxy-revalidate, or s-maxage
# becomes stale, a cache MUST NOT use the response to satisfy subsequent
# requests without successful validation on the origin server.
# Specifically:
# 1. When origin is healthy, the cache must revalidate synchronously rather
#    than serving stale data from grace (which produces a new backend request ID).
# 2. When origin is unreachable, the cache MUST NOT serve stale data from grace,
#    but instead generate a gateway error (503 Backend fetch failed).

revalidate_urls=(
  "${base_url}/revalidate/must-revalidate"
  "${base_url}/revalidate/proxy-revalidate"
  "${base_url}/revalidate/s-maxage"
  "${base_url}/revalidate/casing-must-revalidate"
  "${base_url}/revalidate/s-maxage-space"
)

echo "=== Phase A: Testing synchronous revalidation while origin is healthy ==="

for url in "${revalidate_urls[@]}"; do
  name="$(basename "$url" | tr '.' '-')"

  echo "1. Priming cache for $name (expects MISS)..."
  http_request prime-"$name" "$url"
  assert_http_status prime-"$name" 200 "prime $name"
  assert_cache_state prime-"$name" MISS "prime $name"
  prime_id="$(assert_origin_request_id_present prime-"$name" "prime $name")"
  echo "OK: $name primed (ID: $prime_id)"

  echo "2. Waiting 2s for TTL (max-age=1s / s-maxage=1s) to expire..."
  sleep 2

  echo "3. Requesting $name again while origin is healthy (must revalidate, not serve stale from grace)..."
  http_request reval-"$name" "$url"
  assert_http_status reval-"$name" 200 "revalidate $name"
  # If beresp.grace > 0, Varnish delivers stale object from grace with same backend request ID
  assert_different_origin_request_id reval-"$name" "$prime_id" "revalidate $name must contact origin, not serve stale from grace"
  echo "OK: $name revalidated with origin (new backend request ID)"
done

echo "=== Phase B: Testing prohibition of stale grace serving when origin is down ==="

# Prime fresh objects for backend-down test
for url in "${revalidate_urls[@]}"; do
  name="down-$(basename "$url" | tr '.' '-')"
  # Use query string to have a freshly primed entry
  prime_url="${url}?phase=down"

  echo "Priming fresh entry for $name..."
  http_request prime-"$name" "$prime_url"
  assert_http_status prime-"$name" 200 "prime $name"
  assert_cache_state prime-"$name" MISS "prime $name"
done

# Prime control entry that DOES have normal grace (no must-revalidate)
echo "Priming control entry with normal grace (/revalidate/normal-grace)..."
http_request prime-normal-grace "${base_url}/revalidate/normal-grace?phase=down"
assert_http_status prime-normal-grace 200 "prime normal grace"
assert_cache_state prime-normal-grace MISS "prime normal grace"
control_id="$(assert_origin_request_id_present prime-normal-grace "prime normal grace")"

echo "Stopping origin backend..."
docker compose stop web

echo "Waiting 2s for TTL expiry..."
sleep 2

echo "Requesting revalidate endpoints with backend down (must fail with 503, NOT serve stale 200)..."
for url in "${revalidate_urls[@]}"; do
  name="down-$(basename "$url" | tr '.' '-')"
  req_url="${url}?phase=down"

  http_request stale-"$name" "$req_url"
  # Under RFC 9111 §5.2.2.2, a stale response with must-revalidate/proxy-revalidate/s-maxage
  # MUST NOT be served if origin cannot be reached. Varnish returns 503 Backend fetch failed.
  assert_http_status stale-"$name" 503 "stale $name with origin down must return 503, not 200"
  echo "OK: $name returned 503 as required"
done

echo "Checking control: normal grace object without revalidate directives IS served stale (200)..."
http_request stale-control "${base_url}/revalidate/normal-grace?phase=down"
assert_http_status stale-control 200 "normal grace control should return 200 from grace"
assert_same_origin_request_id stale-control "$control_id" "normal grace control serves stale cached object"
echo "OK: Control endpoint served 200 from grace when origin is down"

echo "=== All hostile revalidation tests passed ==="
