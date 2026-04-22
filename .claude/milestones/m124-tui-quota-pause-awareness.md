# M124 - TUI Quota-Pause Awareness & Spinner Coordination

<!-- milestone-meta
id: "124"
status: "pending"
-->

## Overview

Issue #180 reports that when the pipeline hits a Claude usage-limit
rate error, the TUI gets stuck displaying a fake "running" state for
hours while the bash process is actually asleep in `enter_quota_pause`.
Three compounding defects produce the illusion that a stage is still
running:

1. **The spinner/updater subshell keeps heartbeating during the pause.**
   `run_agent` in `lib/agent.sh:150-159` starts the spinner *before*
   calling `_run_with_retry`, and only calls `_stop_agent_spinner`
   *after* it returns. When `_run_with_retry` (lib/agent_retry.sh:74-97)
   detects a rate-limit error and calls `enter_quota_pause`, control
   stays inside that loop — the TUI-updater subshell in
   `lib/agent_spinner.sh:62-83` keeps writing `current_agent_status`
   `="running"` with incrementing elapsed into `tui_status.json` at
   5 Hz for the entire pause window.

2. **`enter_quota_pause` has zero TUI awareness.**
   `lib/quota.sh:59-128` calls `emit_event "quota_pause"` and
   `emit_dashboard_run_state` but never `tui_append_event`,
   `tui_update_agent`, or any other TUI helper. `grep -r quota
   lib/tui*.sh tools/tui*.py` returns nothing — the pause is completely
   invisible to the sidecar.

3. **The TUI watchdog cannot save the user.**
   `tools/tui.py:176-190` self-terminates only when
   `current_agent_status=="idle"` AND the status-file mtime is stale
   beyond `TUI_WATCHDOG_TIMEOUT` (default 300s). The heartbeating
   spinner pins `current_agent_status="running"` and bumps mtime every
   200 ms, so both conditions are permanently false. The watchdog only
   covers the "parent shell blocked before sending complete" failure
   mode it was designed for.

User-visible symptom: a stage pill stuck on "Coder ▶ running — 8
turns, 02:47:32…" while the bash process is blocked in
`sleep "${QUOTA_RETRY_INTERVAL:-300}"` with no way to know the pipeline
is actually quota-paused — short of Ctrl-C'ing and checking
`.claude/QUOTA_PAUSED`. Because `QUOTA_MAX_PAUSE_DURATION` defaults to
4 hours, this state can persist for up to 4h before the pause gives up
and the run dies.

M124 is the TUI-visibility half of the fix: make the pause observable
in the sidecar and keep the existing watchdog / abandon flows
functional. M125 (follow-up) handles the quota-refresh correctness
issues separately — pause-duration tuning, probe cost, and
Retry-After propagation.

## Design

### Goal 1 — Pause the spinner before entering quota pause, restart after

Add a helper pair in `lib/agent_spinner.sh` that `_run_with_retry` can
call around `enter_quota_pause`:

```bash
# _pause_agent_spinner SPINNER_PID TUI_UPDATER_PID
# Temporarily stop the heartbeat subshell so tui_status.json does not
# keep reporting "running" during an externally-imposed pause.
# Symmetric with _stop_agent_spinner but does NOT clear /dev/tty
# (the alt-screen / pill row must survive the pause).

# _resume_agent_spinner LABEL TURNS_FILE MAX_TURNS
# Respawn the subshell with the same arguments the stage originally
# used. Echoes the new "<spinner_pid>:<tui_updater_pid>" pair.
```

`_pause_agent_spinner` is implementation-wise identical to
`_stop_agent_spinner` minus the `/dev/tty` clear. `_resume_agent_spinner`
is a thin wrapper around `_start_agent_spinner`. Keep both in
`agent_spinner.sh` so the state machine lives in one file.

In `lib/agent_retry.sh`, thread the spinner PIDs into `_run_with_retry`
so it can pause/resume the heartbeat around `enter_quota_pause`:

- Add two new trailing parameters: `spinner_pid_var`, `tui_pid_var`.
  These are **variable names** (passed by reference via `declare -n`),
  not values — `run_agent` allocates the locals, and the retry loop
  rewrites them after each restart so the caller's
  `_stop_agent_spinner` at the end still sees the current PIDs.
