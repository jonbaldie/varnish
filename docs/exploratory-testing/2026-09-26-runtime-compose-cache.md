# Exploratory testing: runtime config, Compose sample, cache policy (2026-09-26)

I ran this pass without supervision. I drove the image the way a user would: `docker run`, the sample `docker compose`, and plain HTTP with `curl` and raw sockets. I didn't use the Makefile test harness for this pass.

## Setup

- Build: `master` @ `5cd63cf`, built with `make build` as `jonbaldie/varnish:latest` (see `build.txt`).
- Host: macOS, Docker 29.4.0 (OrbStack, aarch64), Compose v2.
- Journey 1 and 3 topology: a user-defined network `vx-net` with a scriptable origin (`origin-app.py`, run in `python:3.12-alpine` as `vx-origin:8080`). The origin echoes the request as JSON and sets response status and headers from `?status=` and `?h_<Header>=` query parameters. It also returns a per-hit counter in `X-Origin-N`. Varnish ran as `vx-varnish` with `-p 18580:80 -e VARNISH_BACKEND_HOST=vx-origin -e VARNISH_BACKEND_PORT=8080`.
- Journey 2: a clean `git archive HEAD` copy of the repo, brought up with `docker compose -p vxc`.
  - **Intervention:** I changed the published port from `80:80` to `18582:80` because host port 80 was taken. Nothing else changed.
- Evidence directory: [`2026-09-26-runtime-compose-cache/`](2026-09-26-runtime-compose-cache/).

## Confirmed bugs

