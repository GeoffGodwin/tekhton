## Test Audit Report

### Audit Summary
Tests audited: 4 files, ~167 test assertions/functions
Verdict: PASS

Files audited:
- `tests/test_out_complete.sh` — 9 pass/fail points (new)
- `tests/test_tui_action_items.sh` — 10 pass/fail points across 6 test groups (new)
- `tests/test_finalize_run.sh` — ~96 assert/assert_eq calls across 16 suites (modified: hook count updated for M102)
- `tools/tests/test_tui.py` — 52 test functions (6 new M102 tests, 46 pre-existing)

### Findings

#### NAMING: Stale header comment in test_finalize_run.sh
- File: `tests/test_finalize_run.sh:9`
- Issue: The test file header comment says "20 hooks in deterministic sequence" but Suite 1 assertion 1.1 correctly checks for 25 hooks, which matches the 25 `register_finalize_hook` calls in `lib/finalize.sh:507-542`. The comment predates the M102 addition of `_hook_tui_complete`. No assertion is wrong — only the prose description is stale.
- Severity: LOW
- Action: Update the header comment to read "25 hooks in deterministic sequence".

#### EXERCISE: Watchdog tests in test_tui.py replicate condition logic inline
- File: `tools/tests/test_tui.py:599-703`
- Issue: The four watchdog tests (`test_watchdog_condition_fires_when_idle_and_stale`, `test_watchdog_condition_does_not_fire_when_running`, `test_watchdog_condition_does_not_fire_before_any_turns`, `test_watchdog_disabled_when_secs_zero`) reproduce the watchdog boolean expression in test code and assert that the expression evaluates as expected, rather than calling the actual watchdog code path inside `tui.main()`. The values used (agent_status, agent_turns_used, watchdog_secs) are derived from the implementation's documented behavior, not hardcoded. This is an acceptable design constraint: `tui.main()` contains an event loop that cannot be unit-invoked without running a Rich Live context, making direct invocation impractical as a unit test.
- Severity: LOW
- Action: No change required. Add a comment in the test noting why inline condition evaluation is used instead of calling `main()` directly, so future readers don't mistake it for a gap.

### None: STALE-SYM flags are all false positives

The pre-verified STALE-SYM list for `tests/test_finalize_run.sh` (cat, cd, dirname, echo, exit, grep, mkdir, mktemp, pwd, return, rm, set, source, touch, trap) consists entirely of POSIX shell builtins and standard UNIX utilities. None are Tekhton-defined functions. The detection tool performs a textual search against Tekhton source files and cannot distinguish project-internal definitions from shell builtins.

The pre-verified STALE-SYM list for `tools/tests/test_tui.py` (Console, Panel, Path, Table, argparse, builtins, console, io, json, panel, pathlib, pytest, sys, table, tui, tui_render) consists of: standard-library modules (`sys`, `json`, `io`, `pathlib`, `argparse`, `builtins`), third-party library types (`pytest`, `rich.console.Console`, `rich.panel.Panel`, `rich.table.Table`), local test variables (`console`, `panel`, `table`), and two project-module imports (`tui` → `tools/tui.py`; `tui_render` → `tools/tui_render.py`, listed in CLAUDE.md). All are valid.

---

### Detailed per-file assessment

#### tests/test_out_complete.sh (new)

**Assertion Honesty**: PASS. `out_complete` is loaded from the real `lib/output.sh` via `source`. The mock `tui_complete()` is a minimal recording stub; the function under test is unmodified. For `_hook_tui_complete` (tests 6–9), the function body is extracted at runtime from `lib/finalize.sh` via an `awk` state machine (lines 119–123) and `eval`-ed. An explicit guard (lines 125–130) fails the test immediately if awk extraction returns empty, preventing silent false-passes. Assertions check exact string values ("SUCCESS", "FAIL") that come from the extracted function's logic, not hardcoded expectations chosen arbitrarily.

