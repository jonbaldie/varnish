# Context

## Domain Terms

- **Cache policy**: VCL rules that decide request normalization, pass/hash behavior, TTL, grace, purge access, and cache observability.
- **Hostile backend**: executable backend adapter used by E2E tests to expose cache-safety behavior that generic nginx cannot show clearly.
- **E2E harness**: Makefile, compose files, and hostile backend scenarios that run Varnish against real HTTP traffic.
- **Standalone image**: built Docker image whose embedded VCL includes generated localhost backend configuration.
- **Configuration check**: `/start.sh --check` validates runtime settings, renders backend VCL, and compiles the selected VCL without starting Varnish.
- **Compose image**: same Varnish image run with mounted VCL and Docker-network backend configuration.
- **Campaign runtime**: the Varnish instance the bug-finding campaign starts once through `/start.sh`; startup readiness and the stress phase inspect it through checked health snapshots.
- **Health snapshot**: one reading of the campaign runtime's required counters and its varnishd manager and child processes. It is either available or unavailable with collector diagnostics; missing values are never defaulted.
- **Stress result**: the stress phase's report entry. Its execution status (`completed` or `incomplete`) and connection-failure counts are kept apart from Varnish findings.
