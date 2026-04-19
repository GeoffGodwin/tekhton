## Test Audit Report

### Audit Summary
Tests audited: 3 files, 18 test cases (10 shell TC-OB + 6 shell TC-TUI + 2 Python)
Verdict: PASS

### Findings

#### COVERAGE: _tui_stage_order_json primary path unexercised
- File: tests/test_output_tui_sync.sh:119–130 (TC-TUI-03)
- Issue: `_tui_stage_order_json()` has two branches: (1) use `_TUI_STAGE_ORDER` when
  populated — the production path set by `tui_set_context` — and (2) fall back to
  `_OUT_CTX[stage_order]` when the array is empty. TC-TUI-03 only exercises the fallback
  branch by leaving `_TUI_STAGE_ORDER=()` in every `_reset_tui_globals` call. No test
  populates `_TUI_STAGE_ORDER` with entries and verifies the JSON output. The branch
  executed in every real pipeline run is untested.
- Severity: MEDIUM
- Action: Add TC-TUI-07 that assigns `_TUI_STAGE_ORDER=("intake" "coder" "tester")`
  before calling `_tui_json_build_status`, then asserts those three labels appear in the
  JSON stage_order array. This exercises `tui_helpers.sh:93–96`.

#### COVERAGE: _out_emit silent-drop path (TUI active, no LOG_FILE) not tested
- File: tests/test_output_bus.sh:96–104 (TC-OB-06)
- Issue: TC-OB-06 verifies TUI mode with a populated `LOG_FILE`. A third execution path
  exists in `output.sh:93–99`: when `_TUI_ACTIVE=true` but `LOG_FILE` is empty or unset,
  the message is silently dropped — no stdout, no file write. This path is live whenever
  the TUI sidecar is active before a log file has been configured. No test case covers it.
- Severity: MEDIUM
- Action: Add TC-OB-11: set `_TUI_ACTIVE=true` and `LOG_FILE=""`, call
  `_out_emit info "dropped"`, assert stdout is empty. Confirm via a reference temp file
  that no bytes were written anywhere.

#### COVERAGE: _out_color() NO_COLOR suppression not directly tested
- File: tests/test_output_bus.sh:128–147 (TC-OB-10)
- Issue: TC-OB-10 tests `_out_emit` NO_COLOR behavior by manually clearing the color
  vars (`CYAN="" RED=""…`). This correctly exercises `_out_emit` (which uses direct var
  references), but the `_out_color()` helper in `output_format.sh:22–28` — which
  evaluates `NO_COLOR` at call time and is used by `out_banner`, `out_kv`, and
  `out_action_item` — is never exercised for its suppression branch.
- Severity: LOW
- Action: Add a small test that sets `NO_COLOR=1`, calls `_out_color "${RED}"`, and
  asserts the output is empty. Then unsets `NO_COLOR` and confirms the ANSI code passes
  through. Self-contained, no pipeline state required.

#### COVERAGE: _hold_on_complete recent_events rendering branch not tested
- File: tools/tests/test_tui_action_items.py:78–124
- Issue: Both Python tests pass `"recent_events": []` via `_base_status()`. The event
  log rendering block in `tui_hold.py:49–58` — which iterates events and applies
  per-level styles from `_EVENT_LEVEL_STYLES` — is never exercised. This is a sibling
  branch in the same function under test.
- Severity: LOW
- Action: Add `test_recent_events_rendered` that populates `recent_events` with one event
  per level and asserts the message text and "Event log:" header appear in console output.

### None

No INTEGRITY, ISOLATION, WEAKENING, SCOPE, or EXERCISE violations found.

---

### Detailed per-file assessment

#### tests/test_output_bus.sh (new — TC-OB-01..10)

**Assertion Honesty**: PASS. All expected values derive directly from `output.sh`
implementation logic: `out_init` defaults (`mode=""`, `attempt="1"`, `max_attempts="1"`,
`action_items=""`) match `output.sh:26–37`; `_out_emit` prefix strings (`[tekhton]`,
`[!]`, `[✗]`, `══`) match the `case` table at `output.sh:61–83`; mode defaults for
`log`/`warn`/`header` match `common.sh:94–99`. No hardcoded magic values.

**Edge Case Coverage**: Covers missing-key safety under `set -u` (TC-OB-03), overwrite
semantics (TC-OB-04), TUI vs CLI routing branch (TC-OB-05 + TC-OB-06), and NO_COLOR
regression (TC-OB-10). The silent-drop path (TUI active, LOG_FILE empty) is the one
gap noted under COVERAGE above.

