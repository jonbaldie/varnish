#!/usr/bin/env bash
# Ensure shell tracing (xtrace) is disabled so credentials are never printed
set +x 2>/dev/null || true
set -euo pipefail

# Verifies Docker Hub authentication against registry token service
USERNAME="${DOCKERHUB_USERNAME:-jonbaldie}"
TOKEN="${DOCKERHUB_TOKEN:-}"

# Ensure token is cleared from memory on exit
trap 'unset TOKEN 2>/dev/null || true' EXIT

if [ -z "$TOKEN" ]; then
    echo "FAIL: DOCKERHUB_TOKEN is empty or not set" >&2
    exit 1
fi

echo "Verifying Docker Hub credentials for user: $USERNAME"

# Pass credentials securely via curl config stdin to prevent exposure in process table (ps aux)
RESPONSE=$(printf 'user = "%s:%s"\n' "$USERNAME" "$TOKEN" | curl -s -i --config - "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${USERNAME}/varnish:pull,push")

HTTP_STATUS=$(echo "$RESPONSE" | grep -E '^HTTP/' | tail -1 | awk '{print $2}')

if [ "$HTTP_STATUS" = "200" ]; then
    echo "OK: Docker Hub token is valid and authorized for ${USERNAME}/varnish"
    exit 0
else
    echo "FAIL: Docker Hub authentication failed with HTTP ${HTTP_STATUS}"
    # Only show safe error details, never full response
    echo "$RESPONSE" | grep -E '("details"|"message"|unauthorized)' || echo "$RESPONSE" | grep -E '^HTTP/'
    exit 1
fi