**Edge Case Coverage**: PASS. Covers: absent `tui_complete` (exit 0, no error), defined `tui_complete` (delegation), "SUCCESS" verdict, "FAIL" verdict, unset-after-use silent no-op, exit 0 → "SUCCESS", exit 1 → "FAIL", exit 42 → "FAIL" (arbitrary non-zero), and a canary test (test 9) that verifies `_hook_tui_complete` does not bypass `out_complete` and call `tui_complete` directly.

**Implementation Exercise**: PASS. The real `out_complete` and the real `_hook_tui_complete` body run. Mocks are narrowly scoped to the interface boundary (`tui_complete` recording stub, `out_complete` recording stub for Part 2).

**Test Weakening**: N/A — new file.

**Naming**: PASS. Test labels encode scenario and expected outcome throughout (e.g., "_hook_tui_complete with exit 42 passes 'FAIL' to out_complete").

**Scope Alignment**: PASS. Both M102 implementation targets (`out_complete` in `lib/output.sh`, `_hook_tui_complete` routing in `lib/finalize.sh`) are exercised. No references to deleted files.

**Isolation**: PASS. `TMPDIR_TEST=$(mktemp -d)` with `trap 'rm -rf "$TMPDIR_TEST"' EXIT`. No mutable pipeline artifacts read.

---

#### tests/test_tui_action_items.sh (new)

**Assertion Honesty**: PASS. All assertions are derived from real function-call outputs parsed via `python3 -c 'import json...'`. The JSON is written to a temp status file by calling the real `_tui_json_build_status` (via `_write_status`), which calls the real `_tui_action_items_json`. Test 6 greps `lib/tui_helpers.sh` for the M102 acceptance-criterion pattern `action_items.*\[\]` — this targets an immutable source file and verifies implementation structure, not output values.

**Edge Case Coverage**: PASS. All five behavioral corners of `_tui_action_items_json` are hit: empty `_OUT_CTX[action_items]` (test 1), single item accumulation (test 2), multiple items (test 3), JSON special characters round-trip including double-quotes and backslashes (test 4), and `_OUT_CTX` entirely undefined (test 5). The JSON escaping test correctly accounts for bash single-quote literal semantics vs. the double-escaping done by `_out_json_escape`.

**Implementation Exercise**: PASS. Sources real `lib/tui.sh`, `lib/output.sh`, and `lib/output_format.sh`. Stubs are confined to the TUI sidecar boundary (`_tui_strip_ansi`, `_tui_notify`, colour codes). `_tui_action_items_json`, `_out_append_action_item`, `out_action_item`, and `_tui_json_build_status` all execute unmodified.

**Test Weakening**: N/A — new file.

**Naming**: PASS. Test-group labels encode scenario and outcome (e.g., "without _OUT_CTX defined, action_items falls back to []").

**Scope Alignment**: PASS. Exercises the M102 primary change: `_tui_action_items_json` reading from `_OUT_CTX[action_items]` via `_out_append_action_item` instead of emitting a hardcoded `[]`.

**Isolation**: PASS. `TMPDIR_TEST=$(mktemp -d)` with EXIT trap; all JSON status files written to temp directory; no live `.tekhton/` or `.claude/` files read.

---

#### tests/test_finalize_run.sh (modified)

**Assertion Honesty**: PASS. Suite 1 (hook order) asserts exact string names against `${FINALIZE_HOOKS[@]}`, which is populated by sourcing the real `lib/finalize.sh`. The 25-hook count in assertion 1.1 matches the 25 `register_finalize_hook` calls at lines 507–542 of `lib/finalize.sh` (verified by auditor). Suites 7–16 test real hook implementations (`_hook_cleanup_resolved`, `_hook_resolve_notes`, etc.) through the mock dispatch table, not hand-written stubs of those hooks.