- Before calling `enter_quota_pause`, call
  `_pause_agent_spinner "$_spinner_pid" "$_tui_updater_pid"`.
- After a successful return from `enter_quota_pause`, call
  `_resume_agent_spinner "$label" "$turns_file" "$max_turns"` and
  update the referenced vars.
- If `enter_quota_pause` returns non-zero (pause timed out, fatal
  path), **do not** resume. The caller's `_stop_agent_spinner` will
  still run and be a no-op since the PIDs are empty.

`run_agent` in `lib/agent.sh` changes are minimal: declare
`_spinner_pid` / `_tui_updater_pid` (already present), pass their
names to `_run_with_retry`, keep the trailing `_stop_agent_spinner`
call.

### Goal 2 — Add a `paused` agent status to the TUI protocol

Extend the `_TUI_AGENT_STATUS` enum with a fourth value: `paused`.
Current values are `idle | running | working | complete`
(grep `_TUI_AGENT_STATUS` across `lib/tui*.sh` confirms the set).

New helpers in `lib/tui_ops.sh`:

```bash
# tui_enter_pause REASON [RETRY_INTERVAL_SECS] [MAX_DURATION_SECS]
#   Sets _TUI_AGENT_STATUS="paused", writes pause metadata globals,
#   appends a warn-level event, flushes status.
# tui_update_pause NEXT_PROBE_IN_SECS [ELAPSED_SECS]
#   Refresh the countdown without appending new events; rate-limit
#   safe (no event every loop iteration).
# tui_exit_pause [RESULT=refreshed|timeout|cancelled]
#   Clears pause globals, appends a summary event, sets status back
#   to whatever agent status the pause interrupted (default: idle —
#   the spinner restart in Goal 1 will re-set "running").
```

Add matching state globals in `lib/tui.sh` (near the other
`_TUI_*`): `_TUI_PAUSE_REASON`, `_TUI_PAUSE_RETRY_INTERVAL`,
`_TUI_PAUSE_MAX_DURATION`, `_TUI_PAUSE_STARTED_AT`,
`_TUI_PAUSE_NEXT_PROBE_AT`.

Extend `_tui_write_status` (lib/tui_helpers.sh:222-252) to emit
these fields:

```
"pause_reason":"...",
"pause_retry_interval":300,
"pause_max_duration":14400,
"pause_started_at":1714000000,
"pause_next_probe_at":1714000300,
```

Keys are always present; empty string / 0 when not paused. This
keeps the JSON shape stable so the sidecar's `_read_status` path
never sees a schema change.

### Goal 3 — Wire the TUI helpers into `enter_quota_pause`

In `lib/quota.sh:59-128`, inject TUI calls at the three transition
points. All guarded with `command -v tui_enter_pause &>/dev/null`
so quota.sh stays usable without the TUI layer (unit tests, non-TUI
runs):

- At the top of `enter_quota_pause`, after the marker file is
  written, call `tui_enter_pause "${pause_reason}"
  "${QUOTA_RETRY_INTERVAL:-300}" "${QUOTA_MAX_PAUSE_DURATION:-14400}"`.
- Inside the retry loop, before each `sleep`, call
  `tui_update_pause "$seconds_until_next_probe" "$elapsed"` so the
  sidecar can render a live countdown.
- On the two exit paths (successful refresh → `exit_quota_pause`;
  max-duration timeout → `return 1`), call
  `tui_exit_pause "refreshed"` / `tui_exit_pause "timeout"`.

The existing `emit_event` / `emit_dashboard_run_state` calls stay as
they are — Watchtower dashboard consumers rely on them. The new TUI
calls are additive.

### Goal 4 — Sidecar renderer: draw the paused state distinctly

`tools/tui_render.py:_build_active_bar` currently branches on
`agent_status in ("working", "running", "complete", "idle")`
(lines 123-148). Add a `paused` branch above the others:

```python
if agent_status == "paused":
    return _build_paused_bar(status)
```

New `_build_paused_bar` in `tools/tui_render.py`:

- Label: stage name from `status.get("stage_label")` (unchanged).
- Body: amber "⏸ PAUSED — quota refresh" text.
- Countdown: derive `next_probe_in = max(0,
  pause_next_probe_at - time.time())`; format as `mm:ss`. If
  `pause_next_probe_at == 0` fall back to the bare reason string.
