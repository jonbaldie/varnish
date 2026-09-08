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

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    if (req.http.Cookie) {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_response {
    # Mutant: applies the static-extension TTL unconditionally, ignoring the
    # origin's freshness. Zero-freshness static assets (max-age=0, s-maxage=0,
    # or an Expires date in the past) are stored as fresh 1-day objects
    # instead of staying hit-for-miss.
    if (bereq.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
        set beresp.ttl = 1d;
        set beresp.grace = 7d;
    } else {
        set beresp.grace = 1h;
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