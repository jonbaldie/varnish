#!/bin/bash
# Replay the three confirmed failures from clean containers.
# Usage: ./replay.sh <image> <outdir>
set -u
IMG="${1:?image}"
OUT="${2:?outdir}"
ROOT="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"

wait_ready() {
  local name="$1"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if docker exec "$name" varnishadm ping >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.5
  done
  echo "FAIL: $name did not become ready" >&2
  docker logs "$name" >&2 || true
  return 1
}

cleanup_names() {
  docker rm -f "$@" >/dev/null 2>&1 || true
}

summarize() {
  local file="$1"
  grep -Ei '^(HTTP/|X-Cache:|Content-Encoding:|Content-Length:|Location:|Content-Location:|X-Origin-AE:|Age:)' "$file" || true
}

replay_encoding() {
  local n="$1"
  local net="vx-et-a87f-enc-$n"
  local origin="vx-et-a87f-enc-origin-$n"
  local varnish="vx-et-a87f-enc-varnish-$n"
  local port=$((18820 + n))
  local dir="$OUT/encoding-$n"
  mkdir -p "$dir"
  docker network create "$net" >/dev/null
  docker run -d --name "$origin" --network "$net" -v "$ROOT/origin-app.py:/origin-app.py:ro" python:3.12-alpine python /origin-app.py >/dev/null
  docker run -d --name "$varnish" --network "$net" -p "$port:80" \
    -e VARNISH_BACKEND_HOST="$origin" -e VARNISH_BACKEND_PORT=8080 -e VARNISH_BACKEND_PROBE_PATH=/health \
    "$IMG" >/dev/null
  wait_ready "$varnish"
  docker exec -i "$origin" python - <<'PY'
import json, urllib.request
payload = json.dumps({
    "path": "/article",
    "status": 200,
    "body": "article-plain-text",
    "negotiate": "encoding",
    "headers": {"Content-Type": "text/html; charset=utf-8", "Cache-Control": "max-age=120"},
}).encode()
print(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8080/__control", data=payload, method="POST")).read().decode())
PY
  curl -sS -D "$dir/deflate.hdr" -o "$dir/deflate.body" -H 'Accept-Encoding: deflate' "http://127.0.0.1:$port/article"
  curl -sS -D "$dir/gzip.hdr" -o "$dir/gzip.body" -H 'Accept-Encoding: gzip' "http://127.0.0.1:$port/article"
  curl -sS -D "$dir/identity.hdr" -o "$dir/identity.body" -H 'Accept-Encoding: identity' "http://127.0.0.1:$port/article"
  curl -sS -D "$dir/browser.hdr" -o "$dir/browser.body" -H 'Accept-Encoding: gzip, deflate, br' "http://127.0.0.1:$port/article"
  python3 - "$dir" <<'PY'
import pathlib, sys, gzip, zlib
d = pathlib.Path(sys.argv[1])
print(f"encoding run files in {d.name}")
for name in ("deflate", "gzip", "identity", "browser"):
    hdr = (d / f"{name}.hdr").read_text(errors="replace")
    body = (d / f"{name}.body").read_bytes()
    encoding = next((line.split(":",1)[1].strip() for line in hdr.splitlines() if line.lower().startswith("content-encoding:")), "")
    cache = next((line.split(":",1)[1].strip() for line in hdr.splitlines() if line.lower().startswith("x-cache:")), "")
    kind = "raw"
    try:
        gzip.decompress(body)
        kind = "gzip"
    except Exception:
        try:
            zlib.decompress(body)
            kind = "deflate"
        except Exception:
            kind = "plain" if body.startswith(b"article-") else "unknown"
    print(f"  {name}: cache={cache} content-encoding={encoding or '-'} body={kind} len={len(body)}")
PY
  cleanup_names "$varnish" "$origin"
  docker network rm "$net" >/dev/null
}

replay_relative() {
  local n="$1"
  local net="vx-et-a87f-rel-$n"
  local origin="vx-et-a87f-rel-origin-$n"
  local varnish="vx-et-a87f-rel-varnish-$n"
  local port=$((18830 + n))
  local dir="$OUT/relative-$n"
  mkdir -p "$dir"
  docker network create "$net" >/dev/null
  docker run -d --name "$origin" --network "$net" -v "$ROOT/origin-app.py:/origin-app.py:ro" python:3.12-alpine python /origin-app.py >/dev/null
  docker run -d --name "$varnish" --network "$net" -p "$port:80" \
    -e VARNISH_BACKEND_HOST="$origin" -e VARNISH_BACKEND_PORT=8080 -e VARNISH_BACKEND_PROBE_PATH=/health \
    "$IMG" >/dev/null
  wait_ready "$varnish"
  docker exec -i "$origin" python - <<'PY'
import json, urllib.request
def store(path, status, body, headers):
    payload = json.dumps({"path": path, "status": status, "body": body, "headers": headers}).encode()
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8080/__control", data=payload, method="POST")).read()
store("/dir/item", 200, "dir-item-v1", {"Content-Type": "text/plain", "Cache-Control": "max-age=300"})
store("/dir/mutate", 201, "created", {"Content-Type": "text/plain", "Location": "item"})
store("/dir/mutate-cl", 201, "created", {"Content-Type": "text/plain", "Content-Location": "item"})
store("/dir/mutate-abs", 201, "created", {"Content-Type": "text/plain", "Location": "/dir/item"})
print("stored")
PY
  base="http://127.0.0.1:$port"
  curl -sS -D "$dir/get1.hdr" -o /dev/null "$base/dir/item"
  curl -sS -D "$dir/get2.hdr" -o /dev/null "$base/dir/item"
  curl -sS -D "$dir/post-rel.hdr" -o /dev/null -X POST "$base/dir/mutate" --data x
  curl -sS -D "$dir/after-rel.hdr" -o /dev/null "$base/dir/item"
  curl -sS -D "$dir/post-cl.hdr" -o /dev/null -X POST "$base/dir/mutate-cl" --data x
  curl -sS -D "$dir/after-cl.hdr" -o /dev/null "$base/dir/item"
  curl -sS -D "$dir/post-abs.hdr" -o /dev/null -X POST "$base/dir/mutate-abs" --data x
  curl -sS -D "$dir/after-abs.hdr" -o /dev/null "$base/dir/item"
  echo "relative run $n"
  for step in get1 get2 post-rel after-rel post-cl after-cl post-abs after-abs; do
    echo "  $step: $(grep -Ei '^(HTTP/|X-Cache:|Location:|Content-Location:)' "$dir/$step.hdr" | tr '\n' ' ')"
  done
  cleanup_names "$varnish" "$origin"
  docker network rm "$net" >/dev/null
}

replay_check() {
  local n="$1"
  local dir="$OUT/check-$n"
  mkdir -p "$dir"
  echo "check run $n"
  docker run --rm --name "vx-et-a87f-check-storage-$n" -e VARNISH_STORAGE=notastorage,1g "$IMG" /start.sh --check >"$dir/storage-check.out" 2>"$dir/storage-check.err"
  echo "  storage --check exit=$?"
  docker run --rm --name "vx-et-a87f-start-storage-$n" -e VARNISH_STORAGE=notastorage,1g "$IMG" >"$dir/storage-start.out" 2>"$dir/storage-start.err"
  echo "  storage start exit=$?"
  echo "  storage start stderr: $(head -2 "$dir/storage-start.err" | tr '\n' ' ')"
  docker run --rm --name "vx-et-a87f-check-extra-$n" -e VARNISH_EXTRA_ARGS='--not-a-real-flag' "$IMG" /start.sh --check >"$dir/extra-check.out" 2>"$dir/extra-check.err"
  echo "  extra --check exit=$?"
  docker run --rm --name "vx-et-a87f-start-extra-$n" -e VARNISH_EXTRA_ARGS='--not-a-real-flag' "$IMG" >"$dir/extra-start.out" 2>"$dir/extra-start.err"
  echo "  extra start exit=$?"
  echo "  extra start stderr: $(grep -E 'invalid option|Error' "$dir/extra-start.err" | head -1)"
}

echo "image=$IMG"
docker image inspect "$IMG" --format 'id={{.Id}} created={{.Created}}'
for n in 1 2 3; do
  echo "========== iteration $n =========="
  replay_encoding "$n"
  replay_relative "$n"
  replay_check "$n"
done
