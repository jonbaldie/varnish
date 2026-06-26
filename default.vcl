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

include "/etc/varnish/cache-policy.vcl";
