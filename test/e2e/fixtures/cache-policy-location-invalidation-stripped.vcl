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

    return (hash);
}

sub vcl_backend_response {
    set beresp.http.X-Varnish-Cache-Host = bereq.http.host;
    set beresp.http.X-Varnish-Cache-URL = bereq.url;

    # Mutant: invalidates only the target URI. Location and
    # Content-Location referenced URIs (RFC 9111 §4.4) stay cached.
    if (bereq.method ~ "^(POST|PUT|DELETE|PATCH)$" && beresp.status < 400) {
        ban("obj.http.X-Varnish-Cache-Host == " + bereq.http.host +
            " && obj.http.X-Varnish-Cache-URL == " + bereq.url);
    }

    return (deliver);
}

sub vcl_deliver {
    unset resp.http.X-Varnish-Cache-Host;
    unset resp.http.X-Varnish-Cache-URL;

    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
