#!/usr/bin/env bash

set -euo pipefail

scenario="${1:-}"

if [ -z "$scenario" ]; then
	echo "Usage: $0 <scenario>" >&2
	exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
compose_files=("$repo_root/docker-compose.yml" "$repo_root/docker-compose.hostile.yml")
ready_timeout=60
curl_max_time=10

compose() {
  local args=(-p "$project")
  local compose_file

  for compose_file in "${compose_files[@]}"; do
    args+=(-f "$compose_file")
  done

  docker compose "${args[@]}" "$@"
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
  account-cookie)
    lockdir="/tmp/varnish-hostile-8081.lock"
    project="varnish-hostile-account-$$"
    readiness_url="http://localhost:8081/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-account-cookie.sh"
    services=(hostile-backend varnish-hostile)
    ;;
  set-cookie)
    lockdir="/tmp/varnish-hostile-8081.lock"
    project="varnish-hostile-set-cookie-$$"
    readiness_url="http://localhost:8081/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-set-cookie.sh"
    services=(hostile-backend varnish-hostile)
    ;;
  5xx)
        compose_files=("$repo_root/docker-compose.e2e-scenario.yml")
        lockdir="/tmp/varnish-5xx-test-8082.lock"
        project="varnish-5xx-test-$$"
        HOSTILE_SCENARIO_PORT=8082
        readiness_url="http://localhost:8082/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-5xx.sh"
    services=()
    curl_max_time=5
    ;;
  post)
        compose_files=("$repo_root/docker-compose.e2e-scenario.yml")
        lockdir="/tmp/varnish-post-test-8084.lock"
        project="varnish-post-test-$$"
        HOSTILE_SCENARIO_PORT=8084
        readiness_url="http://localhost:8084/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-post.sh"
    services=()
    curl_max_time=5
    ;;
  grace)
        compose_files=("$repo_root/docker-compose.e2e-scenario.yml")
        lockdir="/tmp/varnish-grace-stale-8083.lock"
        project="varnish-grace-stale-$$"
        HOSTILE_SCENARIO_PORT=8083
        readiness_url="http://localhost:8083/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-grace.sh"
    services=()
    curl_max_time=5
    ;;
  purge-acl)
        compose_files=("$repo_root/docker-compose.e2e-scenario.yml")
    lockdir="/tmp/varnish-purge-acl-test-8085.lock"
        project="varnish-purge-acl-$$"
        HOSTILE_SCENARIO_PORT=8085
        HOSTILE_SCENARIO_SUBNET=203.0.113.0/24
        HOSTILE_SCENARIO_VARNISH_IP=203.0.113.2
    readiness_url="http://localhost:8085/ready"
    assertion_script="$repo_root/test/e2e/assert-hostile-purge-acl.sh"
    services=()
    curl_max_time=5
    ;;
	*)
		echo "Unknown hostile scenario: $scenario" >&2
		exit 1
		;;
esac

export HOSTILE_SCENARIO_PORT="${HOSTILE_SCENARIO_PORT:-}"
export HOSTILE_SCENARIO_SUBNET="${HOSTILE_SCENARIO_SUBNET:-}"
export HOSTILE_SCENARIO_VARNISH_IP="${HOSTILE_SCENARIO_VARNISH_IP:-}"
export COMPOSE_FILE
COMPOSE_FILE="$(IFS=:; echo "${compose_files[*]}")"
export COMPOSE_PROJECT_NAME="$project"

trap cleanup EXIT

while ! mkdir "$lockdir" 2>/dev/null; do
	sleep 1
done

tmpdir="$(mktemp -d)"

if [ -n "${HOSTILE_SCENARIO_SUBNET:-}" ]; then
    purge_override="$tmpdir/docker-compose.purge-acl.override.yml"
    cat >"$purge_override" <<EOF
services:
  varnish:
    networks:
      backend:
      external:
        ipv4_address: ${HOSTILE_SCENARIO_VARNISH_IP:?HOSTILE_SCENARIO_VARNISH_IP is required}

networks:
  external:
    ipam:
      driver: default
      config:
        - subnet: ${HOSTILE_SCENARIO_SUBNET:?HOSTILE_SCENARIO_SUBNET is required}
EOF
    compose_files+=("$purge_override")
    COMPOSE_FILE="$(IFS=:; echo "${compose_files[*]}")"
fi

if [ "${#services[@]}" -gt 0 ]; then
  compose up -d --build "${services[@]}"
else
  compose up -d --build
fi

echo "Waiting hostile services to be ready..."
if ! wait_for_ready "$ready_timeout" "$readiness_url" "OK: Hostile services ready"; then
  echo "FAIL: Hostile services did not become ready within 60s"
  compose logs
  exit 1
fi

export TEST_TMPDIR="$tmpdir"
export TEST_PROJECT="$project"
export TEST_CURL_MAX_TIME="$curl_max_time"
"$assertion_script"
