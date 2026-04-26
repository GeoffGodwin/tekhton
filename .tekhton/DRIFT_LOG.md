# Drift Log

## Metadata
- Last audit: 2026-04-25
- Runs since audit: 2

## Unresolved Observations
- [2026-04-26 | "m126"] `lib/gates_ui.sh:172` — `_ui_detect_framework` is called a second time in the terminal-failure diagnosis block (`if [[ "$(_ui_detect_framework)" == "playwright" ]]; then`), after already being called once per subprocess invocation via `_normalize_ui_gate_env`. The result is deterministic (reads config/filesystem, no mutable state), so there is no correctness impact; but a `local _ui_framework` cached at the top of `_run_ui_test_phase` would eliminate the duplicate syscall cluster and make the intent clearer. Not worth a rework cycle.
- [2026-04-26 | "m126"] -- **Review notes:** All acceptance criteria satisfied. Key verification points:
- [2026-04-26 | "m126"] `PLAYWRIGHT_HTML_OPEN=never` delivered at the `env(1)` boundary; `$PLAYWRIGHT_HTML_OPEN` confirmed unset in parent shell (Test 14). ✓
- [2026-04-26 | "m126"] `CI=1` injected only on HARDENED=1 path (`_ui_deterministic_env_list` lines 57–59). ✓
- [2026-04-26 | "m126"] `_ui_detect_framework` priority order (config → word-boundary regex → config file) implemented correctly; word-boundary regex `(^|[[:space:]/])playwright([[:space:]]|$)` correctly rejects `./test-playwright-helper.sh` (Test 15). ✓
- [2026-04-26 | "m126"] `_ui_timeout_signature` is pure — no logging, no file writes (Tests 13a–13e exercise the truth table directly). ✓
- [2026-04-26 | "m126"] Interactive-report branch: exactly 2 invocations (run#1 + hardened rerun); M54 and generic retry both skipped (Test 16 asserts count=2). ✓
- [2026-04-26 | "m126"] Generic-timeout/none branch: 2 invocations (run#1 + generic flakiness retry); existing M54 and retry paths unchanged (Test 17 asserts count=2). ✓
- [2026-04-26 | "m126"] Hardened rerun success: gate returns 0, no error files on disk, log line `UI tests passed after deterministic reporter hardening.` emitted (Tests 16, 19). ✓
- [2026-04-26 | "m126"] Terminal failure diagnosis: `## UI Gate Diagnosis` section written to both `UI_TEST_ERRORS_FILE` and `BUILD_ERRORS_FILE` with all four bullet fields populated (Test 18). ✓
- [2026-04-26 | "m126"] `_ui_hardened_timeout` clamps correctly to `[1, BASE]`; never mutates `$_ui_timeout` in parent shell. ✓
- [2026-04-26 | "m126"] 300-line ceiling observed: `gates_ui.sh` = 183 lines, `gates_ui_helpers.sh` = 163 lines. ✓
- [2026-04-26 | "m126"] Source order in `tekhton.sh` (line 857): `gates_ui_helpers.sh` sourced after `gates_phases.sh` and before `gates_ui.sh`, so consumers see helpers at parse time. ✓
- [2026-04-26 | "m126"] Security agent LOW finding (`lib/milestone_split_dag.sh:87` echo flag issue) is out of scope for M126.
- [2026-04-25 | "architect audit"] **Obs 5 — `quota.sh` inverted source ordering:** The observation itself closes with "no change required; noting for the audit backlog." The `source` at line 166 executes at file-load time before any function call, so execution order is correct. The comment block at lines 163–165 already explains the placement. Carrying this forward would produce a cosmetic reorder with zero behavioral benefit. **Obs 6 — Prior audit deferrals:** The three sub-items (pipeline_order subshell overhead, `_INIT_FILES_WRITTEN` global scatter risk, further `common.sh` reduction) each had explicit written rationale in the prior audit: no demonstrated performance problem, no scatter has materialized, and further `common.sh` splitting risks circular sourcing. No new evidence contradicts those decisions. All remain standing deferrals.

## Resolved
