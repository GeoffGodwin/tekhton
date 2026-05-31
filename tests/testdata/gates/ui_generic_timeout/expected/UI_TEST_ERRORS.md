# UI Test Errors — TIMESTAMP
## Stage
post-coder

## UI Test Command
`printf 'Test timeout exceeded\n' && exit 124`

## Exit Code
124

## Output (last 100 lines)
```
Test timeout exceeded

```

## UI Gate Diagnosis
- Timeout class: generic_timeout
- Deterministic env applied: yes (normal)
- Hardened rerun attempted: no
- Suggested action: Increase UI_TEST_TIMEOUT only after confirming the command is non-interactive and any required dev server is healthy.
