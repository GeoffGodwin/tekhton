# UI Test Errors — TIMESTAMP
## Stage
post-coder

## UI Test Command
`printf 'AssertionError: button not found\n' && exit 1`

## Exit Code
1

## Output (last 100 lines)
```
AssertionError: button not found

```

## UI Gate Diagnosis
- Timeout class: none
- Deterministic env applied: yes (normal)
- Hardened rerun attempted: no
- Suggested action: UI tests failed without a recognized timeout signature; inspect the captured output for the underlying assertion or runtime error.
