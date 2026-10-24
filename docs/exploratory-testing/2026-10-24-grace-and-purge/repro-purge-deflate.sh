#!/bin/bash
# Operator updates /article at origin and PURGEs it from inside the container
# (an allowed localhost client). Every client should then get fresh content.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
B=http://127.0.0.1:18824
"$EV/up.sh"
get(){ printf '%-34s ' "$1"; curl -s -o /dev/null -D - -H "Accept-Encoding: $2" $B/article | grep -iE '^(x-cache|x-origin-n):' | tr -d '\r' | tr '\n' ' '; echo; }
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/article&h_Cache-Control=max-age%3D600" >/dev/null
for ae in gzip deflate identity; do get "fill AE=$ae" $ae; get "repeat AE=$ae" $ae; done
echo "-- PURGE from host via published port (expected: denied)"
curl -s -o /dev/null -w '%{http_code}\n' -X PURGE $B/article
echo "-- PURGE from inside the container (localhost)"
docker run --rm --network container:vx24-varnish python:3.13-alpine python -c '
import http.client
c = http.client.HTTPConnection("127.0.0.1", 80)
c.request("PURGE", "/article", headers={"Host": "127.0.0.1:18824"})
r = c.getresponse(); print(r.status, r.reason)'
for ae in gzip deflate identity; do get "after purge AE=$ae" $ae; done
"$EV/down.sh"
