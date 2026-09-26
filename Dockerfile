FROM debian:bookworm-slim
LABEL maintainer="Jonathan Baldie <jon@jonbaldie.com>"

ADD embedded-default.vcl embedded-default.vcl
ADD cache-policy.vcl cache-policy.vcl
ADD render-vcl.sh render-vcl.sh
ADD install.sh install.sh
RUN chmod +x install.sh render-vcl.sh && sh ./install.sh && rm install.sh embedded-default.vcl cache-policy.vcl render-vcl.sh
RUN chown -R varnish:varnish /etc/varnish /var/lib/varnish

# Keep configuration image-owned so Compose rebuilds pick up updated VCL files.
VOLUME ["/var/lib/varnish"]
EXPOSE 80

ADD start.sh /start.sh
RUN chown varnish:varnish /start.sh && chmod +x /start.sh

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD varnishadm ping || exit 1

USER varnish
CMD ["/start.sh"]
