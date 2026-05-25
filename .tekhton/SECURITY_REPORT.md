## Summary
This changeset consists entirely of test infrastructure cleanup for the m23 TUI Ops Port milestone: two Go test files receive standard `t.Setenv()` env-isolation calls to prevent parent-shell MANIFEST state from leaking into fixture-based tests, and five bash test files are retired to 22-line skip stubs whose sole effect is `printf … ; exit 0`. No production logic was modified. There are no new input surfaces, no credential handling, no network calls, and no injection-susceptible code paths in any changed file.

## Findings
None

## Verdict
CLEAN
