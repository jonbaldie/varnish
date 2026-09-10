## Agent skills

### Issue tracker

Issues live in GitHub Issues for this repo. See `docs/agents/issue-tracker.md`.

### Triage labels

Default role labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` and `docs/adr/`. See `docs/agents/domain.md`.

## Testing
- Use red/green TDD. 
- Actually run the code, automated tests by themselves aren't sufficient.
- Use 'tracer bullets', aka canary tests, aka smoke tests, aka E2E tests. 
- Actively look for genuine bugs, edge cases, failure modes - if you find these, then you've succeeded, not failed.
- No mocks, ever. They're a common escape hatch for writing tautological or pat-self-on-back tests.

Fleet shares an 8-core macOS host with other repositories. During iteration, run one named test target at a time, for example `make test-vcl-compile`. Do not start independent Docker test targets in parallel.

Before handoff, run the complete Docker gates serially:

```bash
COMPOSE_PARALLEL_LIMIT=1 make -j1 test test-e2e-hard
```

Wait for this command to return before you start another Docker test or campaign. The test recipes use teardown traps to remove containers and Compose resources. Do not interrupt or overlap that teardown.
