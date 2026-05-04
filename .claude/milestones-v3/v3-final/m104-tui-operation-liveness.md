# M104 — TUI Operation Liveness: Heartbeat & Activity Indicator
<!-- milestone-meta
id: "104"
status: "done"
-->

## Overview

During long-running shell operations — test baseline capture, build gate analysis,
completion tests, final hooks — the TUI displays a static dim arch logo and a silent
active-stage bar. From the user's perspective the application has hung; only the
clock in the header corner continues to tick. A 10-minute test suite looks identical
to a crashed process.

The root cause is that `current_agent_status` only has three values: `"idle"`,
`"running"` (set by `run_agent()`), and `"complete"`. There is no value for "the
shell is running a command." The logo and spinner both gate on `"running"`; during
all other work they are visually inert.

A secondary risk: the TUI watchdog fires after 300 s of status-file inactivity
when `current_agent_status == "idle"` and an agent has previously run. A long test
suite in the tester or completion-gate stages can silently kill the sidecar
mid-run.

This milestone introduces `run_op LABEL CMD...` — a single wrapper function,
modelled on the existing spinner-subprocess pattern in `lib/agent.sh` — that:

1. Sets `current_agent_status = "working"` and `current_operation = LABEL` in the
   JSON status file before the command starts.
2. Spawns a lightweight heartbeat subprocess that re-writes the status file every
   10 seconds, keeping the watchdog satisfied for arbitrarily long operations.
3. Restores `current_agent_status = "idle"` and kills the heartbeat when the
   command finishes (pass or fail).
4. Falls back to a transparent passthrough when the TUI is not active — zero
   overhead for non-TUI users.

On the Python side, the sidecar animates the logo and shows a spinner for
`"working"` status, and the active-stage bar displays the `current_operation` label.

## Design

### §1 — New `current_agent_status` Value: `"working"`

Add `"working"` as a first-class status alongside `"idle"`, `"running"`, and
`"complete"`. It means: a shell command is in progress; no Claude agent is running.

**JSON schema addition** (`lib/tui_helpers.sh`):

```json
"current_agent_status": "working",
"current_operation":    "Running test baseline"
```

Add `current_operation` as a new top-level JSON field immediately after
`current_agent_status`. Empty string when not in a `run_op` call.

In `_tui_json_build_status` (`lib/tui_helpers.sh`), add:
```bash
local op_label="${_TUI_OPERATION_LABEL:-}"
# (after the existing current_agent_status printf)
printf '"current_operation":"%s",' "$(_tui_escape "$op_label")"
```

Add the corresponding global at the top of `lib/tui.sh`:
```bash
_TUI_OPERATION_LABEL=""
```

### §2 — `run_op LABEL CMD...` in `lib/tui.sh`

```bash
# run_op LABEL CMD [ARGS...] — run CMD with TUI "working" state and heartbeat.
# Falls back to a transparent passthrough when TUI is not active.
# Preserves CMD exit code. Safe under set -euo pipefail.
run_op() {
    local _label="$1"; shift
    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        "$@"
        return
    fi

    _TUI_AGENT_STATUS="working"
    _TUI_OPERATION_LABEL="$_label"
    _tui_write_status 2>/dev/null || true

    # Heartbeat subprocess: re-writes status file every 10 s so the watchdog
    # timer never expires during long-running commands. Uses TERM trap so
    # kill() returns immediately without leaving a sleeping child behind.
    (
        trap 'exit 0' TERM INT
        while true; do
            sleep 10 &
            wait $!
            _tui_write_status 2>/dev/null || true
        done
    ) &
    local _hb_pid=$!

    local _rc=0
    "$@" || _rc=$?

    kill "$_hb_pid" 2>/dev/null || true
    wait "$_hb_pid" 2>/dev/null || true

    _TUI_AGENT_STATUS="idle"
    _TUI_OPERATION_LABEL=""
    _tui_write_status 2>/dev/null || true

    return "$_rc"
}
```

