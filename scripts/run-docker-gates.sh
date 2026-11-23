#!/usr/bin/env bash
# Safe full-gate runner for #176.
#
# Builds a disposable image tag, then runs the complete Docker gates serially
# with that tag. Every test container in the gates is already capped with
# --cpus/--memory/--pids-limit (daemon Varnish: 1 CPU / 2g / 512; short-lived
# checks and helpers: 1 CPU / 512m / 100; nginx/Python helpers: 256m/100) and
# every published test port is bound to 127.0.0.1. Compose services carry the
# same limits via deploy.resources.limits and publish on loopback only.
# The disposable image is removed on exit; output is teed to a log file so
# failure diagnostics are preserved.
set -euo pipefail

cd "$(dirname "$0")/.."

IMAGE="varnish-176-gates-$$:test"
LOG="${TMPDIR:-/tmp}/varnish-176-gates-$$.log"

cleanup() {
  docker image rm -f "$IMAGE" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Safe gates: disposable image $IMAGE (log: $LOG)"
echo "Safe gates: serial run, COMPOSE_PARALLEL_LIMIT=1 make -j1 test test-e2e-hard"

set +e
{
  echo "=== building disposable image $IMAGE ==="
  docker build -t "$IMAGE" .
  echo "=== running gates with IMAGE=$IMAGE VARNISH_IMAGE=$IMAGE ==="
  COMPOSE_PARALLEL_LIMIT=1 VARNISH_IMAGE="$IMAGE" make -j1 IMAGE="$IMAGE" test test-e2e-hard
  echo "=== safe gates PASSED ==="
} 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e
if [ "$status" -ne 0 ]; then
  echo "Safe gates FAILED (exit $status); diagnostics preserved in $LOG" >&2
  exit "$status"
fi
echo "Safe gates log: $LOG"
