#!/bin/sh

apk update
apk add varnish

tee /etc/varnish/default.vcl <<EOF
vcl 4.0;
#import std;
backend default {
    .host = "127.0.0.1";
    .port = "80";
}
EOF
