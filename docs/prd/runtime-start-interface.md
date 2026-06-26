# PRD: Runtime Start Interface

## Problem Statement

The container runtime interface exposes the full Varnish start command. The start module only expands a command string, so callers must understand the listen address, foreground mode, VCL path, storage configuration, and varnishd flags to change one runtime value.

## Solution

Deepen the runtime start module so it accepts narrow configuration variables, applies defaults and validation, and constructs and execs the varnishd command locally.

## User Stories

1. As a Docker image user, I want to configure common runtime values without replacing the whole command, so the image is easier to run safely.
2. As a maintainer, I want startup defaults to live in one module, so runtime changes have locality.
3. As an operator, I want invalid runtime configuration to fail early, so container startup errors are clear.
4. As a maintainer, I want the process to exec varnishd, so signal handling remains predictable.
5. As a contributor, I want tests to verify the runtime interface, so changes do not silently alter container startup behavior.

## Implementation Decisions

- Treat the start script as the runtime start module.
- Interface should expose common configuration values such as listen address, VCL path, storage size, and extra arguments.
- Preserve current default runtime behavior.
- Implementation should construct the varnishd command internally and execute it as the container process.
- Keep an escape hatch for advanced varnishd flags if it does not undermine the smaller interface.

## Testing Decisions

- Smoke tests should continue proving varnishd starts inside the built image.
- Add canary coverage for default startup and at least one overridden runtime value.
- Tests should inspect external container behavior and process startup, not private shell implementation.
- No mocks: use the built image and real varnishd.

## Out of Scope

- Changing cache policy behavior.
- Supporting every varnishd option as a first-class variable.
- Introducing a separate process supervisor.

## Further Notes

This is speculative compared with cache policy and harness work. It should be tackled only if runtime configuration flexibility is a real user need.
