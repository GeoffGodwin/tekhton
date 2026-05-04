# M107 — TUI Stage Wiring: All Stages Instrumented
<!-- milestone-meta
id: "107"
status: "done"
-->

## Overview

M106 built the registry and protocol API. This milestone wires every stage in the
pipeline to that protocol, eliminating all the grey-pill bugs the user sees in
practice.

Stages currently missing TUI lifecycle notifications:

| Stage | Where | Why missing |
|---|---|---|
| `intake` | Pre-stage in `tekhton.sh` | Runs before the pipeline loop; no TUI calls |
| `scout` | Inside `stages/coder.sh` | Loop skips it with `continue`; runs hidden |
| `tester`/`tester-write` | Pipeline loop | Wrong label (`"test verify"` ≠ `"tester"`) |
| Sr/Jr coder rework | `stages/review.sh` | Sub-stage; no TUI calls anywhere |
| wrap-up | Finalization | Stage doesn't exist yet |

Additionally, the pipeline loop still uses the broken `${_stage_name//_/ }` label
derivation for coder, security, review, and docs stages. These happen to work
today (the spaces match the expected labels), but they are fragile — any future
stage rename will silently break pill tracking again. The fix locks them to
`get_stage_display_label`.

## Design

### §1 — `get_display_stage_order`: Add "wrap-up" and Remove Redundant "scout"

**Add "wrap-up"** as the permanent final pill in `get_display_stage_order()`. It
is always visible from the moment the run starts, setting the user's expectation
that finalization is the last step of every pipeline run.

Insert these two lines immediately before the final `echo "$display"` in
`get_display_stage_order()` (`lib/pipeline_order.sh`):

```bash
    # wrap-up is always the final pill; it activates during finalize_run().
    display="${display:+$display }wrap-up"

    echo "$display"
}
```

No other changes to the function body. The existing case mappings and
conditional filtering remain unchanged.

### §2 — Fix Pipeline Loop Label Derivation in `tekhton.sh`

Replace both `tui_update_stage`/`tui_finish_stage` call sites in the pipeline
loop with `tui_stage_begin`/`tui_stage_end` using `get_stage_display_label`.

**Before each stage case block** (currently at `tekhton.sh:2328`):

```bash
# Before:
if declare -f tui_update_stage &>/dev/null; then
    local _tui_stage_label
    _tui_stage_label="${_stage_name//_/ }"
    tui_update_stage "$_stage_idx" "$PIPELINE_STAGE_COUNT" "$_tui_stage_label" "${CLAUDE_STANDARD_MODEL:-}"
fi

# After:
if declare -f tui_stage_begin &>/dev/null; then
    local _tui_display_label
    _tui_display_label=$(get_stage_display_label "$_stage_name")
    tui_stage_begin "$_tui_display_label" "${CLAUDE_STANDARD_MODEL:-}"
fi
```

**After each stage case block** (currently at `tekhton.sh:2489`):

```bash
# Before:
if declare -f tui_finish_stage &>/dev/null; then
    local _tui_finish_label _tui_finish_dur
    _tui_finish_label="${_stage_name//_/ }"
    _tui_finish_dur="${_STAGE_DURATION[$_stage_name]:-0}s"
    tui_finish_stage "$_tui_finish_label" "${CLAUDE_STANDARD_MODEL:-}" \
        "${_STAGE_TURNS[$_stage_name]:-0}/${_STAGE_BUDGET[$_stage_name]:-0}" \
        "$_tui_finish_dur" ""
fi

# After:
if declare -f tui_stage_end &>/dev/null; then
    local _tui_display_label _tui_finish_dur
    _tui_display_label=$(get_stage_display_label "$_stage_name")
    _tui_finish_dur="${_STAGE_DURATION[$_stage_name]:-0}s"
    tui_stage_end "$_tui_display_label" "${CLAUDE_STANDARD_MODEL:-}" \
        "${_STAGE_TURNS[$_stage_name]:-0}/${_STAGE_BUDGET[$_stage_name]:-0}" \
        "$_tui_finish_dur" ""
fi
```

### §3 — Intake Pre-Stage Wiring in `tekhton.sh`

The intake pre-stage block (around `tekhton.sh:2256`) runs before the pipeline
loop. Add protocol calls immediately around `run_stage_intake`:

