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

    assert_mutation_invalidates \
        "$prefix" \
        "${base_url}${target_path}" \
        "${base_url}${create_path}" \
        "$method"

    assert_http_status "${prefix}-mutation" "$expected_status" "${method} ${prefix} mutation"
    assert_header_contains "${prefix}-mutation" "$ref_header" "$expected_ref" "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-Host "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-URL "${method} ${prefix} mutation"
    echo "OK: successful ${method} invalidated the ${ref_header} referenced URI"
}

run_empty_path_query_invalidation_case() {
    local prefix="$1"
    local method="$2"
    local create_path="$3"
    local ref_header="$4"
    local expected_status="$5"
    local target_path="/?case=${case_id}-${prefix}"
    local cache_host="${prefix}-${case_id}.example.test:8091"
    local root_id
    local target_id
    local expected_ref="http://${cache_host}?case=${case_id}-${prefix}"

    assert_cached_after_warm "${prefix}-root" "${base_url}/" -H "Host: ${cache_host}"
    root_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

    assert_cached_after_warm "${prefix}-target" "${base_url}${target_path}" -H "Host: ${cache_host}"
    target_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

    http_request "${prefix}-mutation" \
        "${base_url}${create_path}?case=${case_id}-${prefix}" \
        -X "$method" \
        -H "Host: ${cache_host}"
    assert_http_status "${prefix}-mutation" "$expected_status" "${method} ${prefix} mutation"
    assert_header_contains "${prefix}-mutation" "$ref_header" "$expected_ref" "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-Host "${method} ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-URL "${method} ${prefix} mutation"

    http_request "${prefix}-root-after" "${base_url}/" \
        -H "Host: ${cache_host}"
    assert_http_status "${prefix}-root-after" 200 "GET root after ${method} ${prefix}"
    assert_cache_state "${prefix}-root-after" HIT "GET root after ${method} ${prefix}"
    assert_same_origin_request_id "${prefix}-root-after" "$root_id" "GET root after ${method} ${prefix}"

    http_request "${prefix}-target-after" "${base_url}${target_path}" \
        -H "Host: ${cache_host}"
    assert_http_status "${prefix}-target-after" 200 "GET ${prefix} target after ${method}"
    assert_cache_state "${prefix}-target-after" MISS "GET ${prefix} target after ${method}"
    assert_different_origin_request_id "${prefix}-target-after" "$target_id" "GET ${prefix} target after ${method}"
    echo "OK: ${method} invalidated ${ref_header} ${target_path} and preserved root"
}

run_variant_port_invalidation_case() {
    local prefix="$1"
    local create_path="$2"
    local variant_host="$3"
    local variant_scheme="$4"
    local case_suffix="$5"
    local target_path="/location-target?case=${case_id}-${case_suffix}"
    local first_id

    assert_cached_after_warm "${prefix}" "${base_url}${target_path}" -H "Host: localhost"
    first_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

    http_request "${prefix}-mutation" \
        "${base_url}/${create_path}?case=${case_id}-${case_suffix}" \
        -X POST -H "Host: localhost"
    assert_http_status "${prefix}-mutation" 201 "POST ${prefix} mutation"
    assert_header_contains \
        "${prefix}-mutation" \
        Location \
        "${variant_scheme}://${variant_host}/location-target?case=${case_id}-${case_suffix}" \
        "POST ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-Host "POST ${prefix} mutation"
    assert_header_absent "${prefix}-mutation" X-Varnish-Cache-Ref-URL "POST ${prefix} mutation"

    http_request "${prefix}-after" "${base_url}${target_path}" -H "Host: localhost"
    assert_http_status "${prefix}-after" 200 "GET ${prefix} target after POST"
    assert_cache_state "${prefix}-after" MISS "GET ${prefix} target after POST"
    assert_different_origin_request_id "${prefix}-after" "$first_id" "GET ${prefix} target after POST"
    echo "OK: ${variant_host} Location invalidated the bare-host target"
}

case_id="$(openssl rand -hex 4)"

