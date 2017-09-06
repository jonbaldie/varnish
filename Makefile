build:
	- docker build -t jonbaldie/varnish:latest .

test:
	- docker run jonbaldie/varnish which varnishd | grep '/usr/sbin/varnishd'
	- docker run jonbaldie/varnish [ -f /etc/varnish/default.vcl ] && echo 'ok' | grep 'ok'
	- docker run jonbaldie/varnish [ -f /start.sh ] && echo 'ok' | grep 'ok'

