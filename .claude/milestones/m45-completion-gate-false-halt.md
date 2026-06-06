<!-- milestone-meta
id: "45"
status: "todo"
-->

# m45 — Completion Gate: Stop False-Halting on Transient TEST_CMD Failure After a Large Coder Refactor

## Overview

| Item | Detail |
|------|--------|
| **Arc motivation** | The completion gate currently halts a successful coder run on a single transient `TEST_CMD` non-zero exit. This has fired falsely on at least two large stage-port milestones in the m36 arc: m36.2 (intake helpers) and m36.3 (intake stage). In both cases the coder's work was correct, the tree compiled, and running `bash tests/run_tests.sh` immediately after halt returned 511 shell + Go pass — but the gate had already halted the pipeline, blocked reviewer/tester, and forced a manual manifest flip. Each false halt cost ~1 hour of operator attention (diagnosis + recovery + commit). The cost compounds because operators learn to distrust gate halts and start manually overriding, which weakens the gate's actual purpose. |
| **Gap** | `internal/gates/completion.go::Run` (line 212) returns `ErrCompletionTestFailed` immediately when `TEST_CMD` exits non-zero AND no baseline exists. There is no retry, no grace period, no file-system-sync window, no distinction between "coder bailed with broken work" and "coder finished a 200+ turn refactor and the test runner caught the tree mid-flush". After a large refactor the gate's `TEST_CMD` invocation fires within milliseconds of the coder's last `Edit`/`Write`/`Bash` tool use. Transient causes observed in the m36.2 / m36.3 incidents: stale `test_dedup.fingerprint`, file-system write barrier not yet flushed, test runner caching deleted-file metadata, port collision on a newly-spawned test subprocess. |
| **m45 fills** | A two-piece narrowing of the false-halt window in `internal/gates/completion.go`: (1) a configurable grace-period sleep (`COMPLETION_GATE_GRACE_SECS`, default 3s) between coder-stage exit and the `TEST_CMD` invocation, with a `sync` system call to flush write buffers; (2) a one-retry policy on the no-baseline failure path — when the first `TEST_CMD` exits non-zero and no baseline exists, sleep `COMPLETION_GATE_RETRY_DELAY_SECS` (default 5s) and re-run once. If the retry passes, log a structured `completion_gate_flake` event to the causal log and proceed. If both attempts fail, halt as before. Adds Go unit tests for both branches and a shim-boundary integration test driving the flake-then-pass scenario. |
| **Depends on** | none (purely internal to `internal/gates/`) |
| **Files changed** | `internal/gates/completion.go`, `internal/gates/completion_test.go`, `internal/config/defaults.go`, `internal/config/sections.go`, `tests/test_completion_gate_retry.sh`, `templates/pipeline.conf.example`, `CLAUDE.md` |

### Prior arc context

| Milestone | Concern addressed |
|-----------|------------------|
| m41 | Finalize: stop false-blocking the commit when the milestone block can't be populated |
| m42 | Preflight: guard against the no-op TEST_CMD="true" default |
| m43 | Version-bump completeness: sync all version files and validate after bump |
| m44 | Commit subject regression: stop falling back to ".claude/project_version.cfg" |
| **m45** | **Completion gate: stop false-halting on transient TEST_CMD failures after a large coder refactor** |

---

## Design

### Sequencing note

m45 is independent of the m37–m39 stage-port sprint. Land it whenever convenient.
The risk of NOT landing it is that every large stage port (m37.2 review,
m38.6 tester, m39.4 coder) is one transient flake away from a false halt.

### Goal 1 — Grace period before the gate's first `TEST_CMD` invocation

**File:** `internal/gates/completion.go::Run`

Current code (around line 185, just before the first `runner.Run`):

```go
runner := g.Runner
if runner == nil {
    runner = ExecRunner{}
}
out, exitCode, _, err := runner.Run(ctx, g.TestCmd, g.Timeout)
```

