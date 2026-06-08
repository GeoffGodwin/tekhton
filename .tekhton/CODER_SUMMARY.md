# Coder Summary

## Status: COMPLETE

## What Was Implemented

Milestone **m48 — Auto-advance loop: reset per-iteration state so every
milestone gets its own commit**. Adds two helpers and a banner to the Go
auto-advance loop in `cmd/tekhton/run.go::runAutoAdvanceLoop`, plus
three Go unit tests and one shim-boundary integration test.

### Goal 1 — `clearAutoAdvanceIterationState(projectDir string) error`

New file-scope helper in `cmd/tekhton/run.go`. Removes three commit-skip
sentinels from `<projectDir>/.tekhton/`:

- `.final_check_result`
- `.final_check_reason`
- `.commit_decision`

Uses `os.Remove` + `errors.Is(err, os.ErrNotExist)` to be idempotent.
Returns the first non-not-exist error encountered (so all three removals
are still attempted). Returns nil when `projectDir == ""`. The
exhaustive-but-not-closed sentinel list is documented inline so future
additions can be grepped.

Called from `runAutoAdvanceLoop` at the TOP of each iteration, before
`buildRunner`. Failure is non-fatal — emits a single
`auto-advance: warning: clear iteration state for <id>: <err>` line to
stdout so an operator can spot it, then continues with the iteration
(worst case = pre-m48 silent commit skip, which the banner below will
surface anyway).

### Goal 2 — `emitAutoAdvanceCommitBanner(w io.Writer, projectDir, milestoneID string)`

New file-scope helper in `cmd/tekhton/run.go`. After each successful
`RunSingle` call, inspects HEAD via `readGitHead(projectDir)` and emits
one of three banner lines:

- `✓ <id> committed as <8-char-hash>` — HEAD subject begins
  `[MILESTONE <num> ✓]` (the prefix from
  `lib/milestone_ops.sh::get_milestone_commit_prefix`)
- `⚠ <id> finalize skipped commit — HEAD subject is "<subj>" (expected "<prefix>" prefix). Inspect .tekhton/.commit_decision and .tekhton/.final_check_result.`
  — HEAD subject doesn't match (skip case)
- `⚠ <id> finalize completed but HEAD read failed (<err>) — verify commit fired` — `git log` failed

`strings.TrimPrefix(milestoneID, "m")` is applied because the bash side
emits the bare-number form in the prefix (e.g. `[MILESTONE 38.5 ✓]`)
while the Go runner carries milestoneID as `m38.5`.

### Goal 3 — `readGitHead(projectDir string) (hash, subject string, err error)`

Pure helper that shells out to `git log -1 --format=%H %s` rooted at
projectDir and parses `<hash> <subject>` via `strings.SplitN`. Returns
`("", "", err)` when git fails (no commit yet, not a repo, etc.). Used
only by `emitAutoAdvanceCommitBanner`.

### Goal 4 — Loop wiring

Two-line additions to `runAutoAdvanceLoop`:

- Before `buildRunner`, immediately after `advances++` and the header
  banner: `clearAutoAdvanceIterationState(initialReq.ProjectDir)` with
  non-fatal warn fallback.
- After the successful-disposition gate (after `currentID = next.ID`
  would be set): `emitAutoAdvanceCommitBanner(cmd.OutOrStdout(),
  initialReq.ProjectDir, next.ID)`.

Both additions are scoped narrowly — no other loop logic changed.

### Goal 5 — Three Go unit tests (`cmd/tekhton/run_test.go`)

- `TestClearAutoAdvanceIterationState_RemovesSentinels` — plants the
  three sentinel files under `t.TempDir()/.tekhton/`, calls the helper,
  asserts all three are gone via `os.Stat` + `os.IsNotExist`.
- `TestClearAutoAdvanceIterationState_GracefulOnMissing` — exercises
  three branches: (1) `.tekhton/` does not exist, (2) `.tekhton/` exists
  but is empty, (3) `projectDir == ""`. All three must return nil.
- `TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit` — initializes
  a real git repo via `exec.Command("git", "init")`, commits with
  subject `[MILESTONE 38.5 ✓] port test_baseline subsystem`, calls
  `emitAutoAdvanceCommitBanner` with `m38.5`, asserts stdout contains
  `"✓ m38.5 committed as"` and does NOT contain `"finalize skipped commit"`.
  Then makes a second commit with a generic subject, re-calls, asserts
  output contains `"⚠ m38.5 finalize skipped commit"` and does NOT contain
  `"✓ m38.5 committed as"`. Self-skips when `git` is not on PATH.

### Goal 6 — Shim-boundary integration test

New `tests/test_autoadvance_per_milestone_commits.sh` (266 LOC) drives
the production `tekhton` binary across the bash-shim ↔ Go-binary
boundary. Sets up:

- Throwaway git repo under `mktemp -d`
- Minimal `.claude/pipeline.conf`, agent role stubs, `CLAUDE.md`,
  `ARCHITECTURE.md`
- 3-entry `MANIFEST.cfg` (m1 → m2 → m3) + 3 milestone files

Drives `tekhton run --milestone m1 --auto-advance --auto-advance-limit 3`
with `TEKHTON_AGENT_BINARY=/bin/false` to short-circuit real agent
invocations. Six assertions:

