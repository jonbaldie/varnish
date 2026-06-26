#!/usr/bin/env bash

response_headers_path() {
    printf '%s/%s.headers\n' "${TEST_TMPDIR:?TEST_TMPDIR must be set}" "$1"
}

response_body_path() {
    printf '%s/%s.body\n' "${TEST_TMPDIR:?TEST_TMPDIR must be set}" "$1"
}

response_status_code() {
    local name="$1"
    sed -n '1s/.* \([0-9][0-9][0-9]\).*/\1/p' "$(response_headers_path "$name")"
}

response_header_value() {
    local name="$1"
    local header_name="$2"
    local header_file
    header_file="$(response_headers_path "$name")"

    grep -i "^${header_name}:" "$header_file" \
        | tail -n 1 \
        | tr -d '\r' \
        | sed 's/^[^:]*:[[:space:]]*//'
}

response_body_field_value() {
    local name="$1"
    local field_name="$2"
    local body_file
    body_file="$(response_body_path "$name")"

    grep "^${field_name}=" "$body_file" \
        | tail -n 1 \
        | cut -d= -f2-
}

dump_response() {
    local name="$1"
    local headers_file
    local body_file
    headers_file="$(response_headers_path "$name")"
    body_file="$(response_body_path "$name")"

    echo "--- ${name} headers ---"
    cat "$headers_file"
    echo "--- ${name} body ---"
    cat "$body_file"
}

fail_response_assertion() {
    local message="$1"
    local name="$2"

    echo "FAIL: ${message}"
    dump_response "$name"
    exit 1
}

http_request() {
    local name="$1"
    local url="$2"
    shift 2

    curl -sS --max-time 10 \
        -D "$(response_headers_path "$name")" \
        -o "$(response_body_path "$name")" \
        "$@" \
        "$url"
}

assert_http_status() {
    local name="$1"
    local expected_status="$2"
    local context="$3"
    local actual_status
    actual_status="$(response_status_code "$name")"

    if [ "$actual_status" != "$expected_status" ]; then
        fail_response_assertion \
            "expected ${context} HTTP ${expected_status}, got ${actual_status:-missing}" \
            "$name"
    fi
}

assert_cache_state() {
    local name="$1"
    local expected_state="$2"
    local context="$3"
    local actual_state
    actual_state="$(response_header_value "$name" "X-Cache" || true)"

    if [[ "$actual_state" != *"$expected_state"* ]]; then
        fail_response_assertion \
            "expected ${context} cache ${expected_state,,}, got '${actual_state:-missing}'" \
            "$name"
    fi
}

assert_header_contains() {
    local name="$1"
    local header_name="$2"
    local expected_fragment="$3"
    local context="$4"
    local actual_value
    actual_value="$(response_header_value "$name" "$header_name" || true)"

    if [[ "$actual_value" != *"$expected_fragment"* ]]; then
        fail_response_assertion \
            "expected ${context} header ${header_name} contain '${expected_fragment}', got '${actual_value:-missing}'" \
            "$name"
    fi
}

assert_body_field_equals() {
    local name="$1"
    local field_name="$2"
    local expected_value="$3"
    local context="$4"
    local actual_value
    actual_value="$(response_body_field_value "$name" "$field_name" || true)"

    if [ "$actual_value" != "$expected_value" ]; then
        fail_response_assertion \
            "expected ${context} body field ${field_name}=${expected_value}, got '${actual_value:-missing}'" \
            "$name"
    fi
}

assert_origin_request_id_present() {
    local name="$1"
    local context="$2"
    local request_id
    request_id="$(response_header_value "$name" "X-Backend-Request-Id" || true)"

    if [ -z "$request_id" ]; then
        fail_response_assertion \
            "expected ${context} include origin request id header X-Backend-Request-Id" \
            "$name"
    fi

    printf '%s\n' "$request_id"
}

assert_same_origin_request_id() {
    local name="$1"
    local expected_request_id="$2"
    local context="$3"
    local actual_request_id
    actual_request_id="$(assert_origin_request_id_present "$name" "$context")"

    if [ "$actual_request_id" != "$expected_request_id" ]; then
        fail_response_assertion \
            "expected ${context} reuse origin request id ${expected_request_id}, got ${actual_request_id}" \
            "$name"
    fi
}
