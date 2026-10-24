#!/bin/bash
# Variations: (a) PURGE carrying Accept-Encoding: deflate; (b) POST invalidation.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
B=http://127.0.0.1:18824
get(){ printf '%-34s ' "$1"; curl -s -o /dev/null -D - -H "Accept-Encoding: $2" $B/article | grep -iE '^(x-cache|x-origin-n):' | tr -d '\r' | tr '\n' ' '; echo; }
purge(){ docker run --rm --network container:vx24-varnish python:3.13-alpine python -c '
import http.client, sys
c = http.client.HTTPConnection("127.0.0.1", 80)
h = {"Host": "127.0.0.1:18824"}
if sys.argv[1]: h["Accept-Encoding"] = sys.argv[1]
c.request("PURGE", "/article", headers=h)
r = c.getresponse(); print("PURGE AE=%r ->" % sys.argv[1], r.status, r.reason)' "$1"; }
"$EV/up.sh"
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/article&h_Cache-Control=max-age%3D600" >/dev/null
get "fill gzip" gzip; get "fill deflate" deflate
purge deflate
get "after deflate-purge gzip" gzip; get "after deflate-purge deflate" deflate
purge ""
get "after plain purge gzip" gzip; get "after plain purge deflate" deflate
echo "-- (b) POST /article"
curl -s -o /dev/null -w 'POST %{http_code}\n' -X POST $B/article
get "after POST gzip" gzip; get "after POST deflate" deflate
"$EV/down.sh"
