vcl 4.0;

backend default {
    .host = "web";
    .port = "80";
}

sub vcl_recv {
    # Remove cookies for static assets to improve cache hit rate
    if (req.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$") {
        unset req.http.Cookie;
    }
}

sub vcl_backend_response {
    # Cache static assets for 1 hour
    if (bereq.url ~ "\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$") {
        set beresp.ttl = 1h;
    }
}

sub vcl_deliver {
    # Add a header to indicate cache hits/misses
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
