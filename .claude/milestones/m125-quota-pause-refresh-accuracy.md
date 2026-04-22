# M125 - Quota Pause Refresh Accuracy & Probe Budget

<!-- milestone-meta
id: "125"
status: "pending"
-->

## Overview

Issue #180 surfaces three correctness defects in the quota-pause
subsystem that are independent of the TUI-visibility fix in M124.
Even with the pause fully observable, a user can still end up with a
failed run because:

1. **`QUOTA_MAX_PAUSE_DURATION` default (4h, 14400s) is shorter than
   Anthropic's 5h rolling usage window.** When a Claude Pro/Max
   subscription hits the cap, the quota refreshes on a rolling 5h
   window. `lib/quota.sh:107` gives up at 4h, so a legitimate refresh
   one hour later never gets attempted — the pause exits with
   `AGENT_ERROR_CATEGORY=UPSTREAM`, `AGENT_ERROR_SUBCATEGORY=quota_exhausted`,
   and the run dies having burned four hours of wall-clock time.

2. **`_quota_probe` itself consumes quota.** `lib/quota.sh:140` runs
   `claude --max-turns 1 --output-format json -p "respond with OK"`
   every `QUOTA_RETRY_INTERVAL` seconds. Each probe generates a few
   tokens of input + output that count against the rolling window. On
   a just-refreshed quota that's sitting right at the cap boundary,
   one probe can push it right back over — the probe succeeds, the
   pipeline resumes, the first real agent call hits the cap again,
   and the pause re-enters. In the worst case the probe cadence
   prevents the quota from ever settling below the threshold.

3. **`Retry-After` headers from the original rate-limit error are
   parsed but never propagated to the pause loop.**
   `lib/agent_retry.sh:210-221` extracts a `"retry_after":N` value
   from `agent_last_output.txt` when the error subcategory is
   `api_rate_limit`, but that path only applies to transient-retry
   delays — not to `enter_quota_pause`. The pause loop always uses
   the flat `QUOTA_RETRY_INTERVAL` (default 300s), even when
   Anthropic's own response told us exactly when the quota resets.
   First probe fires at 5 minutes regardless of whether the server
   said "retry in 47 minutes".

M125 is the correctness pass. It matches the pause window to the
real refresh window, lowers the probe's token cost to near-zero, and
threads the `Retry-After` signal from the initial error through to
the first probe's scheduling so the pause actually respects
upstream's explicit guidance.

M125 depends on M124 semantically: the `tui_update_pause` countdown
from M124 will show the correct "next probe in Nm" number only once
M125's Retry-After propagation lands. Land M124 first so the
visibility exists to validate M125's timing behaviour by eye.

## Design

### Goal 1 — Match `QUOTA_MAX_PAUSE_DURATION` to the 5h rolling window

Change the default in `lib/config_defaults.sh:261` from `14400` (4h)
to `18900` (5h 15m). The extra 15-minute buffer handles clock skew
between the local machine and Anthropic's quota-reset edge plus
natural drift between when the pause starts and when the window
anchor was set server-side.

The existing `_clamp_config_value QUOTA_MAX_PAUSE_DURATION 86400`
(24h upper bound) stays. Users who want a stricter cap can still set
a lower value in `pipeline.conf`; only the built-in default shifts.

Update `CLAUDE.md`'s template-variable table row for
`QUOTA_MAX_PAUSE_DURATION` to reflect the new default
(`18900` / 5h 15m) and note that the value should match the
upstream quota window.

Add a log line at pause entry that tells the user up front how long
the pause can last in plain English, rather than a raw seconds
count: `"Pipeline paused — <reason>. Waiting up to 5h15m for quota
refresh (probing every 5m)."`. Format the durations via the
existing `_fmt_duration` helper in `lib/common.sh` (or a local
bash equivalent if that helper lives in Python-only code — grep
first).

### Goal 2 — Make `_quota_probe` cost (effectively) zero tokens

The current probe in `lib/quota.sh:134-154` invokes a real
`claude -p "respond with OK"` call that generates input + output
tokens. Replace it with a layered probe that tries cheap options
first and only falls back to the real call when necessary.

Preferred order, each gated behind a feature-detection check:

1. **`claude --version` probe.** Invoking `timeout 10 claude
   --version` completes without authenticating against the API at
   all — it exits 0 if the binary is present and runnable. This
   alone doesn't verify quota, but combined with (2) it rules out
   local environment regressions (`claude` binary removed, PATH
   broken) that would otherwise masquerade as unrefreshed quota.

