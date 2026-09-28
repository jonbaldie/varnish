#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture="$repo_root/test/e2e/fixtures/compose-fixture-lifecycle.yml"
lifecycle="$repo_root/test/e2e/compose-fixture.sh"
tmpdir="$(mktemp -d)"
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
url="http://127.0.0.1:$port"
project_prefix="varnish-fixture-lifecycle-$$"

trap 'rm -rf "$tmpdir"' EXIT

run_fixture() {
  local project="$1"
  local timeout="$2"
  local readiness_url="$3"
  shift 3

  "$lifecycle" run \
    --project "$project" \
    --compose-file "$fixture" \
    --env "FIXTURE_PORT=$port" \
    --env "FIXTURE_TEST_URL=$url" \
    --service fixture-web \
    --readiness-url "$readiness_url" \
    --timeout "$timeout" \
    --poll-interval 1 \
    --curl-timeout 2 \
    "$@"
}

assert_project_is_clean() {
  local project="$1"
  local containers

  containers="$(FIXTURE_PORT="$port" docker compose -p "$project" -f "$fixture" ps -aq)"
  if [ -n "$containers" ]; then
    echo "FAIL: Compose project $project still has containers after fixture cleanup" >&2
    FIXTURE_PORT="$port" docker compose -p "$project" -f "$fixture" ps >&2
    exit 1
  fi

  local networks
  networks="$(docker network ls --filter "label=com.docker.compose.project=$project" -q)"
  if [ -n "$networks" ]; then
    echo "FAIL: Compose project $project still has networks after fixture cleanup" >&2
    docker network ls --filter "label=com.docker.compose.project=$project" >&2
    exit 1
  fi
}

success_project="${project_prefix}-success"
success_assertion="$tmpdir/assert-success.sh"
cat >"$success_assertion" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
curl -sf "$FIXTURE_TEST_URL" | grep -Fq 'Welcome to nginx!'
"$COMPOSE_FIXTURE_SCRIPT" stop fixture-web
"$COMPOSE_FIXTURE_SCRIPT" start fixture-web
restarted=false
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  if curl -sf "$FIXTURE_TEST_URL" | grep -Fq 'Welcome to nginx!'; then
    restarted=true
    break
  fi
  sleep 1
done
[ "$restarted" = true ]
EOF
chmod +x "$success_assertion"

echo "=== Compose fixture lifecycle: ready assertion and named service controls ==="
run_fixture "$success_project" 15 "$url" -- "$success_assertion"
assert_project_is_clean "$success_project"

failure_project="${project_prefix}-assertion-failure"
failure_assertion="$tmpdir/assert-failure.sh"
cat >"$failure_assertion" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$COMPOSE_FIXTURE_SCRIPT" stop fixture-web
exit 23
EOF
chmod +x "$failure_assertion"

echo "=== Compose fixture lifecycle: restore and cleanup after assertion failure ==="
set +e
run_fixture "$failure_project" 15 "$url" --restore-service fixture-web -- "$failure_assertion" >"$tmpdir/assertion-failure.log" 2>&1
failure_status=$?
set -e
if [ "$failure_status" -ne 23 ]; then
  echo "FAIL: fixture lifecycle should preserve assertion exit code 23, got $failure_status" >&2
  cat "$tmpdir/assertion-failure.log" >&2
  exit 1
fi
grep -Fq 'Restoring fixture service: fixture-web' "$tmpdir/assertion-failure.log" || {
  echo "FAIL: fixture lifecycle should restore stopped services before teardown" >&2
  cat "$tmpdir/assertion-failure.log" >&2
  exit 1
}
assert_project_is_clean "$failure_project"

timeout_project="${project_prefix}-readiness-timeout"
echo "=== Compose fixture lifecycle: readiness timeout diagnostics and cleanup ==="
set +e
run_fixture "$timeout_project" 2 "$url/not-ready" -- true >"$tmpdir/readiness-timeout.log" 2>&1
timeout_status=$?
set -e
if [ "$timeout_status" -eq 0 ]; then
  echo "FAIL: fixture lifecycle should fail when readiness times out" >&2
  cat "$tmpdir/readiness-timeout.log" >&2
  exit 1
fi
grep -Fq 'Services did not become ready within 2s' "$tmpdir/readiness-timeout.log" || {
  echo "FAIL: readiness timeout should explain the configured deadline" >&2
  cat "$tmpdir/readiness-timeout.log" >&2
  exit 1
}
grep -Fq 'GET /not-ready HTTP/1.1' "$tmpdir/readiness-timeout.log" || {
  echo "FAIL: readiness timeout should include Compose service logs" >&2
  cat "$tmpdir/readiness-timeout.log" >&2
  exit 1
}
assert_project_is_clean "$timeout_project"

echo "OK: Compose fixture lifecycle contract passed"