**Edge Case Coverage**: PASS. Covers hook ordering, dynamic registration, exit-code dispatch (0 and non-zero for all guarded hooks), failure resilience of `finalize_run`, shared-state initialization, HUMAN_MODE and CLAIMED_NOTE_IDS interaction (Suite 8b), all disposition values (COMPLETE_AND_CONTINUE, COMPLETE_AND_WAIT, PARTIAL), and express-mode flag combinations.

**Implementation Exercise**: PASS. Sources real `lib/finalize.sh` (which transitively sources `finalize_display.sh`, `finalize_summary.sh`, `run_memory.sh`, `timing.sh`, `finalize_version.sh`, `changelog.sh`). Hook implementations are the real ones; mocks replace only their external dependencies (e.g., `generate_commit_message`, `archive_reports`). `finalize_run` itself is exercised unmodified in Suites 3, 4, 5, 14, and 15.

**Test Weakening**: PASS for M102 change. The only modification to this file for M102 was updating the hook-count assertion from 24 to 25 and adding assertion 1.18 (`_hook_tui_complete` at index 24). No prior assertion was removed or broadened.

**Naming**: PASS. Suite and assertion labels describe the invariant being verified with sufficient specificity.

**Scope Alignment**: PASS. The M102 hook (`_hook_tui_complete`) is verified in assertion 1.18 and implicitly through Suite 14/15 (`finalize_run 0`/`finalize_run 1` exercising all real hooks). The `out_complete` mock at line 207–210 correctly intercepts `_hook_tui_complete`'s call path. No references to deleted files (`.claude/tui_sidecar.pid` is not referenced).

**Isolation**: PASS. `TMPDIR=$(mktemp -d)` with EXIT trap; `cd "$TMPDIR"` at line 80 ensures all relative-path file operations (`.tekhton/HUMAN_NOTES.md`, etc.) land in the temp directory. No reads of live pipeline artifacts.

---

#### tools/tests/test_tui.py (modified — 6 new M102 tests)

**Assertion Honesty**: PASS for M102 additions. Each new test calls the real `tui._hold_on_complete` (which is `tui_hold._hold_on_complete` re-exported via `tui.py`) with a `Console` writing to `StringIO`, then checks `sio.getvalue()` for specific strings. Icon assertions (`\u2717`, `\u26a0`, `\u2139`) and the `"[CRITICAL]"` suffix match `tui_hold.py:67–69` exactly. The `"Action items:"` header suppression tests match the `if action_items:` guard at `tui_hold.py:61`. No hardcoded values appear that are not derived from the implementation.

**Edge Case Coverage**: PASS. M102 tests cover: critical severity (icon + suffix), warning severity (icon, no suffix), normal severity (icon, no suffix), empty list (header suppressed), `None` value (header suppressed via `or []`), and multiple mixed-severity items (all rendered). Pre-existing tests cover the non-interactive fallback path.

**Implementation Exercise**: PASS. `tui._hold_on_complete` is the real `tui_hold._hold_on_complete`. The action-items rendering block (`tui_hold.py:60–72`) executes completely unmodified in every M102 test. The only mocks are `/dev/tty` (unavailable in CI — triggers the `except OSError` fallback) and `tui_hold.time.sleep` (short-circuits the 3-second pause). Both mocks are at the I/O boundary and do not affect the rendering logic.

**Test Weakening**: PASS. Pre-existing tests (`test_hold_on_complete_non_interactive`, all stage-pill, watchdog tests) are unchanged. The `_no_tty` helper is a refactored extraction of the identical `monkeypatch` pattern from the existing test — not a weakening, reduces duplication.

**Naming**: PASS. M102 test names are fully descriptive (e.g., `test_hold_on_complete_null_action_items_no_header`).

**Scope Alignment**: PASS. All 6 new tests target `tui_hold._hold_on_complete`, the M102 implementation target. No imports reference deleted files. `.claude/tui_sidecar.pid` is not referenced.

**Isolation**: PASS. Uses `tmp_path` pytest fixture and `monkeypatch` for all external dependencies. No mutable project state read.
