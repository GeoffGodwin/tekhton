<!-- milestone-meta
id: "48"
status: "todo"
-->

# m48 — Auto-Advance Loop: Reset Per-Iteration State So Every Milestone Gets Its Own Commit

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The m47 dogfood run was the most productive auto-advance ever — six milestones in a single chain (m47 + m38.5 + m38.6 + m39.1 + m39.2 + m39.3). m47's envelope-is-source-of-truth fix did exactly what it promised: every stage envelope correctly reported its verdict, every milestone's work landed correctly in the tree, every manifest entry flipped to `done`. But the *per-milestone commit chain* broke partway through. After m47's clean `[MILESTONE 47 ✓]` commit at `bf46f8f` and m38.5's intake-stage bookkeeping commit at `a4579be`, the auto-commit machinery went silent for the remaining 5 milestones of the chain. 9,852 lines of work landed in a single manual-cleanup commit ("Auto Advance through m38.5–m39.3") with no per-milestone narrative, forcing the operator to write the per-milestone story into the squash commit message by hand. V5 will lean heavily on auto-advance — this bug stops it from being a clean operator experience. |
| **Gap** | `cmd/tekhton/run.go::runAutoAdvanceLoop` (introduced in m20 and refined through m40.1/m40.2) iterates over milestones, calling `r.RunSingle(ctx, nextReq)` per iteration. The runner per-iteration calls `r.Hooks.Finalize(ctx, req, res)`, which dispatches the bash `_hook_commit` through the Go finalize orchestrator. Some piece of state — most likely the `.tekhton/.final_check_result`, `.tekhton/.commit_decision`, or `.tekhton/.final_check_reason` sentinel files — accumulates between iterations and gets read as "non-zero" by `_hook_commit` from iteration 2 onward. m46 added `_clear_commit_skip_sentinels` to handle the operator-override path (`[c]/[r]/[s]/[a]` in the replan dialog), but did NOT add it to the auto-advance loop's between-iteration boundary. The first iteration has a clean tree (the operator started with a clean tree); each subsequent iteration inherits the prior iteration's commit-decision sentinels, and `_hook_commit`'s skip path fires silently. The m46-added warn DOES emit a `warn` line per skipped iteration — but that line gets buried in the per-iteration log output and is easy to miss when chains run for hours. |
| **m48 fills** | Two pieces: (1) add a `clearAutoAdvanceIterationState` function called at the top of each `runAutoAdvanceLoop` iteration — removes `.tekhton/.final_check_result`, `.tekhton/.commit_decision`, `.tekhton/.final_check_reason`, and any other per-iteration sentinels found during the audit; (2) at the END of each successful iteration, emit a one-line operator-visible confirmation banner: `✓ m38.5 committed as <hash>` or `⚠ m38.5 finalize skipped commit (run with --verbose for details)`. The banner makes per-milestone commit success/failure impossible to miss the next time something regresses. Adds a Go unit test exercising the reset function and a shim-boundary integration test that drives a 3-iteration auto-advance and asserts each milestone produces its own `[MILESTONE X.Y ✓]` commit. |
| **Depends on** | m46 (provides `_clear_commit_skip_sentinels` in bash; m48's Go-side reset function does the same work from the Go iteration boundary), m47 (the envelope-source-of-truth fix that made today's 6-milestone chain possible; m48 hardens the commit cadence of that chain) |
| **Files changed** | `cmd/tekhton/run.go`, `cmd/tekhton/run_test.go`, `tests/test_autoadvance_per_milestone_commits.sh` (new) |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m41 | Finalize: stop false-blocking commit when milestone block can't be populated |
| m42 | Preflight: guard against no-op TEST_CMD |
| m43 | Version-bump completeness |
| m44 | Commit subject regression: stop falling back to `.claude/project_version.cfg` |
| m45 | Completion gate: stop false-halting on transient TEST_CMD failure |
| m46 | Replan detector body-grep + commit-skip cascade (operator-override path) |
| m47 | Stage verdict envelope is source of truth: subprocess errors don't override a PASS verdict |
| **m48** | **Auto-advance loop: reset per-iteration state so every milestone gets its own commit** |

---

## Design

### Sequencing note

m48 is independent of m39.4 (the V4 closer). Land m48 before m39.4 so the
V4 close-out run produces a clean `[MILESTONE 39.4 ✓]` commit instead of
needing a manual squash. After m48, the auto-advance loop is suitable for
V5's heavier reliance on multi-milestone chains.

