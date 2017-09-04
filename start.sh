#!/bin/sh

/usr/sbin/varnishd -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,1g
