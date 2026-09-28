#!/usr/bin/env bash
set -euo pipefail

test_path="/?cachebust=$(openssl rand -hex 8)"
test_url="http://localhost$test_path"
echo "Priming cache..."
cache="$(curl -sI --max-time 10 "$test_url" | grep -i x-cache)"
if ! echo "$cache" | grep -qi MISS; then
  echo "FAIL: Expected X-Cache MISS, got: $cache"
  exit 1
fi
echo "OK: X-Cache MISS"

echo "Checking X-Cache HIT..."
cache="$(curl -sI --max-time 10 "$test_url" | grep -i x-cache)"
if ! echo "$cache" | grep -qi HIT; then
  echo "FAIL: Expected X-Cache HIT, got: $cache"
  exit 1
fi
echo "OK: X-Cache HIT"

echo "Sending PURGE from Varnish loopback..."
varnish_container="$(docker compose ps -q varnish)"
if [ -z "$varnish_container" ]; then
  echo "FAIL: Could not find Varnish container"
  exit 1
fi
status="$(docker run --rm --network "container:$varnish_container" alpine sh -c 'apk add -q curl >/dev/null && curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X PURGE -H "Host: localhost" "$1"' sh "http://127.0.0.1$test_path")"
if [ "$status" != "200" ]; then
  echo "FAIL: Expected PURGE HTTP 200, got $status"
  exit 1
fi
echo "OK: PURGE returned 200"

echo "Checking X-Cache MISS after PURGE..."
cache="$(curl -sI --max-time 10 "$test_url" | grep -i x-cache)"
if ! echo "$cache" | grep -qi MISS; then
  echo "FAIL: Expected X-Cache MISS after PURGE, got: $cache"
  exit 1
fi
echo "OK: X-Cache MISS after PURGE"
