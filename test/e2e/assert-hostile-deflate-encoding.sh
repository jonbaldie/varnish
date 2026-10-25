#!/usr/bin/env bash

set -euo pipefail

base_url="http://localhost:8081"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

plain="article-plain-text"

body_kind() {
    local name="$1"
    python3 - "$plain" "$(response_body_path "$name")" <<'PY'
import gzip
import sys
import zlib

plain, path = sys.argv[1:]
body = open(path, "rb").read()
try:
    decoded = gzip.decompress(body)
    kind = "gzip" if decoded == plain.encode() else "gzip-other"
except Exception:
    try:
        decoded = zlib.decompress(body)
        kind = "deflate" if decoded == plain.encode() else "deflate-other"
    except Exception:
        kind = "plain" if body == plain.encode() else "unknown"
print(kind)
PY
}

assert_body_kind() {
    local name="$1"
    local expected="$2"
    local context="$3"
    local actual
    actual="$(body_kind "$name")"
    if [ "$actual" != "$expected" ]; then
        fail_response_assertion \
            "expected ${context} body ${expected}, got ${actual}" \
            "$name"
    fi
}

assert_body_kind_one_of() {
    local name="$1"
    local context="$2"
    shift 2
    local actual
    local expected
    actual="$(body_kind "$name")"
    for expected in "$@"; do
        if [ "$actual" = "$expected" ]; then
            return 0
        fi
    done
    fail_response_assertion \
        "expected ${context} body one of $*, got ${actual}" \
        "$name"
}

echo "=== Gzip object still gunzips for an identity client ==="
gzip_url="${base_url}/encoding-article?case=gzip-control"
http_request gzip-control "$gzip_url" -H "Accept-Encoding: gzip"
assert_http_status gzip-control 200 "gzip control"
assert_cache_state gzip-control MISS "gzip control"
assert_header_contains gzip-control Content-Encoding gzip "gzip control"
assert_body_kind gzip-control gzip "gzip control"
gzip_control_id="$(assert_origin_request_id_present gzip-control "gzip control")"

http_request identity-control "$gzip_url" -H "Accept-Encoding: identity"
assert_http_status identity-control 200 "identity client of a gzip object"
assert_cache_state identity-control HIT "identity client of a gzip object"
assert_header_absent identity-control Content-Encoding "identity client of a gzip object"
assert_body_kind identity-control plain "identity client of a gzip object"
assert_same_origin_request_id identity-control "$gzip_control_id" "identity client of a gzip object"
echo "OK: identity client received plain text from the gzip object"

echo "=== Deflate object is not reused for a different Accept-Encoding ==="
url="${base_url}/encoding-article"
http_request deflate "$url" -H "Accept-Encoding: deflate"
assert_http_status deflate 200 "deflate client"
assert_cache_state deflate MISS "deflate client"
assert_header_contains deflate Content-Encoding deflate "deflate client"
assert_header_contains deflate X-Origin-AE deflate "deflate client"
assert_body_kind deflate deflate "deflate client"
deflate_id="$(assert_origin_request_id_present deflate "deflate client")"
echo "OK: deflate client stored a deflate object (${deflate_id})"

http_request gzip-after "$url" -H "Accept-Encoding: gzip"
assert_http_status gzip-after 200 "gzip client after deflate"
assert_cache_state gzip-after MISS "gzip client after deflate"
assert_header_missing_or_not_contains gzip-after Content-Encoding deflate "gzip client after deflate"
assert_header_missing_or_not_contains gzip-after X-Origin-AE deflate "gzip client after deflate"
assert_body_kind_one_of gzip-after "gzip client after deflate" gzip plain
assert_different_origin_request_id gzip-after "$deflate_id" "gzip client after deflate"
echo "OK: gzip client did not receive the deflate object"

