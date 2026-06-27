#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/test/e2e/run-hostile-scenario.sh"

description="$("$runner" --describe 5xx)"

echo "$description" | grep -q '^scenario=5xx$' || {
  echo "FAIL: 5xx scenario description should include scenario name"
  echo "$description"
  exit 1
}

echo "$description" | grep -q '^port=8082$' || {
  echo "FAIL: 5xx scenario description should include exposed port"
  echo "$description"
  exit 1
}

echo "$description" | grep -q '^readiness_url=http://localhost:8082/ready$' || {
  echo "FAIL: 5xx scenario description should include readiness URL"
  echo "$description"
  exit 1
}

echo "$description" | grep -q 'assertion_script=.*/test/e2e/assert-hostile-5xx.sh$' || {
  echo "FAIL: 5xx scenario description should include semantic assertion script"
  echo "$description"
  exit 1
}

set +e
unknown_output="$("$runner" --describe does-not-exist 2>&1)"
unknown_status=$?
set -e

if [ "$unknown_status" -eq 0 ]; then
  echo "FAIL: unknown scenario should fail"
  echo "$unknown_output"
  exit 1
fi

echo "$unknown_output" | grep -q 'Unknown hostile scenario: does-not-exist' || {
  echo "FAIL: unknown scenario should name the bad scenario"
  echo "$unknown_output"
  exit 1
}

echo "$unknown_output" | grep -q 'Available scenarios: static-cookie, account-cookie, set-cookie, 5xx, post, grace, purge-acl' || {
  echo "FAIL: unknown scenario should list available scenarios"
  echo "$unknown_output"
  exit 1
}

echo "OK: E2E harness exposes scenario metadata and useful failures"
