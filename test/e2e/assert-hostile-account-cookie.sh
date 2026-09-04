#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8081/account"

echo "Purging any existing cached account response..."
http_request purge-account "$url" -X PURGE
assert_http_status purge-account 200 "account PURGE"

echo "Requesting /account as alice..."
http_request account-alice "$url" -H 'Cookie: client=alice'
assert_cache_state account-alice MISS "alice account request"
assert_body_field_equals account-alice route account "alice account request"
assert_body_field_equals account-alice client alice "alice account request"
alice_request_id="$(assert_origin_request_id_present account-alice "alice account request")"
echo "OK: Alice response stayed uncached client-specific"

echo "Requesting /account as bob..."
http_request account-bob "$url" -H 'Cookie: client=bob'
assert_cache_state account-bob MISS "bob account request"
assert_body_field_equals account-bob route account "bob account request"
assert_body_field_equals account-bob client bob "bob account request"
assert_different_origin_request_id account-bob "$alice_request_id" "bob account request"
echo "OK: Bob response stayed uncached isolated from alice"

echo "Requesting /private with Cache-Control private and no-store (first request)..."
private_url="http://localhost:8081/private"
http_request private-first "$private_url"
assert_cache_state private-first MISS "first private request"
assert_body_field_equals private-first route private "first private request"
private_request_id="$(assert_origin_request_id_present private-first "first private request")"

echo "Requesting /private (second request)..."
http_request private-second "$private_url"
assert_cache_state private-second MISS "second private request"
assert_body_field_equals private-second route private "second private request"
assert_different_origin_request_id private-second "$private_request_id" "second private request"
echo "OK: Cache-Control private and no-store responses stayed uncached"
