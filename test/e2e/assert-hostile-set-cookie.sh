#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8081/set-cookie"

echo "Purging any existing cached set-cookie response..."
http_request purge-set-cookie "$url" -X PURGE
assert_http_status purge-set-cookie 200 "set-cookie PURGE"

echo "Requesting /set-cookie as alice and bob (assert client isolation)..."
assert_client_isolated set-cookie "$url" 'Cookie: client=alice' 'Cookie: client=bob'
assert_body_field_equals set-cookie-client-a route set-cookie "alice set-cookie request"
assert_body_field_equals set-cookie-client-a client alice "alice set-cookie request"
assert_header_contains set-cookie-client-a Set-Cookie "session=alice; Path=/" "alice set-cookie request"
assert_body_field_equals set-cookie-client-b route set-cookie "bob set-cookie request"
assert_body_field_equals set-cookie-client-b client bob "bob set-cookie request"
assert_header_contains set-cookie-client-b Set-Cookie "session=bob; Path=/" "bob set-cookie request"
assert_header_missing_or_not_contains set-cookie-client-b Set-Cookie "session=alice; Path=/" "bob set-cookie request"
echo "OK: Bob response stayed uncached and isolated from alice's Set-Cookie response"

echo "Requesting /set-cookie as first unauthenticated visitor..."
http_request set-cookie-anon1 "$url"
assert_cache_state set-cookie-anon1 MISS "anon 1 set-cookie request"
anon1_request_id="$(assert_origin_request_id_present set-cookie-anon1 "anon 1 set-cookie request")"

echo "Requesting /set-cookie as second unauthenticated visitor..."
http_request set-cookie-anon2 "$url"
assert_cache_state set-cookie-anon2 MISS "anon 2 set-cookie request"
assert_different_origin_request_id set-cookie-anon2 "$anon1_request_id" "anon 2 set-cookie request"
echo "OK: Unauthenticated requests with origin Set-Cookie stayed uncached"
