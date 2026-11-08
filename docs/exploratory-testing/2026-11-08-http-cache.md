# Exploratory testing: language variants and mutation invalidation (2026-11-08)

No product bugs were confirmed. The [transcript](2026-11-08-http/transcript.txt) contains the responses, and the [replay script](2026-11-08-http/replay.sh) builds the image and repeats the requests. Its [cleanup script](2026-11-08-http/cleanup.sh) removes the named containers, network, and image tag.

## Starting state

- Tested `master` at `1e88ebf167dc7ac5b344c57053cc90950b630e24` in a separate Linux worktree with Docker 29.1.3. Responses identified Varnish 7.1.
- Built the repository Dockerfile. The Dockerfile installs Debian packages without a project lockfile. The existing `python:3.13-alpine` image ran the [scriptable origin](2026-10-24-grace-and-purge/origin.py).
- The replay used a fresh cache, a private Docker network, a dynamically assigned loopback port, and 32 MB of Varnish storage. The origin echoed request headers and numbered its responses. The client values were synthetic.

## Journeys

### Check a deployment before starting it

The README promises that `/start.sh --check` validates runtime settings without starting Varnish. A check with the configured origin succeeded, then the same image started and served HTTP. An invalid listener port, `65536`, failed with an explicit range error. This pass did not compare backend files before and after the check.

### Keep language variants separate

An origin response with `Vary: Accept-Language` and `Cache-Control: max-age=600` missed for English and then hit origin response 3. French missed and then hit response 4. Returning to English hit response 3, showing that the French request did not replace the English variant. As a related cacheability variation, two requests for a static asset with `Cache-Control: no-store` both missed and produced different origin numbers. The origin is a controllable test server, not a production application.

### Refresh a page after a mutation

A cacheable GET for `/item` missed and then hit response 7. An unrelated URL also missed and then hit response 8. After a successful POST to `/item`, the next GET missed with response 10 and the following GET hit response 10. The unrelated URL remained a hit on response 8. This verifies both invalidation and preservation of the other object.

## Findings and limits

There were no unresolved candidate bugs. No issue was filed. The issue list and prior rejections were checked before the pass. Related reports include [mutation invalidation #59](https://github.com/jonbaldie/varnish/issues/59), [preflight argument parity #157](https://github.com/jonbaldie/varnish/issues/157), and the previously closed [PURGE ACL report #70](https://github.com/jonbaldie/varnish/issues/70). This pass did not retest that rejected report.

TLS, PURGE, backend-file comparison, restart persistence, origin outages, and other `Vary` fields were not explored. The replay captures responses for inspection; it does not assert the cache outcomes automatically.

The local full Docker gate was not run. Its Makefile builds into the existing shared `jonbaldie/varnish:latest` and `varnish-campaign:latest` tags, and uses fixed ports. Overwriting resources owned by other runs would violate this pass's isolation. The PR's GitHub Actions workflow runs the full test and hostile E2E targets on a separate runner.
