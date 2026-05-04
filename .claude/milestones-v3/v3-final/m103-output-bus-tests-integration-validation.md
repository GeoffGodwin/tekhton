# M103 — Output Bus Tests + Integration Validation
<!-- milestone-meta
id: "103"
status: "done"
-->

## Overview

M99–M102 introduced `lib/output.sh`, `lib/output_format.sh`, changes to
`lib/tui_helpers.sh`, and a new completion sequence. None of these have dedicated
automated tests yet (M101 added a lint check, but not behavioral tests). This
milestone closes that gap with:

1. **Unit tests** for the context store and emit routing
2. **Integration tests** verifying TUI JSON correctness across all six execution modes
3. **Regression tests** for CLI output (NO_COLOR, backward compat)
4. **Lint enforcement** as a required test (the file from M101 is run here as part of
   the full suite)
5. **Python tests** for `tui_hold.py` action-item rendering

## Design

### §1 — Test File Layout

All new tests follow the existing Tekhton convention: bash test files in `tests/`,
Python tests in `tools/tests/`. Tests are discovered by `tests/run_tests.sh`.

```
tests/
  test_output_bus.sh         # Unit: _OUT_CTX, _out_emit, out_set_context, out_ctx
  test_output_tui_sync.sh    # Integration: TUI JSON fields for all 6 run modes
  test_output_lint.sh        # Lint: zero direct ANSI echoes outside output module
                             # (created in M101; verified to exist and pass here)
tools/tests/
  test_tui_action_items.py   # Python unit: action_items rendering in tui_hold.py
```

### §2 — `tests/test_output_bus.sh`: Context Store Unit Tests

Source `lib/output.sh` (and `lib/common.sh` for `_tui_strip_ansi`) in a test
harness. Use the existing test helper pattern from other test files in `tests/`.

**Test cases:**

```bash
# TC-OB-01: out_init populates all keys with safe defaults
out_init
assert_eq "" "$(out_ctx mode)"        "mode default is empty"
assert_eq "1" "$(out_ctx attempt)"    "attempt default is 1"
assert_eq "1" "$(out_ctx max_attempts)" "max_attempts default is 1"

# TC-OB-02: out_set_context / out_ctx round-trip
out_set_context mode "fix-nb"
assert_eq "fix-nb" "$(out_ctx mode)"  "set and get mode"

# TC-OB-03: out_ctx on unset key returns empty, no error under set -u
out_init
result=$(out_ctx nonexistent_key 2>&1)
assert_eq "" "$result"                 "missing key returns empty"
assert_eq "0" "$?"                     "missing key does not error"

# TC-OB-04: out_set_context overwrites previous value
out_set_context attempt 1
out_set_context attempt 3
assert_eq "3" "$(out_ctx attempt)"    "overwrite works"

# TC-OB-05: _out_emit in CLI mode (TUI inactive) writes to stdout
_TUI_ACTIVE=false
output=$(LOG_FILE="" _out_emit info "hello" 2>/dev/null)
assert_contains "[tekhton]" "$output"  "_out_emit info has prefix"
assert_contains "hello" "$output"     "_out_emit info has message"

# TC-OB-06: _out_emit in TUI mode writes nothing to stdout
_TUI_ACTIVE=true
tmplog=$(mktemp)
LOG_FILE="$tmplog" output=$(_out_emit info "hello" 2>/dev/null)
assert_eq "" "$output"                 "TUI mode: no stdout"
assert_contains "hello" "$(cat "$tmplog")"  "TUI mode: message in log"
rm -f "$tmplog"
_TUI_ACTIVE=false

# TC-OB-07: log() wrapper produces same output as pre-M99 (backward compat)
_TUI_ACTIVE=false
output=$(LOG_FILE="" log "test message" 2>/dev/null)
assert_contains "[tekhton]" "$output"  "log() prefix preserved"
assert_contains "test message" "$output" "log() message preserved"

# TC-OB-08: warn() wrapper produces [!] prefix
_TUI_ACTIVE=false
output=$(LOG_FILE="" warn "bad thing" 2>/dev/null)
assert_contains "[!]" "$output"        "warn() prefix preserved"

# TC-OB-09: header() produces surrounding newlines and border
_TUI_ACTIVE=false
output=$(LOG_FILE="" header "Section" 2>/dev/null)
assert_contains "══" "$output"         "header() has border"
assert_contains "Section" "$output"   "header() has title"
```

