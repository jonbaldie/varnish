### Varnish Docker Repository

[![Docker CI](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml/badge.svg)](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml)

To use:

`docker pull jonbaldie/varnish`

Alternatively you can `git clone` the repo and run `make` from the project root.

### Version Matrix

| Debian Version | Varnish Version |
|----------------|-----------------|
| bookworm       | 7.1.1           |

### What is Varnish?

It's basically Redis for HTTP requests.

Instead of serving identical HTTP requests, eating up resources and bandwidth, Varnish caches requests for as long you like.

Just put it in front of your HTTP server, and it will intercept all HTTP requests.

It's one of the simplest ways to make your website faster.

### How does it work?

Expose Varnish on port 80, and point it to your web server using a `vcl` config file. See the Varnish docs (and Google) for details on how to do this.

For this Docker image, you can `ADD` your `default.vcl` file into `/etc/varnish/` inside the container. For my own setup I use Docker Compose with mounted volumes, which means any edits I make don't mean I have to rebuild the container.

### VCL Configuration

`default.vcl` is the single source of truth for all Varnish configuration. It includes:

- **Backend health probe** — monitors the backend with a 2s timeout, 5s interval, sliding window of 5 checks, threshold of 3.
- **PURGE ACL** — allows cache purging from `localhost` and `127.0.0.1`.
- **Accept-Encoding normalization** — normalises to `gzip` or `deflate` for text content, unsets for binary assets (images, media, archives).
- **Cookie stripping** — removes cookies for static assets to improve cache hit rates.
- **Cache TTLs** — 1 day TTL with 7 day grace for static assets, 1 hour grace for other content.
- **500 error handling** — sets TTL to 0 and 24h grace for backend 5xx errors.
- **X-Cache header** — adds `HIT`/`MISS` header for cache observability.

The backend address differs between Docker Compose mode (`web:80`) and standalone mode (`127.0.0.1:8080`). During the Docker build, `install.sh` patches the backend to `127.0.0.1:8080` for standalone use. In Docker Compose, the `default.vcl` is mounted from the host and retains `web:80`.

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
