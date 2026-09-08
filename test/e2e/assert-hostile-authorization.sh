#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8087"
url_auth="${base_url}/auth"

# Test Case 1: Alice requests /auth with Authorization header
echo "=== Test 1: Authenticated request (Alice) ==="
http_request purge-auth "$url_auth" -X PURGE
assert_http_status purge-auth 200 "auth PURGE"

echo "Requesting /auth as alice with Authorization header..."
http_request auth-alice-1 "$url_auth" -H "Authorization: Bearer alice-secret-token"
assert_http_status auth-alice-1 200 "alice first auth request"
assert_cache_state auth-alice-1 MISS "alice first auth request"
assert_body_field_equals auth-alice-1 route auth "alice first auth request"
assert_body_field_equals auth-alice-1 client alice-secret-token "alice first auth request"
alice_id_1="$(assert_origin_request_id_present auth-alice-1 "alice first auth request")"
echo "OK: Alice response was MISS from origin (ID: ${alice_id_1})"

# Test Case 2: Bob requests /auth with different Authorization header
# With the bug, Varnish cached Alice's response and serves it as HIT to Bob, leaking Alice's data!
echo "=== Test 2: Authenticated request (Bob) must not receive Alice's cached response ==="
echo "Requesting /auth as bob with different Authorization header..."
http_request auth-bob "$url_auth" -H "Authorization: Bearer bob-secret-token"
assert_http_status auth-bob 200 "bob auth request"
assert_cache_state auth-bob MISS "bob auth request"
assert_body_field_equals auth-bob route auth "bob auth request"
assert_body_field_equals auth-bob client bob-secret-token "bob auth request"
assert_different_origin_request_id auth-bob "$alice_id_1" "bob auth request"
bob_id="$(assert_origin_request_id_present auth-bob "bob auth request")"
echo "OK: Bob response stayed uncached and isolated from Alice (ID: ${bob_id})"

# Test Case 3: Anonymous user requests /auth without Authorization header
# With the bug, anonymous user receives Alice's cached response!
echo "=== Test 3: Anonymous request must not receive cached authenticated response ==="
echo "Requesting /auth as anonymous user..."
http_request auth-anon-1 "$url_auth"
assert_http_status auth-anon-1 200 "anonymous first auth request"
assert_cache_state auth-anon-1 MISS "anonymous first auth request"
assert_body_field_equals auth-anon-1 route auth "anonymous first auth request"
assert_body_field_equals auth-anon-1 client anonymous "anonymous first auth request"
assert_different_origin_request_id auth-anon-1 "$alice_id_1" "anonymous first auth request"
assert_different_origin_request_id auth-anon-1 "$bob_id" "anonymous first auth request"
anon_id_1="$(assert_origin_request_id_present auth-anon-1 "anonymous first auth request")"
echo "OK: Anonymous response was fresh from origin (ID: ${anon_id_1})"

# Test Case 4: Anonymous request can be cached if unauthenticated
echo "=== Test 4: Subsequent unauthenticated request can be served from cache ==="
echo "Requesting /auth again as anonymous user..."
http_request auth-anon-2 "$url_auth"
assert_http_status auth-anon-2 200 "anonymous second auth request"
assert_cache_state auth-anon-2 HIT "anonymous second auth request"
assert_body_field_equals auth-anon-2 route auth "anonymous second auth request"
assert_body_field_equals auth-anon-2 client anonymous "anonymous second auth request"
assert_same_origin_request_id auth-anon-2 "$anon_id_1" "anonymous second auth request"
echo "OK: Subsequent anonymous request served as HIT"

# Test Case 5: Authenticated request must bypass cache even when an unauthenticated response is cached
echo "=== Test 5: Authenticated request bypasses cache when unauthenticated response is cached ==="
echo "Requesting /auth as alice with Authorization header while anonymous response is cached..."
http_request auth-alice-2 "$url_auth" -H "Authorization: Bearer alice-secret-token"
assert_http_status auth-alice-2 200 "alice second auth request"
assert_cache_state auth-alice-2 MISS "alice second auth request"
assert_body_field_equals auth-alice-2 route auth "alice second auth request"
assert_body_field_equals auth-alice-2 client alice-secret-token "alice second auth request"
assert_different_origin_request_id auth-alice-2 "$anon_id_1" "alice second auth request"
echo "OK: Authenticated request bypassed cached anonymous response"

# Test Case 6: HEAD request with Authorization header must bypass cache
echo "=== Test 6: HEAD request with Authorization header ==="
echo "Sending HEAD /auth with Authorization header..."
http_request auth-alice-head "$url_auth" -I -H "Authorization: Bearer alice-secret-token"
assert_http_status auth-alice-head 200 "alice HEAD auth request"
assert_cache_state auth-alice-head MISS "alice HEAD auth request"
assert_origin_request_id_present auth-alice-head "alice HEAD auth request" >/dev/null
echo "OK: HEAD request with Authorization bypassed cache"

# Test Case 7: Basic authentication with Authorization header must bypass cache
echo "=== Test 7: Basic authentication request ==="
echo "Requesting /auth with Authorization: Basic header..."
http_request auth-basic "$url_auth" -H "Authorization: Basic YWxpY2U6c2VjcmV0"
assert_http_status auth-basic 200 "basic auth request"
assert_cache_state auth-basic MISS "basic auth request"
assert_body_field_equals auth-basic route auth "basic auth request"
assert_body_field_equals auth-basic client YWxpY2U6c2VjcmV0 "basic auth request"
assert_different_origin_request_id auth-basic "$anon_id_1" "basic auth request"
echo "OK: Basic authentication request bypassed cache"

# Test Case 8: Static asset with Authorization header must not be cached or shared
echo "=== Test 8: Static asset with Authorization header ==="
url_static_auth="${base_url}/static/auth.css"
http_request purge-static-auth "$url_static_auth" -X PURGE
assert_http_status purge-static-auth 200 "static auth PURGE"

echo "Requesting /static/auth.css as alice with Authorization header..."
http_request static-auth-alice "$url_static_auth" -H "Authorization: Bearer alice-secret-token"
assert_http_status static-auth-alice 200 "static auth alice request"
assert_cache_state static-auth-alice MISS "static auth alice request"
assert_body_field_equals static-auth-alice asset auth.css "static auth alice request"
assert_body_field_equals static-auth-alice client alice-secret-token "static auth alice request"
static_alice_id="$(assert_origin_request_id_present static-auth-alice "static auth alice request")"

echo "Requesting /static/auth.css as bob with Authorization header..."
http_request static-auth-bob "$url_static_auth" -H "Authorization: Bearer bob-secret-token"
assert_http_status static-auth-bob 200 "static auth bob request"
assert_cache_state static-auth-bob MISS "static auth bob request"
assert_body_field_equals static-auth-bob asset auth.css "static auth bob request"
assert_body_field_equals static-auth-bob client bob-secret-token "static auth bob request"
assert_different_origin_request_id static-auth-bob "$static_alice_id" "static auth bob request"
echo "OK: Static asset with Authorization header was not cached"

echo "=== All hostile Authorization tests passed ==="
