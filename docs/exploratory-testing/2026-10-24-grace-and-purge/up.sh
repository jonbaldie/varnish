#!/bin/bash
# Fresh topology: network, origin, varnish (published on 127.0.0.1:18824).
set -eu
EV=$(cd "$(dirname "$0")" && pwd)
IMG=${IMG:-varnish-et-20261024:run}
docker rm -fv vx24-varnish vx24-origin >/dev/null 2>&1 || true
docker network rm vx24-net >/dev/null 2>&1 || true
docker network create vx24-net >/dev/null
docker run -d --name vx24-origin --network vx24-net -v "$EV/origin.py:/origin.py:ro" python:3.13-alpine python -u /origin.py >/dev/null
docker run -d --name vx24-varnish --network vx24-net -p 127.0.0.1:18824:80 \
  -e VARNISH_BACKEND_HOST=vx24-origin -e VARNISH_BACKEND_PORT=8080 -e VARNISH_BACKEND_PROBE_PATH=/probe "$@" "$IMG" >/dev/null
for i in $(seq 1 60); do
  curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18824/ready 2>/dev/null | grep -q 200 && break; sleep 0.5
done
echo "up: $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18824/ready)"
