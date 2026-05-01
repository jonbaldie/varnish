vcl 4.0;

probe backend_probe {
    .url = "/ready";
    .timeout = 1s;
    .interval = 2s;
    .window = 3;
    .threshold = 2;
}

backend default {
    .host = "hostile-backend";
    .port = "8080";
    .probe = backend_probe;
}

acl purge {
    "localhost";
    "127.0.0.1";
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {
    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed"));
        }
        return (purge);
    }

    if (req.http.Accept-Encoding) {
        if (req.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)$") {
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip") {
            set req.http.Accept-Encoding = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate") {
            set req.http.Accept-Encoding = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    if (req.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)$") {
        unset req.http.Cookie;
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    if (req.http.Cookie) {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    if (bereq.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)$") {
        set beresp.ttl = 1d;
        set beresp.grace = 7d;
    } else {
        set beresp.ttl = 0s;
        set beresp.uncacheable = true;
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
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
