# Exploratory testing: cache policy, Surrogate-Control, and mutation invalidation (2026-10-03)

I ran this exploratory pass without supervision. I drove the image through real HTTP requests using `curl`, raw sockets, Docker container lifecycles, and a scriptable origin server. I did not use mocks.

## Setup

- Build: `origin/master` @ `3392a55`, built as image `sha256:5ad228b3ee4ffea6f510f398d5d1955d0e4b9708ac5b4` (see [`build.txt`](2026-10-03-cache-policy-surrogate-invalidation/build.txt)).
- Host: macOS (8-core host), Docker (OrbStack, aarch64), Varnish 7.1.1.
- Topology:
  - Docker network `vx-et-net`.
  - Origin container `vx-et-origin`: `python:3.12-alpine` running [`origin-app.py`](2026-10-03-cache-policy-surrogate-invalidation/origin-app.py) on port 8080. It allows setting arbitrary response statuses (`?status=`), response headers (`?h_<Header>=`), and tracks hit counters per path and globally.
  - Varnish container `vx-et-varnish`: `jonbaldie/varnish:latest` listening on port 18780 with `-e VARNISH_BACKEND_HOST=vx-et-origin -e VARNISH_BACKEND_PORT=8080 -e VARNISH_BACKEND_PROBE_PATH=/`.
- Evidence directory: [`2026-10-03-cache-policy-surrogate-invalidation/`](2026-10-03-cache-policy-surrogate-invalidation/).

## Confirmed bugs

