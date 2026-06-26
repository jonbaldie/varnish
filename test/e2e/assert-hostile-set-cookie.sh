#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8081/set-cookie"

echo "Purging any existing cached set-cookie response..."
http_request purge-set-cookie "$url" -X PURGE
assert_http_status purge-set-cookie 200 "set-cookie PURGE"

echo "Requesting /set-cookie as alice..."
http_request set-cookie-alice "$url" -H 'Cookie: client=alice'
assert_cache_state set-cookie-alice MISS "alice set-cookie request"
assert_body_field_equals set-cookie-alice route set-cookie "alice set-cookie request"
assert_body_field_equals set-cookie-alice client alice "alice set-cookie request"
assert_header_contains set-cookie-alice Set-Cookie "session=alice; Path=/" "alice set-cookie request"
alice_request_id="$(assert_origin_request_id_present set-cookie-alice "alice set-cookie request")"
echo "OK: Alice response stayed client-specific with Set-Cookie"

echo "Requesting /set-cookie as bob..."
http_request set-cookie-bob "$url" -H 'Cookie: client=bob'
assert_cache_state set-cookie-bob MISS "bob set-cookie request"
assert_body_field_equals set-cookie-bob route set-cookie "bob set-cookie request"
assert_body_field_equals set-cookie-bob client bob "bob set-cookie request"
assert_header_contains set-cookie-bob Set-Cookie "session=bob; Path=/" "bob set-cookie request"
assert_header_missing_or_not_contains set-cookie-bob Set-Cookie "session=alice; Path=/" "bob set-cookie request"
assert_different_origin_request_id set-cookie-bob "$alice_request_id" "bob set-cookie request"
echo "OK: Bob response stayed uncached and isolated from alice's Set-Cookie response"