```bash
if [ "$START_AT" = "intake" ] || [ "$START_AT" = "coder" ]; then
    CURRENT_STAGE="intake"
    _STAGE_STATUS[intake]="active"
    _STAGE_BUDGET[intake]="${INTAKE_MAX_TURNS:-10}"
    _STAGE_START_TS[intake]="$SECONDS"
    emit_dashboard_run_state 2>/dev/null || true
    local _intake_start_evt
    _intake_start_evt=$(emit_event "stage_start" "intake" "" "$_LAST_STAGE_EVT" "" "")
    if declare -f tui_stage_begin &>/dev/null; then          # ← ADD
        tui_stage_begin "intake" "${CLAUDE_STANDARD_MODEL:-}"
    fi
    run_stage_intake
    _LAST_STAGE_EVT=$(emit_event "stage_end" "intake" "${INTAKE_VERDICT:-pass}" "$_intake_start_evt" "" \
        "{\"confidence\":${INTAKE_CONFIDENCE:-0}}")
    _STAGE_STATUS[intake]="complete"
    _STAGE_TURNS[intake]="${LAST_AGENT_TURNS:-0}"
    _STAGE_DURATION[intake]="$(( SECONDS - ${_STAGE_START_TS[intake]:-$SECONDS} ))"
    if declare -f tui_stage_end &>/dev/null; then             # ← ADD
        tui_stage_end "intake" "${CLAUDE_STANDARD_MODEL:-}" \
            "${_STAGE_TURNS[intake]:-0}/${_STAGE_BUDGET[intake]:-0}" \
            "${_STAGE_DURATION[intake]:-0}s" "${INTAKE_VERDICT:-}"
    fi
    emit_dashboard_run_state 2>/dev/null || true
    ...
fi
```

### §4 — Scout Wiring in `stages/coder.sh`

Scout runs as a sub-invocation of `run_stage_coder`. Locate the `run_agent` call
for the Scout agent inside that function and bracket it with protocol calls.

The display label is `"scout"` (matches `get_stage_display_label "scout"`).

```bash
if declare -f tui_stage_begin &>/dev/null; then
    tui_stage_begin "scout" "${CLAUDE_STANDARD_MODEL:-}"
fi
run_agent "Scout" "$CLAUDE_STANDARD_MODEL" "$SCOUT_MAX_TURNS" \
    "$SCOUT_PROMPT" "$SCOUT_LOG" "$AGENT_TOOLS_SCOUT"
if declare -f tui_stage_end &>/dev/null; then
    tui_stage_end "scout" "${CLAUDE_STANDARD_MODEL:-}" \
        "${LAST_AGENT_TURNS:-0}/${SCOUT_MAX_TURNS:-10}" \
        "${LAST_AGENT_ELAPSED:-0}s" ""
fi
```

Because `"scout"` is already present in `_TUI_STAGE_ORDER` (from
`get_display_stage_order()`), `tui_stage_begin` will not duplicate it — it will
just activate the existing pill.

**Note on dual elapsed values:** `tui_stage_end` internally computes a frozen
elapsed from `_TUI_STAGE_START_TS` (M106 §2) for the active bar display, while
the explicit `time_str` argument (`"${LAST_AGENT_ELAPSED:-0}s"`) is stored in the
`stages_complete` JSON entry (via `tui_finish_stage` → `_tui_json_stage`). These
serve different purposes: the frozen value drives the active-bar "✓ Complete"
display; the `time_str` field appears in the timings column (M108). They may
differ by 1–2 seconds due to the timing gap between `run_agent` returning and
`tui_stage_end` executing; this is cosmetic and acceptable.

### §5 — Rework Sub-Stage Wiring in `stages/review.sh`

Two rework paths exist: Sr coder rework (around line 260) and Jr-only rework
(around line 299). Both call `run_agent` for a coder variant. Bracket each with
protocol calls using label `"rework"`.

**Sr coder rework path:**

```bash
if declare -f tui_stage_begin &>/dev/null; then
    tui_stage_begin "rework" "${CLAUDE_CODER_MODEL:-}"
fi
run_agent "Coder (rework cycle ${REVIEW_CYCLE})" \
    "$CLAUDE_CODER_MODEL" ...
if declare -f tui_stage_end &>/dev/null; then
    tui_stage_end "rework" "${CLAUDE_CODER_MODEL:-}" \
        "${LAST_AGENT_TURNS:-0}/${CODER_MAX_TURNS:-70}" \
        "${LAST_AGENT_ELAPSED:-0}s" ""
fi
```

**Jr coder rework path** (same pattern, different model variable):

```bash
if declare -f tui_stage_begin &>/dev/null; then
    tui_stage_begin "rework" "${CLAUDE_JR_CODER_MODEL:-}"
fi
run_agent ... "$CLAUDE_JR_CODER_MODEL" \
    "${EFFECTIVE_JR_CODER_MAX_TURNS:-$JR_CODER_MAX_TURNS}" ...
if declare -f tui_stage_end &>/dev/null; then
    tui_stage_end "rework" "${CLAUDE_JR_CODER_MODEL:-}" \
        "${LAST_AGENT_TURNS:-0}/${JR_CODER_MAX_TURNS:-30}" \
        "${LAST_AGENT_ELAPSED:-0}s" ""
fi
```

On the first rework call, `tui_stage_begin "rework"` appends `"rework"` to
`_TUI_STAGE_ORDER` (the dynamic pill insertion from M106 §2). Subsequent cycles
reuse the same pill: the pill cycles active → complete → active → complete as
cycles proceed.

