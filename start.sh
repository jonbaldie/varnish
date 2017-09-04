#!/bin/sh

/usr/sbin/varnishd -f /etc/varnish/default.vcl -s malloc,1g
