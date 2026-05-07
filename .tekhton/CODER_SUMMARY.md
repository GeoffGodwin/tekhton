# Coder Summary

## Status: COMPLETE

## What Was Implemented
Addressed all 17 open non-blocking notes in `.tekhton/NON_BLOCKING_LOG.md`. The
17 entries collapse to 10 distinct issues (several were duplicated across the
m07/m08 and m13/M12 milestone entries). Each is now in the **Resolved**
section of the log with a one-line resolution summary; details below by class.

### Code/test changes
- **`internal/supervisor/retry.go`** — Added a typed-error early guard in
  `retryLoop` for `MaxAttempts <= 0` so a degenerate policy fails loudly
  instead of silently returning `(nil, nil)`. Replaced the now-unreachable
  trailing `return lastResult, nil` with a defensive error return so a
  future refactor that re-introduces the silent-nil path is caught. Added
  a comment in `Delay()` documenting the intentional zero-delay behavior
  for `BaseDelay <= 0`.
- **`internal/supervisor/retry_test.go`** — Added four new tests:
  `TestRetry_MaxAttemptsZero_Errors`, `TestRetry_MaxAttemptsNegative_Errors`,
  `TestRetryPolicy_Delay_BaseDelayZeroReturnsZero`,
  `TestRetryPolicy_Delay_BaseDelayNegativeReturnsZero`.
- **`lib/milestone_query.sh`** — `parse_milestones_auto` now returns 0 when
  the manifest loaded successfully but contains zero rows. The previous
  `[[ "$found" -eq 1 ]]` guard incorrectly reported failure for an
  empty-but-valid manifest.
- **`lib/orchestrate_main.sh`** — Removed the `set -euo pipefail` directive.
  This file is sourced from `lib/orchestrate.sh` and inherits the caller's
  shell options per the reviewer role spec.
- **`scripts/dag-parity-check.sh`** — Now gracefully skips with exit 0 and a
  yellow "SKIP" banner when `go` or `make` is missing (analogous to how
  `check_indexer_available` degrades when Python is absent). Set
  `DAG_PARITY_REQUIRE=1` to fail-fast instead. Added a Requirements section
  to the script header.
- **`go.mod`** — Ran `go mod tidy`. `github.com/fsnotify/fsnotify v1.9.0`
  and `golang.org/x/sys v0.13.0` are now correctly listed as direct
  dependencies.
- **`cmd/tekhton/state_cmd_test.go` (NEW)** — Added 7 tests covering the
  Cobra `Execute()` paths for `state update`, `state clear`, and the
  full-snapshot read branch of `state read`. `cmd/tekhton` package
  coverage rose 78.5% → 81.1%, clearing the ≥80% target.

### Resolved without code change (informational notes)
- **m11 §1.5 cross-language metric divergence** — The substitute metric used
  by the coder is more accurate than the AC's literal `lang_origin: ambiguous`
  wording (no such field exists). Marked resolved as informational.
- **m10 `run_test.go` length (684 lines)** — Per CLAUDE.md Rule 8, the Go
  split signal is purpose fragmentation, not line count, and the file is
  domain-coherent. No split required.
- **m14 `frontier`/`active` stdout shape** — The bare-newline-separated ID
  output is the locked m13 contract that `scripts/dag-parity-check.sh`
  asserts. Deferring an envelope conversion to a future v2 dag subcommand
  cycle so the parity gate isn't broken.

## Root Cause (bugs only)
N/A — these are tech-debt items, not bug reports.

## Files Modified
- `internal/supervisor/retry.go` — MaxAttempts<=0 guard, BaseDelay comment, defensive trailing return
- `internal/supervisor/retry_test.go` — 4 new tests for the guards
- `lib/milestone_query.sh` — empty-manifest exit-code fix
- `lib/orchestrate_main.sh` — removed `set -euo pipefail` from sourced file
- `scripts/dag-parity-check.sh` — skip-when-missing toolchain handling
- `go.mod` — `go mod tidy` (fsnotify and x/sys promoted to direct)
- `cmd/tekhton/state_cmd_test.go` (NEW) — coverage tests for state update/clear/read full-JSON
- `.tekhton/NON_BLOCKING_LOG.md` — moved 17 entries from Open to Resolved

## Docs Updated
None — docs agent found no updates needed. No public-surface changes in this task. The CLI surface, exported function signatures, config keys, and prompt template variables are all unchanged. The `scripts/dag-parity-check.sh` requirements section is self-documenting in the script header. The `BaseDelay`/`MaxAttempts` behavior changes are internal supervisor implementation details surfaced only through typed errors.

## Human Notes Status
There were no `## Human Notes` items injected into this run — only the
17 non-blocking log entries above, all of which are addressed.

## Self-Check
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` — clean.
- `go vet ./...` — clean.
- `go build ./...` — clean.
- `go test ./...` — all packages pass; `cmd/tekhton` coverage 81.1%.
- `bash tests/run_tests.sh` — 496 shell tests pass; 1 unrelated flake
  (`test_watchtower_parallel_groups_datalist.sh` — passes when re-run in
  isolation; touches Watchtower JS only, unrelated to my changes).
- File length check — all modified files under their respective ceilings:
  - `lib/orchestrate_main.sh` 247 lines (≤300)
  - `lib/milestone_query.sh` 144 lines (≤300)
  - `scripts/dag-parity-check.sh` 283 lines (≤300)
  - `internal/supervisor/retry.go` 288 lines (≤600 soft)
  - `internal/supervisor/retry_test.go` 680 lines (≤1000 hard, domain-coherent)
  - `cmd/tekhton/state_cmd_test.go` 159 lines (NEW, ≤600 soft)
