## Test Audit Report

### Audit Summary
Tests audited: 3 files, 12 test functions (3 bash sub-tests in test_tty_no_screen_clear.sh,
6 bash sub-tests in test_tui_status_contract.sh, 4 Go test functions in status_contract_test.go)
Verdict: NEEDS_WORK

---

### Findings

#### SCOPE: test_tty_no_screen_clear.sh — Tests A and C assert a guard that does not exist
- File: tests/test_tty_no_screen_clear.sh:31–66 (Test A), tests/test_tty_no_screen_clear.sh:109–203 (Test C)
- Issue: Both tests are designed around the premise that `_tui_restore_terminal()` checks
  `_TUI_ACTIVE` before calling `tput rmcup`. The current implementation in
  `lib/sidecar_lifecycle.sh:126–130` is unconditional — it calls `tput rmcup`, `tput cnorm`,
  and `stty icrnl` regardless of `_TUI_ACTIVE`. Test A stubs `tput` and expects rmcup NOT to
  appear in the call log when `_TUI_ACTIVE=false`. With the current implementation rmcup IS
  always called, so Test A fails. Test C uses a PTY and will likewise detect `\e[?1049l` in the
  captured output. Both tests fail in CI. The tester's own report (TESTER_REPORT.md lines 10,12)
  confirms these failures. The fix described in the test header ("guard every terminal-restore
  action behind `[[ "${_TUI_ACTIVE:-false}" == "true" ]]`") was never applied to the
  implementation.
- Severity: HIGH
- Action: Apply the `_TUI_ACTIVE` guard to `lib/sidecar_lifecycle.sh::_tui_restore_terminal`
  (lines 126–130). Change to:
  ```bash
  _tui_restore_terminal() {
      [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
      tput rmcup 2>/dev/null || true
      tput cnorm 2>/dev/null || true
      stty icrnl 2>/dev/null || true
  }
  ```
  Do NOT modify the tests — they encode the correct contract and must stay red until the fix
  lands.

#### SCOPE: status_contract_test.go — Three Go tests fail against current WriteInitial/WriteFinal
- File: internal/tui/status_contract_test.go:25 (TestWriteInitialFieldName_CurrentAgentStatus),
  internal/tui/status_contract_test.go:130 (TestWriteInitialFieldName_UsesProtoNotSchema),
  internal/tui/status_contract_test.go:163 (TestWriteFinalFieldName_CurrentAgentStatus)
- Issue: The `initialStatus` struct in `internal/tui/status.go:14–28` diverges from both the
  proto package contract and what Python reads in three concrete ways:
  1. `status.go:23` — `AgentStatus string \`json:"agent_status"\``. Tests require
     `"current_agent_status"` (matches `proto.TUIStatusV1Payload.CurrentAgentStatus` at
     `proto/tui.go:59` and Python `tui_render.py:69,124`).
  2. `status.go:15` — `Schema string \`json:"schema"\``. Tests require `"proto"` (matches
     `TUIStatusV1Envelope.Proto` at `proto/tui.go:27` and Python `_read_status()` key lookup).
  3. `status.go:22` — `RecentEvents []string`. Tests require an array of objects (matching
     `[]proto.TUIEventEntry`); Python crashes with `AttributeError` on `ev.get("ts")` if any
     string element is present.
  All three failing Go tests call the real `WriteInitial`/`WriteFinal` functions and check
  actual JSON output — assertions are honest. The cascade effect: FAIL verdicts propagate to
  `test_tui_status_contract.sh` tests E and F (lines 232 and 259), which shell out to
  `go test -run TestWriteInitialFieldName` / `-run TestWriteFinalFieldName`. Confirmed by
  tester's own run results (TESTER_REPORT.md lines 18–19, 23–26).
- Severity: HIGH
- Action: Eliminate the divergent `initialStatus` struct. Rewrite `WriteInitial` to use
  `NewState()` (already exists in `state.go:67`) and `SaveAtomic` — the same path
  `tekhton tui start` uses. `WriteFinal` should likewise mutate a loaded or fresh `State` and
  call `SaveAtomic`. This collapses both functions onto the production code path, removing the
  separate struct entirely and making the tests pass.

#### INTEGRITY: test_tty_no_screen_clear.sh Test B — passes vacuously against current code
- File: tests/test_tty_no_screen_clear.sh:71–101 (Test B)
- Issue: Test B verifies that rmcup IS called when `_TUI_ACTIVE=true`. Because the current
  implementation calls rmcup unconditionally (no guard), Test B passes — but for the wrong
  reason. It provides no signal that distinguishes "correctly guarded to fire only when active"
  from "fires unconditionally regardless of _TUI_ACTIVE". After the guard fix in finding 1 is
  applied, Test B will continue to pass correctly.
- Severity: LOW
- Action: No change required. The vacuous-pass issue resolves when finding 1 is fixed. Test B
  then meaningfully verifies that the guard allows rmcup when _TUI_ACTIVE=true.

#### COVERAGE: test_tui_status_contract.sh — no error-path test for tui append-event
- File: tests/test_tui_status_contract.sh (Tests B and C)
- Issue: Tests B and C verify a successfully written event has correct shape. No test covers
  `tekhton tui append-event` against a missing or corrupt status file. Minor omission.
- Severity: LOW
- Action: Consider adding a sub-test that invokes `tekhton tui append-event` without a prior
  `tui start` (missing status file) and asserts a clean exit with a non-zero code or graceful
  no-op, to guard against panics on missing state.

---

### Freshness Sample Assessment (informational — not blocking)
Files: internal/diagnose/rules/{registry_test.go, resilience_test.go, rules_test.go}

These tests are in good shape and require no action:
- registry_test.go: The hardcoded 18-rule list is a legitimate parity gate (not an INTEGRITY
  violation) — it explicitly documents the bash↔Go drift detection intent, and the comment
  explains the design. TestRules_ReturnsCopy correctly guards against aliased slice mutation.
- resilience_test.go: Good multi-source coverage across match and no-match paths; uses
  t.TempDir() for fixture isolation throughout; includes the "ignores .md files" self-trigger
  guard as an explicit sub-test.
- rules_test.go: TestParity_AllFixtures reads from testdata/fixtures_v3/ (controlled fixture
  directory, not mutable pipeline state); correctly pins all env vars with t.Setenv before each
  sub-test; priority collision tests are load-bearing and non-trivial.
