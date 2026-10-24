# Exploratory testing: grace under origin errors, origin freshness, and PURGE (2026-10-24)

I ran this exploratory pass without supervision. I drove the image through real HTTP requests with `curl`, Docker container lifecycles, a scriptable origin, and a loopback sidecar for PURGE. I did not use mocks.

## Setup

- Build: `master` @ `8c9a304`, image `varnish-et-20261024:run` (`sha256:e46d9a85…`, [`build.txt`](2026-10-24-grace-and-purge/build.txt)). Varnish 7.1.1 on OrbStack, aarch64.
- Topology ([`up.sh`](2026-10-24-grace-and-purge/up.sh)):
  - network `vx24-net`
  - origin `vx24-origin`: `python:3.13-alpine` running [`origin.py`](2026-10-24-grace-and-purge/origin.py). The origin sets the status and headers for each path at runtime through `/__set`, and numbers each response with `X-Origin-N`.
  - standalone `vx24-varnish` on `127.0.0.1:18824` with `VARNISH_BACKEND_HOST/PORT/PROBE_PATH`.
- PURGE is sent from loopback with `docker run --network container:vx24-varnish`, the same way `test/e2e/assert-compose-purge.sh` does it.
- Every replay starts from fresh containers.
- Evidence: [`2026-10-24-grace-and-purge/`](2026-10-24-grace-and-purge/).

## Confirmed bugs

