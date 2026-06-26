# PRD: Single-Source Cache Policy Module

## Problem Statement

The cache policy is the deepest module in the repo, but it used to be copied into the hostile backend test path. That weakened locality: changes to PURGE handling, request normalization, pass/hash behavior, TTL, grace, and cache observability could drift between production VCL and E2E tests.

## Solution

Make the cache policy single-source. Keep backend addressing and health probing as small adapters, so the compose image, standalone image, and hostile backend all exercise the same cache policy implementation.

## User Stories

1. As a maintainer, I want cache policy changes to land in one place, so production and E2E behavior cannot drift silently.
2. As a maintainer, I want hostile backend tests to run against the production cache policy, so passing tests prove shipped behavior.
3. As a maintainer, I want backend host, port, and probe differences to be explicit adapters, so environment-specific wiring does not copy cache rules.
4. As a maintainer, I want static asset behavior tested through the real cache policy, so cookie stripping and cache hits remain trustworthy.
5. As a maintainer, I want dynamic cookie-bearing behavior tested through the real cache policy, so client isolation stays protected.
6. As a maintainer, I want 5xx and grace behavior tested through the real cache policy, so resilience rules stay localized.
7. As a contributor, I want one cache policy interface to learn, so safe changes do not require comparing VCL forks.

## Implementation Decisions

- Treat the cache policy as a module.
- Treat backend addressing and probe configuration as adapters at the seam.
- Prefer a single VCL implementation exercised by all E2E scenarios.
- If VCL inclusion or generation is introduced, the public interface should be backend host, backend port, and probe path, not raw VCL text.
- The hostile backend remains an executable backend adapter, not a replacement cache policy implementation.
- The compose image and standalone image must continue working as distinct adapters.

## Testing Decisions

- Tests should exercise external HTTP behavior through Varnish, not internal VCL structure.
- Hostile backend E2E scenarios remain the main proof path.
- Add or update a canary test that fails if the hostile backend path stops using the shared cache policy.
- Existing smoke tests continue proving the standalone image starts and VCL compiles.
- No mocks: tests use real Varnish, real Docker containers, and real HTTP requests.

## Out of Scope

- Rewriting cache policy semantics.
- Replacing Varnish.
- Adding new cache feature behavior beyond preserving existing rules.
- Changing the hostile backend response contract unless required to keep the shared policy testable.

## Further Notes

This top architecture recommendation protects the repo's deepest module and gives the E2E harness more leverage.
