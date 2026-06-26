#!/bin/bash

apt-get -y update
apt-get -y install varnish=7.*

install -m 755 render-vcl.sh /usr/local/bin/render-vcl
cp embedded-default.vcl /etc/varnish/default.vcl
cp cache-policy.vcl /etc/varnish/cache-policy.vcl
VARNISH_BACKEND_HOST=127.0.0.1 \
VARNISH_BACKEND_PORT=8080 \
VARNISH_BACKEND_PROBE_PATH=/ \
	/usr/local/bin/render-vcl /etc/varnish/backend.vcl

touch /etc/varnish/secret
