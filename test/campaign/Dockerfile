FROM jonbaldie/varnish

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-minimal \
    curl \
    procps \
    netcat-openbsd \
    shellcheck \
    iproute2 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /campaign

# Ensure varnish directories are accessible
RUN chown -R varnish:varnish /etc/varnish /var/lib/varnish /campaign

CMD ["/bin/bash", "/campaign/entrypoint.sh"]
