#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runner="$repo_root/test/e2e/run-hostile-scenario.sh"

if grep -Eq 'docker-compose\.(5xx-test|grace-test|post-test|purge-acl-test)\.yml' "$runner"; then
    echo "FAIL: hostile scenarios should use scenario config, not per-scenario compose files"
    grep -En 'docker-compose\.(5xx-test|grace-test|post-test|purge-acl-test)\.yml' "$runner"
    exit 1
fi

echo "OK: hostile scenarios use shared scenario compose config"
