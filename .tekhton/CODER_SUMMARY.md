# Coder Summary
## Status: COMPLETE

## What Was Implemented
M125 — Quota Pause Refresh Accuracy & Probe Budget. Three correctness fixes
to `enter_quota_pause` so a genuine Anthropic 5h rolling-window refresh
lands successfully instead of burning four wall-clock hours and dying with
`quota_exhausted`.

- **Goal 1 (pause window):** Bumped default `QUOTA_MAX_PAUSE_DURATION`
  from 14400s (4h) to 18900s (5h15m). The 15m buffer absorbs clock skew
  and drift between pause entry and the server-side window anchor. The
  existing 24h clamp cap is unchanged; pipeline.conf can still override.
- **Goal 2 (probe cost):** Replaced the flat `claude -p "respond with OK"`
  probe with a layered scheme cached per pipeline invocation in
  `_QUOTA_PROBE_MODE`: `version` (zero tokens), `zero_turn` (~zero
  tokens), or `fallback` (original call, now rate-limited to at most
  one call per `QUOTA_PROBE_MIN_INTERVAL=600s`). Mode detection logs
  once at info level.
- **Goal 3 (Retry-After propagation):** Added
  `_extract_retry_after_seconds` in `lib/agent_retry.sh`. It parses
  `Retry-After` from both `agent_last_output.txt` (JSON) and
  `agent_stderr.txt` (plain-text / `Retry-After: NNN` HTTP-header form).
  `_enter_qp_rate` threads the value as the second argument to
  `enter_quota_pause`, which clamps it into
  `[QUOTA_PROBE_MIN_INTERVAL, QUOTA_MAX_PAUSE_DURATION]` and uses it as
  the first-probe delay. `tui_enter_pause` gained an optional
  `FIRST_PROBE_DELAY` fourth argument so the TUI countdown starts at
  the upstream-provided value instead of the default interval.
- **Goal 4 (back-off + jitter):** After the first probe, subsequent
  probes use mild 1.5× exponential back-off applied to the previous
  delay (probes 1–2 stay at `QUOTA_RETRY_INTERVAL`), capped by
  `QUOTA_PROBE_MAX_INTERVAL=1800s`, with ±10% uniform jitter. Each
  iteration of the pause loop updates the TUI countdown via
  `tui_update_pause` with the computed delay — so the paused-bar
  countdown reflects reality across probes.
- **Plain-English logs:** Pause-entry `warn` now reports durations via
  the new `_quota_fmt_duration` helper (`5h15m` / `47m` / `30s`) rather
  than raw seconds. Retry-After-informed delays also log in plain
  English.

## Root Cause (bugs only)
Issue #180 surfaced three correctness defects:
1. `QUOTA_MAX_PAUSE_DURATION=14400` (4h) was shorter than Anthropic's
   5h rolling quota window, so a legitimate refresh one hour later
   never got attempted.
2. `_quota_probe` called `claude -p "respond with OK"` on every wake,
   which itself consumed quota — on a just-refreshed quota sitting at
   the cap boundary, probe tokens could push it back over.
3. `Retry-After` hints from the original rate-limit error were parsed
   only inside `_should_retry_transient` (transient retry path) and
   never reached `enter_quota_pause`, so the first probe always fired
   at the flat `QUOTA_RETRY_INTERVAL` regardless of server guidance.

## Files Modified
- `lib/config_defaults.sh` — Raised `QUOTA_MAX_PAUSE_DURATION` default to
  18900, added `QUOTA_PROBE_MIN_INTERVAL:=600` and
  `QUOTA_PROBE_MAX_INTERVAL:=1800`, plus `_clamp_config_value` entries
  (3600 upper bound on each new key).
- `lib/quota.sh` — `enter_quota_pause` takes optional
  `retry_after_seconds` second arg; clamps it into
  `[QUOTA_PROBE_MIN_INTERVAL, QUOTA_MAX_PAUSE_DURATION]`; forwards the
  clamped value to `tui_enter_pause` as `FIRST_PROBE_DELAY`; drives the
  probe-delay loop via `_quota_next_probe_delay`; logs all durations
  through `_quota_fmt_duration`; sources the new `quota_probe.sh`
  companion.
