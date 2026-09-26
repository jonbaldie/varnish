#!/bin/bash
# Replay: compose `up -d --build` does not apply changed image files under /etc/varnish.
set -u
cd "$1"
chk(){ echo "X-Image-Build header count: $(curl -s -o /dev/null -D - localhost:18582/ | grep -ci x-image-build)"; }
docker compose -p vxc down -v >/dev/null 2>&1
git -C "$2" show HEAD:embedded-default.vcl > embedded-default.vcl
echo "## step 1: docker compose up -d --build (stock image)"; docker compose -p vxc up -d --build >/dev/null 2>&1; sleep 8; chk
printf '\nsub vcl_deliver {\n    set resp.http.X-Image-Build = "v2";\n}\n' >> embedded-default.vcl
echo "## step 2: change embedded-default.vcl, docker compose up -d --build (README workflow)"; docker compose -p vxc up -d --build >/dev/null 2>&1; sleep 8; chk
echo "container default.vcl md5: $(docker compose -p vxc exec -T varnish md5sum /etc/varnish/default.vcl)"
echo "image     default.vcl md5: $(docker run --rm --entrypoint md5sum jonbaldie/varnish /etc/varnish/default.vcl)"
echo "## step 3: docker compose down && up -d"; docker compose -p vxc down >/dev/null 2>&1; docker compose -p vxc up -d >/dev/null 2>&1; sleep 8; chk
