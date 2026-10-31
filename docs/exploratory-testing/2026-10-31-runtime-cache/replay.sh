#!/bin/bash
set -euo pipefail
evidence_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$(git -C "$evidence_dir" rev-parse --show-toplevel)"
for name in exp-varnish-20261031 exp-origin-20261031; do
  if docker container inspect "$name" >/dev/null 2>&1; then echo "Container $name already exists" >&2; exit 1; fi
done
if docker network inspect exp-varnish-20261031 >/dev/null 2>&1 || docker image inspect exp-varnish-20261031:local >/dev/null 2>&1; then
  echo 'Replay network or image already exists' >&2; exit 1
fi
trap '"$evidence_dir/cleanup.sh"' EXIT
printf 'Build: '; git rev-parse HEAD
docker build -q -t exp-varnish-20261031:local .
docker network create exp-varnish-20261031 >/dev/null
docker run -d --name exp-origin-20261031 --network exp-varnish-20261031 -v "$PWD/docs/exploratory-testing/2026-10-24-grace-and-purge/origin.py:/origin.py:ro" python:3.13-alpine python /origin.py >/dev/null
printf '\n== preflight valid ==\n'
docker run --rm --network exp-varnish-20261031 -e VARNISH_BACKEND_HOST=exp-origin-20261031 -e VARNISH_BACKEND_PORT=8080 exp-varnish-20261031:local /start.sh --check; echo 'exit=0'
printf '\n== preflight invalid port ==\n'
if docker run --rm --network exp-varnish-20261031 -e VARNISH_LISTEN=0.0.0.0:65536 exp-varnish-20261031:local /start.sh --check; then echo 'unexpected success'; exit 1; else echo 'exit nonzero as expected'; fi
docker run -d --name exp-varnish-20261031 --network exp-varnish-20261031 -p 127.0.0.1::80 -e VARNISH_BACKEND_HOST=exp-origin-20261031 -e VARNISH_BACKEND_PORT=8080 -e VARNISH_STORAGE=malloc,32m exp-varnish-20261031:local >/dev/null
port=$(docker port exp-varnish-20261031 80/tcp | awk -F: '{print $NF}')
url="http://127.0.0.1:$port"
for i in $(seq 1 60); do if curl -fsS "$url/" >/dev/null 2>&1; then break; fi; sleep 1; done
curl -fsS "$url/" >/dev/null
request() { printf '\n-- %s --\n' "$1"; shift; curl -sS -i "$@" | tr -d '\r'; }
printf '\n== static cache and query isolation ==\n'
request static-first -H 'Cookie: session=alice' "$url/static/site.css?v=1&h_Cache-Control=max-age%3D600"
request static-again -H 'Cookie: session=bob' "$url/static/site.css?v=1&h_Cache-Control=max-age%3D600"
request static-other-query -H 'Cookie: session=bob' "$url/static/site.css?v=2&h_Cache-Control=max-age%3D600"
printf '\n== dynamic cookie and authorization isolation ==\n'
request account-alice -H 'Cookie: session=alice' "$url/account?h_Cache-Control=max-age%3D600"
request account-bob -H 'Cookie: session=bob' "$url/account?h_Cache-Control=max-age%3D600"
request auth-alice -H 'Authorization: Bearer alice' "$url/profile?h_Cache-Control=max-age%3D600"
request auth-bob -H 'Authorization: Bearer bob' "$url/profile?h_Cache-Control=max-age%3D600"
printf '\n== unsafe method invalidates same URL ==\n'
request unrelated-prime "$url/unrelated?h_Cache-Control=max-age%3D600"
request unrelated-hit "$url/unrelated?h_Cache-Control=max-age%3D600"
request item-first "$url/item?h_Cache-Control=max-age%3D600"
request item-hit "$url/item?h_Cache-Control=max-age%3D600"
request item-post -X POST "$url/item?h_Cache-Control=max-age%3D600"
request item-after "$url/item?h_Cache-Control=max-age%3D600"
request item-hit-again "$url/item?h_Cache-Control=max-age%3D600"
request unrelated-after "$url/unrelated?h_Cache-Control=max-age%3D600"
printf '\n== preflight refuses command override ==\n'
if docker run --rm -e 'VARNISH_START=varnishd -V' exp-varnish-20261031:local /start.sh --check; then echo 'unexpected success'; exit 1; else echo 'exit nonzero as expected'; fi
