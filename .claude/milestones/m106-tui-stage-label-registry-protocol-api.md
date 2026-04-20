# M106 — TUI Stage Label Registry & Protocol API
<!-- milestone-meta
id: "106"
status: "done"
-->

## Overview

The TUI stage-pill bar is unreliable. Intake, scout, and tester pills stay grey
through an entire run. After tester finishes its elapsed timer keeps counting
upward indefinitely. The spinner text `[tekhton] ⠹ Stage (0m12s, --/10 turns)`
appears at the bottom-left corner of the TUI overlaid on the layout.

These are three distinct bugs sharing one root cause: there is no canonical bridge
between Tekhton's internal stage names (`test_verify`, `scout`, `intake`) and the
display labels the pill bar renders (`tester`, `scout`, `intake`). Every call site
that updates the TUI derives its label with an ad-hoc `${name//_/ }` substitution
that doesn't match what `get_display_stage_order()` emits. Additionally the spinner
subprocess in `lib/agent.sh` and the TUI sidecar write to `/dev/tty` concurrently
without a clean separation of responsibilities, and `tui_finish_stage` never stops
the live elapsed clock.

This milestone builds the structural foundation that M107 (wiring) and M108
(timings column) depend on. Nothing is user-visible yet; correctness comes from
wiring in the next milestone.

## Design

### §1 — Stage Label Registry: `get_stage_display_label` in `lib/pipeline_order.sh`

Add a single function that is the **only** authoritative mapping from internal
pipeline stage name to TUI display label. Every call site that communicates a stage
transition to the TUI MUST call this function rather than performing any manual
string transformation.

```bash
# get_stage_display_label NAME
# Returns the display label used in the TUI pill bar for a given internal stage name.
# This is the single extension point: add new stage mappings HERE ONLY.
# Both get_display_stage_order() and all tui_stage_begin/end call sites depend on
# this function. When a new stage is added to the pipeline, add its mapping here
# first; the pill bar, timings column, and stage-complete records all update automatically.
get_stage_display_label() {
    case "${1:-}" in
        intake)          echo "intake" ;;
        scout)           echo "scout" ;;
        coder)           echo "coder" ;;
        test_write)      echo "tester-write" ;;
        test_verify)     echo "tester" ;;
        security)        echo "security" ;;
        review)          echo "review" ;;
        docs)            echo "docs" ;;
        rework)          echo "rework" ;;
        wrap_up|wrap-up) echo "wrap-up" ;;
        # Fallback: replace underscores with hyphens. New stages MUST be added
        # above; this catch-all prevents hard failures during development but
        # will not produce a label that matches get_display_stage_order() output.
        # NOTE: get_display_stage_order()'s * case passes internal names unmodified
        # (no hyphenation). Both must be updated in tandem when a new stage is added.
        *)               echo "${1//_/-}" ;;
    esac
}
```

Place this function immediately after `get_display_stage_order()` and before the
closing of the file.

### §2 — Protocol API: `tui_stage_begin` / `tui_stage_end` in `lib/tui_ops.sh`

These two functions are the new public contract for stage lifecycle notifications.
They wrap the existing low-level primitives (`tui_update_stage`, `tui_finish_stage`)
and add three behaviours that callers must not duplicate:

1. **Dynamic pill insertion** (`tui_stage_begin`): if the display label is not
   already in `_TUI_STAGE_ORDER` (e.g., the first rework cycle), append it before
   calling the low-level update. This ensures the pill appears the moment a
   previously-unknown sub-stage starts, without requiring callers to pre-register
   anything.

2. **Timer freeze** (`tui_stage_end`): compute the final elapsed seconds, zero
   `_TUI_STAGE_START_TS`, and store the frozen value in `_TUI_AGENT_ELAPSED_SECS`
   before delegating. The Python sidecar then uses the frozen value for display
   instead of computing `time.time() - stage_start_ts`.

3. **No-op when TUI is inactive**: identical guard pattern to existing functions.