### Goal 1 — `clearAutoAdvanceIterationState` helper

**File:** `cmd/tekhton/run.go`.

Add the helper at file scope alongside `runAutoAdvanceLoop`. The function
removes per-iteration commit-skip sentinels and is invoked at the top of
each loop iteration (before `buildRunner` and `r.RunSingle`).

```go
// clearAutoAdvanceIterationState removes commit-skip sentinels and other
// per-iteration state files that, if inherited from the previous
// milestone in the chain, would silently poison the current iteration's
// _hook_commit. The reset is intentionally minimal: every file listed
// here is a sentinel that the Go finalize chain WRITES during its own
// flow; clearing them at iteration start is equivalent to running the
// pipeline against a fresh tree.
//
// Without this reset, every iteration after the first inherits the
// previous iteration's .commit_decision="skipped" (or worse, a
// FINAL_CHECK_RESULT=1) and _hook_commit short-circuits. The m46-added
// warn fires on every skip, but the loud output gets lost in
// long-chain runs (six milestones × dozens of log lines each).
//
// Reference: 2026-06-07 auto-advance run that produced bf46f8f
// (m47 [MILESTONE ✓]) + a4579be (m38.5 intake bookkeeping) + zero
// commits for the next 5 milestones. The work landed correctly, but
// the per-milestone narrative was lost.
func clearAutoAdvanceIterationState(projectDir string) error {
    if projectDir == "" {
        return nil
    }
    tekhtonDir := filepath.Join(projectDir, ".tekhton")
    sentinels := []string{
        ".final_check_result",
        ".final_check_reason",
        ".commit_decision",
    }
    var firstErr error
    for _, name := range sentinels {
        path := filepath.Join(tekhtonDir, name)
        if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
            if firstErr == nil {
                firstErr = err
            }
        }
    }
    return firstErr
}
```

**Call site:** inside the `for advances < limit` loop, immediately
before `r, cleanup, err := buildRunner(nextReq, ...)`:

```go
// m48 — Reset per-iteration commit-skip sentinels. Without this, every
// iteration after the first inherits the previous one's
// .commit_decision / .final_check_result sentinels and _hook_commit
// silently skips.
if err := clearAutoAdvanceIterationState(initialReq.ProjectDir); err != nil {
    fmt.Fprintf(cmd.OutOrStdout(),
        "auto-advance: warning: clear iteration state for %s: %v\n",
        next.ID, err)
    // Non-fatal: continue with the iteration. The worst case is the
    // pre-fix behavior (silent commit skip), and the post-iteration
    // banner (Goal 2) will surface it.
}
```

### Goal 2 — Per-iteration confirmation banner

**File:** `cmd/tekhton/run.go`.

After `r.RunSingle(ctx, nextReq)` returns successfully, inspect the
git state and emit a one-line confirmation:

```go
res, runErr := r.RunSingle(ctx, nextReq)
cleanup()

if res != nil {
    printRunSummary(cmd.OutOrStdout(), res)
}
if runErr != nil {
    // ... existing error handling
}

// m48 — Per-iteration commit confirmation banner. Inspects HEAD to
// determine whether _hook_commit fired for this iteration. Lets the
// operator see at-a-glance whether the per-milestone narrative is
// being preserved.
emitAutoAdvanceCommitBanner(cmd.OutOrStdout(), initialReq.ProjectDir, next.ID)
```

Helper:

```go
func emitAutoAdvanceCommitBanner(w io.Writer, projectDir, milestoneID string) {
    headHash, headSubject, err := readGitHead(projectDir)
    if err != nil || headHash == "" {
        fmt.Fprintf(w,
            "⚠ %s finalize completed but HEAD read failed (%v) — verify commit fired\n",
            milestoneID, err)
        return
    }
    // The post-finalize commit subject is `[MILESTONE <id> ✓] <message>`
    // when _hook_commit fired. Anything else (a "feat: changes in ..."
    // fallback subject or an unrelated commit) means the per-milestone
    // commit did not happen for this iteration.
    expectedPrefix := fmt.Sprintf("[MILESTONE %s ✓]", strings.TrimPrefix(milestoneID, "m"))
    if strings.HasPrefix(headSubject, expectedPrefix) {
        fmt.Fprintf(w, "✓ %s committed as %s\n", milestoneID, headHash[:8])
        return
    }
    fmt.Fprintf(w,
        "⚠ %s finalize skipped commit — HEAD subject is %q (expected %q prefix). "+
        "Inspect .tekhton/.commit_decision and .tekhton/.final_check_result.\n",
        milestoneID, headSubject, expectedPrefix)
}

func readGitHead(projectDir string) (hash, subject string, err error) {
    cmd := exec.Command("git", "log", "-1", "--format=%H %s")
    cmd.Dir = projectDir
    out, err := cmd.Output()
    if err != nil {
        return "", "", err
    }
    parts := strings.SplitN(strings.TrimSpace(string(out)), " ", 2)
    if len(parts) != 2 {
        return strings.TrimSpace(string(out)), "", nil
    }
    return parts[0], parts[1], nil
}
```

