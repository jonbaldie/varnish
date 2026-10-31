# Exploratory testing: runtime preflight and HTTP cache (2026-10-31)

No product bugs were confirmed in this pass. The [HTTP transcript](2026-10-31-runtime-cache/http-output.txt) records response headers and origin request bodies. The [replay script](2026-10-31-runtime-cache/replay.sh) starts and removes its own containers, network, and image tag. It uses the [scriptable origin](2026-10-24-grace-and-purge/origin.py) from the previous pass.

## Setup

- Tested `master` at `fc5f04b032fc8f6946a13e3d7ad311576e3e74d6` in a separate worktree on Linux with Docker 29.1.3 and Varnish 7.1.1.
- Built the repository Dockerfile as `exp-varnish-20261031:local`. The Dockerfile installs Debian packages without a project lockfile. `python:3.13-alpine` was already present.
- Used an isolated Docker network and a dynamically assigned loopback port. The origin echoes request headers and numbers origin responses. The Varnish container used a 32 MB storage limit and the named backend settings.
- The replay starts a fresh cache and origin. Its cleanup trap removes the named containers with their anonymous volumes, the network, and the image tag.

## Journeys

### Validate a deployment before startup

The README promises `/start.sh --check` validates the same runtime arguments as startup without publishing a backend candidate. A valid backend host and port passed the check and the image then started and served HTTP. An invalid listener port failed with an error. A `VARNISH_START` override also failed in check mode as documented. This pass did not independently compare backend files before and after the check.

### Cache static assets without sharing private requests

The README promises static cookie stripping, per-client dynamic cookies, and Authorization pass-through. A request for `/static/site.css?v=1` missed, omitted the cookie at origin, and the second request hit the same origin response. A different query missed. Two `/account` requests with different cookies both missed and preserved their respective cookies. Two `/profile` requests with different Authorization values both missed and preserved their respective headers. Origin response numbers and echoed headers show the lasting cache and isolation outcomes.

### Refresh a cached page after a mutation

The project documents invalidation after a successful unsafe request. The first GET for `/item` missed and the second hit the same origin response. POST returned 200. The next GET missed with a new origin number, and the following GET hit that new response. An unrelated primed URL stayed a hit after the POST. This checks both invalidation and preservation of another object.

## Findings and limits

No candidate in these journeys required a bug report. The issue list, including closed issues and prior rejections, was checked before concluding. Related fixed reports include [Authorization isolation #38](https://github.com/jonbaldie/varnish/issues/38), [unsafe-method invalidation #59](https://github.com/jonbaldie/varnish/issues/59), and [preflight validation #157](https://github.com/jonbaldie/varnish/issues/157). [PURGE ACL #70](https://github.com/jonbaldie/varnish/issues/70) was rejected previously. This pass did not retest that rejected deployment case.

The image and origin are real network services, but the origin is a configurable Python server rather than a production application. TLS, browser use, `Vary` combinations, PURGE, persistence across container restarts, and backend-file comparison were not explored in this pass. The echoed client values were synthetic, not credentials.

## Local verification

The required `COMPOSE_PARALLEL_LIMIT=1 make -j1 test test-e2e-hard` first failed because this environment created the worktree with mode 0700 and bind-mounted VCL files with mode 0600. After making worktree files readable to the container user, the retry completed `test` and the hostile scenarios through revalidation. It then waited for a pre-existing `/tmp/varnish-unsafe-location-test-8091.lock` and was interrupted by the command timeout. The lock was not removed.

The remaining unsafe-location, mutant canary, and Compose image rebuild targets passed serially after a temporary, pass-specific lock path was substituted in the test runner. A subsequent complete `COMPOSE_PARALLEL_LIMIT=1 make -j1 test test-e2e-hard` run also passed with that temporary lock path. The runner was restored afterward. The first remote PR CI run failed in `test-campaign-report` when a PURGE received HTTP 500 rather than a connection error after Varnish was stopped. A full workflow retry passed.

The runtime check errors identify the invalid setting, but the full-command override error does not suggest how to validate that override. The README documents that limitation.