Add a configurable grace window. The default (3 seconds + a `sync`) matches
the observed file-system-flush window on the WSL2 environment the operator
runs on; tunable via `COMPLETION_GATE_GRACE_SECS` for projects whose tests
need a longer settle.

```go
runner := g.Runner
if runner == nil {
    runner = ExecRunner{}
}

// m45 — Grace window before TEST_CMD invocation. After a large coder
// refactor (200+ turns, hundreds of file writes/deletes), `TEST_CMD`
// fires within milliseconds of the coder's last syscall. Observed
// transient flakes: stale test_dedup fingerprint, write barrier not yet
// flushed, test runner caching deleted-file metadata. A short sleep +
// fsync narrows the window enough to eliminate the observed false-halts
// without slowing successful runs perceptibly.
if g.GraceSecs > 0 {
    select {
    case <-time.After(g.GraceSecs):
    case <-ctx.Done():
        return ctx.Err()
    }
    _ = syscall.Sync()  // best-effort; ignored on platforms without it
}

out, exitCode, _, err := runner.Run(ctx, g.TestCmd, g.Timeout)
```

`CompletionGate` struct gets a new field:

```go
type CompletionGate struct {
    // ... existing fields
    GraceSecs time.Duration  // m45: default 3s via env COMPLETION_GATE_GRACE_SECS
}
```

The constructor reads `COMPLETION_GATE_GRACE_SECS` from the env contract
via `internal/config/defaults.go` (default 3, range 0–60). 0 disables
the grace window — useful for unit tests and CI where the file system
is in-memory.

### Goal 2 — One-retry policy on the no-baseline failure path

**File:** `internal/gates/completion.go::Run`

Current no-baseline branch (around line 211):

```go
g.warn("Completion gate FAILED — TEST_CMD exited %d (no baseline for comparison).", exitCode)
return ErrCompletionTestFailed
```

Replace with a single retry. The retry pattern is intentionally NOT
applied to the "have-baseline" branch — when a baseline exists, the
baseline comparison already filters out pre-existing failures, so a
non-zero exit there indicates novel breakage and should halt immediately.
The no-baseline branch is the false-halt sweet spot.

```go
if g.Baseline != nil && g.Baseline.HasBaseline() {
    // ... existing baseline-compare branch unchanged
}

// m45 — One-retry policy on the no-baseline failure path. Catches the
// observed transient-flake pattern (file-system flush, port collision,
// test_dedup stale fingerprint) without weakening the gate's purpose:
// if the work is genuinely broken, the retry fails too. If the retry
// passes, log a causal event so the pattern can be tracked over time.
if g.RetryOnNoBaseline {
    select {
    case <-time.After(g.RetryDelay):
    case <-ctx.Done():
        return ctx.Err()
    }
    retryOut, retryExitCode, _, retryErr := runner.Run(ctx, g.TestCmd, g.Timeout)
    if retryErr == nil && retryExitCode == 0 {
        g.causal("completion_gate_flake", map[string]string{
            "first_exit":  strconv.Itoa(exitCode),
            "retry_exit":  "0",
            "test_cmd":    g.TestCmd,
            "milestone":   g.Milestone,
        })
        g.warn("Completion gate: first TEST_CMD flaked (exit=%d), retry passed. Proceeding.", exitCode)
        if g.Dedup != nil {
            g.Dedup.RecordPass()
        }
        return nil
    }
    // Retry also failed — fall through to the original halt path.
    out = retryOut
    exitCode = retryExitCode
}

g.warn("Completion gate FAILED — TEST_CMD exited %d (no baseline for comparison).", exitCode)
return ErrCompletionTestFailed
```

`CompletionGate` struct adds:

```go
type CompletionGate struct {
    // ... existing fields
    GraceSecs         time.Duration
    RetryOnNoBaseline bool          // m45: default true via env COMPLETION_GATE_RETRY_NO_BASELINE
    RetryDelay        time.Duration // m45: default 5s via env COMPLETION_GATE_RETRY_DELAY_SECS
}
```

