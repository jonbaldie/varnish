build:
	- docker build -t jonbaldie:varnish .

test:
	- docker run jonbaldie:varnish which varnishd | grep '/usr/sbin/varnishd'