http_request identity-after "$url" -H "Accept-Encoding: identity"
assert_http_status identity-after 200 "identity client after deflate"
assert_header_absent identity-after Content-Encoding "identity client after deflate"
assert_body_kind identity-after plain "identity client after deflate"
assert_different_origin_request_id identity-after "$deflate_id" "identity client after deflate"
echo "OK: identity client did not receive the deflate object"

http_request browser-after "$url" -H "Accept-Encoding: gzip, deflate, br"
assert_http_status browser-after 200 "browser client after deflate"
assert_header_missing_or_not_contains browser-after Content-Encoding deflate "browser client after deflate"
assert_body_kind_one_of browser-after "browser client after deflate" gzip plain
assert_different_origin_request_id browser-after "$deflate_id" "browser client after deflate"
echo "OK: browser client did not receive the deflate object"

http_request deflate-again "$url" -H "Accept-Encoding: deflate"
assert_http_status deflate-again 200 "second deflate client"
assert_cache_state deflate-again HIT "second deflate client"
assert_header_contains deflate-again Content-Encoding deflate "second deflate client"
assert_body_kind deflate-again deflate "second deflate client"
assert_same_origin_request_id deflate-again "$deflate_id" "second deflate client"
echo "OK: a later deflate client reused the deflate object"

echo "=== PURGE invalidates both encoding objects ==="
gzip_id="$(assert_origin_request_id_present gzip-after "gzip before PURGE")"
http_request other-host "$url" -H "Host: other.example" -H "Accept-Encoding: deflate"
other_host_id="$(assert_origin_request_id_present other-host "other host")"
http_request purge "$url" -X PURGE
assert_http_status purge 200 "PURGE"
http_request deflate-purged "$url" -H "Accept-Encoding: deflate"
assert_http_status deflate-purged 200 "deflate after PURGE"
assert_cache_state deflate-purged MISS "deflate after PURGE"
assert_different_origin_request_id deflate-purged "$deflate_id" "deflate after PURGE"
http_request gzip-purged "$url" -H "Accept-Encoding: gzip"
assert_http_status gzip-purged 200 "gzip after PURGE"
assert_cache_state gzip-purged MISS "gzip after PURGE"
assert_different_origin_request_id gzip-purged "$gzip_id" "gzip after PURGE"
http_request identity-purged "$url" -H "Accept-Encoding: identity"
assert_http_status identity-purged 200 "identity after PURGE"
assert_different_origin_request_id identity-purged "$deflate_id" "identity after PURGE"

# A PURGE carrying Accept-Encoding must still invalidate every encoding.
deflate_id="$(assert_origin_request_id_present deflate-purged "deflate before second PURGE")"
gzip_id="$(assert_origin_request_id_present gzip-purged "gzip before second PURGE")"
http_request purge-deflate "$url" -X PURGE -H "Accept-Encoding: deflate"
assert_http_status purge-deflate 200 "PURGE with deflate"
for encoding in deflate gzip; do
    http_request "${encoding}-purged-again" "$url" -H "Accept-Encoding: $encoding"
    assert_cache_state "${encoding}-purged-again" MISS "$encoding after second PURGE"
done
assert_different_origin_request_id deflate-purged-again "$deflate_id" "deflate after second PURGE"
assert_different_origin_request_id gzip-purged-again "$gzip_id" "gzip after second PURGE"

http_request other-host-after "$url" -H "Host: other.example" -H "Accept-Encoding: deflate"
assert_cache_state other-host-after HIT "other host after PURGE"
assert_same_origin_request_id other-host-after "$other_host_id" "other host after PURGE"
http_request other-url-after "$gzip_url" -H "Accept-Encoding: gzip"
assert_cache_state other-url-after HIT "other URL after PURGE"
assert_same_origin_request_id other-url-after "$gzip_control_id" "other URL after PURGE"
assert_no_vcl_errors "encoding PURGE"
echo "=== DEFLATE ENCODING ASSERTIONS PASSED ==="