### Goal 3 — Env contract additions

**File:** `internal/config/defaults.go`

Add three keys to the default map:

```go
"COMPLETION_GATE_GRACE_SECS":        "3",
"COMPLETION_GATE_RETRY_NO_BASELINE": "true",
"COMPLETION_GATE_RETRY_DELAY_SECS":  "5",
```

**File:** `internal/config/sections.go`

Add a `SectionRule` entry for these three keys under the existing
"Build and completion gate" section (around line 85).

**File:** `templates/pipeline.conf.example`

Document the three keys in the build-and-completion-gate section with
the same comment format as other gate-tuning keys.

### Goal 4 — Tests

**File:** `internal/gates/completion_test.go`

Add three table-driven cases to the existing `TestCompletionGate_Run` body:

1. `no_baseline_first_fails_retry_passes` — `Runner` mock returns
   `{exit: 1, out: "..."}` then `{exit: 0, out: "..."}`. Assert `Run`
   returns nil error AND `Dedup.RecordPass` was called.
2. `no_baseline_both_fail` — `Runner` mock returns `{exit: 1, out: "..."}`
   twice. Assert `Run` returns `ErrCompletionTestFailed`.
3. `grace_period_respects_context_cancel` — `GraceSecs: 10*time.Second`,
   context cancelled at 100ms. Assert `Run` returns `context.Canceled`
   without invoking `runner.Run`.

**File:** `tests/test_completion_gate_retry.sh` (new, ~80 lines).

Shim-boundary integration test: invoke `tekhton run --task ...` against
a fixture project whose `TEST_CMD` is a script that fails on first
invocation (creates a sentinel file) and passes on subsequent
invocations. Assert the pipeline does NOT halt at completion_gate AND
the causal log contains a `completion_gate_flake` event.

### Goal 5 — Docs

**File:** `CLAUDE.md`

Add three rows to the "Template Variables" table for the new env keys.

---

## Files Modified

| File | Change type | Description |
|------|------------|-------------|
| `internal/gates/completion.go` | Modify | Add `GraceSecs`, `RetryOnNoBaseline`, `RetryDelay` fields to `CompletionGate`. Implement grace-period sleep before first `runner.Run`. Implement one-retry policy on the no-baseline failure path. Emit `completion_gate_flake` causal event on successful retry. |
| `internal/gates/completion_test.go` | Modify | Add three table-driven cases for the new branches. |
| `internal/config/defaults.go` | Modify | Add three default-map entries. |
| `internal/config/sections.go` | Modify | Add three keys to the build-and-completion-gate `SectionRule`. |
| `templates/pipeline.conf.example` | Modify | Document the three new keys with explanatory comments. |
| `tests/test_completion_gate_retry.sh` | Create | Shim-boundary integration test driving the flake-then-pass scenario. |
| `CLAUDE.md` | Modify | Add three rows to the Template Variables table. |

---

## Acceptance Criteria

- [ ] `internal/gates/completion.go::Run`, when called with
      `GraceSecs > 0`, sleeps that duration before invoking
      `runner.Run` for the first time. Verified by
      `TestCompletionGate_Run/grace_period_respects_context_cancel`.
- [ ] `internal/gates/completion.go::Run`, when no baseline is set and
      the first `TEST_CMD` invocation returns non-zero but the second
      returns zero, returns nil and calls `Dedup.RecordPass()`. Verified
      by `TestCompletionGate_Run/no_baseline_first_fails_retry_passes`.
- [ ] `internal/gates/completion.go::Run`, when both `TEST_CMD`
      invocations return non-zero in the no-baseline branch, returns
      `ErrCompletionTestFailed`. Verified by
      `TestCompletionGate_Run/no_baseline_both_fail`.
