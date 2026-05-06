## Test Audit Report

### Audit Summary
Tests audited: 2 files, 42 test functions
(fsnotify_test.go: 17 functions; run_test.go: 25 functions)
Verdict: PASS

### Findings

#### EXERCISE: Dead `timerStub` type in run_test.go
- File: internal/supervisor/run_test.go:458
- Issue: `timerStub` (a struct with a `Reset(time.Duration) bool` method) is
  defined with a comment but is never referenced by any test function. The comment
  block above it discusses a `fakeWatcher` that does not exist in the file.
  `handleActivityTimeout` takes `**time.Timer` (not an interface), so `timerStub`
  cannot substitute for it. The type was likely planned during test design but
  abandoned when the tests settled on real `*time.Timer` instances. Go does not
  error on unused types, so the file compiles, but the dead code misleads readers
  into thinking a Reset-call assertion exists somewhere.
- Severity: MEDIUM
- Action: Remove `timerStub` and its associated comment block (run_test.go:457–464).
  If timer-reset verification is needed in the future, add it at that point with a
  proper interface abstraction in the package.

#### INTEGRITY: `TestReaper_KillIsIdempotent` omits `applyProcAttr` — kill never reaches the process
- File: internal/supervisor/run_test.go:642
- Issue: The test spawns `exec.Command("sleep", "30")` and calls `cmd.Start()`
  without invoking `applyProcAttr(cmd)` first. Without `Setpgid: true`, the child
  inherits the test-runner's process group (child.PGID ≠ child.PID).
  `posixReaper.Kill()` sends `syscall.Kill(-child.pid, SIGTERM)` targeting process
  group PGID=child.pid, which contains no processes → ESRCH. The implementation
  folds ESRCH to nil (reaper_unix.go:73). The wait-loop probe `Kill(-pid, 0)` also
  returns ESRCH immediately, so the function returns nil without delivering a signal.
  The second Kill() returns nil via the `already` guard. Both assertions pass, but
  the `sleep 30` process is never terminated. `cmd.Wait()` then blocks for up to
  30 seconds, slowing the suite. The test validates the nil-return / `already`-guard
  idempotence contract of the Kill() API but does NOT validate that the reaper
  terminates the process — the semantically meaningful contract for a reaper.
  (End-to-end kill-path coverage is provided by `TestRun_CallerCancellation_Terminates`
  and `TestRun_ActivityTimeout_Fires`, which go through `buildCommand`→`applyProcAttr`
  and observe tight elapsed-time bounds.)
- Severity: MEDIUM
- Action: Add `applyProcAttr(cmd)` before `cmd.Start()` at run_test.go:650 so the
  child creates its own process group (PGID = child.PID) and the reaper's
  `Kill(-pid, SIGTERM)` reaches it. After both Kill() calls, add a wait-with-timeout
  assertion to confirm actual termination:
  ```go
  applyProcAttr(cmd)
  if err := cmd.Start(); err != nil {
      t.Fatalf("start: %v", err)
  }
  // ... Attach, Kill, Kill as before ...
  done := make(chan error, 1)
  go func() { done <- cmd.Wait() }()
  select {
  case <-done: // process reaped — pass
  case <-time.After(2 * time.Second):
      t.Error("process not reaped within 2s — Kill did not terminate the process")
  }
  ```

#### SCOPE: Shell-detected stale symbols are false positives — no action required
- File: internal/supervisor/run_test.go (both reported symbols)
- Issue: The pre-audit shell scanner flagged `cancel` and `len` as symbols "not
  found in any source definition."
  — `cancel` at line 140 is a local variable returned by `context.WithCancel` on
    line 138; it is not a reference to a package-level symbol.
  — `len` is a Go built-in; it is never defined in any module source file by design.
  Neither represents an orphaned or stale test reference.
- Severity: LOW
- Action: No test changes needed. The shell-based orphan scanner has no understanding
  of Go built-ins or local variable scope. Consider scoping the scanner to exported
  identifiers defined within the module only.

---

### Detailed Rubric Assessment

| Rubric Point | fsnotify_test.go | run_test.go | Notes |
|---|---|---|---|
| 1. Assertion Honesty | PASS | PASS | All assertions derive from real implementation behavior; no hard-coded magic values unconnected to implementation logic. |
| 2. Edge Case Coverage | PASS | PASS | nil receiver, empty dir, nonexistent dir, non-directory path, fallback mode, cap exhaustion, pre-Attach guard all covered. |
| 3. Implementation Exercise | PASS | MEDIUM | Real functions called throughout; the only dead code is the unused `timerStub` type, not a test that calls only stubs. |
| 4. Test Weakening | PASS | PASS | Tester-added tests are all new additions (TestQualifiesEvent_Cases, TestIsExcluded_MoreSegments, TestActivityWatcher_FallbackCloseIsIdempotent, TestApplyProcAttr_SetsSetpgid); no existing assertions were broadened or removed. |
| 5. Naming and Intent | PASS | PASS | All names encode the scenario and expected outcome. |
| 6. Scope Alignment | PASS | MEDIUM | `cancel`/`len` flags are false positives. `TestReaper_KillIsIdempotent` tests nil-return idempotence rather than actual process termination. |
| 7. Test Isolation | PASS | PASS | All tests use `t.TempDir()`; no test reads from mutable project state files or depends on prior pipeline runs. |
