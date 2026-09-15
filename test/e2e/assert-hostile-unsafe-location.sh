#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

base_url="http://localhost:8091"

# Prime the target URL, confirm it is cached, mutate through a second URL
# whose response references the target, then verify the referenced target
# was invalidated (RFC 9111 §4.4).
#
# Arguments:
#   $1 prefix      unique step-name prefix
#   $2 method      unsafe method for the mutating request
#   $3 create_path mutation endpoint path (with query)
#   $4 target_path referenced target path (with query)
#   $5 ref_header  response header carrying the reference (Location or Content-Location)
#   $6 expected_ref expected value of the reference header
#   $7 expected_status status code of the mutating response
run_referenced_invalidation_case() {
    local prefix="$1"
    local method="$2"
    local create_path="$3"
    local target_path="$4"
    local ref_header="$5"
    local expected_ref="$6"
    local expected_status="$7"
    local first_id

    http_request "${prefix}-first" "${base_url}${target_path}"
    assert_http_status "${prefix}-first" 200 "first GET of ${prefix} target"
    assert_cache_state "${prefix}-first" MISS "first GET of ${prefix} target"
    first_id="$(assert_origin_request_id_present "${prefix}-first" "first GET of ${prefix} target")"

    http_request "${prefix}-second" "${base_url}${target_path}"
    assert_http_status "${prefix}-second" 200 "second GET of ${prefix} target"
    assert_cache_state "${prefix}-second" HIT "second GET of ${prefix} target"
    assert_same_origin_request_id "${prefix}-second" "$first_id" "second GET of ${prefix} target"

    http_request "${prefix}-mutation" "${base_url}${create_path}" -X "$method"
    assert_http_status "${prefix}-mutation" "$expected_status" "${method} ${prefix} mutation"
    assert_header_contains "${prefix}-mutation" "$ref_header" "$expected_ref" "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-Host "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-URL "${method} ${prefix} mutation"

    http_request "${prefix}-after" "${base_url}${target_path}"
    assert_http_status "${prefix}-after" 200 "GET ${prefix} target after ${method}"
    assert_cache_state "${prefix}-after" MISS "GET ${prefix} target after ${method}"
    assert_different_origin_request_id "${prefix}-after" "$first_id" "GET ${prefix} target after ${method}"
    echo "OK: successful ${method} invalidated the ${ref_header} referenced URI"
}

case_id="$(openssl rand -hex 4)"

echo "Testing relative Location invalidation for every unsafe method..."
for method in POST PUT DELETE PATCH; do
    method_slug="$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')"
    run_referenced_invalidation_case \
        "rel-${method_slug}" \
        "$method" \
        "/create-rel?case=${case_id}-${method_slug}" \
        "/location-target?case=${case_id}-${method_slug}" \
        "Location" \
        "/location-target?case=${case_id}-${method_slug}" \
        201
done

echo "Testing absolute Location invalidation on POST..."
run_referenced_invalidation_case \
    abs-post \
    POST \
    "/create-abs?case=${case_id}-abs" \
    "/location-target?case=${case_id}-abs" \
    "Location" \
    "http://localhost:8091/location-target?case=${case_id}-abs" \
    201

echo "Testing Content-Location invalidation on PUT..."
run_referenced_invalidation_case \
    content-loc-put \
    PUT \
    "/create-content-location?case=${case_id}-cl" \
    "/content-location-target?case=${case_id}-cl" \
    "Content-Location" \
    "/content-location-target?case=${case_id}-cl" \
    200

echo "Testing cross-host Location does not invalidate same-host cache..."
cross_target="/location-target?case=${case_id}-cross"
http_request cross-first "${base_url}${cross_target}"
assert_http_status cross-first 200 "first GET of cross-host target"
assert_cache_state cross-first MISS "first GET of cross-host target"
cross_id="$(assert_origin_request_id_present cross-first "first GET of cross-host target")"

http_request cross-second "${base_url}${cross_target}"
assert_cache_state cross-second HIT "second GET of cross-host target"
assert_same_origin_request_id cross-second "$cross_id" "second GET of cross-host target"

http_request cross-mutation "${base_url}/create-cross-host?case=${case_id}-cross" -X POST
assert_http_status cross-mutation 201 "cross-host POST mutation"
assert_header_contains \
    cross-mutation \
    Location \
    "http://other.example.test:9999/location-target?case=${case_id}-cross" \
    "cross-host POST mutation"

http_request cross-after "${base_url}${cross_target}"
assert_cache_state cross-after HIT "GET cross-host target after cross-host POST"
assert_same_origin_request_id cross-after "$cross_id" "GET cross-host target after cross-host POST"
echo "OK: cross-host Location did not invalidate the same-host cached object"
