# Exploratory testing: site cache, encoding, and preflight (2026-10-17)

I ran this pass without supervision. I drove the image the way a user would: `docker run`, a Compose stack shaped like the sample, and plain HTTP with `curl`. I did not use the Makefile harness.

## Setup

- Build: product files from `release/v1.0.11` @ `dace271`, which match `origin/master` @ `f4a5b76` for `cache-policy.vcl`, `start.sh`, and `Dockerfile`. Built as `varnish-et-a87f:run`, `sha256:c4f36feb7d9cc6e0f65293164335c4e9818dbfab774360d6fbbbf7b096fe30e4`. See [`build.txt`](2026-10-17-site-cache-and-preflight/build.txt).
- Host: macOS, Docker 29.8.2 (OrbStack, arm64), Varnish 7.1.1.
- Journey 1 topology: network `vx-et-a87f-net`, origin `python:3.12-alpine` running a scriptable app, Varnish on host port 18717. I used a high port because I did not want to take host port 80 on a shared machine. The image tag was not `jonbaldie/varnish:latest`, so this pass did not retag the name other local work uses.
- Journey 2: Compose project `vx-et-a87f-c` with the sample service shape, image `varnish-et-a87f:run`, nginx on the Docker network, published port 18718. The cache policy bind mount was a copy, not the repo file.
- Evidence: [`2026-10-17-site-cache-and-preflight/`](2026-10-17-site-cache-and-preflight/). [`replay.sh`](2026-10-17-site-cache-and-preflight/replay.sh) repeats the three confirmed failures from clean containers.

## Confirmed bugs

