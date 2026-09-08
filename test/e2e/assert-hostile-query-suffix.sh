#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

# Dynamic URLs whose query VALUE ends in a static extension must not be
# treated as static assets: cookies must reach origin per-client and the
# response must never be shared from cache.
suffix_url="http://localhost:8081/account?q=jquery.js"
download_url="http://localhost:8081/account?file=backup.tar.gz"

echo "Purging any existing cached query-suffix responses..."
http_request purge-suffix "$suffix_url" -X PURGE
assert_http_status purge-suffix 200 "query-suffix PURGE"
http_request purge-download "$download_url" -X PURGE
assert_http_status purge-download 200 "query-suffix download PURGE"

echo "Requesting /account?q=jquery.js as alice (first request)..."
http_request suffix-alice "$suffix_url" -H 'Cookie: client=alice'
assert_cache_state suffix-alice MISS "first query-suffix request"
assert_body_field_equals suffix-alice route account "first query-suffix request"
assert_body_field_equals suffix-alice client alice "first query-suffix request"
alice_request_id="$(assert_origin_request_id_present suffix-alice "first query-suffix request")"
echo "OK: Alice cookie reached origin on query-suffix URL"

echo "Requesting /account?q=jquery.js as bob (second request)..."
http_request suffix-bob "$suffix_url" -H 'Cookie: client=bob'
assert_cache_state suffix-bob MISS "second query-suffix request"
assert_body_field_equals suffix-bob client bob "second query-suffix request"
assert_different_origin_request_id suffix-bob "$alice_request_id" "second query-suffix request"
echo "OK: Bob stayed isolated from alice on query-suffix URL"

echo "Requesting /account?file=backup.tar.gz as alice..."
http_request download-alice "$download_url" -H 'Cookie: client=alice'
assert_cache_state download-alice MISS "first query-suffix download request"
assert_body_field_equals download-alice client alice "first query-suffix download request"
download_request_id="$(assert_origin_request_id_present download-alice "first query-suffix download request")"

echo "Requesting /account?file=backup.tar.gz as bob..."
http_request download-bob "$download_url" -H 'Cookie: client=bob'
assert_cache_state download-bob MISS "second query-suffix download request"
assert_body_field_equals download-bob client bob "second query-suffix download request"
assert_different_origin_request_id download-bob "$download_request_id" "second query-suffix download request"
echo "OK: Bob stayed isolated from alice on download URL"

echo "Control: real static asset with query still strips cookie and caches..."
control_url="http://localhost:8081/static/app.css?v=2"
http_request purge-control "$control_url" -X PURGE
assert_http_status purge-control 200 "static control PURGE"
http_request control-first "$control_url" -H 'Cookie: client=alice'
assert_cache_state control-first MISS "first static control request"
assert_body_field_equals control-first cookie none "first static control request"
control_request_id="$(assert_origin_request_id_present control-first "first static control request")"
http_request control-second "$control_url" -H 'Cookie: client=bob'
assert_cache_state control-second HIT "second static control request"
assert_body_field_equals control-second cookie none "second static control request"
assert_same_origin_request_id control-second "$control_request_id" "second static control request"
echo "OK: Static asset with query parameter still stripped cookie and was cached"