### §6 — Wrap-Up Wiring in `lib/finalize.sh`

**Begin wrap-up inside `finalize_run()`**, as the very first action, before any
hooks execute. This covers all call sites of `finalize_run` with a single change:

```bash
finalize_run() {
    local pipeline_exit_code="${1:-0}"

    # Notify TUI that finalization has begun (wrap-up stage)
    if declare -f tui_stage_begin &>/dev/null; then
        tui_stage_begin "wrap-up" "" 2>/dev/null || true
    fi

    # State shared between hooks
    FINAL_CHECK_RESULT=0
    ...
```

**End wrap-up inside `_hook_tui_complete()`** in `lib/finalize.sh`, just before
`out_complete`. This is the natural endpoint: all commit, archive, and version-bump
hooks have already run:

```bash
_hook_tui_complete() {
    local exit_code="${1:-0}"
    local verdict="SUCCESS"
    [[ "$exit_code" -ne 0 ]] && verdict="FAIL"
    # Mark wrap-up complete before signalling TUI sidecar to enter hold-on-complete
    if declare -f tui_stage_end &>/dev/null; then
        tui_stage_end "wrap-up" "" "" "" "$verdict" 2>/dev/null || true
    fi
    out_complete "$verdict" 2>/dev/null || true
}
```

This design has one `tui_stage_begin` site and one `tui_stage_end` site for
wrap-up, regardless of how many `finalize_run` call sites exist. No changes needed
at those call sites.

### §7 — Test Coverage

Add `tests/test_tui_stage_wiring.sh` (new integration test):

Test each label the pipeline emits under the new wiring:

- Simulate intake block: call `tui_stage_begin "intake"` then `tui_stage_end "intake"`;
  confirm `stages_complete` JSON contains an entry with `"label":"intake"`.
- Confirm that when `tui_stage_begin "test_verify"` is called with the OLD broken
  label, it does NOT create a pill matching `"tester"`. Instead it creates a pill
  labeled `"test_verify"` (raw name) which does not match any entry from
  `get_display_stage_order()`. (Regression guard — callers must use
  `get_stage_display_label`, not raw names.)
- Simulate two rework cycles: call `tui_stage_begin "rework"` / `tui_stage_end "rework"`
  twice; confirm `_TUI_STAGE_ORDER` contains exactly one `"rework"` entry but
  `_TUI_STAGES_COMPLETE` contains two `"rework"` entries.
- Confirm `get_display_stage_order` output ends with `"wrap-up"`.

## Files Modified

| File | Change |
|------|--------|
| `lib/pipeline_order.sh` | Append `wrap-up` at end of `get_display_stage_order()` |
| `tekhton.sh` | Pipeline loop: replace `tui_update_stage`/`tui_finish_stage` with `tui_stage_begin`/`tui_stage_end` via `get_stage_display_label`; add intake pre-stage TUI calls |
| `stages/coder.sh` | Add `tui_stage_begin`/`tui_stage_end` around scout `run_agent` call |
| `stages/review.sh` | Add `tui_stage_begin`/`tui_stage_end` around both Sr and Jr rework `run_agent` calls |
| `lib/finalize.sh` | Add `tui_stage_begin "wrap-up"` at start of `finalize_run()`; add `tui_stage_end "wrap-up"` in `_hook_tui_complete()` before `out_complete` |
| `tests/test_tui_stage_wiring.sh` | New integration test for all wired labels |

## Acceptance Criteria

- [ ] After a full pipeline run, the pill bar shows all stages in sequence (intake → scout → coder → security → review → tester → wrap-up)
- [ ] Intake pill turns yellow (▶) when intake runs and green (✓) when it completes
- [ ] Scout pill turns yellow (▶) briefly during the scout phase inside coder; turns green (✓) before coder begins
- [ ] Tester pill turns yellow (▶) when tester runs and green (✓) when it completes; elapsed timer freezes (does not count up after completion)
- [ ] When a reviewer triggers rework, a `"rework"` pill appears dynamically in the pill bar, turns yellow (▶) during the rework agent, and turns green (✓) when it finishes
- [ ] A second rework cycle reuses the same `"rework"` pill (bar has one pill, not two); the pill turns yellow again for the second cycle
- [ ] The wrap-up pill is visible from run start as grey (○), turns yellow (▶) when `finalize_run` begins, and turns green (✓) when `_hook_tui_complete` fires
- [ ] The active-stage bar shows the correct label for each of intake, scout, rework, and wrap-up (not a raw internal name like `"test verify"`)
- [ ] The two-rework integration test confirms one pill entry but two `stages_complete` entries
- [ ] `get_display_stage_order` output ends with `"wrap-up"` in all pipeline configurations (standard, test_first, with/without security/docs)
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
