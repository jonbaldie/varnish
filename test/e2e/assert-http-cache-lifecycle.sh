#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/test/e2e/http-cache-assert.sh"

echo "=== Test: Semantic cache-lifecycle operations exported ==="

# 1. Verify that all 3 semantic functions exist in http-cache-assert.sh
for fn in assert_cached_after_warm assert_mutation_invalidates assert_client_isolated; do
    if ! type -t "$fn" | grep -q 'function'; then
        echo "FAIL: expected function '$fn' to be defined in http-cache-assert.sh"
        exit 1
    fi
    echo "OK: $fn is defined"
done

echo "=== Test: Diagnostic response dumping on assertion failure ==="
test_tmpdir="$(mktemp -d)"
trap 'rm -rf "$test_tmpdir"' EXIT
export TEST_TMPDIR="$test_tmpdir"

# Populate synthetic response for diagnostic check
cat >"$(response_headers_path diag-sample)" <<'EOF'
HTTP/1.1 200 OK
Content-Type: text/plain
X-Cache: MISS
X-Backend-Request-Id: req-1234
EOF
cat >"$(response_body_path diag-sample)" <<'EOF'
route=diagnostic
client=alice
EOF

# Assert that failure reporting dumps response headers and body
set +e
diag_output="$(assert_cache_state diag-sample HIT "diagnostic sample" 2>&1)"
diag_status=$?
set -e

if [ "$diag_status" -eq 0 ]; then
    echo "FAIL: expected assert_cache_state to fail on mismatched cache state"
    exit 1
fi

echo "$diag_output" | grep -q "FAIL: expected diagnostic sample cache hit, got 'MISS'" || {
    echo "FAIL: diagnostic failure output did not include expected message"
    echo "$diag_output"
    exit 1
}

echo "$diag_output" | grep -q -- "--- diag-sample headers ---" || {
    echo "FAIL: diagnostic failure output did not include headers dump"
    echo "$diag_output"
    exit 1
}

echo "$diag_output" | grep -q -- "--- diag-sample body ---" || {
    echo "FAIL: diagnostic failure output did not include body dump"
    echo "$diag_output"
    exit 1
}

echo "$diag_output" | grep -q "route=diagnostic" || {
    echo "FAIL: diagnostic failure output did not include body content"
    echo "$diag_output"
    exit 1
}

echo "OK: Failure diagnostics dump response headers and body"

echo "=== All semantic cache-lifecycle checks passed ==="