echo "Testing absolute empty-path query Location and Content-Location invalidation..."
run_empty_path_query_invalidation_case \
    abs-query-post \
    POST \
    "/create-abs-query" \
    "Location" \
    201
run_empty_path_query_invalidation_case \
    content-loc-abs-query-put \
    PUT \
    "/create-content-location-abs-query" \
    "Content-Location" \
    200

echo "Testing absolute authority-only Location invalidation..."
run_referenced_invalidation_case \
    authority-only-post \
    POST \
    "/create-authority-only?case=${case_id}-authority-only" \
    "/" \
    "Location" \
    "http://localhost:8091" \
    201

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

echo "Testing default-port variant Location invalidation..."
run_variant_port_invalidation_case \
    variant-leading-zero \
    create-abs-default-port \
    "localhost:080" \
    http \
    variant-leading-zero
run_variant_port_invalidation_case \
    variant-empty \
    create-abs-empty-port \
    "localhost:" \
    http \
    variant-empty
run_variant_port_invalidation_case \
    variant-https-leading-zero \
    create-https-default-port \
    "localhost:0443" \
    https \
    variant-https-leading-zero

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
assert_cached_after_warm cross "${base_url}${cross_target}"
cross_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

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

echo "Testing mixed-case Location host invalidation for every unsafe method..."
for method in POST PUT DELETE PATCH; do
    method_slug="$(printf '%s' "$method" | tr '[:upper:]' '[:lower:]')"
    run_referenced_invalidation_case \
        "mixed-${method_slug}" \
        "$method" \
        "/create-abs-mixed-host?case=${case_id}-mixed-${method_slug}" \
        "/location-target?case=${case_id}-mixed-${method_slug}" \
        "Location" \
        "http://LocalHost:8091/location-target?case=${case_id}-mixed-${method_slug}" \
        201
done

echo "Testing uppercase Location host invalidation on POST..."
run_referenced_invalidation_case \
    upper-post \
    POST \
    "/create-abs-upper-host?case=${case_id}-upper" \
    "/location-target?case=${case_id}-upper" \
    "Location" \
    "http://LOCALHOST:8091/location-target?case=${case_id}-upper" \
    201

echo "Testing uppercase Content-Location host invalidation on PUT..."
run_referenced_invalidation_case \
    content-loc-upper-put \
    PUT \
    "/create-content-location-abs-upper-host?case=${case_id}-cl-upper" \
    "/content-location-target?case=${case_id}-cl-upper" \
    "Content-Location" \
    "http://LOCALHOST:8091/content-location-target?case=${case_id}-cl-upper" \
    200

echo "Testing mixed-case Content-Location host invalidation on PUT..."
run_referenced_invalidation_case \
    content-loc-mixed-put \
    PUT \
    "/create-content-location-abs-mixed?case=${case_id}-cl-mixed" \
    "/content-location-target?case=${case_id}-cl-mixed" \
    "Content-Location" \
    "http://LocalHost:8091/content-location-target?case=${case_id}-cl-mixed" \
    200

echo "Testing mixed-case cross-host Location does not invalidate same-host cache..."
cross_mixed_target="/location-target?case=${case_id}-cross-mixed"
assert_cached_after_warm cross-mixed "${base_url}${cross_mixed_target}"
cross_mixed_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

http_request cross-mixed-mutation "${base_url}/create-cross-host-mixed?case=${case_id}-cross-mixed" -X POST
assert_http_status cross-mixed-mutation 201 "mixed-case cross-host POST mutation"
assert_header_contains \
    cross-mixed-mutation \
    Location \
    "http://Other.Example.Test:9999/location-target?case=${case_id}-cross-mixed" \
    "mixed-case cross-host POST mutation"

http_request cross-mixed-after "${base_url}${cross_mixed_target}"
assert_cache_state cross-mixed-after HIT "GET mixed-case cross-host target after mixed-case cross-host POST"
assert_same_origin_request_id cross-mixed-after "$cross_mixed_id" "GET mixed-case cross-host target after mixed-case cross-host POST"
echo "OK: mixed-case cross-host Location did not invalidate the same-host cached object"
