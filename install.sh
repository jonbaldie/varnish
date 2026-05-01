#!/bin/bash

apt-get -y update
apt-get -y install varnish=7.*

cp default.vcl /etc/varnish/default.vcl
sed -i 's/\.host = "web";/.host = "127.0.0.1";/' /etc/varnish/default.vcl
sed -i 's/\.port = "80";/.port = "8080";/' /etc/varnish/default.vcl

touch /etc/varnish/secret
