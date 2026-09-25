#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

url="http://localhost:8084/static/app.css"

echo "Purging any existing cached asset..."
http_request purge-post-asset "$url" -X PURGE
assert_http_status purge-post-asset 200 "POST asset PURGE"

echo "Priming cache with GET (first request, expect MISS)..."
assert_cached_after_warm post-get "$url"
first_request_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

echo "Sending POST same cached URL..."
http_request post-request "$url" -X POST
assert_cache_state post-request MISS "POST request"
assert_body_field_equals post-request asset app.css "POST request"
assert_different_origin_request_id post-request "$first_request_id" "POST request"
assert_header_absent post-request X-Varnish-Cache-Host "POST request"
assert_header_absent post-request X-Varnish-Cache-URL "POST request"
echo "OK: POST bypassed cached GET object and reached origin"

echo "Confirming successful POST invalidates the cached GET object..."
http_request post-get-after-mutation "$url"
assert_cache_state post-get-after-mutation MISS "GET after successful POST"
assert_different_origin_request_id post-get-after-mutation "$first_request_id" "GET after successful POST"
echo "OK: successful POST invalidated the cached GET object"

echo "Sending mutating requests with Cookie to static asset URL..."
for method in POST PUT DELETE PATCH; do
    step_name="mutating-${method}-cookie"
    http_request "$step_name" "$url" -X "$method" -H 'Cookie: client=alice'
    assert_cache_state "$step_name" MISS "${method} request with Cookie"
    assert_body_field_equals "$step_name" asset app.css "${method} request with Cookie"
    assert_body_field_equals "$step_name" cookie present "${method} request with Cookie"
    echo "OK: ${method} to static asset preserved Cookie header at origin"
done

run_rejected_mutation_case() {
    local prefix="$1"
    local method="$2"
    local expected_status="$3"
    local case_url="$4"
    local first_id

    assert_cached_after_warm "${prefix}" "$case_url"
    first_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

    http_request "${prefix}-mutation" "$case_url" -X "$method"
    assert_http_status "${prefix}-mutation" "$expected_status" "rejected ${method} mutation (${expected_status})"
    assert_cache_state "${prefix}-mutation" MISS "rejected ${method} mutation (${expected_status})"
    assert_different_origin_request_id "${prefix}-mutation" "$first_id" "rejected ${method} mutation (${expected_status})"

    http_request "${prefix}-after" "$case_url"
    assert_cache_state "${prefix}-after" HIT "GET after rejected ${method} (${expected_status})"
    assert_same_origin_request_id "${prefix}-after" "$first_id" "GET after rejected ${method} (${expected_status})"
    echo "OK: rejected ${method} mutation (${expected_status}) preserved the cached GET object"
}

case_id="$(openssl rand -hex 4)"

echo "Testing every successful unsafe method on a static-extension URL..."
for method in POST PUT DELETE PATCH; do
    method_slug="$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')"
    assert_mutation_invalidates \
        "static-${method_slug}" \
        "http://localhost:8084/static/app.css?mutation=${case_id}-${method}" \
        "$method"
done

echo "Testing successful mutation on a non-static URL..."
assert_mutation_invalidates \
    dynamic-post \
    "http://localhost:8084/short-cache?mutation=${case_id}-dynamic" \
    POST

echo "Testing rejected 4xx and 5xx mutations preserve the cached object..."
for method in POST PUT DELETE PATCH; do
    method_slug="$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')"
    run_rejected_mutation_case \
        "rejected-4xx-${method_slug}" \
        "$method" \
        409 \
        "http://localhost:8084/mutation-error-4xx?mutation=${case_id}-${method}"
    run_rejected_mutation_case \
        "rejected-5xx-${method_slug}" \
        "$method" \
        500 \
        "http://localhost:8084/mutation-error-5xx?mutation=${case_id}-${method}"
done

echo "Testing invalidation is scoped to the exact URL..."
scope_target_url="http://localhost:8084/short-cache?scope=${case_id}-target"
scope_sibling_url="http://localhost:8084/short-cache?scope=${case_id}-sibling"
assert_cached_after_warm scope-target "$scope_target_url"
scope_target_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
assert_cached_after_warm scope-sibling "$scope_sibling_url"
scope_sibling_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
http_request scope-target-mutation "$scope_target_url" -X POST
assert_cache_state scope-target-mutation MISS "POST target URL"
http_request scope-target-after "$scope_target_url"
assert_cache_state scope-target-after MISS "target URL after POST"
assert_different_origin_request_id scope-target-after "$scope_target_id" "target URL after POST"
http_request scope-sibling-after "$scope_sibling_url"
assert_cache_state scope-sibling-after HIT "sibling URL after target POST"
assert_same_origin_request_id scope-sibling-after "$scope_sibling_id" "sibling URL after target POST"
echo "OK: invalidation did not affect a sibling URL"

