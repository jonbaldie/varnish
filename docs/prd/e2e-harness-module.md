# PRD: Deepen the E2E Harness Module

## Problem Statement

The E2E harness proves important cache safety behavior, but each Makefile target repeats Docker lifecycle, lock management, readiness polling, temporary files, curl calls, header parsing, request-id checks, and teardown. The tests exercise real behavior, but the harness interface is shallow.

## Solution

Create a deeper E2E harness module with a small scenario interface and semantic HTTP assertions. Keep the real Docker, Varnish, hostile backend, and curl behavior underneath that interface.

## User Stories

1. As a maintainer, I want scenario setup to be expressed once, so that lifecycle bugs are fixed in one place.
2. As a contributor, I want tests to read in cache-domain terms, so that assertions show behavior rather than shell mechanics.
3. As a maintainer, I want readiness polling to be shared, so that timeout and log behavior stays consistent.
4. As a maintainer, I want HTTP assertions to name cache hits, cache misses, origin hits, and client isolation, so that failures point at behavior.
5. As a maintainer, I want adding a new hostile backend scenario to require minimal boilerplate, so that test coverage can grow without copy-paste.
6. As a maintainer, I want Docker locks and project names handled locally, so that parallel or repeated runs stay reliable.
7. As a contributor, I want the harness to keep using real adapters, so that tests do not become tautological.

## Implementation Decisions

- Treat the E2E harness as a module.
- The scenario interface should include the scenario name, port, compose profile or files, readiness URL, and assertions to run.
- The HTTP assertion interface should speak in cache behavior terms: cache hit, cache miss, origin request id, body field, response header, client isolation.
- The implementation may remain shell-based if it provides a smaller, more semantic interface.
- Prefer prefactoring duplicated lifecycle behavior before adding new scenarios.

## Testing Decisions

- Existing E2E tests are the prior art and should keep running against real containers.
- Harness changes should preserve current cache behavior assertions before adding new ones.
- Add a small canary scenario to prove the harness reports useful failures.
- No mocks: the harness should keep exercising real Docker Compose, Varnish, curl, and hostile backend behavior.

## Out of Scope

- Replacing the Makefile with a full test framework unless the existing shell interface blocks the deeper module.
- Removing E2E tests.
- Replacing real HTTP requests with mocked requests.

## Further Notes

This work is worth exploring after the cache policy seam is stabilized, because a deeper harness gets more leverage once it is proving the shared policy.