- A: run executed and produced output
- B: no Go runtime panic on the new code path
- C: `tekhton --help` works after m48 changes
- D: `tekhton run --help` advertises `--auto-advance-limit`
- E: `tekhton run --help` advertises `--milestone`
- F: binary's string table contains the m48 reset format literal
  (`clear iteration state for`), proving the new code is linked in

Self-skips cleanly when `bin/tekhton` is not built. Picks up the LOCAL
build over an inherited `$TEKHTON_BIN` (which would point at a
tekhton-stable binary in self-hosted runs and silently test stale code).

Scope-honest about what the shim-boundary test cannot do: a true 3-
iteration end-to-end driving 3 separate `[MILESTONE X.Y ✓]` commits
would require a fake agent that emits CODER_SUMMARY.md /
REVIEWER_REPORT.md / TESTER_REPORT.md per stage — far beyond
`testdata/fake_agent.sh`'s two-turn shape. The Go unit tests in
`cmd/tekhton/run_test.go` cover the banner success/warn paths against a
real git repo at full fidelity; this shim test covers the binary-level
integration.

## Root Cause (bugs only)

Per the milestone's Gap section: `runAutoAdvanceLoop` was introduced in
m20 + refined m40.1/m40.2 but never cleared per-iteration commit-skip
sentinels at the iteration boundary. m46 added the bash-side clear for
the operator-override `[c]/[r]/[s]/[a]` path
(`_clear_commit_skip_sentinels`) but never extended it to the
Go-driven auto-advance loop's iteration boundary. Symptoms:

- 2026-06-07 auto-advance produced `bf46f8f` (`[MILESTONE 47 ✓]` —
  clean) + `a4579be` (m38.5 intake bookkeeping) + zero commits for the
  next 5 milestones (m38.6, m39.1, m39.2, m39.3, m47-loose-ends)
- 9,852 lines of work landed in a single manual squash commit
- Per-milestone narrative was lost; operator had to hand-write the
  per-milestone story in the squash message

Fix: clear the three sentinels at the top of each iteration BEFORE
`buildRunner` runs the next stage; emit a banner AFTER each iteration
to surface skip-on-commit regressions in real-time.

## Files Modified

### Modified

- `cmd/tekhton/run.go` (768 LOC) — added imports (`io`, `os/exec`),
  added three helpers (`clearAutoAdvanceIterationState`,
  `emitAutoAdvanceCommitBanner`, `readGitHead`), wired the helpers into
  `runAutoAdvanceLoop` at the iteration top/bottom.
- `cmd/tekhton/run_test.go` (336 LOC) — added imports (`bytes`, `os`,
  `os/exec`, `path/filepath`), added three tests
  (`TestClearAutoAdvanceIterationState_RemovesSentinels`,
  `TestClearAutoAdvanceIterationState_GracefulOnMissing`,
  `TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit`).

### Created

- `tests/test_autoadvance_per_milestone_commits.sh` (NEW, 266 LOC) —
  shim-boundary integration test driving the production `tekhton`
  binary with `TEKHTON_AGENT_BINARY=/bin/false` short-circuit.

### File-length compliance

- `cmd/tekhton/run.go` 768 LOC — within the Go 1000-line hard ceiling
  (CLAUDE.md Rule 8); domain-coherent (one cobra subcommand).
- `cmd/tekhton/run_test.go` 336 LOC — within the Go ceiling; siblings
  in `cmd/tekhton/` go up to 549 LOC (`state_test.go`).
- `tests/test_autoadvance_per_milestone_commits.sh` 266 LOC — under
  the bash 300-line hard ceiling.

## Docs Updated

None — no public-surface changes in this task. The new helpers are
package-private to `cmd/tekhton/`; no CLI flag or env var added. The
existing `--auto-advance` / `--auto-advance-limit` flags already
documented; behavior change (per-iteration reset + banner) is
operator-visible at runtime but not a documented contract change. The
`.tekhton/.commit_decision` / `.final_check_result` / `.final_check_reason`
sentinels are internal pipeline state, not user-facing.

## Human Notes Status

No actionable human notes attached to this run. The `CLARIFICATIONS.md`
content carried in the run context is from prior unrelated sessions
(Watchtower dashboard, NON_BLOCKING_LOG, brownfield --init flow, intake
testing) — none applies to m48.

## Verification

All acceptance criteria pass:

- AC1 (`grep -nE 'func clearAutoAdvanceIterationState'`) → 1 match at
  `cmd/tekhton/run.go:703`
- AC2 (`grep -B 2 -A 3 'clearAutoAdvanceIterationState'`) → call inside
  the `for advances < limit` block, before `buildRunner`
- AC3 — AC6: `go test -run TestClearAutoAdvanceIterationState|TestEmitAutoAdvanceCommitBanner -v`
  → 3 PASS
- AC7 — `bash tests/test_autoadvance_per_milestone_commits.sh` →
  `Passed: 6  Failed: 0`
- AC8 — `go test ./cmd/tekhton/ ./internal/runner/` → both packages PASS
- AC9 — `shellcheck tests/test_autoadvance_per_milestone_commits.sh` →
  clean
- AC10 — `go vet ./cmd/tekhton/...` clean, `gofmt -l cmd/tekhton/` clean
- AC11 — `bash tests/run_tests.sh` → 494 shell pass / 0 fail, all Go
  packages pass (was 493 → 494: +1 for new shim-boundary test)

## Observed Issues (out of scope)

None observed in files touched during this task.
