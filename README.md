### Varnish Docker Repository

[![Docker CI](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml/badge.svg)](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml)

To use:

`docker pull jonbaldie/varnish`

Alternatively you can `git clone` the repo and run `make` from the project root.

### What is Varnish?

It's basically Redis for HTTP requests.

Instead of serving identical HTTP requests, eating up resources and bandwidth, Varnish caches requests for as long you like.

Just put it in front of your HTTP server, and it will intercept all HTTP requests.

It's one of the simplest ways to make your website faster.

### How does it work?

Expose Varnish on port 80, and point it to your web server using a `vcl` config file. See the Varnish docs (and Google) for details on how to do this.

For this Docker image, you can `ADD` your `default.vcl` file into `/etc/varnish/` inside the container. For my own setup I use Docker Compose with mounted volumes, which means any edits I make don't mean I have to rebuild the container.

### Docker Compose example

This repository includes a `docker-compose.yml` file and a sample `default.vcl` that demonstrates a typical setup:

- `varnish` service running this image on port 80, with the VCL file mounted from the host.
- `web` backend service running the official `nginx:alpine` image.

To try it out, run:

```bash
docker compose up
```

The sample `default.vcl` points Varnish to the `web` backend and adds basic caching rules for static assets.

### What about SSL?

Unfortunately Varnish doesn't understand HTTPS requests, so you have to do some creative rerouting of requests to make it work. This is how I do it in my setup:

HTTPS request ==> Nginx container port 443 ==> Varnish container port 80 ==> Nginx port 80 (internal) ==> Website.

HTTP request ==> Varnish container port 80 ==> Nginx port 80 (internal) ==> Website.

This may look ugly, but fortunately with Docker networking this is surprisingly easy to set up, and very performant.

(c) 2017 Jonathan Baldie