- Total-paused timer: `time.time() - pause_started_at` formatted
  via `_fmt_duration`.
- Reason: short form of `pause_reason` truncated to one line.

Style uses `yellow` / `bold yellow` (already registered — matches
existing "Working" spinner style) to distinguish from green complete
and dim idle without introducing a new colour key.

Update `tools/tui_render_logo.py:74` so the idle logo frame is used
when `current_agent_status` is `idle` *or* `paused`. The running
arch animation is reserved for active work; the pause should feel
like the pipeline has stopped, not like it's crunching.

Update `tools/tui_render_timings.py:45-106` so `paused` is treated
like `idle` for the "has live row" check (i.e. no live ticker for
the currently-paused stage — the active bar already owns the
countdown).

### Goal 5 — Make the watchdog work during pause

`tools/tui.py:184-189` currently treats only `idle` as eligible for
watchdog self-termination. Extend the check to `idle` *or* `paused`:

```python
if (
    status.get("current_agent_status") in ("idle", "paused")
    and status.get("agent_turns_used", 0) > 0
    and time.monotonic() - _last_mtime_time > watchdog_secs
):
    break
```

The mtime-staleness check still protects against false positives:
`tui_update_pause` is called once per `sleep` iteration
(~`QUOTA_RETRY_INTERVAL` = 300s by default) so the status file
*will* be updated within the 300s watchdog window during an active
pause — the watchdog will not fire while the pause is progressing.
It will only fire if the parent shell has actually died and the
pause loop is no longer heartbeating, which is the case the
watchdog was designed for.

**Alternative considered:** keep the spinner running but have it
emit `paused` instead of `running`. Rejected: that still means the
spinner subshell burns CPU/fork overhead and writes status files
during the entire pause, and the state machine has two owners for
the same field. Goal 1's pause-the-spinner approach gives a single
writer (`enter_quota_pause` via `tui_update_pause`) for pause state,
which is simpler and matches the existing `tui_stage_begin` /
`tui_stage_end` single-owner pattern.

### Goal 6 — Chunked sleep for responsiveness

Replace the single `sleep "${QUOTA_RETRY_INTERVAL:-300}"` in
`lib/quota.sh:116` with a helper that sleeps in small steps so
SIGINT / SIGTERM is responsive and so `tui_update_pause` can refresh
the countdown on a sub-minute cadence:

```bash
_quota_sleep_chunked() {
    local total="$1"
    local chunk="${QUOTA_SLEEP_CHUNK:-5}"
    local remaining="$total"
    while [[ "$remaining" -gt 0 ]]; do
        local step=$(( remaining < chunk ? remaining : chunk ))
        sleep "$step"
        remaining=$(( remaining - step ))
        if command -v tui_update_pause &>/dev/null; then
            tui_update_pause "$remaining" "$(( $(date +%s) - pause_start ))"
        fi
    done
}
```

This gives ~5s Ctrl-C responsiveness vs. the current up-to-300s
wait, and a smooth live countdown. No new public config key beyond
`QUOTA_SLEEP_CHUNK` (internal, not documented in pipeline.conf —
added to `lib/config_defaults.sh` with a 5s default and the usual
`_clamp_config_value` bound of 60).

### Goal 7 — Preserve non-TUI behaviour

Every new TUI call in `lib/quota.sh` is guarded with
`command -v tui_* &>/dev/null`. The spinner pause/resume in
`_run_with_retry` runs regardless of whether the TUI is active:
when `_TUI_ACTIVE=false` the non-TUI (`/dev/tty`) spinner subshell
was still writing progress lines at 5 Hz during pauses, which is
equally wrong (the terminal prints a "running" spinner while bash
is sleeping). Pausing it fixes that path too. The `/dev/tty` clear
happens once at final `_stop_agent_spinner` time, unchanged.

`TEKHTON_TEST_MODE=true` runs never start a spinner (see
`lib/agent_spinner.sh:29`), so the pause/resume helpers are no-ops
and test fixtures keep working without edits.

### Goal 8 — Tests

Unit-level (extend `tests/test_quota.sh`):

