# Coder Summary

## Status: COMPLETE

## What Was Implemented

M124 — TUI Quota-Pause Awareness & Spinner Coordination. Issue #180:
the TUI was stuck rendering a fake "Coder ▶ running …" frame for hours
while bash was actually blocked in `enter_quota_pause`. Three coupled
fixes:

### Goal 1 — Pause the spinner subshell across the quota wait

- `lib/agent_spinner.sh`: added `_pause_agent_spinner` (symmetric with
  `_stop_agent_spinner` minus the `/dev/tty` clear, so the alt-screen
  survives) and `_resume_agent_spinner` (thin wrapper that respawns
  the same subshell pair via `_start_agent_spinner`).
- `lib/agent_retry_pause.sh` (NEW): the bracket helper
  `_retry_pause_spinner_around_quota` — captures spinner PIDs from the
  caller via nameref, calls `_pause_agent_spinner`, runs the supplied
  `enter_quota_pause` callback, and on success rewrites the caller's
  vars with the new generation so the trailing `_stop_agent_spinner`
  kills the right PIDs. Also defines `_enter_qp_rate` /
  `_enter_qp_proactive` callbacks.
- `lib/agent_retry.sh`: `_run_with_retry` now accepts two trailing
  variable-NAME arguments (`SPINNER_PID_VAR`, `TUI_UPDATER_PID_VAR`)
  and routes both quota-pause sites (rate-limit and Tier-2 proactive)
  through `_retry_pause_spinner_around_quota`.
- `lib/agent.sh`: passes its locals' names (`"_spinner_pid"`,
  `"_tui_updater_pid"`) so the bracket can rewrite them.

### Goal 2 — `paused` agent_status + JSON pause fields

- `lib/tui.sh`: added five pause globals (`_TUI_PAUSE_REASON`,
  `_TUI_PAUSE_RETRY_INTERVAL`, `_TUI_PAUSE_MAX_DURATION`,
  `_TUI_PAUSE_STARTED_AT`, `_TUI_PAUSE_NEXT_PROBE_AT`).
- `lib/tui_helpers.sh`: every `_tui_json_build_status` snapshot now
  emits `pause_reason`, `pause_retry_interval`, `pause_max_duration`,
  `pause_started_at`, `pause_next_probe_at`. Always present (empty / 0
  when not paused) so the consumer schema stays stable.
- `lib/tui_ops_pause.sh` (NEW): public API — `tui_enter_pause REASON
  RETRY MAX_DUR`, `tui_update_pause NEXT_IN [ELAPSED]`, `tui_exit_pause
  [refreshed|timeout|cancelled]`. Sets/clears `_TUI_AGENT_STATUS` to
  `paused`/`idle`. Sourced by `lib/tui_ops.sh`.

### Goal 3 — Wire enter_quota_pause to the new helpers

- `lib/quota.sh`: invokes `tui_enter_pause` after the marker file is
  written, `tui_exit_pause "refreshed"` on probe success, and
  `tui_exit_pause "timeout"` on max-duration timeout. All three are
  guarded with `command -v` so quota.sh continues to work when sourced
  without the TUI layer (unit tests, smoke scripts).

### Goal 4 — Renderer paused state

- `tools/tui_render_pause.py` (NEW): `_build_paused_bar` — amber
  "PAUSED — quota refresh" indicator with a `mm:ss` next-probe
  countdown, `_fmt_duration` total-paused timer, parent stage label,
  and truncated reason.
- `tools/tui_render.py`: `_build_active_bar` branches on
  `agent_status == "paused"` *before* the `working` / `running`
  branches so a pause inside an active agent or `run_op` still
  surfaces.
- `tools/tui_render_logo.py`: idle logo frame is also used when status
  is `paused` (no running arch animation while bash is sleeping).
- `tools/tui_render_timings.py`: `paused` already excluded from the
  live-row check via the `("running", "working")` list — added a
  comment to make the M124 contract explicit.

### Goal 5 — Watchdog can save the user during pause

- `tools/tui.py`: watchdog eligibility extends to `current_agent_status
  in ("idle", "paused")`. The mtime-staleness check still gates the
  fire — an active pause keeps the file fresh via `tui_update_pause`
  on each chunked sleep tick, so the watchdog only trips when the
  parent shell has actually died.

### Goal 6 — Chunked sleep for responsiveness

- `lib/quota_sleep.sh` (NEW): `_quota_sleep_chunked TOTAL PAUSE_START`
  sleeps in `QUOTA_SLEEP_CHUNK`-second steps (default 5s) so SIGINT
  returns within ~chunk seconds and so `tui_update_pause` refreshes
  the countdown on a sub-minute cadence.
- `lib/quota.sh`: replaces the single `sleep "${QUOTA_RETRY_INTERVAL}"`
  with `_quota_sleep_chunked`.
- `lib/config_defaults.sh`: `QUOTA_SLEEP_CHUNK:=5` with `_clamp_config_value`
  ceiling of 60.

### Goal 8 — Tests

- `tests/test_quota.sh`: added two test sections — one stubs
  `tui_enter_pause` / `tui_update_pause` / `tui_exit_pause` as counting
  shell functions and verifies they're called the expected number of
  times around an `enter_quota_pause` that times out (5 assertions);
  one verifies the absent-helpers path exits cleanly (1 assertion).
  Test totals: 49 passed (was 43).