```bash
# tui_stage_begin DISPLAY_LABEL [MODEL]
# Begin a stage: ensure its pill exists in the bar, mark it running.
# DISPLAY_LABEL must come from get_stage_display_label(); callers must not
# pass raw internal stage names.
# NOTE: _TUI_STAGE_ORDER is a single-writer array (main process only). When
# parallel stages are introduced in a future milestone, this will require a
# lock or a migration to an atomic update via the JSON status file.
tui_stage_begin() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    # Dynamic pill insertion: append if not already present
    local _found=false
    local _s
    for _s in "${_TUI_STAGE_ORDER[@]:-}"; do
        [[ "$_s" == "$label" ]] && { _found=true; break; }
    done
    [[ "$_found" == "false" ]] && _TUI_STAGE_ORDER+=("$label")
    # Compute label's 1-based index within _TUI_STAGE_ORDER for stage_num.
    local _idx=0 _i
    for _i in "${!_TUI_STAGE_ORDER[@]}"; do
        [[ "${_TUI_STAGE_ORDER[$_i]}" == "$label" ]] && { _idx=$((_i + 1)); break; }
    done
    tui_update_stage "$_idx" "${#_TUI_STAGE_ORDER[@]}" \
        "$label" "$model"
}

# tui_stage_end DISPLAY_LABEL [MODEL] [TURNS_STR] [TIME_STR] [VERDICT]
# End a stage: freeze the timer and mark it complete.
# DISPLAY_LABEL must match what was passed to tui_stage_begin.
tui_stage_end() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    # Freeze timer: store final elapsed, zero the live timestamp
    local _final_elapsed=0
    if [[ "${_TUI_STAGE_START_TS:-0}" -gt 0 ]]; then
        _final_elapsed=$(( $(date +%s) - _TUI_STAGE_START_TS ))
    fi
    _TUI_STAGE_START_TS=0
    _TUI_AGENT_ELAPSED_SECS="$_final_elapsed"
    tui_finish_stage "$label" "$model" "$turns" "$time_str" "$verdict"
}
```

Place these two functions at the end of `lib/tui_ops.sh`, after `run_op`.

### §3 — Frozen Timer Display in `tools/tui_render.py`

**Fix `_build_active_bar`:**

The current code always computes elapsed as `time.time() - stage_start_ts` when
`stage_start_ts > 0`. After `tui_stage_end` zeroes `stage_start_ts`, the
`agent_elapsed_secs` field holds the frozen final elapsed.

Update the elapsed derivation:

```python
stage_start_ts = int(status.get("stage_start_ts", 0) or 0)
elapsed_secs   = int(status.get("agent_elapsed_secs", 0) or 0)

if stage_start_ts > 0:
    elapsed = max(0, int(time.time()) - stage_start_ts)   # live clock
else:
    elapsed = elapsed_secs                                  # frozen at completion
```

Update the spinner/status display:

```python
if agent_status == "running":
    char = _SPIN_CHARS[int(time.time() * 10) % len(_SPIN_CHARS)]
    spinner = Text(f"{char} Running", style="yellow")
elif agent_status == "idle" and elapsed > 0:
    # idle + elapsed > 0 = stage finished (tui_stage_end was called).
    # Note: tui_finish_stage always sets status to "idle", never "complete";
    # the presence of a frozen elapsed value is the signal that a stage ended.
    spinner = Text("\u2713 Complete", style="green")
else:
    spinner = Text("idle", style="dim")
    elapsed = 0  # suppress "0s" for the initial pre-stage idle state
```

**Fix `_stage_state`:**

