#!/bin/bash

apt-get -y update
apt-get -y install varnish=7.*

tee /etc/varnish/default.vcl <<EOF
vcl 4.0;

probe backend_probe {
    .url = "/health";
    .timeout = 2s;
    .interval = 5s;
    .window = 5;
    .threshold = 3;
}

backend default {
    .host = "127.0.0.1";
    .port = "8080";
    .probe = backend_probe;
}

acl purge {
    "localhost";
    "127.0.0.1";
}

sub vcl_recv {
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed"));
        }
        return (purge);
    }

    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(jpg|jpeg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|webm)$") {
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    if (bereq.url ~ "\.(png|gif|jpg|jpeg|svg|css|js|ico|woff|woff2|ttf|eot|otf)$") {
        set beresp.ttl = 1d;
        set beresp.grace = 7d;
    } else {
        set beresp.grace = 1h;
    }

    if (beresp.status >= 500 && beresp.status < 600) {
        set beresp.ttl = 0s;
        set beresp.grace = 24h;
        return (deliver);
    }

    return (deliver);
}
EOF

touch /etc/varnish/secret
