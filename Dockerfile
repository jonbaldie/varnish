FROM debian:bookworm-slim
LABEL maintainer="Jonathan Baldie <jon@jonbaldie.com>"

ADD default.vcl default.vcl
ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh default.vcl
RUN chown -R varnish:varnish /etc/varnish /var/lib/varnish

VOLUME ["/var/lib/varnish", "/etc/varnish"]
EXPOSE 80

ENV VARNISH_START="/usr/sbin/varnishd -F -f /etc/varnish/default.vcl -a 0.0.0.0:80 -s malloc,1g"
ADD start.sh /start.sh
RUN chown varnish:varnish /start.sh && chmod +x /start.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD varnishadm ping || exit 1

USER varnish
CMD ["/start.sh"]
