#!/bin/bash
# varnishlog of the background fetch that replaces a graced /news with a 500.
set -u
EV=$(cd "$(dirname "$0")" && pwd)
B=http://127.0.0.1:18824
"$EV/up.sh"
docker exec -d vx24-varnish sh -c 'varnishlog -b -q "BereqURL ~ news" -i Begin,BereqURL,BerespStatus,TTL,VCL_call,VCL_return > /tmp/vlog.txt'
sleep 1
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/news&h_Cache-Control=max-age%3D2" >/dev/null
curl -s -o /dev/null -w 'cache fill %{http_code}\n' $B/news
docker exec vx24-origin wget -qO- "http://127.0.0.1:8080/__set?path=/news&status=500&h_Cache-Control=max-age%3D2" >/dev/null
sleep 3
for i in 1 2 3; do curl -s -o /dev/null -w "after expiry #$i %{http_code}\n" $B/news; sleep 1; done
sleep 1; docker exec vx24-varnish cat /tmp/vlog.txt
"$EV/down.sh"