### Goal 3 — Tests

**File:** `cmd/tekhton/run_test.go` — add three tests:

1. `TestClearAutoAdvanceIterationState_RemovesSentinels` — plant the
   three sentinel files in a `t.TempDir()`, call the function, assert
   all three are gone.

2. `TestClearAutoAdvanceIterationState_GracefulOnMissing` — call the
   function against a `t.TempDir()` where no sentinels exist, assert
   `err == nil` (no error on missing files).

3. `TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit` — set up
   a temp git repo, create a commit with subject
   `[MILESTONE 38.5 ✓] ...`, call `emitAutoAdvanceCommitBanner`,
   capture stdout, assert it contains `"✓ m38.5 committed as"`. Then
   create a follow-up commit with a generic subject, call again,
   assert output contains `"⚠ m38.5 finalize skipped commit"`.

**File:** `tests/test_autoadvance_per_milestone_commits.sh` (new, ~120
lines). Shim-boundary integration test:

1. Set up a throwaway git repo + 3-entry manifest fixture.
2. Stub the agent runner so each milestone's coder produces a trivial
   file change.
3. Drive `tekhton --milestone <first> --auto-advance --auto-advance-limit 3`.
4. Assert: 3 commits with `[MILESTONE X.Y ✓]` subjects landed (one per
   milestone), each milestone's file change is preserved, and no
   "⚠ ... finalize skipped commit" banner appeared in stdout.

Self-skips cleanly when the Go binary isn't built — same pattern as
`tests/test_state_writer_resume_fields.sh`.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `cmd/tekhton/run.go` | Modify | Add `clearAutoAdvanceIterationState`, `emitAutoAdvanceCommitBanner`, `readGitHead`. Call the reset at the top of each `runAutoAdvanceLoop` iteration and the banner after each successful iteration. |
| `cmd/tekhton/run_test.go` | Modify | Add three new tests: `TestClearAutoAdvanceIterationState_RemovesSentinels`, `TestClearAutoAdvanceIterationState_GracefulOnMissing`, `TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit`. |
| `tests/test_autoadvance_per_milestone_commits.sh` | Create | Three-iteration shim-boundary test asserting per-milestone commits fire. |

---

## Acceptance Criteria

