import std;

acl purge {
    "localhost";
    "127.0.0.1";
    "::1";
}

sub vcl_recv {
    if (req.esi_level == 0 &&
        req.proto == "HTTP/1.1" &&
        (!req.http.host ||
         req.http.host ~ "^[[:space:]]*$" ||
         req.http.host !~ "(?i)^(?:\[(?:[0-9a-f:.]+|v[0-9a-f]+\.[a-z0-9._~!$&'()*+,;=:-]+)\]|(?:[a-z0-9._~!$&'()*+,;=-]|%[0-9a-f]{2})+)(?::[0-9]*)?$")) {
        # HTTP/1.1 requires a valid Host authority value (RFC 9112 §7.1,
        # RFC 9110 §7.2). Reject userinfo, whitespace, invalid delimiters,
        # and non-numeric ports before cache lookup or backend forwarding.
        return (synth(400));
    }

    if (req.http.host ~ "[[:upper:]]") {
        set req.http.host = req.http.host.lower();
    }

    # The HTTP default port is equivalent to an omitted port (RFC 9110
    # sections 4.2.3 and 7.2). Treat zero-padded and empty port spellings the
    # same way before cache lookup and mutation invalidation.
    if (req.http.host) {
        set req.http.host = regsub(req.http.host, ":0*80$", "");
        set req.http.host = regsub(req.http.host, ":$", "");
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
        } elsif (req.http.Accept-Encoding ~ "(?i)(^|,)[[:space:]]*gzip([[:space:]]*;|[[:space:]]*,|$)" &&
                 req.http.Accept-Encoding !~ "(?i)(^|,)[[:space:]]*gzip[[:space:]]*;[[:space:]]*q[[:space:]]*=[[:space:]]*0(\.0*)?([[:space:]]*[,;]|$)") {
            set req.http.Accept-Encoding = "gzip";
            set req.http.X-Normalized-AE = "gzip";
        } elsif (req.http.Accept-Encoding ~ "(?i)(^|,)[[:space:]]*deflate([[:space:]]*;|[[:space:]]*,|$)" &&
                 req.http.Accept-Encoding !~ "(?i)(^|,)[[:space:]]*deflate[[:space:]]*;[[:space:]]*q[[:space:]]*=[[:space:]]*0(\.0*)?([[:space:]]*[,;]|$)") {
            set req.http.Accept-Encoding = "deflate";
            set req.http.X-Normalized-AE = "deflate";
        # A wildcard accepts any available coding not explicitly listed
        # (RFC 9110 §12.5.3). Prefer gzip unless it or the wildcard is q=0.
        } elsif (req.http.Accept-Encoding ~ "(?i)(^|,)[[:space:]]*\*[[:space:]]*(;|,|$)" &&
                 req.http.Accept-Encoding !~ "(?i)(^|,)[[:space:]]*\*[[:space:]]*;[[:space:]]*q[[:space:]]*=[[:space:]]*0(\.0*)?([[:space:]]*[,;]|$)" &&
                 req.http.Accept-Encoding !~ "(?i)(^|,)[[:space:]]*gzip[[:space:]]*;[[:space:]]*q[[:space:]]*=[[:space:]]*0(\.0*)?([[:space:]]*[,;]|$)") {
            set req.http.Accept-Encoding = "gzip";
            set req.http.X-Normalized-AE = "gzip";
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

# RFC 9111 §4.4: a successful unsafe response must also invalidate any URI
# referenced in its Location or Content-Location header. The reference is
# passed in beresp.http.X-Varnish-Cache-Ref and resolved against the cache
# identity (host + URL) used by the ban above. Multi-valued fields (Varnish
# joins repeats with ", ") and scheme-relative ("//host/path") or
# relative-without-slash references are skipped: they cannot be resolved to
# a single cache identity safely in VCL.
sub invalidate_reference {
    if (beresp.http.X-Varnish-Cache-Ref ~ "(?i)^https?://[^/?#]+") {
        # Absolute reference: the authority is the cache host identity
        # (including empty and zero-padded spellings), and the path with
        # query, minus any fragment, is the cache URL identity.
        set beresp.http.X-Varnish-Cache-Ref-Host =
            regsub(beresp.http.X-Varnish-Cache-Ref, "(?i)^https?://", "");
        set beresp.http.X-Varnish-Cache-Ref-Host =
            regsub(beresp.http.X-Varnish-Cache-Ref-Host, "[/?#].*$", "");
        if (beresp.http.X-Varnish-Cache-Ref ~ "(?i)^https://") {
            set beresp.http.X-Varnish-Cache-Ref-Host =
                regsub(beresp.http.X-Varnish-Cache-Ref-Host, ":0*443$", "");
            set beresp.http.X-Varnish-Cache-Ref-Host =
                regsub(beresp.http.X-Varnish-Cache-Ref-Host, ":$", "");
        } else {
            set beresp.http.X-Varnish-Cache-Ref-Host =
                regsub(beresp.http.X-Varnish-Cache-Ref-Host, ":0*80$", "");
            set beresp.http.X-Varnish-Cache-Ref-Host =
                regsub(beresp.http.X-Varnish-Cache-Ref-Host, ":$", "");
        }
        set beresp.http.X-Varnish-Cache-Ref-URL =
            regsub(beresp.http.X-Varnish-Cache-Ref, "(?i)^https?://[^/?#]+", "");
        set beresp.http.X-Varnish-Cache-Ref-URL =
            regsub(beresp.http.X-Varnish-Cache-Ref-URL, "#.*$", "");
        # An authority-only reference has an empty path; an empty-path
        # reference with a query uses "/" as its effective path. Prefix the
        # slash so either form keeps any query in the cache URL identity.
        if (beresp.http.X-Varnish-Cache-Ref-URL !~ "^/") {
            set beresp.http.X-Varnish-Cache-Ref-URL =
                "/" + beresp.http.X-Varnish-Cache-Ref-URL;
        }
        set beresp.http.X-Varnish-Cache-Ref-Host =
            std.tolower(beresp.http.X-Varnish-Cache-Ref-Host);
    } elsif (beresp.http.X-Varnish-Cache-Ref ~ "^/" &&
             beresp.http.X-Varnish-Cache-Ref !~ "^//") {
        # Same-host relative reference: the cache host identity is the
        # request's own host, already normalized in vcl_recv.
        set beresp.http.X-Varnish-Cache-Ref-Host = bereq.http.host;
        set beresp.http.X-Varnish-Cache-Ref-URL =
            regsub(beresp.http.X-Varnish-Cache-Ref, "#.*$", "");
    }

    # The ban expression parser treats horizontal whitespace as token
    # separators. Encode HTAB and spaces so references match request URLs.
    set beresp.http.X-Varnish-Cache-Ref-URL =
        regsuball(beresp.http.X-Varnish-Cache-Ref-URL, "\t", "%09");
    set beresp.http.X-Varnish-Cache-Ref-URL =
        regsuball(beresp.http.X-Varnish-Cache-Ref-URL, " ", "%20");

    # Only a reference sharing the request's host identity may invalidate:
    # the cache has no authority over other hosts' entries.
    if (beresp.http.X-Varnish-Cache-Ref-Host == bereq.http.host) {
        ban("obj.http.X-Varnish-Cache-Host == " + bereq.http.host +
            " && obj.http.X-Varnish-Cache-URL == " + beresp.http.X-Varnish-Cache-Ref-URL);
    }

    unset beresp.http.X-Varnish-Cache-Ref;
    unset beresp.http.X-Varnish-Cache-Ref-Host;
    unset beresp.http.X-Varnish-Cache-Ref-URL;
}

sub vcl_backend_response {
    # Keep the normalized cache identity on the object so a successful
    # unsafe request can invalidate every variant for this exact host and URL.
    set beresp.http.X-Varnish-Cache-Host = bereq.http.host;
    set beresp.http.X-Varnish-Cache-URL = bereq.url;

    # A pass only bypasses lookup for the unsafe request. RFC 9111 §4.4
    # requires invalidation for all unsafe methods, which RFC 9110 §9.2.1
    # defines as every method except GET, HEAD, OPTIONS, and TRACE.
    if (bereq.method !~ "^(GET|HEAD|OPTIONS|TRACE)$" && beresp.status < 400) {
        ban("obj.http.X-Varnish-Cache-Host == " + bereq.http.host +
            " && obj.http.X-Varnish-Cache-URL == " + bereq.url);

        if (beresp.http.Location && beresp.http.Location !~ ", ") {
            set beresp.http.X-Varnish-Cache-Ref = beresp.http.Location;
            call invalidate_reference;
        }

        if (beresp.http.Content-Location && beresp.http.Content-Location !~ ", ") {
            set beresp.http.X-Varnish-Cache-Ref = beresp.http.Content-Location;
            call invalidate_reference;
        }
    }

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

    # Surrogate-Control (W3C Edge Architecture §4.2) controls storage for
    # surrogates: no-store/no-cache and zero max-age (with or without a +N
    # freshness extension) prohibit storage, while a positive max-age overrides
    # Cache-Control. Other values — including the ESI capability advertisement
    # content="ESI/1.0" or OFF — leave Cache-Control no-cache/no-store/private
    # directives in force.
    if (beresp.http.Set-Cookie ||
        beresp.http.Surrogate-Control ~ "(?i:no-store|no-cache)" ||
        beresp.http.Surrogate-Control ~ "(?i)(?:^|[,;\s])\s*max-age\s*=\s*0+(?:\+[0-9]+)?(?:\s*[,;\s]|$)" ||
        (beresp.http.Surrogate-Control !~ "(?i)(?:^|[,;\s])\s*max-age\s*=\s*0*[1-9][0-9]*" &&
          beresp.http.Cache-Control ~ "(?i:no-cache|no-store|private)")) {
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    # Positive Surrogate-Control freshness takes precedence over Cache-Control,
    # Expires, and the static-asset TTL policy (W3C Edge Architecture §4.2).
    # The optional +N freshness extension is an explicit stale-serving window;
    # without it, stale objects must be refetched immediately.
    if (beresp.http.Surrogate-Control ~ "(?i)(?:^|[,;\s])\s*max-age\s*=\s*0*[1-9][0-9]*") {
        set beresp.ttl = std.duration(
            regsub(beresp.http.Surrogate-Control,
                "(?i).*(?:^|[,;\s])\s*max-age\s*=\s*([0-9]+)(?:\+([0-9]+))?.*",
                "\1s"),
            0s);
        set beresp.grace = std.duration(
            regsub(beresp.http.Surrogate-Control,
                "(?i).*(?:^|[,;\s])\s*max-age\s*=\s*([0-9]+)(?:\+([0-9]+))?.*",
                "0\2s"),
            0s);
    } else {
        # An Expires value that is not a valid HTTP-date means already expired
        # (RFC 9111 §5.3). That includes "0", "-1", unparseable strings, and
        # HTTP-dates whose month, day, time, or day-of-week is invalid — for
        # example "Thu, 01 Foo 2026 00:00:00 GMT" or "Sun, 01 Jan 2026
        # 00:00:00 GMT" (1 Jan 2026 was a Thursday). A character-class shape
        # check accepts those tokens, so Varnish's parser must decide.
        # RFC2616_Ttl treats a parse failure as an absent header and falls
        # back to default_ttl. It also leaves the TTL untouched when a valid
        # Expires date parses to 0, which is every Unix Epoch HTTP-date.
        # std.time uses that same parser and returns the fallback both for a
        # failure and for the epoch. Two different fallbacks tell failure
        # apart from a valid date that happens to equal one sentinel.
        # Cache-Control max-age/s-maxage overrides Expires entirely (RFC 9111
        # §5.3), so either directive skips this check. Apply it to every URL,
        # not just static ones.
        if (beresp.http.Expires &&
            beresp.http.Cache-Control !~ "(?i)(?:^|[,;\s])\s*(?:max-age|s-maxage)\s*=" &&
            std.time(beresp.http.Expires, now) == now &&
            std.time(beresp.http.Expires, std.time("Thu, 01 Jan 1970 00:00:01 GMT", now)) == std.time("Thu, 01 Jan 1970 00:00:01 GMT", now)) {
            set beresp.uncacheable = true;
            set beresp.ttl = 120s;
            return (deliver);
        }

        if (bereq.url ~ "(?i)^[^?]*\.(css|js|png|jpg|jpeg|gif|ico|svg|webp|avif|woff|woff2|ttf|eot|otf|mp3|ogg|webm|gz|tgz|bz2|tbz)(\?|$)") {
            # Apply the static TTL only when the origin granted positive
            # freshness. Zero freshness (max-age=0, s-maxage=0, or an Expires
            # date in the past) must stay hit-for-miss, as builtin
            # vcl_backend_response would do for beresp.ttl <= 0s (RFC 9111 §5.2).
            # An invalid Expires is already handled above.
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
    }

    if (beresp.status >= 500 && beresp.status < 600) {
        set beresp.ttl = 0s;
        set beresp.grace = 24h;
    }

    # RFC 9111 §5.2.2.2, §5.2.2.8, §5.2.2.10: Stale responses must not be served
    # without origin revalidation when prohibited by must-revalidate or
    # proxy-revalidate (or s-maxage, which implies proxy-revalidate). A positive
    # Surrogate-Control max-age supersedes Cache-Control for this surrogate.
    # Setting grace=0 forces synchronous revalidation and returns 503 if the
    # origin is unavailable.
    if (beresp.http.Surrogate-Control !~ "(?i)(?:^|[,;\s])\s*max-age\s*=\s*0*[1-9][0-9]*" &&
        beresp.http.Cache-Control ~ "(?i)(?:^|[,;\s])\s*(?:(?:must-revalidate|proxy-revalidate)(?:$|[,;\s])|s-maxage\s*=)") {
        set beresp.grace = 0s;
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
