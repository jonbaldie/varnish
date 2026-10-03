#!/usr/bin/env bash
# Minimal reproducer for: Unencoded horizontal tab (HTAB) in Location/Content-Location causes Varnish ban syntax error and leaves stale cache entry.
set -euo pipefail

PORT=18790
NET="vx-repro-net-$$"
ORIGIN="vx-repro-origin-$$"
VARNISH="vx-repro-varnish-$$"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cleanup() {
    docker rm -f "$VARNISH" "$ORIGIN" >/dev/null 2>&1 || true
    docker network rm "$NET" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Starting isolated test topology on port $PORT..."
docker network create "$NET" >/dev/null
docker run -d --name "$ORIGIN" --network "$NET" -v "$DIR/origin-app.py:/app/origin-app.py" python:3.12-alpine python3 /app/origin-app.py >/dev/null
docker run -d --name "$VARNISH" --network "$NET" -p "$PORT:80" \
    -e VARNISH_BACKEND_HOST="$ORIGIN" \
    -e VARNISH_BACKEND_PORT=8080 \
    jonbaldie/varnish:latest >/dev/null

echo "Waiting for Varnish on port $PORT..."
for _ in $(seq 1 30); do
    if curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT/" | grep -q "200"; then
        break
    fi
    sleep 0.5
done

echo "1. Priming cache for /report%09data..."
curl -s -i "http://localhost:$PORT/report%09data" | grep -E "(HTTP/|X-Cache|X-Origin-N)"
echo "2. Second GET (expect HIT)..."
curl -s -i "http://localhost:$PORT/report%09data" | grep -E "(HTTP/|X-Cache|X-Origin-N)"

echo "3. Sending POST mutation with Location containing HTAB (\t)..."
python3 -c "
import socket
s = socket.create_connection(('127.0.0.1', $PORT))
s.sendall(b'POST /mutate?status=201&h_Location=/report%09data HTTP/1.1\r\nHost: localhost:$PORT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
resp = s.recv(4096).decode('latin1')
print('\n'.join(l for l in resp.split('\r\n') if l.startswith('HTTP/') or l.lower().startswith('location') or l.lower().startswith('x-cache')))
"

echo "4. Checking Varnish log for VCL_Error:"
docker exec "$VARNISH" varnishlog -d -g raw -i VCL_Error || true

echo "5. Third GET for target (Expected: MISS after Location target invalidation):"
curl -s -i "http://localhost:$PORT/report%09data" | grep -E "(HTTP/|X-Cache|X-Origin-N)"