### §3 — `tests/test_output_tui_sync.sh`: TUI JSON Integration Tests

These tests simulate each execution mode by calling `out_set_context` with the
appropriate values, then calling `_tui_json_build_status 0` (exported from
`lib/tui_helpers.sh`) and asserting the JSON fields.

**The six execution modes and their expected `run_mode` values:**

| Mode | Trigger | Expected `run_mode` |
|------|---------|---------------------|
| Plain task | default | `task` |
| Milestone run | `MILESTONE_MODE=true` | `milestone` |
| `--complete` loop | `COMPLETE_MODE=true` | `complete` |
| `--fix nb` | `FIX_NONBLOCKERS_MODE=true` | `fix-nb` |
| `--fix drift` | `FIX_DRIFT_MODE=true` | `fix-drift` |
| `--human` | `HUMAN_MODE=true` | `human` |

**Test cases:**

```bash
# TC-TUI-01: run_mode=task (default)
out_init
out_set_context mode "task"
out_set_context attempt 1
json=$(_tui_json_build_status 0)
assert_json_field "task" "run_mode" "$json"   "default run_mode is task"

# TC-TUI-02: run_mode=fix-nb shows correct attempt counter
out_set_context mode "fix-nb"
out_set_context attempt 2
out_set_context max_attempts 3
json=$(_tui_json_build_status 0)
assert_json_field "fix-nb" "run_mode" "$json"  "fix-nb run_mode"
assert_json_field "2" "attempt" "$json"         "attempt counter synced"
assert_json_field "3" "max_attempts" "$json"    "max_attempts synced"

# TC-TUI-03: stage_order reflects get_display_stage_order output (M100)
out_set_context stage_order "intake scout coder security review tester"
json=$(_tui_json_build_status 0)
# stage_order JSON array should contain "intake" as first element
assert_contains '"intake"' "$json"             "stage_order includes intake"
assert_contains '"tester"' "$json"             "stage_order includes tester"

# TC-TUI-04: action_items populated from _OUT_CTX (M102)
_OUT_CTX[action_items]='[{"msg":"fix tests","severity":"critical"}]'
json=$(_tui_json_build_status 0)
assert_contains '"fix tests"' "$json"          "action_items appear in JSON"
assert_contains '"critical"' "$json"           "severity appears in JSON"

# TC-TUI-05: attempt reads from _OUT_CTX, not PIPELINE_ATTEMPT
unset PIPELINE_ATTEMPT 2>/dev/null || true
out_set_context attempt 4
json=$(_tui_json_build_status 0)
assert_json_field "4" "attempt" "$json"        "_OUT_CTX[attempt] used, not PIPELINE_ATTEMPT"
```

**Helper `assert_json_field EXPECTED FIELD JSON`** — extracts the field value with
`grep`/`sed` (no jq dependency, consistent with the existing test harness):

```bash
assert_json_field() {
    local expected="$1" field="$2" json="$3"
    local actual
    actual=$(printf '%s' "$json" | sed -n "s/.*\"${field}\":\(\"[^\"]*\"\|[0-9]*\).*/\1/p" | tr -d '"')
    if [[ "$actual" != "$expected" ]]; then
        echo "FAIL: expected ${field}=${expected}, got ${actual}"
        return 1
    fi
}
```

### §4 — `tests/test_output_lint.sh` (from M101): Verify It Passes

M101 created this file. M103 verifies it exists and passes as part of the suite:

```bash
# In tests/run_tests.sh or test_output_lint.sh itself:
bash tests/test_output_lint.sh
```

The lint check must return exit 0. If it fails, output identifies the offending lines.

### §5 — `tests/test_output_bus.sh`: NO_COLOR Regression