- `tests/test_tui_quota_pause.sh` (NEW, 198 lines, picked up
  automatically by the test discovery loop): 5 sections / 20
  assertions covering enter/update/exit pause state JSON, schema
  stability of the pause_* keys, and inactive no-op behaviour.
- `tools/tests/test_tui.py`: 4 new Python tests — paused-bar render
  with countdown, paused-bar zero-next-probe fallback, paused-logo
  uses idle frame, watchdog fires/stays-quiet under paused+stale and
  paused+fresh mtime conditions.

### Goal 9 — Docs

- `docs/tui-lifecycle-model.md`: new §3.8 "Paused state (M124)"
  describing ownership, spinner coordination, lifetime semantics, the
  watchdog interaction, and renderer flow. Schema table now lists the
  five `pause_*` JSON keys and the extended `current_agent_status`
  enum.
- `CLAUDE.md`: added `QUOTA_SLEEP_CHUNK` to the template-variable
  table, updated `TUI_WATCHDOG_TIMEOUT` description to mention the
  paused state, and added the four new files
  (`agent_retry_pause.sh`, `quota_sleep.sh`, `tui_ops_pause.sh`,
  `tui_render_pause.py`) to the Repository Layout section.

## Root Cause (bugs only)

N/A — feature work. Issue #180's user-visible symptom is that the
spinner subshell keeps writing `current_agent_status="running"` at
5 Hz while `enter_quota_pause` blocks bash for up to
`QUOTA_MAX_PAUSE_DURATION` seconds (4h default). Goal 1 stops the
spinner across the wait so the JSON status reverts to a quiet state
that the new pause-aware renderer (Goal 4) and watchdog (Goal 5) can
act on.

## Files Modified

| File | Change |
|------|--------|
| `lib/agent_spinner.sh` | Added `_pause_agent_spinner` (no /dev/tty clear) and `_resume_agent_spinner` helpers. |
| `lib/agent_retry.sh` | Added two nameref params to `_run_with_retry`; routed both quota-pause sites through `_retry_pause_spinner_around_quota`. |
| `lib/agent_retry_pause.sh` | (NEW) Spinner pause/resume bracket and pause callbacks. |
| `lib/agent.sh` | Passes spinner-pid var names into `_run_with_retry`. |
| `lib/quota.sh` | Calls `tui_enter_pause` / `tui_exit_pause` (guarded), uses `_quota_sleep_chunked`. |
| `lib/quota_sleep.sh` | (NEW) Chunked-sleep helper with `tui_update_pause` ticks. |
| `lib/tui.sh` | Added 5 pause-state globals. |
| `lib/tui_ops.sh` | Sources `tui_ops_pause.sh`. |
| `lib/tui_ops_pause.sh` | (NEW) Public `tui_enter_pause` / `tui_update_pause` / `tui_exit_pause` API. |
| `lib/tui_helpers.sh` | Emits 5 `pause_*` fields in every status snapshot. |
| `lib/config_defaults.sh` | Added `QUOTA_SLEEP_CHUNK:=5` with clamp 60. |
| `tools/tui.py` | Watchdog eligibility extended to `idle` OR `paused`. |
| `tools/tui_render.py` | `_build_active_bar` branches on `paused` first; imports `_build_paused_bar`. |
| `tools/tui_render_pause.py` | (NEW) `_build_paused_bar` renderer. |
| `tools/tui_render_logo.py` | Idle logo used for `paused` as well. |
| `tools/tui_render_timings.py` | Comment clarifying `paused` excluded from live-row check. |
| `tests/test_quota.sh` | +6 assertions covering TUI helper invocation and absent-helpers safety. |
| `tests/test_tui_quota_pause.sh` | (NEW) 20 assertions on the pause-state JSON contract. |
| `tools/tests/test_tui.py` | +4 tests for paused renderer + watchdog eligibility. |
| `docs/tui-lifecycle-model.md` | Added §3.8 Paused state + schema table rows. |
| `CLAUDE.md` | New `QUOTA_SLEEP_CHUNK` variable; layout updated for 4 new files. |

## Verification

- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → clean.
- `shellcheck -S warning tests/test_tui_quota_pause.sh` → clean.
- `bash tests/run_tests.sh` → **447 shell pass / 0 fail; 214 Python
  pass / 16 skipped**. Existing TUI invariant + lifecycle tests
  (`test_tui_lifecycle_invariants.sh`, `test_tui_stage_wiring.sh`,
  `test_tui_substage_api.sh`, etc.) all pass unchanged — pause is a
  lateral transition that does not violate stage-pill state rules.
- `wc -l` on every file I created or modified: each `lib/`, `stages/`,
  and `tools/` file ≤ 300 lines (extracted `_build_paused_bar` to
  `tui_render_pause.py`, `_quota_sleep_chunked` to `quota_sleep.sh`,
  and the spinner-pause bracket to `agent_retry_pause.sh` to stay
  under the ceiling). Test files and docs are larger by the project's
  established convention.

## Human Notes Status

No human notes were attached to this milestone task.

## Docs Updated

- `docs/tui-lifecycle-model.md` — added §3.8 Paused state and 5 new
  schema-table rows for the `pause_*` JSON fields.
- `CLAUDE.md` — Repository Layout updated for 4 new files; template
  variable table extended with `QUOTA_SLEEP_CHUNK`;
  `TUI_WATCHDOG_TIMEOUT` description amended for the paused state.

## Observed Issues (out of scope)

None encountered.
