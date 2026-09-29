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

    if [ "$#" -eq 2 ] && [ "$1" = "-X" ] && [ "$2" = "PURGE" ]; then
        local varnish_container
        local host_header
        local loopback_url

        varnish_container="$(
            docker ps \
                --filter "label=com.docker.compose.project=${TEST_PROJECT:?TEST_PROJECT must be set}" \
                --format '{{.ID}} {{.Label "com.docker.compose.service"}}' \
                | awk '$2 ~ /^varnish/ { print $1; exit }'
        )"

        if [ -z "$varnish_container" ]; then
            echo "FAIL: Could not find Varnish container for project $TEST_PROJECT"
            exit 1
        fi

        host_header="$(printf '%s\n' "$url" | sed -E 's#^https?://([^/]+).*#\1#')"
        loopback_url="$(printf '%s\n' "$url" | sed -E 's#^https?://[^/]+#http://127.0.0.1#')"

        docker run --rm \
            --network "container:$varnish_container" \
            --volume "${TEST_TMPDIR:?TEST_TMPDIR must be set}:/test-tmp" \
            python:3.13-alpine \
            python -c '
import http.client
import sys
from urllib.parse import urlsplit

name, url, host_header = sys.argv[1:]
target = urlsplit(url)
path = target.path or "/"
if target.query:
    path += "?" + target.query

connection = http.client.HTTPConnection(target.hostname, target.port, timeout=10)
connection.request("PURGE", path, headers={"Host": host_header})
response = connection.getresponse()

with open(f"/test-tmp/{name}.headers", "w", encoding="utf-8") as headers_file:
    headers_file.write(f"HTTP/1.1 {response.status} {response.reason}" + chr(13) + chr(10))
    for header, value in response.getheaders():
        headers_file.write(f"{header}: {value}" + chr(13) + chr(10))
    headers_file.write(chr(13) + chr(10))

with open(f"/test-tmp/{name}.body", "wb") as body_file:
    body_file.write(response.read())

connection.close()
' "$name" "$loopback_url" "$host_header"
        return
    fi

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
        local lower_expected
        lower_expected="$(printf '%s' "$expected_state" | tr '[:upper:]' '[:lower:]')"
        fail_response_assertion \
            "expected ${context} cache ${lower_expected}, got '${actual_state:-missing}'" \
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

assert_header_absent() {
    local name="$1"
    local header_name="$2"
    local context="$3"
    local actual_value

    actual_value="$(response_header_value "$name" "$header_name" || true)"

    if [ -n "$actual_value" ]; then
        fail_response_assertion \
            "expected ${context} not expose header ${header_name}, got '${actual_value}'" \
            "$name"
    fi
}

assert_header_missing_or_not_contains() {
  local name="$1"
  local header_name="$2"
  local unexpected_fragment="$3"
  local context="$4"
  local actual_value

  actual_value="$(response_header_value "$name" "$header_name" || true)"

  if [[ "$actual_value" == *"$unexpected_fragment"* ]]; then
    fail_response_assertion \
      "expected ${context} header ${header_name} not contain '${unexpected_fragment}', got '${actual_value}'" \
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

assert_different_origin_request_id() {
  local name="$1"
  local previous_request_id="$2"
  local context="$3"
  local actual_request_id

  actual_request_id="$(assert_origin_request_id_present "$name" "$context")"

  if [ "$actual_request_id" = "$previous_request_id" ]; then
    fail_response_assertion \
      "expected ${context} hit origin with a new request id, got reused id ${actual_request_id}" \
      "$name"
  fi
}

_request_with_header_spec() {
    local name="$1"
    local url="$2"
    local header_spec="$3"

    if [ -z "$header_spec" ]; then
        http_request "$name" "$url"
        return
    fi

    local header="$header_spec"
    if [[ "$header" =~ ^-H[[:space:]]+(.*)$ ]]; then
        header="${BASH_REMATCH[1]}"
    fi
    header="${header#\'}"
    header="${header%\'}"
    header="${header#\"}"
    header="${header%\"}"

    http_request "$name" "$url" -H "$header"
}

_is_http_mutation_method() {
    case "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" in
        POST|PUT|DELETE|PATCH) return 0 ;;
        *) return 1 ;;
    esac
}