**Implementation Exercise**: Sources the real `lib/common.sh` (which sources `output.sh`
and `output_format.sh`). Calls `out_init`, `out_set_context`, `out_ctx`, `_out_emit`,
`log`, `warn`, `header` without mocking the function under test.

**Test Weakening**: N/A — new file.

**Naming**: Section labels (`=== TC-OB-01: out_init populates all keys with safe
defaults ===`) and per-assertion labels encode both scenario and expected outcome.

**Scope Alignment**: PASS. All referenced functions exist in current implementation.

**Isolation**: PASS. `TMPDIR_TEST=$(mktemp -d)` with `trap 'rm -rf "$TMPDIR_TEST"' EXIT`.
No mutable pipeline artifacts (`.tekhton/`, `.claude/logs/`) read.

---

#### tests/test_output_tui_sync.sh (new — TC-TUI-01..06)

**Assertion Honesty**: PASS. `assert_json_field` extracts values via `python3 -c
'import json…'` against JSON produced by the real `_tui_json_build_status`. Numeric
fields `attempt` and `max_attempts` are emitted without quotes (`output.sh:185–186`);
the Python extractor prints the integer value as a string, and the comparison
`[[ "2" == "2" ]]` is correct. `_OUT_CTX`-driven counters are set via `out_set_context`
and read by the implementation at `tui_helpers.sh:149–151` — the round-trip is real.

**Edge Case Coverage**: Covers six run modes (TC-TUI-06), counter isolation from
`PIPELINE_ATTEMPT` (TC-TUI-05), stage_order fallback (TC-TUI-03), and action_items
accumulation via `out_action_item` in TUI mode (TC-TUI-04). Primary path of
`_tui_stage_order_json` (non-empty `_TUI_STAGE_ORDER`) is the gap noted above.

**Implementation Exercise**: Sources real `lib/tui.sh` (which sources `tui_helpers.sh`),
then `lib/output.sh` and `lib/output_format.sh`. Only `log/warn/error/success/header/
log_verbose` are stubbed — these are called by sourced modules at definition time but
not in the code paths exercised. `_tui_json_build_status`, `out_action_item`, and
`_out_append_action_item` run unmodified.

**Test Weakening**: N/A — new file.

**Naming**: PASS. Labels include both field name and expected value (e.g., `"fix-nb
run_mode"`, `"attempt counter synced"`).

**Scope Alignment**: PASS. The M103 change to `tui_helpers.sh` (`max_attempts` reads
`_OUT_CTX[max_attempts]` first, `MAX_PIPELINE_ATTEMPTS` as fallback) is directly
exercised by TC-TUI-02.

**Isolation**: PASS. `TMPDIR_TEST=$(mktemp -d)` with EXIT trap. `_reset_tui_globals`
reinitialises all TUI globals between cases with no shared mutable state.

---

#### tools/tests/test_tui_action_items.py (new — 2 tests)

**Assertion Honesty**: PASS. `test_action_items_rendered` calls the real
`tui._hold_on_complete` (which is `tui_hold._hold_on_complete`, re-exported at
`tui.py:38`) with a `Console` writing to `StringIO`. Icon assertions
(`\u2717`/`\u26a0`/`\u2139`) and `"[CRITICAL]"` suffix match `tui_hold.py:67–69`
exactly. `test_empty_action_items_no_section` asserts header suppression against the
`if action_items:` guard at `tui_hold.py:61`. The `status.get("action_items") or []`
idiom at that line correctly maps `[]`, missing key, and `None` to an empty list — all
three are tested.

**Edge Case Coverage**: Covers critical/warning/normal severity rendering, all three
empty-list forms (empty list, missing key, None). The `recent_events` rendering branch
is the gap noted above.

**Implementation Exercise**: The real `_hold_on_complete` body runs. Only `/dev/tty`
(patched to raise `OSError`) and `tui_hold.time.sleep` (patched to no-op) are mocked,
both at the I/O boundary. The action-items rendering block at `tui_hold.py:60–72` executes
completely.

**Test Weakening**: N/A — new file.

**Naming**: PASS. `test_action_items_rendered` and `test_empty_action_items_no_section`
describe the scenario and expected outcome.

**Scope Alignment**: PASS. `tui._hold_on_complete` exists and is the real function
(`tui.py:38`: `from tui_hold import _hold_on_complete  # re-export for tests`). No
references to deleted symbols.

**Isolation**: PASS. Fixture data constructed inline via `_base_status()`. `Console`
writes to `io.StringIO`. No pipeline state or project files read.