echo "Testing invalidation is scoped to the normalized host..."
host_a_url="http://localhost:8084/short-cache?host-scope=${case_id}"
host_b_url="$host_a_url"
assert_cached_after_warm host-a "$host_a_url" -H 'Host: example-a.test:8084'
host_a_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
assert_cached_after_warm host-b "$host_b_url" -H 'Host: example-b.test:8084'
host_b_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
http_request host-a-mutation "$host_a_url" -X POST -H 'Host: example-a.test:8084'
assert_cache_state host-a-mutation MISS "POST host A"
http_request host-a-after "$host_a_url" -H 'Host: example-a.test:8084'
assert_cache_state host-a-after MISS "host A after POST"
assert_different_origin_request_id host-a-after "$host_a_id" "host A after POST"
http_request host-b-after "$host_b_url" -H 'Host: example-b.test:8084'
assert_cache_state host-b-after HIT "host B after host A POST"
assert_same_origin_request_id host-b-after "$host_b_id" "host B after host A POST"
echo "OK: invalidation did not affect the same URL on another host"

echo "Testing uppercase mutation Host invalidates lowercase cached Host..."
normalized_url="http://localhost:8084/short-cache?host-normalization=${case_id}"
assert_cached_after_warm normalized "$normalized_url" -H 'Host: example.com:8084'
normalized_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
http_request normalized-mutation "$normalized_url" -X POST -H 'Host: EXAMPLE.COM:8084'
assert_cache_state normalized-mutation MISS "uppercase Host POST"
http_request normalized-after "$normalized_url" -H 'Host: example.com:8084'
assert_cache_state normalized-after MISS "lowercase Host after uppercase POST"
assert_different_origin_request_id normalized-after "$normalized_id" "lowercase Host after uppercase POST"
echo "OK: Host normalization shared the invalidation identity"

echo "Testing default-port Host normalization shares cache and invalidation identity..."
default_port_url="http://localhost:8084/short-cache?default-port=${case_id}"
http_request default-port-unqualified-first "$default_port_url" -H 'Host: example.com'
assert_cache_state default-port-unqualified-first MISS "unqualified Host first GET"
default_port_first_id="$(assert_origin_request_id_present default-port-unqualified-first "unqualified Host first GET")"
http_request default-port-qualified-second "$default_port_url" -H 'Host: example.com:80'
assert_cache_state default-port-qualified-second HIT "default-port Host second GET"
assert_same_origin_request_id default-port-qualified-second "$default_port_first_id" "default-port Host second GET"

http_request default-port-qualified-mutation "$default_port_url" -X POST -H 'Host: example.com:80'
assert_http_status default-port-qualified-mutation 200 "successful default-port Host POST"
assert_cache_state default-port-qualified-mutation MISS "successful default-port Host POST"
http_request default-port-unqualified-after-qualified "$default_port_url" -H 'Host: example.com'
assert_cache_state default-port-unqualified-after-qualified MISS "GET after default-port Host POST"
assert_different_origin_request_id \
    default-port-unqualified-after-qualified \
    "$default_port_first_id" \
    "GET after default-port Host POST"

http_request default-port-unqualified-mutation "$default_port_url" -X POST -H 'Host: example.com'
assert_http_status default-port-unqualified-mutation 200 "successful unqualified Host POST"
assert_cache_state default-port-unqualified-mutation MISS "successful unqualified Host POST"
http_request default-port-qualified-after-unqualified "$default_port_url" -H 'Host: example.com:80'
assert_cache_state default-port-qualified-after-unqualified MISS "GET after unqualified Host POST"
assert_different_origin_request_id \
    default-port-qualified-after-unqualified \
    "$default_port_first_id" \
    "GET after unqualified Host POST"
echo "OK: default-port Host normalization shared cache and invalidation identity"

echo "Testing all Vary variants for one exact URL are invalidated..."
vary_url="http://localhost:8084/vary-custom?vary=${case_id}"
assert_cached_after_warm vary-plain "$vary_url" -H 'X-Variant: plain'
assert_body_field_equals vary-plain-first variant plain "plain Vary variant first GET"
vary_plain_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

assert_cached_after_warm vary-gzip "$vary_url" -H 'X-Variant: gzip'
assert_body_field_equals vary-gzip-first variant gzip "gzip Vary variant first GET"
vary_gzip_id="$ASSERT_LAST_WARMED_ORIGIN_ID"
http_request vary-mutation "$vary_url" -X POST
assert_cache_state vary-mutation MISS "POST Vary URL"
http_request vary-plain-after "$vary_url" -H 'X-Variant: plain'
assert_cache_state vary-plain-after MISS "plain Vary variant after POST"
assert_different_origin_request_id vary-plain-after "$vary_plain_id" "plain Vary variant after POST"
http_request vary-gzip-after "$vary_url" -H 'X-Variant: gzip'
assert_cache_state vary-gzip-after MISS "gzip Vary variant after POST"
assert_different_origin_request_id vary-gzip-after "$vary_gzip_id" "gzip Vary variant after POST"
echo "OK: exact host+URL invalidation removed all Vary variants"