- `lib/quota_probe.sh` (NEW) — Layered `_quota_probe` with
  `_quota_detect_probe_mode` picking `version` → `zero_turn` →
  `fallback`; `_quota_next_probe_delay` computing the 1.5× back-off
  with ±10% jitter and cap; `_quota_fmt_duration` rendering seconds as
  `5h15m` / `47m` / `30s` for user-facing logs.
- `lib/agent_retry.sh` — Added `_extract_retry_after_seconds` (reads
  both `agent_last_output.txt` and `agent_stderr.txt`, handles JSON
  and plain-text forms); existing `_should_retry_transient` rate-limit
  branch now uses it; rate-limit detection path threads the extracted
  value into `_retry_pause_spinner_around_quota` so the quota pause
  sees it.
- `lib/agent_retry_pause.sh` — `_enter_qp_rate` accepts and forwards
  the optional `retry_after` argument to `enter_quota_pause`.
- `lib/tui_ops_pause.sh` — `tui_enter_pause` accepts optional
  `FIRST_PROBE_DELAY` 4th argument; uses it to set
  `_TUI_PAUSE_NEXT_PROBE_AT` when supplied (falls back to
  `RETRY_INTERVAL` otherwise), preserving all existing schema fields.
- `tests/test_quota.sh` — Added M125 test blocks:
  `_extract_retry_after_seconds` (JSON/stderr/missing cases);
  `enter_quota_pause` Retry-After scheduling, floor clamp, and
  absent-value fallback; probe mode detection across the three CLI
  capability tiers; back-off formula correctness; `_quota_fmt_duration`
  output for 5h15m / 47m / 30s / 1h.
- `tests/test_quota_retry_after_integration.sh` (NEW) — End-to-end
  integration test with a synthetic session payload
  (`retry_after: 6`), stubbed probe, and stubbed TUI pause API;
  asserts first probe fires ~6s after entry (±2s), TUI received the
  threaded delay, `_QUOTA_PAUSE_COUNT=1`, `_QUOTA_TOTAL_PAUSE_TIME`
  within ±1s of wall-clock, `get_quota_stats_json` reports the pause.
- `CLAUDE.md` — Added `QUOTA_MAX_PAUSE_DURATION`,
  `QUOTA_PROBE_MIN_INTERVAL`, `QUOTA_PROBE_MAX_INTERVAL` rows to the
  Template Variables table; added `lib/quota_probe.sh` to the
  repository layout.
- `docs/tui-lifecycle-model.md` — Updated the paused-state section to
  document the new `FIRST_PROBE_DELAY` argument, the Retry-After-
  informed first-probe delay, the 1.5× back-off + jitter, and the
  revised default `QUOTA_MAX_PAUSE_DURATION=5h15m`.

## Docs Updated
- `CLAUDE.md` — Added three new config-key rows
  (`QUOTA_MAX_PAUSE_DURATION`, `QUOTA_PROBE_MIN_INTERVAL`,
  `QUOTA_PROBE_MAX_INTERVAL`) to the Template Variables section, plus
  `lib/quota_probe.sh` in the repository layout.
- `docs/tui-lifecycle-model.md` — Updated the paused-state ownership,
  lifetime, and countdown semantics for M125.

## Human Notes Status
No human notes for this task.

## Verification
- `shellcheck tekhton.sh lib/*.sh stages/*.sh` → zero warnings.
- `bash tests/run_tests.sh` → 450 shell + 214 Python pass, 0 fail.
- `bash tests/test_quota.sh` → 69 pass (up from 47 at M124).
- `bash tests/test_quota_retry_after_integration.sh` → 7 pass in ~7s.
- File lengths: `lib/quota.sh`=293, `lib/quota_probe.sh`=150,
  `lib/agent_retry.sh`=289 (all under the 300-line code ceiling).
