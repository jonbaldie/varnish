#!/usr/bin/env bash

set -euo pipefail

scenario="${1:-}"

if [ -z "$scenario" ]; then
	echo "Usage: $0 <scenario>" >&2
	exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

compose() {
	docker compose -p "$project" -f "$repo_root/docker-compose.yml" -f "$repo_root/docker-compose.hostile.yml" "$@"
}

cleanup() {
	if [ -n "${tmpdir:-}" ] && [ -d "${tmpdir:-}" ]; then
		rm -rf "$tmpdir"
	fi

	if [ -n "${lockdir:-}" ]; then
		rm -rf "$lockdir"
	fi

	if [ -n "${project:-}" ]; then
		compose down --remove-orphans >/dev/null 2>&1 || true
	fi
}

wait_for_ready() {
	local timeout="$1"
	local readiness_url="$2"
	local ready_message="$3"

	while [ "$timeout" -gt 0 ]; do
		if curl -sf --max-time 10 "$readiness_url" >/dev/null 2>&1; then
			echo "$ready_message"
			return 0
		fi

		sleep 2
		timeout=$((timeout - 2))
	done

	return 1
}

case "$scenario" in
	static-cookie)
		lockdir="/tmp/varnish-hostile-8081.lock"
		project="varnish-hostile-static-$$"
		readiness_url="http://localhost:8081/ready"
		assertion_script="$repo_root/test/e2e/assert-hostile-static-cookie.sh"
		services=(hostile-backend varnish-hostile)
		;;
	*)
		echo "Unknown hostile scenario: $scenario" >&2
		exit 1
		;;
esac

trap cleanup EXIT

while ! mkdir "$lockdir" 2>/dev/null; do
	sleep 1
done

tmpdir="$(mktemp -d)"

compose up -d --build "${services[@]}"

echo "Waiting hostile services to be ready..."
if ! wait_for_ready 60 "$readiness_url" "OK: Hostile services ready"; then
	echo "FAIL: Hostile services did not become ready within 60s"
	compose logs
	exit 1
fi

export TEST_TMPDIR="$tmpdir"
"$assertion_script"