2. **Empty-prompt probe.** Invoke `timeout 10 claude --max-turns 0
   --output-format text -p ""` (or the nearest equivalent depending
   on the installed CLI version — test via `claude --help | grep`
   at startup to detect support). `--max-turns 0` forbids any tool
   turn from executing; the call either exits with a structural
   "nothing to do" message at ~zero tokens, or returns the same
   rate-limit error as a real call. Either way, quota state is
   observable without burning meaningful budget.

3. **Current path as fallback.** If neither (1) nor (2) is
   supported by the installed CLI version, keep the existing
   `claude --max-turns 1 -p "respond with OK"` flow but cap the
   probe to once every `QUOTA_PROBE_MIN_INTERVAL` seconds
   (default 600s = 10m) regardless of `QUOTA_RETRY_INTERVAL`, so
   the probe cost can never dominate the paused budget even on
   old CLIs.

The probe detection runs once per pipeline invocation at first
pause and caches the result in `_QUOTA_PROBE_MODE` (values:
`version` / `zero_turn` / `fallback`). Log the chosen mode once at
info level so operators can confirm their CLI is on a cheap mode.

If `is_rate_limit_error` on the probe's stderr returns true, the
probe correctly concludes "still exhausted" regardless of which
mode it used. If the probe exits 0 (version mode) or exits non-zero
with a non-rate-limit error (zero-turn mode), treat quota as
possibly-available and let the pipeline do one real attempt —
which either succeeds or re-enters `enter_quota_pause` with the
fresh `Retry-After` header parsed by the next path.

Add a new config key `QUOTA_PROBE_MIN_INTERVAL` to
`lib/config_defaults.sh` (default 600, clamped to 3600 upper
bound). Keep `QUOTA_RETRY_INTERVAL` as the wake-up / countdown
cadence; introduce the probe cadence as a separate knob so the
TUI can display a live countdown on `QUOTA_RETRY_INTERVAL` without
those wake-ups necessarily triggering a real probe.

### Goal 3 — Propagate `Retry-After` from the original error

`lib/agent_retry.sh:210-221` already extracts a Retry-After numeric
value from `agent_last_output.txt` when the error subcategory is
`api_rate_limit`. M125 makes that value visible to the quota pause.

Extract the parsing into a reusable helper in
`lib/agent_retry.sh`:

```bash
# _extract_retry_after_seconds SESSION_DIR
# Returns 0 with the number of seconds to stdout, or 1 if not found.
_extract_retry_after_seconds() {
    local session_dir="$1"
    local out="${session_dir}/agent_last_output.txt"
    local err="${session_dir}/agent_stderr.txt"
    local secs=""
    for f in "$out" "$err"; do
        [[ -f "$f" ]] || continue
        secs=$(grep -oiE '"?retry.after"?[[:space:]]*:[[:space:]]*"?[0-9]+"?' "$f" 2>/dev/null \
               | grep -oE '[0-9]+' | head -1)
        [[ -n "$secs" ]] && break
    done
    if [[ -n "$secs" ]] && [[ "$secs" =~ ^[0-9]+$ ]]; then
        echo "$secs"
        return 0
    fi
    return 1
}
```

Note the helper also checks `agent_stderr.txt` — the CLI sometimes
logs Retry-After to stderr rather than the structured JSON output,
depending on the error mode. The existing `_should_retry_transient`
call site keeps working with the unchanged regex and falls back on
the helper's return value.

In `lib/agent_retry.sh` at the rate-limit branch (lines 74-97),
compute `_retry_after` before calling `enter_quota_pause` and pass
it through:

```bash
if is_rate_limit_error "$_RWR_EXIT" "$_stderr_path"; then
    local _ra=""
    _ra=$(_extract_retry_after_seconds "$session_dir" || true)
    if command -v enter_quota_pause &>/dev/null; then
        warn "[$label] Rate limit detected — entering quota pause."
        if enter_quota_pause "Rate limited (agent: ${label})" "$_ra"; then
            ...
```

Change `enter_quota_pause`'s signature to accept an optional
second argument: `retry_after_seconds`. Default is empty (current
behaviour). Inside the function:

- If `retry_after_seconds` is present and numeric, clamp it to
  `[QUOTA_PROBE_MIN_INTERVAL, QUOTA_MAX_PAUSE_DURATION]` and sleep
  for that duration before the first probe instead of
  `QUOTA_RETRY_INTERVAL`.