| # | Bug | Issue |
|---|---|---|
| 1 | Horizontal tab (HTAB / `\t`) in `Location` or `Content-Location` breaks Varnish ban syntax and prevents cache invalidation | [#124](https://github.com/jonbaldie/varnish/issues/124) |

### 1. Horizontal tab (HTAB) in `Location` or `Content-Location` breaks ban syntax — #124

- **User impact:** Under RFC 9111 §4.4, non-error responses to unsafe methods (`POST`, `PUT`, `DELETE`, `PATCH`) must invalidate URI(s) referenced in `Location` and `Content-Location` header fields. When a backend origin returns a reference containing a horizontal tab (`\t` / `HTAB`, ASCII 0x09) — e.g. in a query parameter like `/report?tab=1\t2` or path like `/report\tdata` — Varnish fails to invalidate the cached target resource. Clients continue receiving stale responses (`X-Cache: HIT`). Furthermore, Varnish logs a ban syntax error in `varnishlog`: `VCL_Error b ban(): Expected && between conditions, found "..."`.
- **Cause (observed):** In `cache-policy.vcl` lines 147-151, PR #114 introduced `regsuball(beresp.http.X-Varnish-Cache-Ref-URL, " ", "%20");` to encode literal spaces for the ban expression parser. However, RFC 9110 §5.5 permits both `SP` and `HTAB` in HTTP header values. Unencoded `HTAB` characters are not percent-encoded to `%09`, so they pass unquoted into the `ban("obj.http.X-Varnish-Cache-Host == " + bereq.http.host + " && obj.http.X-Varnish-Cache-URL == " + beresp.http.X-Varnish-Cache-Ref-URL)` expression. Varnish's ban parser treats the tab as an unexpected token separator and rejects the ban.
- **Replay:** [`reproduce-tab-invalidation.sh`](2026-10-03-cache-policy-surrogate-invalidation/reproduce-tab-invalidation.sh). Output is in [`reproduce-tab-invalidation.txt`](2026-10-03-cache-policy-surrogate-invalidation/reproduce-tab-invalidation.txt).
- **Expected:** An unsafe POST response with `Location: /report\tdata` causes Varnish to invalidate `/report%09data`. The next GET request yields `X-Cache: MISS`. No `VCL_Error` is logged.
- **Actual:** Varnish logs `VCL_Error ban(): Expected && between conditions, found "data"`. The next GET request yields `X-Cache: HIT`.
- **Repeats:** 3 of 3 runs from clean containers.

## Journeys exercised

### Journey 1: Surrogate-Control and freshness hierarchy

**Goal:** Ensure modern edge caching directives (`Surrogate-Control`) interact correctly with `Cache-Control`, `Expires`, and static asset defaults per W3C Edge Architecture §4.2 and RFC 9111.

- **Ordinary path:**
  - `Surrogate-Control: max-age=10`: first request `MISS`, second request `HIT`.
  - `Surrogate-Control: max-age=10` overriding `Cache-Control: private, no-store`: successfully cached with `X-Cache: HIT`.
  - `Surrogate-Control: max-age=2+10` (with freshness extension): correctly cached for 2s TTL with 10s grace.
- **Variations:**
  - `Surrogate-Control: max-age=0` (zero freshness): both requests produced `MISS`.
  - `Surrogate-Control: max-age=0+10` (zero freshness with extension): both requests produced `MISS`, correctly respecting the uncacheable directive.
  - `Surrogate-Control: content="ESI/1.0"` with `Cache-Control: private`: capability advertisement did not override `private`, correctly resulting in `MISS`.
  - Static asset default policy (`.css`): request 1 `MISS`, request 2 `HIT` with default 1 day TTL and 7 days grace.
  - Static asset with `Cache-Control: max-age=0`: correctly stayed hit-for-miss (`MISS`).
  - Unix Epoch `Expires: Thu, 01 Jan 1970 00:00:00 GMT`: stayed hit-for-miss (`MISS`).

### Journey 2: Backend failure, health checks, and stale grace serving

**Goal:** Verify that Varnish serves stale cached content within the grace window during backend outages, while strictly respecting revalidation prohibitions.

- **Ordinary path:**
  - Resource cached with 1s TTL and default 1h grace. Origin was stopped (`docker stop`). Next request returned `200 OK` with `X-Cache: HIT` from grace.
- **Variations:**
  - Resource cached with `Cache-Control: max-age=1, must-revalidate`: during backend outage, Varnish refused to serve stale and returned `503 Backend fetch failed`.
  - Resource cached with `Cache-Control: max-age=1, s-maxage=60`: during backend outage, Varnish refused to serve stale and returned `503 Backend fetch failed` (RFC 9111 §5.2.2.10 specifies `s-maxage` implies `proxy-revalidate`).
  - Uncached request during backend outage: returned `503 Backend fetch failed`.
  - Origin container restarted: health probe restored backend health, and requests resumed normal operation.

### Journey 3: Unsafe mutations and reference invalidation

**Goal:** Ensure unsafe HTTP methods (`POST`, `PUT`, `DELETE`, `PATCH`) invalidate cached target URIs and referenced URIs per RFC 9111 §4.4.

- **Ordinary path:**
  - POST to `/target` invalidated `/target` (request 1 `MISS`, request 2 `HIT`, POST mutation, request 3 `MISS`).
  - PUT to `/target` invalidated `/target`.
  - DELETE and PATCH to `/target` invalidated `/target`.
  - POST returning `Location: /other` invalidated `/other`.
  - PUT returning `Content-Location: /other` invalidated `/other`.
  - POST with PRG (303 See Other and `Location: /prg-target`) invalidated `/prg-target`.
- **Variations:**
  - `Location` with unencoded space (`/space target`, PR #114): successfully percent-encoded and invalidated `/space%20target`.
  - `Location` with horizontal tab (`/tab\ttarget`): **failed** with ban syntax error; see Bug 1 (#124).
  - `Content-Location` with horizontal tab (`/cl-tab\ttarget`): **failed** with ban syntax error; see Bug 1 (#124).

## Rejected or unresolved candidates

- **Rejected: `Cache-Control: s-maxage` should serve stale during origin outage.** RFC 9111 §5.2.2.10 explicitly specifies that `s-maxage` implies `proxy-revalidate` semantics. Because `proxy-revalidate` prohibits shared caches from serving stale without origin contact, setting `grace = 0s` and returning 503 during origin failure is standards-compliant.
- **Rejected: `Surrogate-Control: max-age=0+N` should be cacheable for grace serving.** W3C Edge Architecture §4.2 prohibits caching when `max-age=0`. The freshness extension only applies when `max-age > 0`.

## Usability observations

- `Location` and `Content-Location` ban reference handling only encodes space (`" "`), but HTTP field content permits any whitespace (`SP` and `HTAB`). Using `regsuball(..., "[[:blank:]]", ...)` or general URI escaping would prevent ban syntax errors when origins emit tabs.
- `Location` headers with uppercase schemes (`HTTP://...`) or mixed-case schemes are correctly handled by case-insensitive regex, but relative-without-slash references (e.g. `Location: item/123`) are silently skipped. A documentation note explaining why relative references must be path-absolute (`/item/123`) or absolute URIs would benefit users.

## Not explored

- HTTPS terminator edge cases with mutual TLS.
- Dynamic VCL reload via `varnishadm vcl.load` during live traffic.
- Chunked transfer encoding trailers in backend responses.

## Limitations and cleanup

- All containers (`vx-et-origin`, `vx-et-varnish`, `vx-repro-origin-*`, `vx-repro-varnish-*`) and networks were cleanly removed.
- All test runs used isolated ports (18780, 18790) without touching production or other test ports.
