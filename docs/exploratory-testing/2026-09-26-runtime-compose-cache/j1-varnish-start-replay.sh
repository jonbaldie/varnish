#!/bin/bash
# Replay: README's VARNISH_START full-command override on the stock image.
set -u
img=jonbaldie/varnish
echo "## image ENV"; docker image inspect "$img" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep VARNISH_
echo "## 1: VARNISH_START only"
timeout 15 docker run --rm -e VARNISH_START='/usr/sbin/varnishd -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,64m' "$img"; echo "exit=$?"
echo "## 2: VARNISH_START with the image ENV defaults blanked (timeout exit 124 = varnishd still running)"
timeout 8 docker run --rm -e VARNISH_LISTEN= -e VARNISH_VCL= -e VARNISH_STORAGE= -e VARNISH_EXTRA_ARGS= -e VARNISH_START='/usr/sbin/varnishd -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,64m' "$img" 2>&1 | head -2; echo "exit=${PIPESTATUS[0]}"
echo "## 3: same, but bare 'varnishd' (not on the login-shell PATH of user varnish)"
timeout 8 docker run --rm -e VARNISH_LISTEN= -e VARNISH_VCL= -e VARNISH_STORAGE= -e VARNISH_EXTRA_ARGS= -e VARNISH_START='varnishd -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,64m' "$img"; echo "exit=$?"
