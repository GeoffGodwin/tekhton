# Build Errors — TIMESTAMP
## Stage
post-coder

## UI Test Failures
Command: `printf 'Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.\n' && exit 124`
Exit code: 124

```
Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.

```

## UI Gate Diagnosis
- Timeout class: interactive_report
- Deterministic env applied: yes (hardened)
- Hardened rerun attempted: yes
- Suggested action: Command stays alive serving the HTML report; configure the gate to disable report serving (PLAYWRIGHT_HTML_OPEN=never) or pass --reporter=line to UI_TEST_CMD.
