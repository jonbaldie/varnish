# PRD: Backend Configuration Adapter

## Problem Statement

Backend configuration is an accidental seam. Today the standalone image depends on text substitutions against VCL content, while the compose image and hostile backend use mounted VCL files. The interface is not backend host, port, and probe configuration; it is knowledge of exact VCL text.

## Solution

Create a real backend configuration adapter with a narrow interface for backend host, backend port, and probe path. Use that interface for the standalone image, compose image, and hostile backend scenarios.

## User Stories

1. As a Docker image user, I want to configure the backend without editing VCL text, so that the image is safer to run in different environments.
2. As a maintainer, I want backend wiring to be explicit, so that production cache policy is not patched by fragile text replacement.
3. As a maintainer, I want compose and standalone modes to share the same configuration interface, so that mode-specific behavior stays local.
4. As a contributor, I want backend probe differences to be named, so that health-check changes are easy to reason about.
5. As a maintainer, I want hostile backend scenarios to supply backend configuration as an adapter, so that tests do not fork cache policy.
6. As an operator, I want sensible defaults to continue working, so that existing quick-start usage remains simple.

## Implementation Decisions

- The backend configuration module exposes host, port, and probe path as its interface.
- Existing compose image defaults should continue to work without extra user configuration.
- Existing standalone image defaults should continue to point at a localhost backend.
- The adapter should avoid raw text substitutions that depend on exact VCL formatting.
- The adapter must preserve VCL compilation checks for embedded and mounted configurations.

## Testing Decisions

- VCL compilation remains a required canary for every generated or configured policy.
- Smoke tests should verify both compose image and standalone image backend defaults.
- E2E tests should prove that changing backend configuration does not change cache policy behavior.
- No mocks: tests should run actual container builds and Varnish commands.

## Out of Scope

- Supporting every Varnish backend option.
- Building a general-purpose VCL templating framework.
- Changing the public cache behavior.

## Further Notes

This PRD can be implemented before or alongside the cache policy module work, but the highest leverage comes when both share the same seam.
