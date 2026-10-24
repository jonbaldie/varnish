#!/bin/bash
# A good cached page (max-age=2) must keep being served from grace while the
# origin returns 500, rather than the 500 replacing it.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
"$EV/up.sh"
B=http://127.0.0.1:18824
req(){ printf '%-28s ' "$1"; curl -s -o "${TMPDIR:-/tmp}/vx24body" -D - "$B/news" | grep -iE '^(HTTP/|x-cache|x-origin-n|age):' | tr -d '\r' | tr '\n' ' '; printf ' body.status=%s\n' "$(grep -o '"status": [0-9]*' "${TMPDIR:-/tmp}/vx24body" | cut -d' ' -f2)"; }
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/news&h_Cache-Control=max-age%3D2" >/dev/null
req "t0 good page cached"
req "t0 repeat"
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/news&status=${STATUS:-500}&h_Cache-Control=max-age%3D2" >/dev/null
echo "-- origin now answers /news with ${STATUS:-500}"
sleep 3
for i in 1 2 3 4 5; do req "t+$((i))s after expiry"; sleep 1; done
"$EV/down.sh"
