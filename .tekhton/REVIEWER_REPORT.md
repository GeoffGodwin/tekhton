# Reviewer Report — m03 Pipeline State Wedge (Cycle 2)

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/state_helpers.sh:118` — The int-field omit-on-zero logic (`[[ "$val" = "0" ]] && continue`) is correct but undocumented. A one-line comment ("zero omitted — matches omitempty on first-class int fields") would prevent a future maintainer from treating it as a bug.
- `lib/state_helpers.sh:152` — The awk-based JSON reader does not handle embedded escaped double-quotes (`\"`). Values like `resume_task='key="val"'` would be truncated at the first inner quote. Acceptable since the fallback is transitional; a comment naming the limitation would clarify intent.

## Coverage Gaps
- `cmd/tekhton/state.go` — No unit tests cover the CLI layer: `applyField` reflection, `lookupField`, `parseFieldPairs`, or `resolveStatePath`. A regression in field-tag matching falls through to `extra` silently.
- `state write` subcommand (stdin JSON → file) has zero test coverage.
- Exit-code distinction (`1` = missing, `2` = corrupt) from `tekhton state read` is only exercised via the Go unit test; no bash-layer test drives the CLI and asserts the process exit code.

## Drift Observations
- `lib/state_helpers.sh:190-220` — No `# REMOVE IN m05` annotation on the legacy markdown branch in `_state_bash_read_field`. When `legacy_reader.go` is deleted in m05 this dead branch is likely to survive the cleanup pass. Adding the annotation now keeps the two removal targets in sync.

---

### Prior Blocker Disposition

**FIXED — `internal/state/snapshot.go:193-194`.**
`readLocked()` now reads `return New(s.path).Read()` — a fresh, unlocked `Store` bound to the same path. The struct copy (`tmp := *s`) that triggered `go vet -copylocks` has been removed. Fix is correct and minimal; the `Update()` flow continues to avoid a second mutex acquisition because `Read()` itself takes no lock.