| # | Bug | Issue |
|---|---|---|
| 1 | A cached deflate response is served to clients that do not accept deflate | [#146](https://github.com/jonbaldie/varnish/issues/146) |
| 2 | Relative-path `Location` and `Content-Location` do not invalidate the cached target | [#147](https://github.com/jonbaldie/varnish/issues/147) |
| 3 | `/start.sh --check` succeeds for runtime settings that `varnishd` rejects at startup | [#148](https://github.com/jonbaldie/varnish/issues/148) |

### 1. Cached deflate is served to gzip and identity clients — #146

- **User impact:** If any client fetches a text URL with `Accept-Encoding: deflate`, the origin's deflate body is stored and then handed to later clients. A gzip-only client gets `Content-Encoding: deflate` and cannot decode it. An identity client gets the same bytes. A normal `gzip, deflate, br` request is rewritten to gzip by the policy and still hits that object.
- **Replay:** [`replay.sh`](2026-10-17-site-cache-and-preflight/replay.sh). Run 1 headers are in [`encoding-1/`](2026-10-17-site-cache-and-preflight/encoding-1/).
- **Expected:** A client that does not accept deflate does not receive a deflate body. Gzip objects already transcode: an identity client is served plain text.
- **Actual:** After the deflate miss, gzip, identity, and `gzip, deflate, br` requests were `X-Cache: HIT` with `Content-Encoding: deflate` and a deflate body.
- **Repeats:** 3 of 3 from clean containers.

### 2. Relative-path Location does not invalidate — #147

- **User impact:** `POST /dir/mutate` with `Location: item` or `Content-Location: item` leaves `GET /dir/item` cached. Clients keep the pre-mutation page. `Location: /dir/item` does invalidate it.
- **Replay:** [`relative-1/`](2026-10-17-site-cache-and-preflight/relative-1/).
- **Expected:** The next GET is `X-Cache: MISS`, as RFC 9111 §4.4 and the README's relative-reference proof require. The path-absolute control is a miss.
- **Actual:** Both relative-path forms stayed `X-Cache: HIT`. The path-absolute control was `X-Cache: MISS`.
- **Repeats:** 3 of 3 from clean containers. An earlier pass on the same image also saw `./item` and `../dir/item` skipped.

### 3. Configuration check misses settings that prevent startup — #148

- **User impact:** The documented rollout check exits 0 for `VARNISH_STORAGE=notastorage,1g` and for `VARNISH_EXTRA_ARGS=--not-a-real-flag`. Starting the container with those values exits 2.
- **Replay:** [`check-1/`](2026-10-17-site-cache-and-preflight/check-1/).
- **Expected:** `--check` fails, and the error names the bad setting.
- **Actual:** `--check` exits 0 with no output. Startup prints `Unknown storage method "notastorage"` or `invalid option -- '-'`.
- **Repeats:** 3 of 3.

## Journeys exercised

### Journey 1: Standalone image in front of an origin

**Goal:** cache GETs, keep private responses private, and drop a cached page after a mutation.

- **Ordinary path:** `/` and `/static/app.css` went `MISS` then `HIT`. A cookie on the CSS miss did not reach the origin, and the next cookieless GET was a `HIT`. `/account` with a cookie reached the origin per client and was not reused. `Authorization` reached the origin and was not served from the anonymous object. `PURGE` from the host was `405`. `PURGE` from inside the container was `200`, and the next GET was a `MISS`.
- **Variations:**
  - A `Range` request did not poison the full object. The full GET was still the complete body, and a later range was sliced from that object.
  - `HEAD` then `GET` returned the full body from cache.
  - Host case, `:80`, and `:0080` shared one object. `example.com.` and `:8080` did not.
  - Invalid `Host` values (`bad host`, empty, userinfo) were `400`.
  - `POST` with `Location` containing `&&`, `>`, `~`, or `==` invalidated the target.
  - `Set-Cookie` and `Vary: *` were not reused.
  - A page with `max-age=1` was served stale (`X-Cache: HIT`, Age 13) after the origin container was stopped. The same shape with `must-revalidate` returned `503`. An uncached URL returned `503`. After the origin started again, traffic resumed.
  - `s-maxage=1` on a non-static URL was not served fresh after 2 seconds.
  - Origin `Age: 40` was `Age: 40` on the miss and `Age: 41` on the next hit.
  - The deflate and relative-reference failures above showed up on this journey.

### Journey 2: Sample Compose stack

**Goal:** run the documented sample shape, check it, change the mounted policy, and recover from a bad edit.

- **Ordinary path:** nginx's welcome page went `MISS` then `HIT`. `docker compose run --rm varnish /start.sh --check` exited 0.
- **Variations:**
  - A copied policy that set `X-Edited` was visible after recreate.
  - A syntax error in the mounted policy put the service into a restart loop. The compiler error was in the logs. Clients could not connect. Restoring the file and restarting returned `200`.

### Journey 3: Operator preflight

**Goal:** use `/start.sh --check` before startup, and use `VARNISH_START` only as the full override.

- **Ordinary path:** default `--check` exited 0 and printed nothing. Default start stayed up.
- **Variations:**
  - `VARNISH_BACKEND_HOST=nosuchhost` failed `--check` with a VCC resolve error, and start failed too.
  - `VARNISH_LISTEN=nope` failed `--check` with `Invalid VARNISH_LISTEN`.
  - `VARNISH_START=echo override-ok`, with no other `VARNISH_*` values set, printed `override-ok` and exited 0. The old "override always fails" failure did not recur.
  - `--unknown` was rejected.
  - Invalid storage and invalid extra flags passed `--check` and failed at start. See bug 3.
  - `VARNISH_EXTRA_ARGS=-p cli_limit=64k` started. A value with a space (`-p cc_command=exec true`) died at start with `Too many arguments`.

## Rejected or unresolved candidates

- **Rejected: a range request replaces the cached full body.** The full GET after a range was the complete 36-byte body.
- **Rejected: HEAD stores an empty body for a later GET.** The later GET was `head-body-should-survive`.
- **Rejected: `&&` in a `Location` query breaks the ban.** `Location: /qamp?a=1&&b=2` was a miss on the next GET. `>`, `~`, and `==` also invalidated.
- **Rejected: a 302 or 307 with no explicit freshness is cached.** Both were a miss twice. A static 302 with no cache headers was also a miss twice. A 301 with no explicit freshness was a hit on the second GET, which matches heuristic caching of 301.
- **Rejected: origin `Age` is replaced with 0.** It was preserved and incremented.
- **Rejected: `VARNISH_START` still cannot run on the stock image.** It ran when the narrower variables were unset.
- **Unresolved: an origin that answers every GET with 304 produces `503 Backend fetch failed`.** I did not capture a clean `FetchError` line after the origin process restarted and dropped that route, so I am not calling it a policy bug. Varnish commonly refuses a 304 that was not conditional.
- **Not filed: static `max-age=1` is still a fresh hit at Age 2.** The README says static URLs with positive freshness get the 1 day policy TTL. The response still advertises `max-age=1`. That is surprising, and it is what the README describes.
- **Not filed: `Host: example.com.` does not share a cache entry with `example.com`.** The policy documents case and default-port normalization, not a trailing dot.

## Usability observations

- `VARNISH_EXTRA_ARGS` is split on whitespace. A flag value that contains a space is not one argument. `--check` does not catch that either.
- A bad bind-mounted VCL makes the Compose service restart with no listener. The log names the line. Fixing the file and restarting brings it back. I had to change the published port from 80 to 18718; nothing else in the sample shape changed.
- `PURGE` from the host is refused. Purging from inside the container works, which matches the localhost ACL. The sample does not show that step.

## Not explored

- The TLS terminator topology in the README.
- WebSocket or `Upgrade` traffic.
- The published Docker Hub image. This pass used a local build.
- Chunked trailers.
- `varnishadm vcl.load` on a live process.

## Limitations and cleanup

- Host ports were 18717 and 18718, not 80.
- The Compose policy edit used a copy of `cache-policy.vcl` so the repo file was not modified.
- Containers, networks, and volumes created for this pass were removed after the replays. The local image tag `varnish-et-a87f:run` and the `python:3.12-alpine` image pulled for the origin were removed at the end of the pass.
