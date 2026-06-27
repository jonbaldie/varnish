#!/usr/bin/env bash

set -euo pipefail

scenario="${1:-}"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ready_timeout=60
curl_max_time=10
available_scenarios=(static-cookie account-cookie set-cookie 5xx post grace purge-acl)

usage() {
  echo "Usage: $0 <scenario>" >&2
  echo "       $0 --describe <scenario>" >&2
}

available_scenarios_text() {
  local separator=""
  local scenario_name

  for scenario_name in "${available_scenarios[@]}"; do
    printf '%s%s' "$separator" "$scenario_name"
    separator=", "
  done
  printf '\n'
}

unknown_scenario() {
  local name="$1"
  echo "Unknown hostile scenario: ${name}" >&2
  echo "Available scenarios: $(available_scenarios_text)" >&2
  exit 1
}

use_legacy_hostile_compose() {
  compose_files=("$repo_root/docker-compose.yml" "$repo_root/docker-compose.hostile.yml")
  port=8081
  lockdir="/tmp/varnish-hostile-${port}.lock"
  project="varnish-hostile-${scenario}-$$"
  readiness_url="http://localhost:${port}/ready"
  services=(hostile-backend varnish-hostile)
}

use_scenario_compose() {
  local slug="$1"
  local scenario_port="$2"

  compose_files=("$repo_root/docker-compose.e2e-scenario.yml")
  port="$scenario_port"
  lockdir="/tmp/varnish-${slug}-${port}.lock"
  project="varnish-${slug}-$$"
  HOSTILE_SCENARIO_PORT="$port"
  readiness_url="http://localhost:${port}/ready"
  services=()
  curl_max_time=5
}

configure_scenario() {
  case "$scenario" in
    static-cookie)
      use_legacy_hostile_compose
      assertion_script="$repo_root/test/e2e/assert-hostile-static-cookie.sh"
      ;;
    account-cookie)
      use_legacy_hostile_compose
      assertion_script="$repo_root/test/e2e/assert-hostile-account-cookie.sh"
      ;;
    set-cookie)
      use_legacy_hostile_compose
      assertion_script="$repo_root/test/e2e/assert-hostile-set-cookie.sh"
      ;;
    5xx)
      use_scenario_compose "5xx-test" 8082
      assertion_script="$repo_root/test/e2e/assert-hostile-5xx.sh"
      ;;
    post)
      use_scenario_compose "post-test" 8084
      assertion_script="$repo_root/test/e2e/assert-hostile-post.sh"
      ;;
    grace)
      use_scenario_compose "grace-stale" 8083
      assertion_script="$repo_root/test/e2e/assert-hostile-grace.sh"
      ;;
    purge-acl)
      use_scenario_compose "purge-acl" 8085
      HOSTILE_SCENARIO_SUBNET=203.0.113.0/24
      HOSTILE_SCENARIO_VARNISH_IP=203.0.113.2
      assertion_script="$repo_root/test/e2e/assert-hostile-purge-acl.sh"
      ;;
    *)
      unknown_scenario "$scenario"
      ;;
  esac
}

describe_scenario() {
  configure_scenario

  echo "scenario=$scenario"
  echo "port=$port"
  echo "readiness_url=$readiness_url"
  echo "assertion_script=$assertion_script"
  echo "compose_files=$(IFS=:; echo "${compose_files[*]}")"
  echo "services=$(IFS=,; echo "${services[*]-}")"
}

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
  local ready_url="$2"
  local ready_message="$3"

  while [ "$timeout" -gt 0 ]; do
    if curl -sf --max-time 10 "$ready_url" >/dev/null 2>&1; then
      echo "$ready_message"
      return 0
    fi

    sleep 2
    timeout=$((timeout - 2))
  done

  return 1
}

if [ -z "$scenario" ]; then
  usage
  exit 1
fi

if [ "$scenario" = "--describe" ]; then
  scenario="${2:-}"
  if [ -z "$scenario" ]; then
    usage
    exit 1
  fi
  describe_scenario
  exit 0
fi

configure_scenario

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
        ipv4_address: ${HOSTILE_SCENARIO_VARNISH_IP:?HOSTILE_SCENARIO_VARNISH_IP required}

networks:
  external:
    ipam:
      driver: default
      config:
        - subnet: ${HOSTILE_SCENARIO_SUBNET:?HOSTILE_SCENARIO_SUBNET required}
EOF
  compose_files+=("$purge_override")
  COMPOSE_FILE="$(IFS=:; echo "${compose_files[*]}")"
fi

if [ "${#services[@]}" -gt 0 ]; then
  compose up -d --build "${services[@]}"
else
  compose up -d --build
fi

echo "Waiting hostile services be ready..."
if ! wait_for_ready "$ready_timeout" "$readiness_url" "OK: Hostile services ready"; then
  echo "FAIL: Hostile services did not become ready within ${ready_timeout}s"
  compose logs
  exit 1
fi

export TEST_TMPDIR="$tmpdir"
export TEST_PROJECT="$project"
export TEST_CURL_MAX_TIME="$curl_max_time"
"$assertion_script"
