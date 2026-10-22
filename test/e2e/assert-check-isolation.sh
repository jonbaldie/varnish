#!/usr/bin/env bash
set -euo pipefail
image="${1:-jonbaldie/varnish:latest}"
name="varnish-test-check-isolation-$(openssl rand -hex 4)"
trap 'docker logs "$name" 2>&1 || true; docker rm -fv "$name" >/dev/null 2>&1 || true' EXIT
# A real running instance must retain its configuration across checks and restart.
docker run -d --name "$name" -p 127.0.0.1::80 "$image" >/dev/null
port="$(docker port "$name" 80/tcp | cut -d: -f2)"
wait_http() {
    for _ in {1..60}; do
        if curl -s --fail-with-body --max-time 1 "http://127.0.0.1:$port/" >/dev/null 2>&1; then return; fi
        # The standalone backend is absent; 503 still proves Varnish serves HTTP.
        if [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 1 "http://127.0.0.1:$port/" || true)" == 503 ]]; then return; fi
        sleep 0.2
    done
    echo 'FAIL: container did not serve HTTP'; return 1
}
wait_http
# Use -i to feed assertions through the supported entrypoint and real compiler.
docker exec -i "$name" bash -s <<'SCRIPT'
set -euo pipefail
trap 'rc=$?; if (( rc )); then cat /tmp/check-out 2>/dev/null || true; fi' EXIT
export VARNISH_LISTEN=127.0.0.1:18099
snapshot() { sha256sum /etc/varnish/*.vcl; }
before="$(snapshot)"
assert_unchanged() {
    [[ "$(snapshot)" == "$before" ]] || { echo 'FAIL: check/start overwrote live VCL'; exit 1; }
    [[ -z "$(find /etc/varnish -maxdepth 1 -name '.backend-*' -print)" ]] || { echo 'FAIL: candidate leaked'; exit 1; }
}
# Success must be quiet and must not publish a candidate.
VARNISH_BACKEND_HOST=localhost VARNISH_BACKEND_PORT=9090 VARNISH_BACKEND_PROBE_PATH=/healthz /start.sh --check >/tmp/check-out 2>&1
[[ ! -s /tmp/check-out ]]
assert_unchanged
# Candidate-specific compiler diagnostics prove it did not compile the live backend.
if VARNISH_BACKEND_HOST=nohost.invalid /start.sh --check >/tmp/check-out 2>&1; then exit 1; fi
grep -q nohost.invalid /tmp/check-out
grep -q 'VCL compilation failed' /tmp/check-out
assert_unchanged
# Failed startup must not publish either (render failure and compile failure).
for host in 'invalid/host' nohost.invalid; do
    if VARNISH_BACKEND_HOST="$host" /start.sh >/tmp/check-out 2>&1; then exit 1; fi
    assert_unchanged
done
# Concurrent checks must have private candidate and compiler work directories.
pids=()
for port in 9091 9092 9093; do
    VARNISH_LISTEN="127.0.0.1:$port" VARNISH_BACKEND_HOST=localhost VARNISH_BACKEND_PORT="$port" /start.sh --check &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
assert_unchanged
SCRIPT
wait_http
docker restart "$name" >/dev/null
port="$(docker port "$name" 80/tcp | cut -d: -f2)"
wait_http
echo 'OK: checks preserve live VCL; failed check followed by restart still serves HTTP'