- After the first Retry-After-scheduled probe, if it still reports
  exhausted, fall back to the normal `QUOTA_RETRY_INTERVAL` cadence
  for subsequent probes.
- Log the decision at info level: `"Anthropic said retry in
  <HHh MMm> — waiting that long before first probe."`
- Forward the value to `tui_enter_pause` as a fourth argument
  (`first_probe_delay`) so M124's countdown starts at the right
  number rather than the default interval.

Tests in `tests/test_quota.sh`:

- `test_extract_retry_after_parses_json_output` — write a fixture
  JSON with `"retry_after": 47` to a temp session dir, assert the
  helper returns `47`.
- `test_extract_retry_after_parses_stderr_message` — fixture with
  plain text `Rate limited. Retry after 180 seconds.` on stderr,
  assert the helper returns `180` (update regex if needed).
- `test_enter_quota_pause_honours_retry_after` — stub `_quota_probe`
  to track wall-clock between calls, invoke with `retry_after=8`
  and `QUOTA_RETRY_INTERVAL=2`, assert the first probe fires ~8s
  later, the second ~2s after that.
- `test_enter_quota_pause_clamps_retry_after_floor` — stub, invoke
  with `retry_after=1` and `QUOTA_PROBE_MIN_INTERVAL=5`, assert
  the first probe waits at least 5s.

### Goal 4 — Probe back-off with jitter

With Retry-After guiding the first probe, subsequent probes still
fire on `QUOTA_RETRY_INTERVAL`. If the first probe fails (quota
still exhausted), replace flat cadence with mild exponential
back-off, capped so the TUI countdown remains predictable:

- Probe 1: `Retry-After` (if present) or `QUOTA_RETRY_INTERVAL`.
- Probe 2: `QUOTA_RETRY_INTERVAL`.
- Probe 3: `min(QUOTA_RETRY_INTERVAL * 1.5, QUOTA_PROBE_MAX_INTERVAL)`.
- Probe N (N>3): same formula applied to the previous delay.

Add `QUOTA_PROBE_MAX_INTERVAL` to `lib/config_defaults.sh` with a
default of 1800 (30 minutes, half the pre-M125 flat cadence cap)
and a clamp bound of 3600.

Add ±10% uniform jitter on each computed delay so many pipelines
refreshing against the same window don't thundering-herd the API.
Implementation: `_delay=$(( _delay * (90 + RANDOM % 21) / 100 ))`.

Update the `tui_update_pause` call site in `_quota_sleep_chunked`
(introduced in M124) to pass the next-probe delay from this
back-off rather than a hardcoded `QUOTA_RETRY_INTERVAL` — so the
TUI countdown reflects reality across probes.

### Goal 5 — Additional integration tests

One new shell test `tests/test_quota_retry_after_integration.sh`:

1. Stage a fake `claude` shim on PATH that writes a synthetic
   rate-limit payload with `"retry_after": 6` to the output file
   on first invocation, then succeeds on the second.
2. Source `lib/agent.sh` and run a minimal `run_agent` call.
3. Assert `enter_quota_pause` was entered, the first probe was
   scheduled ~6s after entry (±2s), the probe succeeded, and
   `AGENT_ERROR_CATEGORY` is empty on return.
4. Assert `get_quota_stats_json` reports `pause_count=1` and
   `total_pause_time_s` within the expected window.

Add to `tests/run_tests.sh`.

Expand the existing `tests/test_quota.sh` with:

- `test_probe_mode_detection_prefers_version` — stub a
  `claude --version` shim that exits 0, assert
  `_QUOTA_PROBE_MODE=version` after first `_quota_probe` call.
- `test_probe_mode_fallback_when_flags_unsupported` — stub
  `claude --help` output without `--max-turns`, assert fallback
  mode is selected and `QUOTA_PROBE_MIN_INTERVAL` is enforced.

## Files Modified

