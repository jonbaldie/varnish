#!/usr/bin/env bash
# Ensure shell tracing (xtrace) is disabled so credentials are never logged
set +x 2>/dev/null || true
set -euo pipefail

# Human-In-The-Loop script to refresh Docker Hub token, verify authentication,
# update GitHub repository secrets, and rerun the failed CI workflow.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USERNAME="${DOCKERHUB_USERNAME:-jonbaldie}"

# Scrub token from memory on exit, interrupt, or termination
trap 'unset TOKEN DOCKERHUB_TOKEN 2>/dev/null || true' EXIT INT TERM

echo "========================================================"
echo " Docker Hub Token Refresh & CI Verification Loop (HITL)"
echo "========================================================"
echo "1. Go to: https://app.docker.com/settings/personal-access-tokens"
echo "2. Generate a new Personal Access Token with Read & Write permissions."
echo ""

while true; do
  if [ -z "${DOCKERHUB_TOKEN:-}" ]; then
    # Read token silently so it is not visible on terminal or in history
    read -rsp "Enter the new Docker Hub Personal Access Token: " TOKEN
    echo ""
  else
    TOKEN="$DOCKERHUB_TOKEN"
  fi

  if [ -z "$TOKEN" ]; then
    echo "Token cannot be empty. Try again."
    unset DOCKERHUB_TOKEN || true
    continue
  fi

  echo "Verifying token against Docker Hub registry..."
  if DOCKERHUB_USERNAME="$USERNAME" DOCKERHUB_TOKEN="$TOKEN" "$SCRIPT_DIR/verify-docker-auth.sh"; then
    echo "Authentication verified successfully!"
    break
  else
    echo "Token verification failed. Please check the token and try again."
    unset DOCKERHUB_TOKEN TOKEN || true
  fi
done

echo ""
echo "Updating GitHub repository secret DOCKERHUB_TOKEN..."
# Pipe secret directly via stdin to prevent command-line exposure
printf '%s' "$TOKEN" | gh secret set DOCKERHUB_TOKEN --repo "${GITHUB_REPOSITORY:-jonbaldie/varnish}"
echo "GitHub secret updated successfully."

# Wipe token from memory immediately after updating secret
unset TOKEN DOCKERHUB_TOKEN || true

echo ""
echo "Triggering re-run of failed CI job (run 33871162122)..."
gh run rerun 33871162122 --failed --repo "${GITHUB_REPOSITORY:-jonbaldie/varnish}"
echo "CI rerun dispatched! Monitor progress with: gh run watch 33871162122"
