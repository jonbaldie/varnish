#!/bin/bash
# Control: same page, but the origin is stopped (connection refused) rather
# than answering 5xx. Also captures varnishlog for the 5xx background fetch.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
B=http://127.0.0.1:18824
req(){ printf '%-28s ' "$1"; curl -s -o "${TMPDIR:-/tmp}/vx24body" -D - "$B$2" | grep -iE '^(x-cache|x-origin-n|age):' | tr -d '\r' | tr '\n' ' '; printf ' code=%s\n' "$(head -c 60 "${TMPDIR:-/tmp}/vx24body" | grep -o '"status": [0-9]*' | cut -d' ' -f2)"; }
"$EV/up.sh"
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/news&h_Cache-Control=max-age%3D2" >/dev/null
req "good page cached" /news
docker stop vx24-origin >/dev/null; echo "-- origin stopped"
sleep 3
for i in 1 2 3 4; do req "t+${i}s after expiry" /news; sleep 1; done
"$EV/down.sh"
echo "##### varnishlog of 5xx background fetch (static asset /site.css)"
"$EV/up.sh"
docker exec -d vx24-varnish sh -c 'varnishlog -g request -b -i BereqURL,BerespStatus,TTL,VCL_call,VCL_return,Begin > /tmp/vlog.txt'
sleep 1
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/site.css&h_Cache-Control=max-age%3D2" >/dev/null
req "static cached" /site.css
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/site.css&status=500&h_Cache-Control=max-age%3D2" >/dev/null
echo "-- origin now answers /site.css with 500"
sleep 3
for i in 1 2 3; do req "t+${i}s" /site.css; sleep 1; done
docker exec vx24-varnish cat /tmp/vlog.txt
"$EV/down.sh"