| File | Change |
|------|--------|
| `lib/config_defaults.sh` | Bump `QUOTA_MAX_PAUSE_DURATION` default to 18900 (5h 15m); add `QUOTA_PROBE_MIN_INTERVAL:=600`, `QUOTA_PROBE_MAX_INTERVAL:=1800`; add clamp bounds for both. |
| `lib/quota.sh` | Accept optional `retry_after_seconds` in `enter_quota_pause`; layered probe (version → zero-turn → fallback) with cached `_QUOTA_PROBE_MODE`; exponential back-off + jitter; forward `first_probe_delay` to `tui_enter_pause`. |
| `lib/agent_retry.sh` | Extract `_extract_retry_after_seconds` helper (reads both stdout and stderr); pass the value into `enter_quota_pause`. |
| `tests/test_quota.sh` | Add Retry-After parsing tests, probe-mode detection tests, pause scheduling tests. |
| `tests/test_quota_retry_after_integration.sh` | **New file.** End-to-end test with a synthetic `claude` shim returning Retry-After payload. |
| `tests/run_tests.sh` | Register the new integration test. |
| `CLAUDE.md` | Update `QUOTA_MAX_PAUSE_DURATION` row; add `QUOTA_PROBE_MIN_INTERVAL`, `QUOTA_PROBE_MAX_INTERVAL` rows. |
| `docs/tui-lifecycle-model.md` | Note that M124's paused countdown reflects the Retry-After-informed next-probe delay. |

## Acceptance Criteria

- [ ] Default `QUOTA_MAX_PAUSE_DURATION` is 18900s; a paused run
      with a 4h45m actual refresh delay resumes successfully
      rather than giving up with `quota_exhausted`.
- [ ] The pause-entry log line reports the duration in plain
      English (`5h15m`, `47m`, etc.) rather than raw seconds.
- [ ] When the original rate-limit error carries a Retry-After
      value, the first probe fires after that delay (within
      `QUOTA_PROBE_MIN_INTERVAL` floor and
      `QUOTA_MAX_PAUSE_DURATION` ceiling) — verified via the
      integration test with a synthetic `claude` shim.
- [ ] When Retry-After is absent, behaviour matches pre-M125:
      first probe fires at `QUOTA_RETRY_INTERVAL` with no
      regression.
- [ ] `_extract_retry_after_seconds` returns the correct value
      from both `agent_last_output.txt` (JSON form) and
      `agent_stderr.txt` (plain-text form). Missing / malformed
      values return non-zero without aborting.
- [ ] `_quota_probe` selects a probe mode at first use and caches
      it in `_QUOTA_PROBE_MODE`. On modern Claude CLIs that
      support `--version`, the mode is `version`; token cost per
      probe is zero.
- [ ] Falling back to the pre-M125 `claude -p "respond with OK"`
      path is rate-limited to at most one call per
      `QUOTA_PROBE_MIN_INTERVAL` seconds regardless of
      `QUOTA_RETRY_INTERVAL`.
- [ ] Subsequent probes (after the Retry-After-scheduled first
      one) use an exponential back-off with ±10% jitter, capped
      by `QUOTA_PROBE_MAX_INTERVAL`. Countdown rendered by M124's
      `tui_update_pause` matches the computed delay within one
      chunk interval.
- [ ] M124's paused-bar countdown shows the correct first-probe
      delay when a Retry-After is present (visual parity test
      with the synthetic shim).
- [ ] All existing `tests/test_quota.sh` assertions continue to
      pass. New tests in `test_quota.sh` and the new
      `test_quota_retry_after_integration.sh` pass in under 60s.
- [ ] Shellcheck clean for `lib/quota.sh`, `lib/agent_retry.sh`,
      and the new integration test.
- [ ] Running a real pipeline against a quota-exhausted
      subscription now refreshes on the first natural refresh
      opportunity (documented manual test: exhaust quota, run
      Tekhton, confirm resume at the server's retry-after time).

## Non-Goals

- TUI visibility for the pause (stage pill, countdown,
  watchdog). All of that is M124.
- Exposing `/usage`-style remaining-quota telemetry. As noted in
  issue #180, `/usage` is not accessible via the Claude API on
  subscriptions and is flaky via the CLI. `should_pause_proactively`
  still depends on users configuring their own
  `CLAUDE_QUOTA_CHECK_CMD`; M125 does not change that surface.
- Cross-run quota budgeting (remembering how much was burned in
  the last N runs to preempt a pause). Belongs to a separate
  metrics milestone.
- Migrating `_QUOTA_PAUSE_COUNT` / `_QUOTA_TOTAL_PAUSE_TIME`
  accounting into `lib/run_memory.sh`. Current in-process globals
  plus `RUN_SUMMARY.json` emission are sufficient.
- Adding a `--no-quota-pause` CLI flag that aborts immediately on
  rate-limit errors. The TUI visibility from M124 plus M125's
  correct pause duration make that unnecessary; Ctrl-C is the
  documented abandon path.
- Rewriting the probe as an HTTP `HEAD` or other non-claude-CLI
  request. Keeping everything behind `claude` means we don't need
  separate auth handling or API-key sourcing.