| # | Bug | Issue |
|---|---|---|
| 1 | A 5xx from the origin replaces a graced dynamic page, so grace does not cover 500/502/503 outages | [#161](https://github.com/jonbaldie/varnish/issues/161) |
| 2 | PURGE leaves the deflate copy of a page in cache; no PURGE can reach it | [#162](https://github.com/jonbaldie/varnish/issues/162) |

### 1. A 5xx replaces a graced page — #161

- **User impact:** When the application fails behind its web server, the origin returns 500/502/503. Visitors get one stale page and then the error, and every request goes back to the failing origin. Grace only helps when the origin cannot be reached at all.
- **Starting conditions:** `GET /news` returns 200 with `Cache-Control: max-age=2`. Policy grace for non-static content is 1h.
- **Replay:** [`repro-5xx-replaces-grace.sh`](2026-10-24-grace-and-purge/repro-5xx-replaces-grace.sh) with `STATUS=500|502|503`. Cache the page, switch the origin to 5xx, wait 3 s, then request once a second.
- **Expected:** a cached 200 on every request while the origin fails. This is what happens when the origin is stopped ([`control-origin-stopped.txt`](2026-10-24-grace-and-purge/control-origin-stopped.txt)).
- **Actual:** the first request is a grace HIT (200). Every later request is a MISS that returns the origin's 5xx ([`repro-5xx-replaces-grace.txt`](2026-10-24-grace-and-purge/repro-5xx-replaces-grace.txt)). varnishlog shows the background fetch storing the 500 as `TTL VCL 0 86400 … cacheable` ([`varnishlog-5xx-bgfetch.txt`](2026-10-24-grace-and-purge/varnishlog-5xx-bgfetch.txt)). The 5xx branch in `vcl_backend_response` sets `ttl=0s, grace=24h` and delivers. The new object replaces the graced 200 but is never served from lookup.
- **Repeats:** 6 of 6: 500, 502 and 503, each in two series from clean containers. The recorded output is from the second series, after I removed a no-op line from the driver.

### 2. PURGE leaves the deflate copy — #162

- **User impact:** an operator purges an updated page and gets `200 Purged`, but clients that only accept deflate keep receiving the old content until the TTL expires.
- **Starting conditions:** `GET /article` returns 200 with `Cache-Control: max-age=600`. It has been fetched with `Accept-Encoding: gzip` and with `Accept-Encoding: deflate`, which produces two objects (#146 fix).
- **Replay:** [`repro-purge-deflate.sh`](2026-10-24-grace-and-purge/repro-purge-deflate.sh).
- **Expected:** after the PURGE, every encoding is a MISS.
- **Actual:** gzip is a MISS. Deflate is still a HIT serving the response from before the purge (`X-Origin-N: 4`). Identity HITs the fresh gzip object ([`repro-purge-deflate.txt`](2026-10-24-grace-and-purge/repro-purge-deflate.txt)).
  - Variation: a PURGE carrying `Accept-Encoding: deflate` also leaves the deflate object. `vcl_recv` returns `purge` before the Accept-Encoding normalization that sets `X-Normalized-AE`, so `vcl_hash` never adds `"deflate"` for a PURGE.
  - `POST /article` invalidates both copies because it uses a ban ([`variation-purge-deflate.txt`](2026-10-24-grace-and-purge/variation-purge-deflate.txt)).
- **Repeats:** 3 of 3 from clean containers. The variation was run once.

## Journeys exercised

### Journey 1: the site stays up when the origin fails

**Goal:** a visitor keeps getting the cached page during an origin failure, as the README's grace and "Grace period (backend down)" test promise.

- **Ordinary path:** cache `/news`, then stop the origin container. The stale 200 is served with a growing `Age`. Passed.
- **Variation:** the origin stays up but answers 500/502/503. Failed (bug 1).
- **Static assets:** `/site.css` with an origin 500 after caching stayed a HIT. The asset gets a 1-day TTL whatever the origin sends, so the 5xx path is not reached within 3 s.
- **Lasting effect checked:** the evicted object did not come back. All later requests went to the origin.

### Journey 2: dynamic pages honour origin freshness

**Goal:** pages the origin marks as zero-freshness are not served from cache ([`zero-freshness-dynamic.txt`](2026-10-24-grace-and-purge/zero-freshness-dynamic.txt)).

- `max-age=0`, `s-maxage=0`, a past `Expires`, `no-cache`, `max-age=0, must-revalidate`, and static `app.css` with `max-age=0`: all MISS on every request. Passed.
- `max-age=1`: MISS, then HIT. The third request at about 2.4 s was a HIT with content from a background refresh. This is the documented 1h grace, so it is not counted as a bug (see observations).

### Journey 3: an operator purges an updated page

**Goal:** after a PURGE, every client gets fresh content, and PURGE from outside is refused.

- **Ordinary path:** PURGE through the published port gives `405`, as expected. PURGE from loopback gives `200 Purged`, and gzip and identity clients then MISS. Passed.
- **Variation:** deflate clients after the PURGE, and a PURGE carrying `Accept-Encoding: deflate`. Failed (bug 2).
- **Control:** POST invalidation removed both copies.

## Rejected or unresolved candidates

- **Rejected: a 5xx on a page with no cached copy gets cached.** Each request was a new MISS to the origin (`ttl=0` objects are not served).
- **Unresolved:** the `grace = 24h` given to 5xx objects appears to have no serving effect, because a `ttl=0` object is skipped at lookup. I did not check whether it holds storage for 24h under memory pressure.

## Usability observations

- **Observation:** the image has no `curl`, `wget`, or `bash`. Sending a PURGE from an allowed address needs a sidecar container in the Varnish network namespace, as the project's own test does. The README's PURGE ACL line does not say how an operator is meant to send one.
  - **Suggestion:** document a one-line PURGE command, or use `varnishadm ban` instead.
- **Observation:** with `max-age=1`, a page was served up to 1h past the origin's freshness lifetime without `stale-while-revalidate` from the origin. This matches the README ("1 hour grace for other content"), but origin authors may not expect it.

## Not explored

- The Compose sample stack (covered on 2026-10-17), the TLS topology, WebSocket/`Upgrade`, `Range` requests, and `varnishadm ban` as an alternative purge path.

## Limitations and cleanup

- Host port 18824, not 80. The origin is Python's `http.server`, not nginx.
- Run on OrbStack on macOS. Timing-based steps use 1 s sleeps against a 2 s TTL.
- At the end of the pass I removed the containers `vx24-*`, the network `vx24-net`, and the image tag `varnish-et-20261024:run`. Every build step was a cache hit (`build.txt`), so the build added no layers or build cache. `python:3.13-alpine` was already on the host and was kept.
- The image declares `VOLUME /var/lib/varnish`, so each container start creates an anonymous volume, and `docker rm -f` without `-v` leaves it behind. The first drivers leaked 16 of these. I identified them by creation time and by their contents (`varnishd` workdir), removed them, and changed `up.sh`/`down.sh` to `docker rm -fv`. A final replay of `repro-purge-deflate.sh` left the volume count unchanged.
