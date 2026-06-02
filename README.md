# Varnish

[![Docker CI](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml/badge.svg)](https://github.com/jonbaldie/varnish/actions/workflows/docker.yml)

Varnish is basically Redis for HTTP requests. Instead of serving identical HTTP requests and eating up resources, it caches them for as long as you like. Put it in front of your HTTP server and it intercepts everything — one of the simplest ways to make a website faster.

## Quick Start

Pull the image:

```bash
docker pull jonbaldie/varnish
```

Or clone the repo and build locally:

```bash
make
```

## Version Matrix

| Debian Version | Varnish Version |
|----------------|-----------------|
| bookworm       | 7.1.1           |

## How It Works

Expose Varnish on port 80 and point it at your web server via a `vcl` config file. See the [Varnish docs](https://varnish-cache.org/docs/) for the full picture.

For this image, `ADD` your `default.vcl` into `/etc/varnish/` inside the container. Using Docker Compose with mounted volumes means you can edit the config without rebuilding.

## VCL Configuration

`default.vcl` is the single source of truth for Varnish config. It includes:

- **Backend health probe** — 2s timeout, 5s interval, sliding window of 5 checks, threshold of 3.
- **PURGE ACL** — allows cache purging from `localhost` and `127.0.0.1`.
- **Accept-Encoding normalisation** — normalises to `gzip` or `deflate` for text; unsets for binary assets.
- **Cookie stripping** — removes cookies for static assets to improve cache hit rates.
- **Cache TTLs** — 1 day TTL with 7 day grace for static assets; 1 hour grace for other content.
- **500 error handling** — sets TTL to 0 and 24h grace for backend 5xx errors.
- **X-Cache header** — adds `HIT`/`MISS` for cache observability.

The backend address differs between modes: Docker Compose uses `web:80`; standalone uses `127.0.0.1:8080`. The `install.sh` script patches this during the Docker build for standalone use.

## Docker Compose Example

The repo includes a `docker-compose.yml` and a sample `default.vcl`:

- `varnish` service on port 80, with the VCL mounted from the host.
- `web` backend running `nginx:alpine`.

```bash
docker compose up
```

## SSL

Varnish doesn't understand HTTPS natively, so requests need rerouting:

```
HTTPS → Nginx:443 → Varnish:80 → Nginx:80 (internal) → Website
HTTP  → Varnish:80 → Nginx:80 (internal) → Website
```

With Docker networking this is straightforward to set up and performs well.

## Development

### Testing

```bash
make test              # default build, smoke, integration, and cache checks
make test-e2e-hard     # stronger hostile-backend proofs
```

### Hostile Backend Fixture Contract

The `nginx:alpine` compose backend covers the happy-path smoke tests. A separate hostile backend fixture exists only to prove behaviours nginx can't expose clearly enough for E2E assertions.

**Endpoints required:**

| Endpoint | Purpose |
|---|---|
| `GET /static/app.css` | Cacheable static asset; must echo whether a `Cookie` reached origin |
| `GET /account` | Dynamic pass-through; must echo caller identity from `Cookie` |
| `GET /set-cookie` | Must return `Set-Cookie`; must not be shared across clients |

**Every response must include:**
- `X-Backend: hostile` — proves the backend handled the request.
- `X-Backend-Request-Id` — unique per origin hit, used to detect cache reuse.

**Response contract:**

- `/static/app.css` — body contains `asset=app.css` and `cookie=none` when no cookie reached origin. Should be cacheable; tests expect `X-Cache: MISS` then `X-Cache: HIT`.
- `/account` — body contains `route=account` and `client=<name>` from the cookie. Must not carry `Set-Cookie`. Both requests should produce `X-Cache: MISS` with different request ids.
- `/set-cookie` — body contains `route=set-cookie` and `client=<name>`. Must include `Set-Cookie: session=<name>; Path=/`. Every request should produce `X-Cache: MISS` with different request ids across clients.

**Proof matrix:**

1. Static asset with `Cookie` strips the cookie before origin — assert `cookie=none`, `X-Cache: MISS` then `HIT`.
2. Non-static request with `Cookie` is passed per-client — assert separate `X-Backend-Request-Id` values; bob must not see alice's response.
3. Response with `Set-Cookie` is never shared from cache — assert separate request ids and `Set-Cookie` values per client.

Out of scope: additional routes, extra Cache-Control permutations, replacing the nginx smoke backend.

---

(c) 2017 Jonathan Baldie
