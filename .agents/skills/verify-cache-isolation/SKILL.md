---
name: verify-cache-isolation
description: Check shared-cache isolation when changing cache-policy.vcl request handling, credential forwarding, or cache storage.
---

# Verify cache isolation

**Property:** An Authorization request or a Cookie request to a dynamic URL reaches the origin independently, and its response is never shared with another request in the checked sequences. On a static URL, Varnish strips Cookie before caching, except when Authorization makes the request pass to the origin.

**Harm:** A shared response can expose one client's content or credentials to another client.

## Check the change

1. Read the covered code and compare it to the last verified commit, including uncommitted changes:

   ```sh
   git diff e706c481ee7fb3fde444785064f1427a2b0dcedd -- cache-policy.vcl
   ```

   The coverage record below identifies the behavior to compare. Review any affected assumptions or URL classifications before interpreting the result.
2. From the repository root, run:

   ```sh
   python3 test/formal/check_cache_isolation.py
   ```

   It requires Python 3.10+, Docker with `host-gateway` support, and network access for the first image build. It builds `varnish-cache-isolation:7.1.1` from this repository's Dockerfile if absent, checks Varnish revision `7cee1c581bead20e88d101ab3d72afb29f14d87a`, mounts the current `cache-policy.vcl`, and starts a temporary Varnish container and HTTP origin. The container and origin are cleaned up after the run. If the Dockerfile or installed Varnish changes, rebuild with `docker build -t varnish-cache-isolation:7.1.1 .`; the version check must still pass.
3. A `PASS` means every case listed under Bounds completed. `FAIL` prints the URL and the actual request/response prefix that exposed a violation; compare it to `vcl_recv`, `vcl_backend_response`, and the origin headers to decide whether the policy is wrong or the check's stated assumptions no longer apply. `ERROR`, a Docker failure, or a missing pass means the check did not complete. Report real violations with their request sequence; do not weaken the property to obtain a pass.
4. If intended code changes alter the property or its assumptions, update the checker and this record together. Confirm a broken scratch variant is detected, restore it, and rerun against the actual code. Move the sync commit to the new committed revision only after confirming the check describes that revision.

To challenge the check, in a scratch checkout remove the `if (req.http.Authorization) { return (pass); }` block in `vcl_recv` and rerun it. With the current policy it reports an anonymous response being served to an authenticated request; restore the block before the normal run. Removing the dynamic Cookie pass or making its static-path check match a query suffix also produces a failure.

## Bounds and assumptions

The checker executes real VCL through Varnish, not a model. It enumerates every three-request GET sequence over seven credentials (anonymous, Alice's or Bob's Authorization, Alice's or Bob's Cookie, and each client's combined headers), and every two-request sequence over those credentials with GET or HEAD. Each sequence starts with a new URL and an empty cache entry. It repeats them for a dynamic URL, a dynamic URL with a `.js` query suffix, a `.css` URL with a query, and a mixed-case `.Js` URL with a query: 2,156 sequences and 5,684 requests total.

The HTTP origin echoes the credentials it received and a unique origin request ID, with `Cache-Control: public, max-age=3600`. A credential-bearing request that must pass must have a new origin ID; every response must reflect the credentials expected at the origin. The unique IDs reveal reuse even on HEAD, where there is no response body. `X-Cache` appears in failure traces for diagnosis but is not the isolation oracle.

This is exhaustive only over those finite, sequential inputs. It does not establish a mathematical proof for arbitrary requests, concurrency, unsafe methods, encoding variants, ESI, Vary, Set-Cookie, cache-control permutations, expiry, cache eviction, backend outages, or distributed caches. No VCL verifier was identified that can check the production policy directly; generated requests therefore exercise the actual Varnish code. The test uses a local origin and a minimal backend definition without the production health probe.

## Coverage record

Last confirmed against commit `e706c481ee7fb3fde444785064f1427a2b0dcedd`:

- `cache-policy.vcl`: `vcl_recv` method, Authorization, static-path classification, Cookie stripping, Cookie pass, and hash decisions; `vcl_backend_response` Authorization storage guard and subsequent cacheability decisions. The check also exercises the relevant Varnish 7.1.1 built-in cache behavior and `vcl_backend_fetch` forwarding. The Authorization storage guard is a second defense behind request pass: this check does not establish its independent effectiveness.
- `test/formal/check_cache_isolation.py`: finite input generation, origin identity, and the observable isolation oracle. Its bounds and assumptions above are part of the coverage contract.

When covered code changes after the sync commit, inspect the diff even if the check passes: a finite runtime check cannot detect every semantic change. For changes that went unchecked, use `/maintain-formal-verification-skill` to bring this record and the checker back in step.
