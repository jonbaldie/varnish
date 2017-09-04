FROM alpine
MAINTAINER Jonathan Baldie "jon@subjectzero.co.uk"

ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh

CMD ["/usr/sbin/varnishd -f /etc/varnish/default.vcl -s malloc,${VARNISH_MEMORY}"]
