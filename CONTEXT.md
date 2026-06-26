# Context

## Domain Terms

- **Cache policy**: VCL rules that decide request normalization, pass/hash behavior, TTL, grace, purge access, and cache observability.
- **Hostile backend**: executable backend adapter used by E2E tests to expose cache-safety behavior that generic nginx cannot show clearly.
- **E2E harness**: Makefile, compose files, and hostile backend scenarios that run Varnish against real HTTP traffic.
- **Standalone image**: built Docker image whose embedded VCL includes generated localhost backend configuration.
- **Compose image**: same Varnish image run with mounted VCL and Docker-network backend configuration.
