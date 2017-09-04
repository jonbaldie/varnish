FROM alpine
MAINTAINER Jonathan Baldie "jon@jonbaldie.com"

ADD install.sh install.sh
RUN chmod +x install.sh && sh ./install.sh && rm install.sh
ADD start.sh start.sh
RUN chmod +x start.sh

VOLUME ["/var/lib/varnish", "/etc/varnish"]

CMD ["./start.sh"]
