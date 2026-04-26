# Reviewer Report — M126 Deterministic UI Gate Execution

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `ARCHITECTURE.md` now describes `lib/gates_ui_helpers.sh` (the new file) but still has no catalog entry for `lib/gates_ui.sh` itself. The M126 addition partially fills the gap but leaves the main file undocumented; `lib/gates_phases.sh` has an entry, so `gates_ui.sh` is the odd one out. Low-priority gap to close in a future cleanup pass.
- `CLAUDE.md` repository layout section does not include `lib/gates_ui_helpers.sh`. The same gap exists for `lib/gates_ui.sh` and `lib/gates_phases.sh`, so this is pre-existing and M126 didn't widen it, but a batch update would be worth doing once the V4 milestone reset happens (per CLAUDE.md).

## Coverage Gaps
- `UI_GATE_ENV_RETRY_ENABLED=false` is an acceptance criterion (M126 AC: "suppress the hardened rerun without changing classification or diagnosis content") but has no corresponding test in `tests/test_ui_build_gate.sh`. The behavior is correctly implemented — the `else` branch logs and falls through to the terminal-failure path — but it is untested. Consider adding as Test 20 before M127 relies on the knob.

## ACP Verdicts
None present in CODER_SUMMARY.md.

## Drift Observations
- `lib/gates_ui.sh:172` — `_ui_detect_framework` is called a second time in the terminal-failure diagnosis block (`if [[ "$(_ui_detect_framework)" == "playwright" ]]; then`), after already being called once per subprocess invocation via `_normalize_ui_gate_env`. The result is deterministic (reads config/filesystem, no mutable state), so there is no correctness impact; but a `local _ui_framework` cached at the top of `_run_ui_test_phase` would eliminate the duplicate syscall cluster and make the intent clearer. Not worth a rework cycle.

---

**Review notes:**

All acceptance criteria satisfied. Key verification points:

- `PLAYWRIGHT_HTML_OPEN=never` delivered at the `env(1)` boundary; `$PLAYWRIGHT_HTML_OPEN` confirmed unset in parent shell (Test 14). ✓
- `CI=1` injected only on HARDENED=1 path (`_ui_deterministic_env_list` lines 57–59). ✓
- `_ui_detect_framework` priority order (config → word-boundary regex → config file) implemented correctly; word-boundary regex `(^|[[:space:]/])playwright([[:space:]]|$)` correctly rejects `./test-playwright-helper.sh` (Test 15). ✓
- `_ui_timeout_signature` is pure — no logging, no file writes (Tests 13a–13e exercise the truth table directly). ✓
- Interactive-report branch: exactly 2 invocations (run#1 + hardened rerun); M54 and generic retry both skipped (Test 16 asserts count=2). ✓
- Generic-timeout/none branch: 2 invocations (run#1 + generic flakiness retry); existing M54 and retry paths unchanged (Test 17 asserts count=2). ✓
- Hardened rerun success: gate returns 0, no error files on disk, log line `UI tests passed after deterministic reporter hardening.` emitted (Tests 16, 19). ✓
- Terminal failure diagnosis: `## UI Gate Diagnosis` section written to both `UI_TEST_ERRORS_FILE` and `BUILD_ERRORS_FILE` with all four bullet fields populated (Test 18). ✓
- `_ui_hardened_timeout` clamps correctly to `[1, BASE]`; never mutates `$_ui_timeout` in parent shell. ✓
- 300-line ceiling observed: `gates_ui.sh` = 183 lines, `gates_ui_helpers.sh` = 163 lines. ✓
- Source order in `tekhton.sh` (line 857): `gates_ui_helpers.sh` sourced after `gates_phases.sh` and before `gates_ui.sh`, so consumers see helpers at parse time. ✓
- Security agent LOW finding (`lib/milestone_split_dag.sh:87` echo flag issue) is out of scope for M126.
