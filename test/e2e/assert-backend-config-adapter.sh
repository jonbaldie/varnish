#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

assert_compose_uses_backend_adapter() {
    local compose_file="$1"
    local service="$2"
    local backend_host="$3"
    local backend_port="$4"
    local backend_probe_path="$5"

    local config
    config="$(docker compose -f "$repo_root/$compose_file" config "$service")"

    if grep -q '/etc/varnish/default.vcl' <<<"$config"; then
        echo "FAIL: $compose_file:$service mounts backend VCL instead of using VARNISH_BACKEND_*"
        return 1
    fi

    grep -q "VARNISH_BACKEND_HOST: $backend_host" <<<"$config" || {
        echo "FAIL: $compose_file:$service missing VARNISH_BACKEND_HOST=$backend_host"
        return 1
    }
    grep -q "VARNISH_BACKEND_PORT: \"$backend_port\"" <<<"$config" || {
        echo "FAIL: $compose_file:$service missing VARNISH_BACKEND_PORT=$backend_port"
        return 1
    }
    grep -q "VARNISH_BACKEND_PROBE_PATH: $backend_probe_path" <<<"$config" || {
        echo "FAIL: $compose_file:$service missing VARNISH_BACKEND_PROBE_PATH=$backend_probe_path"
        return 1
    }

    echo "OK: $compose_file:$service uses backend configuration adapter"
}

assert_compose_uses_backend_adapter docker-compose.yml varnish web 80 /
assert_compose_uses_backend_adapter docker-compose.hostile.yml varnish-hostile hostile-backend 8080 /ready

HOSTILE_SCENARIO_PORT=18083 \
    assert_compose_uses_backend_adapter docker-compose.e2e-scenario.yml varnish web 80 /
