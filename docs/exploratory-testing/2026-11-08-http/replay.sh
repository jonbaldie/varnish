#!/bin/bash
set -euo pipefail
evidence_dir="$(cd "$(dirname "$0")" && pwd)"
cd "$(git -C "$evidence_dir" rev-parse --show-toplevel)"
name=exp-varnish-20261108
for resource in "$name" exp-origin-20261108 exp-check-20261108; do
  if docker container inspect "$resource" >/dev/null 2>&1; then echo "Container already exists: $resource" >&2; exit 1; fi
done
if docker network inspect "$name" >/dev/null 2>&1 || docker image inspect "$name:local" >/dev/null 2>&1; then
  echo 'Network or image already exists' >&2; exit 1
fi
trap 'bash "$evidence_dir/cleanup.sh"' EXIT
printf 'Build: '; git rev-parse HEAD
docker build -q -t "$name:local" .
docker network create "$name" >/dev/null
docker run -d --name exp-origin-20261108 --network "$name" -v "$PWD/docs/exploratory-testing/2026-10-24-grace-and-purge/origin.py:/origin.py:ro" python:3.13-alpine python /origin.py >/dev/null
printf '\n== preflight valid ==\n'
docker run --rm --name exp-check-20261108 --network "$name" -e VARNISH_BACKEND_HOST=exp-origin-20261108 -e VARNISH_BACKEND_PORT=8080 "$name:local" /start.sh --check
printf '\n== preflight invalid listener ==\n'
if docker run --rm --name exp-check-20261108 --network "$name" -e VARNISH_LISTEN=0.0.0.0:65536 "$name:local" /start.sh --check; then echo 'unexpected success'; exit 1; else echo 'rejected as expected'; fi
docker run -d --name "$name" --network "$name" -p 127.0.0.1::80 -e VARNISH_BACKEND_HOST=exp-origin-20261108 -e VARNISH_BACKEND_PORT=8080 -e VARNISH_STORAGE=malloc,32m "$name:local" >/dev/null
port=$(docker port "$name" 80/tcp | awk -F: '{print $NF}')
url="http://127.0.0.1:$port"
for i in $(seq 1 60); do if curl -fsS "$url/" >/dev/null 2>&1; then break; fi; sleep 1; done
curl -fsS "$url/" >/dev/null
request() { printf '\n-- %s --\n' "$1"; shift; curl -sS -i "$@" | tr -d '\r'; }
printf '\n== cache varies by language ==\n'
request en-first -H 'Accept-Language: en' "$url/article?h_Cache-Control=max-age%3D600&h_Vary=Accept-Language"
request en-again -H 'Accept-Language: en' "$url/article?h_Cache-Control=max-age%3D600&h_Vary=Accept-Language"
request fr-first -H 'Accept-Language: fr' "$url/article?h_Cache-Control=max-age%3D600&h_Vary=Accept-Language"
request fr-again -H 'Accept-Language: fr' "$url/article?h_Cache-Control=max-age%3D600&h_Vary=Accept-Language"
request en-return -H 'Accept-Language: en' "$url/article?h_Cache-Control=max-age%3D600&h_Vary=Accept-Language"
printf '\n== no-store static asset ==\n'
request no-store-first "$url/static/private.css?h_Cache-Control=no-store"
request no-store-again "$url/static/private.css?h_Cache-Control=no-store"
printf '\n== mutation invalidates only its target ==\n'
request target-first "$url/item?h_Cache-Control=max-age%3D600"
request target-hit "$url/item?h_Cache-Control=max-age%3D600"
request other-first "$url/other?h_Cache-Control=max-age%3D600"
request other-hit "$url/other?h_Cache-Control=max-age%3D600"
request target-post -X POST "$url/item?h_Cache-Control=max-age%3D600"
request target-after "$url/item?h_Cache-Control=max-age%3D600"
request target-rehit "$url/item?h_Cache-Control=max-age%3D600"
request other-after "$url/other?h_Cache-Control=max-age%3D600"