**Design notes:**

- `trap 'exit 0' TERM INT` inside the heartbeat subshell means `kill "$_hb_pid"`
  causes an immediate clean exit. The running `sleep 10 & wait $!` pattern ensures
  the trap fires without waiting for the full sleep interval.
- `"$@" || _rc=$?` captures the exit code without triggering `set -e`, so cleanup
  always runs even when the command fails.
- `wait "$_hb_pid"` after kill prevents zombie processes.
- The function is intentionally pipe-compatible: when called as
  `run_op "label" cmd | tee file`, it runs in a bash subshell (left side of pipe).
  Since all state updates go through the status FILE, not shell variables, the
  sidecar still sees them correctly.

### §3 — Stub in `lib/common.sh`

Add a one-line passthrough stub to `lib/common.sh` so that any file that sources
only `common.sh` (e.g., test harnesses) can call `run_op` without guards:

```bash
# Stub — lib/tui.sh redefines with full TUI implementation when TUI is active.
run_op() { local _l="$1"; shift; "$@"; }
```

Place after the existing logging functions (before `log_verbose`). `lib/tui.sh` is
sourced after `lib/common.sh` in `tekhton.sh` and redefines `run_op` with the full
implementation. The stub is only used by scripts that source `common.sh` in
isolation.

### §4 — Python: Animate Logo and Spinner for `"working"`

**`tools/tui_render.py` — `_build_logo`:**

Current condition:
```python
elif agent_status == "idle":
    # dim static (idle state)
else:
    # animated (running state)
```

Updated condition — treat `"working"` the same as `"running"` for animation:
```python
elif agent_status == "idle":
    # dim static
else:  # "running" or "working"
    frame = int(time.time() * 0.6) % 3
    ...
```

No other logo changes needed; the three-frame arch animation is appropriate for
both agent work and shell work.

**`tools/tui_render.py` — `_build_active_bar`:**

