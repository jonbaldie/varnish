#!/usr/bin/env bash

set -euo pipefail

base_url="http://localhost:8081"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

expect_accept_encoding() {
    local name="$1"
    local input="$2"
    local expected="$3"
    local url="${base_url}/echo-headers?case=${name}"

    printf 'Requesting %s with Accept-Encoding: %q...\n' "$name" "$input"
    http_request "$name" "$url" -H "Accept-Encoding: ${input}"
    assert_http_status "$name" 200 "${name} request"
    assert_cache_state "$name" MISS "${name} request"
    assert_body_field_equals \
        "$name" accept_encoding "$expected" "${name} origin request"
    echo "OK: ${name} reached origin as Accept-Encoding: ${expected}"
}

expect_accept_encoding "q0-no-space" \
    "gzip;q=0, deflate" "deflate"
expect_accept_encoding "q0-after-semicolon" \
    "gzip; q=0, deflate" "deflate"
expect_accept_encoding "q0-before-semicolon" \
    "gzip ;q=0, deflate" "deflate"
expect_accept_encoding "q0-before-semicolon-and-after" \
    "gzip ; q=0, deflate" "deflate"
expect_accept_encoding "q0-tab-after-semicolon" \
    "$(printf 'gzip ;\tq=0, deflate')" "deflate"
expect_accept_encoding "x-gzip-token" "x-gzip" "none"
expect_accept_encoding "x-deflate-token" "x-deflate" "none"
expect_accept_encoding "gzip-title-case" "Gzip" "gzip"
expect_accept_encoding "gzip-upper-case" "GZIP" "gzip"
expect_accept_encoding "deflate-title-case" "Deflate" "deflate"
expect_accept_encoding "deflate-upper-case" "DEFLATE" "deflate"
expect_accept_encoding "gzip-q0-upper-q-deflate" "gzip; Q=0, deflate" "deflate"
expect_accept_encoding "deflate-q0-upper-q" "deflate; Q=0" "none"
expect_accept_encoding "title-gzip-q0-upper-q-deflate" "Gzip; Q=0, Deflate" "deflate"
expect_accept_encoding "gzip-q0-upper-q-decimal" "gzip; Q=0.0, deflate" "deflate"
expect_accept_encoding "gzip-q0-spaces-around-equals" "gzip; q = 0, deflate" "deflate"
expect_accept_encoding "gzip-q0-upper-q-spaces-around-equals" "gzip; Q = 0, deflate" "deflate"
expect_accept_encoding "gzip-q0-only" "gzip; Q=0" "none"
expect_accept_encoding "deflate-q0-decimal" "deflate; Q=0.00" "none"
expect_accept_encoding "both-q0" "gzip; Q=0, deflate; Q=0" "none"
expect_accept_encoding "mixed-case-gzip-deflate" "Gzip, Deflate" "gzip"
expect_accept_encoding "mixed-case-deflate-gzip" "DEFLATE, GZIP" "gzip"
expect_accept_encoding "weird-case-gzip" "gZiP" "gzip"
expect_accept_encoding "weird-case-deflate" "dEfLaTe" "deflate"
expect_accept_encoding "wildcard" "*" "gzip"
expect_accept_encoding "deflate-q0-wildcard" "deflate;q=0, *" "gzip"
expect_accept_encoding "gzip-q0-wildcard" "gzip;q=0, *" "none"
expect_accept_encoding "wildcard-q0" "*;q=0" "none"

echo "=== ACCEPT-ENCODING ASSERTIONS PASSED ==="