assert_cached_after_warm() {
    local prefix="$1"
    local url="$2"
    shift 2

    local first_name="${prefix}-first"
    local second_name="${prefix}-second"

    local -a curl_args=()
    if [ "$#" -gt 0 ]; then
        curl_args=("$@")
    fi

    http_request "$first_name" "$url" ${curl_args[@]+"${curl_args[@]}"}
    assert_http_status "$first_name" 200 "first GET of ${prefix} target"
    assert_cache_state "$first_name" MISS "first GET of ${prefix} target"
    local first_id
    first_id="$(assert_origin_request_id_present "$first_name" "first GET of ${prefix} target")"

    http_request "$second_name" "$url" ${curl_args[@]+"${curl_args[@]}"}
    assert_http_status "$second_name" 200 "second GET of ${prefix} target"
    assert_cache_state "$second_name" HIT "second GET of ${prefix} target"
    assert_same_origin_request_id "$second_name" "$first_id" "second GET of ${prefix} target"

    export ASSERT_LAST_WARMED_ORIGIN_ID="$first_id"
    echo "OK: ${url} cached after warm request"
}

assert_mutation_invalidates() {
    local prefix="$1"
    local target_url="$2"
    shift 2

    local mutation_url
    local method
    if _is_http_mutation_method "$1"; then
        mutation_url="$target_url"
        method="$1"
        shift 1
    else
        mutation_url="$1"
        method="$2"
        shift 2
    fi

    local -a mutation_args=()
    if [ "$#" -gt 0 ]; then
        mutation_args=("$@")
    fi

    assert_cached_after_warm "$prefix" "$target_url"
    local warmed_id="$ASSERT_LAST_WARMED_ORIGIN_ID"

    local mutation_name="${prefix}-mutation"
    http_request "$mutation_name" "$mutation_url" -X "$method" ${mutation_args[@]+"${mutation_args[@]}"}

    local mutation_status
    mutation_status="$(response_status_code "$mutation_name")"
    if [ -z "$mutation_status" ] || [ "$mutation_status" -ge 400 ]; then
        fail_response_assertion \
            "expected successful ${method} mutation (< 400), got ${mutation_status:-missing}" \
            "$mutation_name"
    fi

    if [ "$mutation_url" = "$target_url" ]; then
        assert_cache_state "$mutation_name" MISS "successful ${method} mutation"
        assert_different_origin_request_id "$mutation_name" "$warmed_id" "successful ${method} mutation"
    fi

    local after_name="${prefix}-after"
    http_request "$after_name" "$target_url"
    assert_http_status "$after_name" 200 "GET ${prefix} target after ${method}"
    assert_cache_state "$after_name" MISS "GET ${prefix} target after ${method}"
    assert_different_origin_request_id "$after_name" "$warmed_id" "GET ${prefix} target after ${method}"

    echo "OK: successful ${method} invalidated the cached object"
}

assert_client_isolated() {
    local prefix="$1"
    local url="$2"
    local client_a_spec="$3"
    local client_b_spec="$4"

    local client_a_name="${prefix}-client-a"
    local client_b_name="${prefix}-client-b"

    _request_with_header_spec "$client_a_name" "$url" "$client_a_spec"
    assert_http_status "$client_a_name" 200 "Client A request for ${url}"
    assert_cache_state "$client_a_name" MISS "Client A request for ${url}"
    local client_a_id
    client_a_id="$(assert_origin_request_id_present "$client_a_name" "Client A request for ${url}")"

    _request_with_header_spec "$client_b_name" "$url" "$client_b_spec"
    assert_http_status "$client_b_name" 200 "Client B request for ${url}"
    assert_cache_state "$client_b_name" MISS "Client B request for ${url}"
    assert_different_origin_request_id "$client_b_name" "$client_a_id" "Client B request for ${url}"

    echo "OK: Client B remained isolated from Client A at ${url}"
}

