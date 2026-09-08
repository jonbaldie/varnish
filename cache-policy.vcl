acl purge {
    "localhost";
    "127.0.0.1";
    "10.0.0.0"/8;
    "172.16.0.0"/12;
    "192.168.0.0"/16;
}

sub vcl_recv {
    if ((!req.http.host || req.http.host ~ "^[[:space:]]*$") &&
        req.esi_level == 0 &&
        req.proto == "HTTP/1.1") {
        # In HTTP/1.1, Host is required (RFC 9112 §7.1).
        return (synth(400));
    }

    if (req.http.host ~ "[[:upper:]]") {
        set req.http.host = req.http.host.lower();
    }

    if (req.method == "PURGE") {
        if (!client.ip ~ purge) {
            return (synth(405, "Not allowed"));
        }
        return (purge);
    }

    unset req.http.X-Normalized-AE;

    if (req.http.Accept-Encoding) {
        if (req.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
            unset req.http.Accept-Encoding;
        } elsif (req.http.Accept-Encoding ~ "gzip" && req.http.Accept-Encoding !~ "gzip;[ ]*q=0(\.0*)?([,;]|$)") {
            set req.http.Accept-Encoding = "gzip";
            set req.http.X-Normalized-AE = "gzip";
        } elsif (req.http.Accept-Encoding ~ "deflate" && req.http.Accept-Encoding !~ "deflate;[ ]*q=0(\.0*)?([,;]|$)") {
            set req.http.Accept-Encoding = "deflate";
            set req.http.X-Normalized-AE = "deflate";
        } else {
            unset req.http.Accept-Encoding;
        }
    }

    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Requests with Authorization must not be cached or served from cache (RFC 9111 §3.5).
    if (req.http.Authorization) {
        return (pass);
    }

    # Remove cookies for static assets to improve cache hit rate.
    if (req.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
        unset req.http.Cookie;
    }

    if (req.http.Cookie) {
        return (pass);
    }

    return (hash);
}

sub vcl_backend_fetch {
    if (bereq.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
        unset bereq.http.Accept-Encoding;
        unset bereq.http.X-Normalized-AE;
    } elsif (bereq.http.X-Normalized-AE) {
        set bereq.http.Accept-Encoding = bereq.http.X-Normalized-AE;
        unset bereq.http.X-Normalized-AE;
    } else {
        unset bereq.http.Accept-Encoding;
    }
}

sub vcl_backend_response {
    # Responses containing Vary: * must not be cached (RFC 9111 §4.1).
    if (beresp.http.Vary ~ "(^|[,\s])\*([,\s]|$)") {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    # Responses to requests with Authorization must not be stored in shared cache (RFC 9111 §3.5).
    if (bereq.http.Authorization) {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    if (beresp.http.Set-Cookie ||
        beresp.http.Surrogate-Control ~ "(?i)no-store" ||
        (!beresp.http.Surrogate-Control &&
          beresp.http.Cache-Control ~ "(?i:no-cache|no-store|private)")) {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    if (bereq.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
        # Apply the static TTL only when the origin granted positive
        # freshness. Zero freshness (max-age=0, s-maxage=0, or an Expires
        # date in the past) must stay hit-for-miss, as builtin
        # vcl_backend_response would do for beresp.ttl <= 0s (RFC 9111 §5.2).
        if (beresp.ttl > 0s) {
            set beresp.ttl = 1d;
            set beresp.grace = 7d;
        } else {
            set beresp.uncacheable = true;
            set beresp.ttl = 120s;
            return (deliver);
        }
    } else {
        set beresp.grace = 1h;
    }

    if (beresp.status >= 500 && beresp.status < 600) {
        set beresp.ttl = 0s;
        set beresp.grace = 24h;
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