| # | Bug | Issue |
|---|---|---|
| 1 | `VARNISH_START` override always fails on the stock image | [#101](https://github.com/jonbaldie/varnish/issues/101) |
| 2 | `docker compose up -d --build` keeps stale `/etc/varnish`, so image VCL changes don't apply | [#102](https://github.com/jonbaldie/varnish/issues/102) |

### 1. `VARNISH_START` override always fails on the stock image — #101

- **User impact:** The README says `VARNISH_START` "still works as a full-command override". Any user who sets only that variable gets exit code 1 at startup, with an error naming variables they never set.
- **Cause (observed):** The `Dockerfile` bakes in `ENV VARNISH_LISTEN`, `VARNISH_VCL` and `VARNISH_STORAGE`. `start.sh` treats any non-empty value as a conflict with `VARNISH_START`.
- **Replay:** [`j1-varnish-start-replay.sh`](2026-09-26-runtime-compose-cache/j1-varnish-start-replay.sh). Output is in [`j1-varnish-start-replay.txt`](2026-09-26-runtime-compose-cache/j1-varnish-start-replay.txt).
- **Expected:** varnishd starts with the supplied command.
- **Actual:** `ERROR: VARNISH_START cannot be combined with ...`, then `exit=1`.
- **Repeats:** 3 of 3 from fresh containers.
- **Workaround:** blank the baked variables with `-e VARNISH_LISTEN= -e VARNISH_VCL= -e VARNISH_STORAGE= -e VARNISH_EXTRA_ARGS=`. In the replay output, `exit=141` for step 2 is SIGPIPE from `head`; varnishd was running at that point.
- **Related:** the override runs under `bash -lc` as user `varnish`, whose `PATH` doesn't include `/usr/sbin`. A bare `varnishd` in the command fails with exit 127.

### 2. `docker compose up -d --build` keeps stale `/etc/varnish` — #102

- **User impact:** The README tells users to rebuild with `docker compose up -d --build` after changing image files. Because of `VOLUME ["/etc/varnish"]`, Compose reuses the old container's anonymous volume, so the rebuilt image's `default.vcl` never takes effect. Only `docker compose down` followed by `up` applies it.
- **Replay:** [`j2-replay.sh`](2026-09-26-runtime-compose-cache/j2-replay.sh). Output is in [`j2-compose-rebuild-replay.txt`](2026-09-26-runtime-compose-cache/j2-compose-rebuild-replay.txt).
- **Expected:** `X-Image-Build: v2` appears after the rebuild.
- **Actual:** The header is absent. The container's `default.vcl` md5 is `32d948…` while the image's is `f14589…`. The header only appears after `down`/`up`.
- **Repeats:** 2 of 2, including one scripted run starting from `down -v`.

## Journeys exercised

### J1: Standalone image in front of an origin (`docker run`)

**Goal:** cache GETs from my origin and expose HIT/MISS.

- **Ordinary path:** first GET returned `MISS` and the second returned `HIT` with the same `X-Origin-N`. The internal `X-Varnish-Cache-Host`/`-URL` headers were stripped from the client response. The healthcheck reported `healthy`.
- **Variations:**
  - `500`/`503` responses were not reused; every request reached the origin.
  - `404` was cached.
  - A response with `Set-Cookie` wasn't cached.
  - A request `Cookie` on a non-static URL was passed to the origin.
  - A HEAD request populated the cache for a later GET.
  - `PURGE` from the host got `405`. `PURGE` from inside the container (`127.0.0.1`) got `200 Purged`, and the next GET was a `MISS`.
  - An HTTP/1.0 request with no Host was cached. A POST without Host invalidated it, and the ban used the backend host name on both sides, so it matched.
- **Runtime configuration:**
  - `VARNISH_LISTEN='[::]:80'` and `VARNISH_STORAGE='file,…,100m'` both started correctly.
  - `VARNISH_START` failed; see bug 1.

### J2: Sample Docker Compose stack

**Goal:** run the documented sample, then change configuration using the README workflows.

- **Ordinary path:** `docker compose up -d --build` came up `healthy`. nginx content went `MISS` then `HIT`. `PURGE` from the host got `405`.
- **Editing `cache-policy.vcl` then `docker compose restart varnish`:** the edit took effect (`X-Cache: HIT-EDITED`).
- **Broken VCL, then restart:** the container went into a restart loop and logged `VCL compilation failed`. Clients saw connection failures. Fixing the file and restarting brought it back with `200`.
- **Changing an image file, then `docker compose up -d --build`:** the change didn't apply; see bug 2.

### J3: Cache correctness for an app with mutations

**Goal:** mutations invalidate cached pages, and alternate request forms don't fragment or bypass the cache.

- Absolute-form request targets (`GET http://app.test/abs`), including ones with a mismatched `Host`, hit the same cache entry as origin-form requests. Varnish rewrites Host from the target.
- I ran [`specialurl.py`](2026-09-26-runtime-compose-cache/specialurl.py) with URLs containing `"`, `\`, `'`, `%20`, `&&`, `~` and `{}`. Every POST invalidated the cached GET (origin counter advanced 3 per URL: MISS, HIT, POST, then MISS). `ban.list` showed each ban parsed.

## Rejected or unresolved candidates

- **Rejected: 5xx cached with a 24h grace would be served stale.** Repeated `500` and `503` responses always went to the origin (`X-Cache: MISS`, new `X-Origin-N` each time).
- **Rejected: origin-controlled `Location` could inject ban conditions.** Ban conditions are only joined with `&&`, so extra tokens can only narrow a ban, never widen it.
- **Unresolved (design question, not filed): static-extension `404` and `301` responses are cached for 1 day with 7 days of grace.** For `/missing.css`, varnishlog showed an RFC TTL of 120s raised by VCL to 86400s with 604800s of grace. This matches the README's "1 day TTL … for static assets", but that text doesn't say whether it covers error or redirect statuses. If an asset is requested before it's deployed, the 404 could be pinned for a day.

## Usability observations

These are observations, with suggested fixes where I have one.

- `VARNISH_LISTEN=':80'` is rejected ("expected host:port") even though `varnishd -a :80` is valid. Multi-listener forms such as `0.0.0.0:80,HTTP` are also rejected.
- `VARNISH_EXTRA_ARGS` is split with `read -a`, so quoting isn't honoured. `-p "cli_limit=64k"` becomes the literal parameter name `"cli_limit`. A README note would help.
- A VCL syntax error in the bind-mounted policy puts the Compose service into a restart loop with no listener. The log's compiler output is clear.
- `VARNISH_START` as the `varnish` user needs the absolute path `/usr/sbin/varnishd`.

## Not explored

- WebSocket or `Upgrade` traffic through the policy. `vcl_recv` never returns `pipe`.
- Pulling the published Docker Hub image. I only tested local builds.
- The TLS-terminator topology from the README's SSL section.
- `stale-while-revalidate` and grace behaviour when the backend is marked sick.

## Limitations and cleanup

- All containers, the `vx-net` network and the Compose project volumes (`down -v`) were removed. The standalone `vx-varnish` container was removed with `docker rm -f` without `-v`, so its two anonymous volumes may remain as dangling volumes. I didn't run a global prune because the host is shared.
- The Compose rebuild replay overwrote the local `jonbaldie/varnish:latest` tag. I rebuilt the stock image from `master` afterwards and confirmed the `default.vcl` md5 was `32d948…`.
- The replay scripts assume the `/tmp/vx` layout and host ports 18580 and 18582 used in this pass.
