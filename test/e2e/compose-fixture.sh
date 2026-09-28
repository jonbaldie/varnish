#!/usr/bin/env bash
set -euo pipefail

script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
fixture_project=""
fixture_compose_files=()
fixture_restore_services=()

usage() {
  cat >&2 <<'EOF'
Usage:
  compose-fixture.sh run --compose-file FILE [options] -- COMMAND [ARG...]
  compose-fixture.sh stop SERVICE [SERVICE...]
  compose-fixture.sh start SERVICE [SERVICE...]

Run options:
  --project NAME                 Isolate this fixture under a Compose project name
  --compose-file FILE            Compose file to use; may be repeated
  --env NAME=VALUE               Export a value for Compose and the assertion command
  --service NAME                 Start only this service; may be repeated
  --restore-service NAME         Start this service before teardown; may be repeated
  --readiness-url URL            URL that must return a successful response
  --timeout SECONDS              Readiness deadline (default: 60)
  --curl-timeout SECONDS         Maximum duration for one readiness request (default: 10)
  --poll-interval SECONDS        Delay between readiness requests (default: 2)
  --ready-message MESSAGE        Message to print after readiness succeeds
EOF
}

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

fixture_compose() {
  local -a args=()
  if [ -n "$fixture_project" ]; then
    args+=(-p "$fixture_project")
  fi
  local compose_file
  for compose_file in "${fixture_compose_files[@]}"; do
    args+=(-f "$compose_file")
  done
  docker compose "${args[@]}" "$@"
}

fixture_cleanup() {
  local original_status=$?
  local cleanup_status=0
  trap - EXIT
  set +e

  local service
  if [ "${#fixture_restore_services[@]}" -gt 0 ]; then
    for service in "${fixture_restore_services[@]}"; do
      echo "Restoring fixture service: $service"
      fixture_compose start "$service" >/dev/null || cleanup_status=1
    done
  fi

  fixture_compose down --remove-orphans >/dev/null 2>&1 || {
    echo "FAIL: could not tear down Compose fixture ${COMPOSE_FIXTURE_PROJECT:-default}" >&2
    cleanup_status=1
  }

  if [ "$original_status" -eq 0 ] && [ "$cleanup_status" -ne 0 ]; then
    original_status=1
  fi
  exit "$original_status"
}

require_active_fixture() {
  if [ "${COMPOSE_FIXTURE_ACTIVE:-}" != "true" ]; then
    fail "service controls must run inside a Compose fixture assertion"
  fi
}

service_control() {
  local action="$1"
  shift
  require_active_fixture
  [ "$#" -gt 0 ] || fail "$action requires at least one service name"
  docker compose "$action" "$@"
}

