## Summary
M65 adds Serena LSP and repo map guidance blocks to 12 prompt templates and extracts
tester timing logic from `stages/tester.sh` into a new `stages/tester_timing.sh`
file. The prompt changes are pure text additions inside `{{IF:SERENA_ACTIVE}}` and
`{{IF:REPO_MAP_CONTENT}}` conditionals — no executable code. The new shell file
reads a report file, extracts numeric values via regex, and performs integer
arithmetic. All extracted values are validated as `^[0-9]+$` before use. No
authentication, networking, credential handling, or user-controlled input is
involved. Security posture is unchanged.

## Findings
None

## Verdict
CLEAN