Add a branch for `"working"` before (or alongside) the existing `"running"` branch.
When `agent_status == "working"`, show the operation label and a spinner; suppress
the model / turns / elapsed fields (they don't apply to shell commands):

```python
if agent_status in ("running", "working"):
    if agent_status == "working":
        op_label = status.get("current_operation") or "Working…"
        spin_chars = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        spinner_char = spin_chars[int(time.time() * 10) % len(spin_chars)]
        bar = Text()
        bar.append(op_label, style="bold white")
        bar.append(f"  {spinner_char} Working", style="yellow")
        return Panel(bar, style="dim")
    # existing "running" branch follows ...
```

### §5 — Watchdog: No Change Needed

The watchdog in `tools/tui.py` fires when `current_agent_status == "idle"`. Since
`run_op` sets status to `"working"`, the watchdog condition is naturally false during
any `run_op` call. Additionally, the 10-second heartbeat keeps the file mtime fresh
as a second line of defence. No watchdog code changes are required.

### §6 — Wiring: 13 Long-Running Sites Across 9 Files

All sites use command substitution to capture output into a variable. The wrapping
pattern is identical for each: add `run_op LABEL` between the `$(` opener and the
`bash -c` call, keeping the exit-code capture (`|| var=$?`) outside.

```bash
# Before (universal pattern):
output=$(bash -c "${CMD}" 2>&1) || exit_code=$?

# After:
output=$(run_op "Human-readable label" bash -c "${CMD}" 2>&1) || exit_code=$?
```

`run_op` passes the wrapped command's stdout through (captured by `$(...)`),
returns the exit code of the wrapped command, and handles all TUI state transitions
internally. The `|| exit_code=$?` outside is unchanged.

**`lib/test_baseline.sh:90`** (pre-coder baseline, potentially 10+ minutes):
```bash
# Before:
test_output=$(bash -c "${TEST_CMD}" 2>&1) || test_exit=$?
# After:
test_output=$(run_op "Running test baseline" bash -c "${TEST_CMD}" 2>&1) || test_exit=$?
```

**`lib/milestone_acceptance.sh:77`** (acceptance gate):
```bash
test_output=$(run_op "Running acceptance tests" bash -c "${TEST_CMD}" 2>&1) || test_exit=$?
```

**`lib/gates_completion.sh:77`** (completion gate):
```bash
_cg_output=$(run_op "Running completion tests" bash -c "${TEST_CMD}" 2>&1) || _cg_exit=$?
```

**`lib/orchestrate.sh:287`** (pre-finalize test verification):
```bash
_preflight_output=$(run_op "Verifying tests before finalizing" bash -c "${TEST_CMD}" 2>&1) || _preflight_exit=$?
```

**`lib/orchestrate_preflight.sh:78`** (pre-run test gate):
```bash
_pf_verify_output=$(run_op "Running pre-run test check" bash -c "${TEST_CMD}" 2>&1) || _pf_verify_exit=$?
```

**`lib/hooks_final_checks.sh:25`** (final analysis pass):
```bash
ANALYZE_OUTPUT=$(run_op "Running final static analysis" bash -c "${ANALYZE_CMD}" 2>&1)
```

**`lib/hooks_final_checks.sh:75`** (analysis with pipe to tee + grep — requires
restructuring; cannot directly wrap a pipeline used as an `if` condition):
```bash
# Before:
if bash -c "${ANALYZE_CMD}" 2>&1 | tee -a "$log_file" | grep -qE "^  (error|warning)"; then

# After — capture first, then filter:
_analyze_out=$(run_op "Running static analysis" bash -c "${ANALYZE_CMD}" 2>&1)
printf '%s\n' "$_analyze_out" | tee -a "$log_file" > /dev/null
if printf '%s\n' "$_analyze_out" | grep -qE "^  (error|warning)"; then
```

**`lib/hooks_final_checks.sh:90`** (final test check pass 1):
```bash
test_output=$(run_op "Running final test check" bash -c "${TEST_CMD}" 2>&1)
```

**`lib/hooks_final_checks.sh:127`** (final test check pass 2):
```bash
test_output=$(run_op "Running final test check" bash -c "${TEST_CMD}" 2>&1)
```

**`lib/gates_phases.sh:51`** (static analysis gate with timeout):
```bash
ANALYZE_OUTPUT=$(run_op "Running static analysis" timeout "$effective_timeout" bash -c "${ANALYZE_CMD}" 2>&1) || analyze_exit=$?
```

**`lib/gates_phases.sh:150`** (build/compile check with timeout):
```bash
COMPILE_OUTPUT=$(run_op "Running build check" timeout "$effective_timeout" bash -c "${BUILD_CHECK_CMD}" 2>&1) || compile_exit=$?
```

**`lib/gates.sh:146`** (dependency constraint validation with timeout):
```bash
constraint_output=$(run_op "Validating dependency constraints" timeout "$effective_timeout" bash -c "$validation_cmd" 2>&1) || constraint_exit=$?
```

**`lib/gates_ui.sh:44,52,60`** (UI test gate — three invocations, same pattern):
```bash
_ui_output=$(run_op "Running UI tests" timeout "$_ui_timeout" bash -c "$UI_TEST_CMD" 2>&1) || _ui_exit=$?
```

### §7 — Updated JSON Schema

Full set of fields affected by M104 (new fields marked `[NEW]`):

```json
{
  "current_agent_status": "working",
  "current_operation":    "Running test baseline"
}
```

`current_operation` is an empty string when `current_agent_status` is not
`"working"`. The Python sidecar ignores it in all other states.

## Files Modified

| File | Change |
|------|--------|
| `lib/tui.sh` | Add `_TUI_OPERATION_LABEL=""` global; add `run_op()` implementation |
| `lib/tui_helpers.sh` | Add `current_operation` JSON field after `current_agent_status` in `_tui_json_build_status` |
| `lib/common.sh` | Add `run_op()` passthrough stub (after `mode_info`, before `log_verbose`) |
| `tools/tui_render.py` | `_build_logo`: animate for `"working"` in the `else` branch; `_build_active_bar`: add `"working"` branch showing `current_operation` label + spinner |
| `lib/test_baseline.sh` | Wrap `bash -c "${TEST_CMD}"` at line 90 |
| `lib/milestone_acceptance.sh` | Wrap `bash -c "${TEST_CMD}"` at line 77 |
| `lib/gates_completion.sh` | Wrap `bash -c "${TEST_CMD}"` at line 77 |
| `lib/orchestrate.sh` | Wrap `bash -c "${TEST_CMD}"` at line 287 |
| `lib/orchestrate_preflight.sh` | Wrap `bash -c "${TEST_CMD}"` at line 78 |
| `lib/hooks_final_checks.sh` | Wrap `ANALYZE_CMD` at line 25; restructure pipe at line 75; wrap `TEST_CMD` at lines 90 and 127 |
| `lib/gates_phases.sh` | Wrap `ANALYZE_CMD` at line 51; wrap `BUILD_CHECK_CMD` at line 150 |
| `lib/gates.sh` | Wrap dependency constraint validation `bash -c "$validation_cmd"` at line 146 |
| `lib/gates_ui.sh` | Wrap `bash -c "$UI_TEST_CMD"` at lines 44, 52, and 60 |

## Acceptance Criteria

- [ ] `run_op` is defined in `lib/tui.sh` and passes `shellcheck` with zero warnings
- [ ] `run_op "label" true` with `_TUI_ACTIVE=false` executes `true` and returns 0;
      no status file is written; the label argument is consumed and not passed to `true`
- [ ] `run_op "label" false` with `_TUI_ACTIVE=false` returns exit code 1 (exit code
      of the wrapped command is preserved)
- [ ] With `_TUI_ACTIVE=true`: `run_op "Running test baseline" sleep 0.1` sets
      `current_agent_status` to `"working"` in the status file during execution,
      then restores it to `"idle"` after — verified by reading the status file
      before, during (from a parallel subshell), and after the call
- [ ] With `_TUI_ACTIVE=true`: `run_op "label" false` returns exit code 1 AND still
      restores `current_agent_status` to `"idle"` and kills the heartbeat
      (no orphaned background process)
- [ ] TUI logo animates (three-frame arch cycle) when `current_agent_status` is
      `"working"` — same behaviour as `"running"`
- [ ] Active-stage bar shows `{current_operation} · ⠏ Working` (with braille
      spinner) when `current_agent_status` is `"working"`
- [ ] Active-stage bar does NOT show model / turns / elapsed fields during
      `"working"` state (these are agent-only concepts)
- [ ] The heartbeat subprocess writes to the status file every ~10 s; file mtime
      stays fresh throughout a 30-second `run_op "label" sleep 30` call
- [ ] The heartbeat is always cleaned up: `run_op "label" sleep 0` leaves no
      background processes behind (`jobs` is empty after the call)
- [ ] The passthrough stub in `lib/common.sh` is overridden by the full
      implementation in `lib/tui.sh` in normal pipeline execution — verified by
      confirming `declare -f run_op` shows the TUI implementation body after both
      files are sourced in order
- [ ] `grep -rn 'bash -c.*TEST_CMD\|bash -c.*ANALYZE_CMD\|bash -c.*BUILD_CHECK_CMD\|bash -c.*UI_TEST_CMD' lib/` shows
      only lines that contain `run_op` — no bare unguarded invocations remain
- [ ] `shellcheck` passes on all modified `.sh` files with zero new warnings
- [ ] All existing tests pass (`bash tests/run_tests.sh`)