compose_fixture_run() {
  shift

  local project=""
  local readiness_url=""
  local timeout=60
  local curl_timeout=10
  local poll_interval=2
  local ready_message="OK: Compose fixture services are ready"
  local -a env_assignments=()
  local -a services=()
  local -a restore_services=()
  local -a assertion_command=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ "$#" -ge 2 ] || fail "--project requires a name"
        project="$2"
        shift 2
        ;;
      --compose-file)
        [ "$#" -ge 2 ] || fail "--compose-file requires a path"
        fixture_compose_files+=("$2")
        shift 2
        ;;
      --env)
        [ "$#" -ge 2 ] || fail "--env requires NAME=VALUE"
        [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || fail "invalid environment assignment: $2"
        env_assignments+=("$2")
        shift 2
        ;;
      --service)
        [ "$#" -ge 2 ] || fail "--service requires a name"
        services+=("$2")
        shift 2
        ;;
      --restore-service)
        [ "$#" -ge 2 ] || fail "--restore-service requires a name"
        fixture_restore_services+=("$2")
        shift 2
        ;;
      --readiness-url)
        [ "$#" -ge 2 ] || fail "--readiness-url requires a URL"
        readiness_url="$2"
        shift 2
        ;;
      --timeout)
        [ "$#" -ge 2 ] || fail "--timeout requires seconds"
        timeout="$2"
        shift 2
        ;;
      --curl-timeout)
        [ "$#" -ge 2 ] || fail "--curl-timeout requires seconds"
        curl_timeout="$2"
        shift 2
        ;;
      --poll-interval)
        [ "$#" -ge 2 ] || fail "--poll-interval requires seconds"
        poll_interval="$2"
        shift 2
        ;;
      --ready-message)
        [ "$#" -ge 2 ] || fail "--ready-message requires a message"
        ready_message="$2"
        shift 2
        ;;
      --)
        shift
        assertion_command=("$@")
        break
        ;;
      *)
        fail "unknown run option: $1"
        ;;
    esac
  done

  [ "${#fixture_compose_files[@]}" -gt 0 ] || fail "run requires at least one --compose-file"
  [ -n "$readiness_url" ] || fail "run requires --readiness-url"
  [ "${#assertion_command[@]}" -gt 0 ] || fail "run requires an assertion command after --"
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || fail "--timeout must be a positive whole number"
  [[ "$curl_timeout" =~ ^[1-9][0-9]*$ ]] || fail "--curl-timeout must be a positive whole number"
  [[ "$poll_interval" =~ ^[1-9][0-9]*$ ]] || fail "--poll-interval must be a positive whole number"

  local compose_file_list
  compose_file_list="$(IFS=:; echo "${fixture_compose_files[*]}")"
  export COMPOSE_FILE="$compose_file_list"
  if [ -n "$project" ]; then
    fixture_project="$project"
    export COMPOSE_PROJECT_NAME="$project"
  else
    fixture_project=""
  fi
  export COMPOSE_FIXTURE_ACTIVE=true
  export COMPOSE_FIXTURE_PROJECT="${project:-${COMPOSE_PROJECT_NAME:-}}"
  export COMPOSE_FIXTURE_SCRIPT="$script_path"
  export COMPOSE_FIXTURE_READINESS_URL="$readiness_url"
  export COMPOSE_FIXTURE_TIMEOUT="$timeout"
  export COMPOSE_FIXTURE_CURL_TIMEOUT="$curl_timeout"
  if [ "${#env_assignments[@]}" -gt 0 ]; then
    for assignment in "${env_assignments[@]}"; do
      export "$assignment"
    done
  fi

  if [ "${#restore_services[@]}" -gt 0 ]; then
    fixture_restore_services=("${restore_services[@]}")
  fi
  trap fixture_cleanup EXIT

  echo "Starting Compose fixture ${COMPOSE_FIXTURE_PROJECT:-default}..."
  if [ "${#services[@]}" -gt 0 ]; then
    if ! fixture_compose up -d --build "${services[@]}"; then
      echo "FAIL: Compose fixture failed to start" >&2
      fixture_compose logs >&2 || true
      return 1
    fi
  elif ! fixture_compose up -d --build; then
    echo "FAIL: Compose fixture failed to start" >&2
    fixture_compose logs >&2 || true
    return 1
  fi

  echo "Waiting for Compose fixture readiness at $readiness_url..."
  local deadline=$((SECONDS + timeout))
  local remaining
  local request_timeout
  while [ "$SECONDS" -lt "$deadline" ]; do
    remaining=$((deadline - SECONDS))
    request_timeout="$curl_timeout"
    if [ "$remaining" -lt "$request_timeout" ]; then
      request_timeout="$remaining"
    fi
    if curl -sf --max-time "$request_timeout" "$readiness_url" >/dev/null 2>&1; then
      echo "$ready_message"
      "${assertion_command[@]}"
      return $?
    fi
    remaining=$((deadline - SECONDS))
    [ "$remaining" -gt 0 ] || break
    if [ "$poll_interval" -lt "$remaining" ]; then
      sleep "$poll_interval"
    else
      sleep "$remaining"
    fi
  done

  echo "FAIL: Services did not become ready within ${timeout}s" >&2
  fixture_compose logs >&2 || true
  return 1
}

case "${1:-}" in
  run)
    compose_fixture_run "$@"
    ;;
  stop|start)
    service_control "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
