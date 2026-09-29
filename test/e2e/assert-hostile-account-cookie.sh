#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8081/account"

echo "Purging any existing cached account response..."
http_request purge-account "$url" -X PURGE
assert_http_status purge-account 200 "account PURGE"

echo "Requesting /account as alice and bob (assert client isolation)..."
assert_client_isolated account "$url" 'Cookie: client=alice' 'Cookie: client=bob'
assert_body_field_equals account-client-a route account "alice account request"
assert_body_field_equals account-client-a client alice "alice account request"
assert_body_field_equals account-client-b route account "bob account request"
assert_body_field_equals account-client-b client bob "bob account request"

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