The current implementation scans `stages_complete` before checking
`current_label`. This causes a rework pill to show "complete" (from the first
cycle's history) even while a second rework cycle is actively running.

Check `current_label` **first**:

```python
def _stage_state(stage: str, stages_complete: list[dict[str, Any]],
                 current_label: str, current_status: str) -> str:
    # Running state takes priority over history; a stage may have prior
    # completed entries (multiple rework cycles) and still be running again.
    if stage.lower() == (current_label or "").lower():
        if current_status == "running":
            return "running"
    # Then check completion history
    for s in stages_complete:
        if (s.get("label") or "").lower() == stage.lower():
            v = (s.get("verdict") or "").upper()
            return "fail" if v in ("FAIL", "FAILED", "BLOCKED", "REJECT") else "complete"
    # Between stages: current stage not yet in history but marked done
    if stage.lower() == (current_label or "").lower():
        if current_status == "complete":
            return "complete"
    return "pending"
```

### §4 — Spinner Isolation in `lib/agent.sh`

**Root cause:** the spinner subshell and the TUI sidecar both write to `/dev/tty`
without clean separation. The inner guard `[[ "${_TUI_ACTIVE:-false}" != "true" ]]`
suppresses the formatted output in TUI mode, but:

1. The guard is inside the `while true` loop of an always-spawned subshell, creating
   a race-condition class between a mutable environment variable and an already-forked
   process.
2. The `printf '\r\033[K'` cleanup at the end of the stop block writes to `/dev/tty`
   unconditionally — no TUI check — corrupting the sidecar's alternate screen.

**Fix:** split the single subshell into two clearly-separated code paths. The
non-TUI path handles terminal output. The TUI path only calls `tui_update_agent`.
Neither path can accidentally write to `/dev/tty` for the other's use case.

Replace the entire spinner block (from `local _spinner_pid=""` through the stop
block) with:

```bash
local _spinner_pid=""
local _tui_updater_pid=""

if [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]] \
   && [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
    # Non-TUI: spinner writes progress to terminal and runs dashboard heartbeat.
    (
        trap 'exit 0' INT TERM
        chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        start_ts=$(date +%s)
        i=0
        _last_refresh=0
        _refresh_interval="${DASHBOARD_REFRESH_INTERVAL:-10}"
        while true; do
            now=$(date +%s)
            elapsed=$(( now - start_ts ))
            mins=$(( elapsed / 60 ))
            secs=$(( elapsed % 60 ))
            _turns_display="--"
            if [[ -f "$_turns_file" ]]; then
                _cur_turns=$(cat "$_turns_file" 2>/dev/null || echo "")
                [[ "$_cur_turns" =~ ^[0-9]+$ ]] && _turns_display="$_cur_turns"
            fi
            printf '\r\033[0;36m[tekhton]\033[0m %s %s (%dm%02ds, %s/%s turns) ' \
                "${chars:i%${#chars}:1}" "$label" "$mins" "$secs" \
                "$_turns_display" "$max_turns" > /dev/tty
            i=$(( i + 1 ))
            if (( elapsed - _last_refresh >= _refresh_interval )); then
                if command -v emit_dashboard_run_state &>/dev/null; then
                    emit_dashboard_run_state 2>/dev/null || true
                fi
                _last_refresh=$elapsed
            fi
            sleep 0.2
        done
    ) &
    _spinner_pid=$!

elif [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ "${_TUI_ACTIVE:-false}" == "true" ]] \
     && declare -f tui_update_agent &>/dev/null; then
    # TUI active: lightweight updater pushes turn count to the sidecar.
    # No terminal writes of any kind in this path.
    # Guard on _TUI_ACTIVE to avoid spawning a useless subshell when TUI
    # functions are loaded but TUI was not activated (e.g., non-TTY).
    (
        trap 'exit 0' INT TERM
        start_ts=$(date +%s)
        while true; do
            elapsed=$(( $(date +%s) - start_ts ))
            _turns_display="--"
            _tui_turns=0
            if [[ -f "$_turns_file" ]]; then
                _cur_turns=$(cat "$_turns_file" 2>/dev/null || echo "")
                [[ "$_cur_turns" =~ ^[0-9]+$ ]] && _turns_display="$_cur_turns"
            fi
            [[ "$_turns_display" =~ ^[0-9]+$ ]] && _tui_turns="$_turns_display"
            tui_update_agent "$_tui_turns" "$max_turns" "$elapsed" 2>/dev/null || true
            sleep 0.2
        done
    ) &
    _tui_updater_pid=$!
fi
```

Replace the stop block:

```bash
# Stop spinner (non-TUI path)
if [[ -n "${_spinner_pid:-}" ]]; then
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    printf '\r\033[K' > /dev/tty 2>/dev/null || true  # safe: only set when !TUI
fi
# Stop TUI updater (TUI path)
if [[ -n "${_tui_updater_pid:-}" ]]; then
    kill "$_tui_updater_pid" 2>/dev/null || true
    wait "$_tui_updater_pid" 2>/dev/null || true
fi
```

**Note:** the dashboard heartbeat (`emit_dashboard_run_state`) is only in the
non-TUI path. The Watchtower dashboard and the TUI sidecar are independent output
channels; there is no need to run the dashboard heartbeat when the TUI is already
keeping the watchdog alive via `tui_update_agent`. **Tradeoff:** if a user has the
Watchtower web dashboard open while TUI is active, Watchtower data will be stale
(updated only at stage transitions, not every 10s). This is acceptable because TUI
and Watchtower serve the same purpose — live run visibility — and using both
simultaneously is not a supported workflow.

### §5 — Test Coverage

Extend `tests/test_tui_active_path.sh`:

- `tui_stage_begin` with a label not in `_TUI_STAGE_ORDER` appends it
- `tui_stage_begin` with a label already in `_TUI_STAGE_ORDER` does not duplicate it
- `tui_stage_end` sets `_TUI_STAGE_START_TS=0` and sets `_TUI_AGENT_ELAPSED_SECS` to
  a positive value
- After `tui_stage_end`, a second `tui_stage_begin` with the same label does not
  duplicate the pill (regression test for multi-rework scenario)

Add a Python unit test in `tools/tests/test_tui.py`:

- `_stage_state("rework", [{"label":"rework","verdict":None}], "rework", "running")`
  returns `"running"` (not `"complete"` — tests the priority-fix in §3)
- `_build_active_bar` with `stage_start_ts=0`, `agent_elapsed_secs=45`,
  `current_agent_status="idle"` renders `"✓ Complete"` with `"45s"` elapsed
- `_build_active_bar` with `stage_start_ts=0`, `agent_elapsed_secs=0`,
  `current_agent_status="idle"` renders `"idle"` with no elapsed shown

## Files Modified

| File | Change |
|------|--------|
| `lib/pipeline_order.sh` | Add `get_stage_display_label()` after `get_display_stage_order()` |
| `lib/tui_ops.sh` | Add `tui_stage_begin()` and `tui_stage_end()` at end of file |
| `tools/tui_render.py` | Fix `_build_active_bar` frozen-elapsed display; fix `_stage_state` priority order |
| `lib/agent.sh` | Replace unified spinner block with two separate non-TUI / TUI paths |
| `tests/test_tui_active_path.sh` | Extend with `tui_stage_begin`/`tui_stage_end` tests |
| `tools/tests/test_tui.py` | Add `_stage_state` priority test and frozen-elapsed bar tests |

## Acceptance Criteria

- [ ] `get_stage_display_label "test_verify"` echoes `"tester"`
- [ ] `get_stage_display_label "test_write"` echoes `"tester-write"`
- [ ] `get_stage_display_label "wrap_up"` and `get_stage_display_label "wrap-up"` both echo `"wrap-up"`
- [ ] `get_stage_display_label "unknown_stage"` echoes `"unknown-stage"` (fallback)
- [ ] `tui_stage_begin "rework"` with `_TUI_ACTIVE=false` is a no-op (no status file write)
- [ ] `tui_stage_begin "newstage"` appends `"newstage"` to `_TUI_STAGE_ORDER` when not present
- [ ] `tui_stage_begin "newstage"` called twice does not produce a duplicate in `_TUI_STAGE_ORDER`
- [ ] `tui_stage_begin` passes the label's 1-based index (not array length) as stage_num to `tui_update_stage`
- [ ] `tui_stage_end` sets `_TUI_STAGE_START_TS=0` and stores a positive value in `_TUI_AGENT_ELAPSED_SECS`
- [ ] `_stage_state("rework", [{"label":"rework","verdict":None}], "rework", "running")` returns `"running"`
- [ ] `_build_active_bar` shows `"✓ Complete"` when `stage_start_ts=0`, `agent_elapsed_secs=45`, `agent_status="idle"`
- [ ] `_build_active_bar` shows `"idle"` (no elapsed) when `stage_start_ts=0`, `agent_elapsed_secs=0`, `agent_status="idle"`
- [ ] With `_TUI_ACTIVE=true`: spinner subshell (`_spinner_pid`) is NOT set; `_tui_updater_pid` IS set
- [ ] With `_TUI_ACTIVE=false`: spinner subshell (`_spinner_pid`) IS set; `_tui_updater_pid` is NOT set
- [ ] `printf '\r\033[K'` cleanup only executes when `_spinner_pid` is non-empty (i.e., never in TUI mode)
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