```bash
# TC-OB-10: NO_COLOR=1 suppresses all ANSI in _out_emit output
NO_COLOR=1
_TUI_ACTIVE=false
output=$(LOG_FILE="" _out_emit info "hello" 2>/dev/null)
# Verify no ESC bytes in output
if printf '%s' "$output" | grep -qP '\x1b'; then
    echo "FAIL: ANSI escape found in output with NO_COLOR=1"
    exit 1
fi
echo "PASS TC-OB-10: NO_COLOR=1 produces clean output"
unset NO_COLOR
```

### §6 — `tools/tests/test_tui_action_items.py`: Python Unit Tests

Tests for the action-item rendering added to `_hold_on_complete` in M102.

```python
# tools/tests/test_tui_action_items.py
from unittest.mock import MagicMock, patch
import sys, os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from tui_hold import _hold_on_complete

def make_status(action_items):
    return {
        "complete": True,
        "verdict": "SUCCESS",
        "task": "test task",
        "milestone": "103",
        "pipeline_elapsed_secs": 60,
        "recent_events": [],
        "action_items": action_items,
    }

def test_action_items_rendered(capsys):
    console = MagicMock()
    with patch("builtins.open", MagicMock()), \
         patch("tui_hold.open", MagicMock(return_value=MagicMock(readline=lambda: "\n"))):
        _hold_on_complete(make_status([
            {"msg": "fix tests", "severity": "critical"},
            {"msg": "review drift", "severity": "warning"},
        ]), console, 60)
    # Verify console.print was called with critical item text
    calls = [str(c) for c in console.print.call_args_list]
    assert any("fix tests" in c for c in calls), "critical item not rendered"
    assert any("review drift" in c for c in calls), "warning item not rendered"

def test_empty_action_items_no_section(capsys):
    console = MagicMock()
    with patch("builtins.open", MagicMock()), \
         patch("tui_hold.open", MagicMock(return_value=MagicMock(readline=lambda: "\n"))):
        _hold_on_complete(make_status([]), console, 60)
    calls = [str(c) for c in console.print.call_args_list]
    assert not any("Action items" in c for c in calls), \
        "Action items header shown when list is empty"
```

### §7 — Update Existing TUI Tests

`tools/tests/test_tui.py` was added in M97/M98. Update it to reflect:
- `_build_header_bar` now reads `run_mode`/`attempt`/`stage_order` from the JSON
  that is sourced from `_OUT_CTX` — existing tests may hardcode these fields; ensure
  they still pass
- Add test: `action_items=[]` in status → `_hold_on_complete` skips the
  "Action items:" section (already covered by §6 `test_empty_action_items_no_section`)

## Files Modified

| File | Change |
|------|--------|
| `tests/test_output_bus.sh` | **New.** Unit tests for context store, emit routing, backward compat, NO_COLOR |
| `tests/test_output_tui_sync.sh` | **New.** Integration tests for TUI JSON correctness across 6 run modes |
| `tests/test_output_lint.sh` | Already created in M101; verified to exist and pass here |
| `tools/tests/test_tui_action_items.py` | **New.** Python unit tests for action-item rendering in `tui_hold.py` |
| `tools/tests/test_tui.py` | Update existing tests to match M102 changes; add empty-action-items test |

## Acceptance Criteria

- [ ] `bash tests/test_output_bus.sh` passes all 10 test cases (TC-OB-01 through TC-OB-10)
- [ ] `bash tests/test_output_tui_sync.sh` passes all 5 test cases (TC-TUI-01 through TC-TUI-05)
- [ ] `bash tests/test_output_lint.sh` passes: zero direct ANSI `echo -e` calls
      outside the output module
- [ ] `pytest tools/tests/test_tui_action_items.py` passes both test functions
- [ ] `PIPELINE_ATTEMPT` appears zero times in `grep -r PIPELINE_ATTEMPT lib/ tekhton.sh`
- [ ] `NO_COLOR=1 bash tests/test_output_bus.sh` passes TC-OB-10 (no ANSI in output)
- [ ] `bash tests/run_tests.sh` passes with all existing and new tests included —
      no regressions from M99–M103 changes
- [ ] `shellcheck` passes on all new `.sh` test files with zero warnings
- [ ] `tools/tests/test_tui.py` passes with any updates applied
