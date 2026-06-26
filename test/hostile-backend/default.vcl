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

include "/etc/varnish/cache-policy.vcl";
