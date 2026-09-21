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

The standalone image embeds `/etc/varnish/default.vcl` and generates `/etc/varnish/backend.vcl`. Docker Compose uses the same backend configuration adapter and mounts only the shared cache policy.

## Runtime Configuration

The container starts `varnishd` from named runtime values instead of a single baked command string.

- `VARNISH_LISTEN` defaults to `0.0.0.0:80`
- `VARNISH_VCL` defaults to `/etc/varnish/default.vcl`
- `VARNISH_STORAGE` defaults to `malloc,1g`
- `VARNISH_EXTRA_ARGS` appends extra `varnishd` flags when you need a small escape hatch

For advanced cases, `VARNISH_START` still works as a full-command override, but it cannot be combined with the narrower `VARNISH_*` settings.

Backend configuration also has named values:

- `VARNISH_BACKEND_HOST` defaults to `127.0.0.1`
- `VARNISH_BACKEND_PORT` defaults to `8080`
- `VARNISH_BACKEND_PROBE_PATH` defaults to `/`

These render the embedded `/etc/varnish/backend.vcl`. If you supply a custom `VARNISH_VCL`, keep backend wiring in that VCL instead.

## Restarting Varnish

This image runs `varnishd` as the container process, not as a distro service.
Do not run `sudo service varnish restart` inside the container.

Restart the container instead:

```bash
docker restart <container-name>
```

With the sample Compose file, restart the Varnish service:

```bash
docker compose restart varnish
```

If you changed mounted cache policy or backend environment values, restart the container so `varnishd` starts
again with the updated configuration. If you changed image files, rebuild first
with `docker compose up -d --build`.

## VCL Configuration

The embedded default VCL includes generated backend configuration and the shared cache policy. The repo `default.vcl` remains a standalone sample for custom VCL mounts. The shared cache policy includes:

- **Backend health probe** — 2s timeout, 5s interval, sliding window of 5 checks, threshold of 3. Override the probe path with `VARNISH_BACKEND_PROBE_PATH`.
- **Host header compliance** — rejects HTTP/1.1 requests with a missing, empty, whitespace-only, or invalid `Host` field value with 400 Bad Request (RFC 9112 §7.1, RFC 9110 §7.2); normalises valid `Host` header casing to lowercase.
- **Authorization header compliance** — passes requests carrying an `Authorization` header directly to origin, preventing authenticated responses from being cached or leaked across clients (RFC 9111 §3.5).
- **Vary header compliance** — marks origin responses containing wildcard `Vary: *` as uncacheable hit-for-miss, preventing shared caching (RFC 9111 §4.1).
- **Zero-freshness static assets** — static-extension URLs only receive the policy TTL when the origin granted positive freshness; responses with zero freshness (`max-age=0`, `s-maxage=0`, or an `Expires` date in the past) stay hit-for-miss (RFC 9111 §5.2). An `Expires` value that is not a valid HTTP-date — the common `0`, `-1`, or any unparseable string — counts as already expired too (RFC 9111 §5.3) and stays hit-for-miss for **every** URL, static or not, unless `Cache-Control` supplies `max-age`/`s-maxage`, which overrides `Expires`.
- **PURGE ACL** — allows cache purging from `localhost` and `127.0.0.1`.
- **Accept-Encoding normalisation** — normalises to `gzip` or `deflate` for text; unsets for binary assets.
- **Cookie stripping** — removes cookies for static assets to improve cache hit rates.
- **Cache TTLs** — 1 day TTL with 7 day grace for static assets; 1 hour grace for other content.
- **500 error handling** — sets TTL to 0 and 24h grace for backend 5xx errors.
- **X-Cache header** — adds `HIT`/`MISS` for cache observability.

The backend address differs between modes through the adapter: Docker Compose uses `web:80`; standalone defaults to `127.0.0.1:8080`. `render-vcl` generates backend VCL from `VARNISH_BACKEND_HOST`, `VARNISH_BACKEND_PORT`, and `VARNISH_BACKEND_PROBE_PATH`.

## Docker Compose Example

The repo includes a `docker-compose.yml` sample:

- `varnish` service on port 80, using `VARNISH_BACKEND_*` to target the backend.
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

Fleet shares an 8-core macOS host with other repositories. During iteration, run one named test target at a time, for example `make test-vcl-compile`. Do not start independent Docker test targets in parallel.

Before handoff, run the complete Docker gates serially:

```bash
COMPOSE_PARALLEL_LIMIT=1 make -j1 test test-e2e-hard
```

Wait for this command to return before you start another Docker test or campaign. The test recipes use teardown traps to remove containers and Compose resources. Do not interrupt or overlap that teardown.

### Hostile Backend Fixture Contract

The `nginx:alpine` compose backend covers the happy-path smoke tests. A separate hostile backend fixture exists only to prove behaviours nginx can't expose clearly enough for E2E assertions.

**Endpoints required:**

| Endpoint | Purpose |
|---|---|
| `GET /static/app.css` | Cacheable static asset; must echo whether a `Cookie` reached origin |
| `GET /account` | Dynamic pass-through; must echo caller identity from `Cookie` |
| `GET /set-cookie` | Must return `Set-Cookie`; must not be shared across clients |
| `GET /location-target`, `GET /content-location-target` | Cacheable targets referenced by unsafe-method responses (RFC 9111 §4.4) |
| unsafe `/create-rel`, `/create-abs`, `/create-abs-mixed-host`, `/create-abs-upper-host`, `/create-cross-host`, `/create-cross-host-mixed`, `/create-content-location`, `/create-content-location-abs-mixed` | Must return `Location`/`Content-Location` referencing the targets above, including mixed-case and uppercase same-host and cross-host forms |

**Every response must include:**
- `X-Backend: hostile` — proves the backend handled the request.
- `X-Backend-Request-Id` — unique per origin hit, used to detect cache reuse.

**Response contract:**

- `/static/app.css` — body contains `asset=app.css` and `cookie=none` when no cookie reached origin. Should be cacheable; tests expect `X-Cache: MISS` then `X-Cache: HIT`.
- `/account` — body contains `route=account` and `client=<name>` from the cookie. Must not carry `Set-Cookie`. Both requests should produce `X-Cache: MISS` with different request ids.
- `/set-cookie` — body contains `route=set-cookie` and `client=<name>`. Must include `Set-Cookie: session=<name>; Path=/`. Every request should produce `X-Cache: MISS` with different request ids across clients.

**Proof matrix:**

1. Static asset with `Cookie` strips the cookie before origin on safe GET/HEAD requests — assert `cookie=none`, `X-Cache: MISS` then `HIT`. Mutating requests (`POST`, `PUT`, `DELETE`, `PATCH`) preserve `Cookie` headers and pass directly to origin.
2. Non-static request with `Cookie` is passed per-client — assert separate `X-Backend-Request-Id` values; bob must not see alice's response.
3. Dynamic URL whose query value ends in a static extension (e.g. `?q=jquery.js`) is not treated as a static asset — cookies reach origin per-client with separate request ids, while a real static asset with a query string (`/static/app.css?v=2`) still strips cookies and caches.
4. Response with `Set-Cookie` is never shared from cache — assert separate request ids and `Set-Cookie` values per client.
5. A successful unsafe request whose response carries `Location` or `Content-Location` (RFC 9111 §4.4) invalidates the cached object for the referenced URI on the same host (relative or absolute reference), while a cross-host reference must not invalidate same-host cache entries.

Out of scope: additional routes, extra Cache-Control permutations, replacing the nginx smoke backend.

---

(c) 2017 Jonathan Baldie
