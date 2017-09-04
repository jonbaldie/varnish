#!/bin/bash

/usr/sbin/varnishd -j unix,user=varnish -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,1g