- [ ] On successful retry, a `completion_gate_flake` event is appended
      to `${CAUSAL_LOG_FILE}` with `first_exit`, `retry_exit`,
      `test_cmd`, and `milestone` fields. Verified by
      `tests/test_completion_gate_retry.sh`.
- [ ] `COMPLETION_GATE_GRACE_SECS`, `COMPLETION_GATE_RETRY_NO_BASELINE`,
      and `COMPLETION_GATE_RETRY_DELAY_SECS` appear in
      `internal/config/defaults.go` with the documented defaults.
      Verified by `grep -E "COMPLETION_GATE_(GRACE|RETRY)" internal/config/defaults.go`
      returning three matches.
- [ ] The three keys land in the build-and-completion-gate section of
      a freshly-rendered `pipeline.conf.example`. Verified by
      `bin/tekhton config defaults --emit shell | grep COMPLETION_GATE_`
      returning three lines under the expected section banner.
- [ ] No regression in: `internal/gates/...` Go tests,
      `internal/pipeline/runner_test.go` (the
      `BlockingStage = "completion_gate"` cases still fire when both
      invocations fail), `internal/config/...` Go tests.
- [ ] `shellcheck tests/test_completion_gate_retry.sh` returns zero
      warnings.
- [ ] `golangci-lint run ./internal/gates/... ./internal/config/...`
      and `go vet ./internal/gates/... ./internal/config/...` clean.
- [ ] Full suite passes: `bash tests/run_tests.sh` + `go test ./...`.

## Watch For

- The grace-period sleep must use `select { case <-time.After(...):
  case <-ctx.Done(): return ctx.Err() }` so a cancelled run aborts
  promptly instead of waiting out the grace window. The unit test for
  context-cancel locks this in.
- `syscall.Sync()` is a best-effort flush — it's not available on every
  platform Go targets, and the only callers in `internal/` are gated
  behind `runtime.GOOS != "windows"`. Use a build tag or runtime check
  to keep the call portable.
- The retry policy is intentionally limited to the *no-baseline* branch.
  When a baseline exists, the baseline-compare path already filters
  pre-existing failures — a non-zero exit there means novel breakage
  and should halt immediately. Do NOT add a retry to the
  have-baseline branch; that would mask real regressions on
  rework cycles.
- The default values (3s grace, 5s retry delay) are tuned for the
  WSL2 environment where the false-halts have been observed. Operators
  on faster file systems may want to lower them; operators on slower
  CI runners may want to raise them. Document the tradeoff in
  `pipeline.conf.example`.
- Coder runs that produce zero file writes (e.g., a doc-only update or
  a comment-only change) shouldn't pay the grace window. As a future
  optimization, the gate could read `CODER_SUMMARY.md`'s `## Files
  Modified` count and skip the grace when 0 — out of scope for m45.
- The `completion_gate_flake` causal event lets future analysis spot
  whether the flake rate is climbing over time. If it spikes, that's
  a signal that the underlying transient is becoming more frequent
  (e.g., test_dedup fingerprint logic regressing) and warrants
  deeper investigation.

## Seeds Forward

- **m46 (potential):** Apply the same grace-window + retry pattern to
  the build gate (`internal/gates/build.go`). The build gate has the
  same exposure to file-system-flush flakes after a large refactor,
  though the symptom is rarer because build commands typically retry
  internally.
- **m47 (potential):** Surface the `completion_gate_flake` event in
  `RUN_SUMMARY.md` and the Watchtower dashboard. A flake rate above
  some threshold (e.g., 5% of runs over the trailing 50) becomes a
  visible signal that something deeper has regressed.
- **Deeper investigation if flakes persist:** the WSL2-specific
  symptom may indicate that `test_dedup`'s fingerprint computation
  races the coder's final file writes. A future milestone could add
  an explicit `coder_done` causal event with the timestamp of the
  last `Edit/Write/Bash` tool use, and have the gate wait for the
  fingerprint to stabilize past that timestamp before computing it.
