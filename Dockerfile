FROM debian
MAINTAINER Jonathan Baldie "jon@jonbaldie.com"

ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh

VOLUME ["/var/lib/varnish", "/etc/varnish"]
EXPOSE 80

ADD start.sh /start.sh
RUN chmod +x /start.sh

CMD ["/start.sh"]
