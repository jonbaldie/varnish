FROM alpine
MAINTAINER Jonathan Baldie "jon@jonbaldie.com"

ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh
VOLUME ["/var/lib/varnish", "/etc/varnish"]
CMD ["/usr/sbin/varnishd -f /etc/varnish/default.vcl -s malloc,${VARNISH_MEMORY}"]