- [ ] `cmd/tekhton/run.go` exports (or contains) `clearAutoAdvanceIterationState(projectDir string) error`. Verified by `grep -nE 'func clearAutoAdvanceIterationState' cmd/tekhton/run.go` returning one match.
- [ ] The `runAutoAdvanceLoop` body calls `clearAutoAdvanceIterationState` at the top of each iteration, before `buildRunner`. Verified by `grep -B 2 -A 3 'clearAutoAdvanceIterationState' cmd/tekhton/run.go` showing the call inside the `for advances < limit` block.
- [ ] After calling `clearAutoAdvanceIterationState(dir)` against a `t.TempDir()` containing the three sentinel files, all three files are gone. Verified by `TestClearAutoAdvanceIterationState_RemovesSentinels`.
- [ ] `clearAutoAdvanceIterationState` returns `nil` (no error) when called against a directory where the sentinels do not exist. Verified by `TestClearAutoAdvanceIterationState_GracefulOnMissing`.
- [ ] After a successful iteration where `_hook_commit` fired, `emitAutoAdvanceCommitBanner` emits a line beginning with `✓ <milestone-id> committed as <8-char-hash>`. Verified by `TestEmitAutoAdvanceCommitBanner_DetectsMilestoneCommit`.
- [ ] After an iteration where `_hook_commit` skipped (HEAD subject doesn't start with `[MILESTONE <id> ✓]`), the banner emits a line beginning with `⚠ <milestone-id> finalize skipped commit`. Verified by the same test.
- [ ] A 3-iteration auto-advance run with stubbed agent activity produces 3 separate `[MILESTONE X.Y ✓]` commits — one per milestone — AND no `⚠ ... skipped commit` banner. Verified by `tests/test_autoadvance_per_milestone_commits.sh`.
- [ ] No regression in: existing `cmd/tekhton/run_test.go` tests, `cmd/tekhton/*_test.go` tests broadly, `internal/runner/...` tests.
- [ ] `shellcheck tests/test_autoadvance_per_milestone_commits.sh` returns zero warnings.
- [ ] `golangci-lint run ./cmd/tekhton/...` and `go vet ./cmd/tekhton/...` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- **The sentinel list is exhaustive but not closed.** Three files today
  (`.final_check_result`, `.final_check_reason`, `.commit_decision`).
  If a future milestone adds another commit-skip sentinel, that file
  MUST be added to `clearAutoAdvanceIterationState`. Document the list
  in a doc-comment so future additions can be grepped for.
- **Don't conflate `.tekhton/RUN_RESULT.json` with the sentinels.**
  RUN_RESULT.json carries the prior iteration's run envelope; the
  next iteration overwrites it cleanly. Clearing it would lose the
  audit trail for partial-progress runs. The sentinels we clear here
  are EXIT-GATE state, not run-history.
- **The banner uses `git log -1 --format='%H %s'` and parses it.** If
  the operator has commits.gpgsign set with a no-tty signing config,
  `git log` is safe — it doesn't sign. But the runtime check for
  whether `_hook_commit` actually fired relies on the subject prefix
  being EXACTLY `[MILESTONE <id> ✓]`. If a future change to m44's
  commit-message generator alters that prefix, m48's banner detection
  breaks. Add an inline test asserting the prefix matches what
  `lib/hooks.sh::generate_commit_message` emits.
- **The `emitAutoAdvanceCommitBanner` warn case is operator-visible
  but non-fatal.** A skipped commit on iteration N means iteration
  N+1 starts with N's work uncommitted; the auto-advance loop
  continues. The banner surfaces the regression; the operator can
  Ctrl-C if they want to investigate. Do NOT make the warn fatal —
  that would regress to pre-m46 silent failures where the operator
  loses long-running auto-advance work.
- **The shim-boundary test must stub the agent runner.** Real Claude
  invocations in a test would burn quota and take hours. Stub at the
  same seam as m38.6's tester parity tests (whichever interface gets
  introduced in the m38.6 work) — the agent runner returns canned
  outputs per stage.
- **Pre-iteration reset vs post-iteration cleanup.** m48 clears
  sentinels BEFORE the iteration runs. An alternative is clearing
  them AFTER, on success — but that's brittle: if iteration N exits
  abnormally (Ctrl-C, kernel OOM), the sentinels stay set and
  iteration N+1 inherits them. Pre-iteration reset is the more
  defensive choice.

## Seeds Forward

- **`subprocess_warnings` Metadata surfacing (m47 follow-on):** the
  m47 envelope-warnings channel is in place but not yet shown in
  `RUN_SUMMARY.md` or the per-iteration banner. A future polish
  could include warning counts in the success line:
  `✓ m38.5 committed as <hash> warnings=2`.
- **Auto-advance recovery prompts:** if the per-iteration banner
  detects a skipped commit, a future enhancement could prompt the
  operator: `Iteration committed-skip detected — [a]bort chain,
  [m]anual-flip and continue, [i]gnore?`. Not m48 scope (operator
  is currently expected to Ctrl-C and investigate).
- **Causal log event for the iteration boundary:** emit an
  `autoadvance_iteration_start` and `autoadvance_iteration_end`
  causal event per iteration with the milestone-id, start/end
  timestamps, and commit-confirmation result. Lets future analysis
  spot patterns ("the third iteration in a chain always skips
  commit") that today require manually parsing pipeline logs.
- **V5 multi-provider auto-advance:** when V5 lands the parallel
  execution engine and multi-provider abstraction, the per-iteration
  reset pattern carries forward unchanged but the banner format may
  need to encode provider info. Track as Seeds Forward.
- **Cron / schedule-driven auto-advance (V5 candidate):** a future
  V5 milestone could surface auto-advance as a scheduled background
  task that runs nightly. Without m48, that nightly task would
  produce intermittent "commit-skipped milestone with no narrative"
  commits — exactly the failure mode V5 needs to avoid. m48 is a
  prerequisite for that scheduling feature even if it's not part of
  the V5 plan today.
