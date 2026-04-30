## Testing
- Use red/green TDD. 
- Actually run the code, automated tests by themselves aren't sufficient.
- Use 'tracer bullets', aka canary tests, aka smoke tests, aka E2E tests. 
- Actively look for genuine bugs, edge cases, failure modes - if you find these, then you've succeeded, not failed. 
- No mocks, ever. They're a common escape hatch for writing tautological or pat-self-on-back tests.
