FROM debian:bookworm-slim
LABEL maintainer="Jonathan Baldie <jon@jonbaldie.com>"

ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh

VOLUME ["/var/lib/varnish", "/etc/varnish"]
EXPOSE 80

ENV VARNISH_START /usr/sbin/varnishd -j unix,user=varnish -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,1g
ADD start.sh /start.sh
RUN chmod +x /start.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD pidof varnishd || exit 1

CMD ["/start.sh"]