- `test_enter_quota_pause_calls_tui_helpers` — stub
  `tui_enter_pause`, `tui_update_pause`, `tui_exit_pause` as
  counting shell functions. Run `enter_quota_pause "test"` with
  `QUOTA_RETRY_INTERVAL=1 QUOTA_MAX_PAUSE_DURATION=2` and a stub
  `_quota_probe` that always fails. Assert `tui_enter_pause`
  called exactly once, `tui_update_pause` called ≥1 time,
  `tui_exit_pause "timeout"` called once.
- `test_enter_quota_pause_tui_absent_no_error` — same flow without
  the stub functions. Assert clean exit, no "command not found".

New bash test `tests/test_tui_quota_pause.sh`:

- Source `lib/tui.sh`, `lib/tui_ops.sh`, `lib/tui_helpers.sh`,
  `lib/quota.sh` with `_TUI_ACTIVE=true` and a writable status
  file path.
- Call `tui_enter_pause "rate limit" 300 14400`. Assert the written
  JSON contains `"current_agent_status":"paused"`,
  `"pause_reason":"rate limit"`, `"pause_retry_interval":300`,
  and `"pause_max_duration":14400`.
- Call `tui_update_pause 120 180`. Assert pause_next_probe_at
  drifts accordingly. Assert `recent_events` was NOT appended (the
  update path is rate-limited).
- Call `tui_exit_pause "refreshed"`. Assert
  `current_agent_status` reverts to `idle`, pause fields clear.

New Python test in `tools/tests/test_tui.py`:

- `test_build_active_bar_renders_paused_status` — construct a
  status dict with `current_agent_status="paused"`,
  `pause_next_probe_at=time.time()+90`,
  `pause_started_at=time.time()-30`. Render and assert the output
  text contains "PAUSED" and a `1m30s`-style countdown.
- `test_watchdog_fires_on_paused_with_stale_mtime` — drive the
  sidecar's main-loop logic (extract into a testable helper if
  needed) with `current_agent_status="paused"` + a stale
  `_last_mtime_time`. Assert it breaks out of the loop.

Register the new shell test in `tests/run_tests.sh`.

### Goal 9 — Documentation

Update `docs/tui-lifecycle-model.md` (referenced from CLAUDE.md) to
add a "Paused" section: when it fires, who owns state (quota.sh +
tui_ops.sh), how long it can last, how the watchdog interacts with
it. One new subsection, ~15 lines; no other structural change.

Update `CLAUDE.md` template-variable table to add
`QUOTA_SLEEP_CHUNK` (Internal default 5s, max 60s).

## Files Modified

| File | Change |
|------|--------|
| `lib/agent_spinner.sh` | Add `_pause_agent_spinner` and `_resume_agent_spinner` helpers. |
| `lib/agent_retry.sh` | Accept spinner-PID var names; pause/resume around `enter_quota_pause`. |
| `lib/agent.sh` | Thread `_spinner_pid` / `_tui_updater_pid` var names into `_run_with_retry`. |
| `lib/quota.sh` | Call `tui_enter_pause` / `tui_update_pause` / `tui_exit_pause`; chunked sleep via `_quota_sleep_chunked`. |
| `lib/tui.sh` | Declare `_TUI_PAUSE_*` globals; reset them in `tui_stop`. |
| `lib/tui_ops.sh` | Add `tui_enter_pause`, `tui_update_pause`, `tui_exit_pause`. |
| `lib/tui_helpers.sh` | Emit `pause_reason` / `pause_retry_interval` / `pause_max_duration` / `pause_started_at` / `pause_next_probe_at` in `_tui_write_status`. |
| `lib/config_defaults.sh` | Add `QUOTA_SLEEP_CHUNK:=5` with clamp bound 60. |
| `tools/tui.py` | Extend watchdog eligibility to `idle` OR `paused`. |
| `tools/tui_render.py` | Add `_build_paused_bar`; branch in `_build_active_bar` on `paused`. |
| `tools/tui_render_logo.py` | Use idle logo when `current_agent_status` is `idle` or `paused`. |
| `tools/tui_render_timings.py` | Treat `paused` like `idle` for live-row check. |
| `tests/test_quota.sh` | Add `test_enter_quota_pause_calls_tui_helpers` and absent-helpers test. |
| `tests/test_tui_quota_pause.sh` | **New file.** End-to-end pause state in status JSON. |
| `tests/run_tests.sh` | Register `test_tui_quota_pause.sh`. |
| `tools/tests/test_tui.py` | Add paused-bar and paused-watchdog tests. |
| `docs/tui-lifecycle-model.md` | Add "Paused" subsection describing state ownership. |
| `CLAUDE.md` | Add `QUOTA_SLEEP_CHUNK` to template-variable table. |

