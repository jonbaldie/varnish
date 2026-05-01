vcl 4.0;

probe backend_probe {
    .url = "/";
    .timeout = 2s;
    .interval = 5s;
    .window = 5;
    .threshold = 3;
}

backend default {
    .host = "web";
    .port = "80";
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

    # Remove cookies for static assets to improve cache hit rate
    if (req.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$") {
        unset req.http.Cookie;
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

sub vcl_deliver {
    # Add a header to indicate cache hits/misses
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
