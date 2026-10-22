#!/bin/bash

apt-get -y update
apt-get -y install varnish=7.*

install -m 755 render-vcl.sh /usr/local/bin/render-vcl
cp embedded-default.vcl /etc/varnish/default.vcl
cp cache-policy.vcl /etc/varnish/cache-policy.vcl
/usr/local/bin/render-vcl /etc/varnish/backend.vcl

touch /etc/varnish/secret