## Acceptance Criteria

- [ ] When `enter_quota_pause` is entered, the agent spinner /
      TUI-updater subshell is stopped; `tui_status.json` stops
      reporting `current_agent_status="running"` within one
      status-write tick of the pause starting.
- [ ] While paused, `tui_status.json` reports
      `current_agent_status="paused"` with non-empty
      `pause_reason`, non-zero `pause_started_at`, and
      `pause_next_probe_at` that advances on each retry interval.
- [ ] The TUI renders a distinct paused state: amber "⏸ PAUSED"
      label on the active-stage bar, a `mm:ss` countdown to the
      next probe, and a total-paused timer. The stage pill does
      NOT flip to "complete" / "failed" — it reverts to pending /
      idle while paused, then resumes running on refresh.
- [ ] Idle logo is drawn while paused (no running arch animation).
- [ ] Ctrl-C during a quota pause returns control to the shell
      within ≤ `QUOTA_SLEEP_CHUNK` seconds (default 5), not the
      full `QUOTA_RETRY_INTERVAL` (default 300).
- [ ] `TUI_WATCHDOG_TIMEOUT` fires from the `paused` state if the
      parent shell has died (status file mtime stale beyond the
      timeout). Verified by disabling `tui_update_pause` in a
      test stub and letting the watchdog trip.
- [ ] On successful quota refresh, the spinner is restarted; the
      active bar returns to `running`; `tui_status.json` clears
      all `pause_*` fields; one summary event
      (`Quota refreshed — resumed`) is appended.
- [ ] On max-duration timeout, the spinner is NOT restarted;
      `tui_exit_pause "timeout"` leaves `current_agent_status`
      unchanged for the caller's failure path; the run dies via
      the existing `AGENT_ERROR_CATEGORY=UPSTREAM` flow with no
      regression.
- [ ] When the TUI is inactive (`_TUI_ACTIVE=false`), the
      non-TUI `/dev/tty` spinner is also paused during the quota
      wait — the terminal no longer shows a spinning indicator
      while bash is sleeping. The final `_stop_agent_spinner`
      clears `/dev/tty` exactly once as before.
- [ ] `lib/quota.sh` continues to work when sourced without the
      TUI layer present (unit tests, smoke scripts): all new
      `tui_*` call sites are guarded by `command -v`.
- [ ] `tests/test_quota.sh` and the new `tests/test_tui_quota_pause.sh`
      pass. Existing TUI invariant tests
      (`test_tui_lifecycle_invariants.sh`,
      `test_tui_stage_wiring.sh`) pass with no edits.
- [ ] Shellcheck clean for `lib/agent_spinner.sh`,
      `lib/agent_retry.sh`, `lib/agent.sh`, `lib/quota.sh`,
      `lib/tui_ops.sh`, `lib/tui_helpers.sh`, and the new shell
      test.

## Non-Goals

- Fixing `QUOTA_MAX_PAUSE_DURATION` default being shorter than
  Anthropic's 5h rolling window, `_quota_probe` itself consuming
  quota, and `Retry-After` propagation from `lib/agent_retry.sh`
  into `lib/quota.sh`. All three are M125.
- Adding a user-facing "cancel pause and exit" keybinding to the
  TUI. The watchdog + Ctrl-C responsiveness (Goals 5 and 6) are
  sufficient for clean abandonment in this milestone.
- Refactoring `_TUI_AGENT_STATUS` into a proper enum type. The
  informal "idle | running | working | complete | paused" set
  already works everywhere it's consumed.
- Rewriting the spinner subshells to a single long-lived process
  with mode switches. The pause/resume pattern reuses the existing
  fork/exec model.
- Integrating the pause countdown into the Watchtower dashboard
  (separate output surface, its own lifecycle already via
  `emit_dashboard_run_state`).
- Surfacing the pause state to `RUN_SUMMARY.json` beyond the
  existing `quota_pause` stats. `format_quota_pause_summary`
  already covers post-run reporting.
