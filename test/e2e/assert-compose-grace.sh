#!/usr/bin/env bash
set -euo pipefail

test_url="http://localhost/?cachebust=$(openssl rand -hex 8)"
echo "Priming cache..."
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$test_url")"
if [ "$status" != "200" ]; then
  echo "FAIL: Expected HTTP 200, got $status"
  exit 1
fi
echo "OK: Cache primed with HTTP 200"

echo "Stopping web container..."
"$COMPOSE_FIXTURE_SCRIPT" stop web
echo "Waiting for backend to be marked sick (~15s)..."
sleep 18

echo "Checking request with backend down..."
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$test_url")"
if [ "$status" != "200" ]; then
  echo "FAIL: Expected HTTP 200 from grace, got $status"
  exit 1
fi
echo "OK: HTTP 200 from grace"
