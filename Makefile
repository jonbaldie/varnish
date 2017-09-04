build:
	- docker build -t jonbaldie/varnish .

test:
	- docker run jonbaldie/varnish which varnishd | grep '/usr/sbin/varnishd'
	- docker run jonbaldie/varnish [ -f /etc/varnish/default.vcl ] && echo 'ok' | grep 'ok'

