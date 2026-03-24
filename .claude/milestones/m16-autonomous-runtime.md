#### Milestone 16: Autonomous Runtime Improvements
<!-- milestone-meta
id: "16"
status: "done"
-->

Reform the --complete / --auto-advance outer loop to reward productive work instead
of punishing it. Three changes: (1) milestone success resets the outer loop counter
so productive runs continue indefinitely, (2) quota-aware pause/resume so the
pipeline gracefully handles rate limits instead of failing, (3) increased split
depth now that PM + security agents provide safety rails.

The end state: a user runs `tekhton --milestone --complete --auto-advance` and
walks away. The pipeline runs until it's out of milestones OR out of quota. It
never stops because of an arbitrary cycle count while it's making progress.

Files to create:
- `lib/quota.sh` — Quota management and rate-limit handling:
  **Rate limit detection** (`is_rate_limit_error(exit_code, stderr_file)`):
  - Parse stderr output from `claude` CLI for known rate-limit patterns:
    "rate limit", "quota exceeded", "usage limit", "too many requests",
    "429", "capacity", "overloaded"
  - Return 0 if rate limit detected, 1 otherwise.
  - This is the Tier 1 (reactive) detection — works for all users with zero
    configuration.

  **Pause/resume state machine** (`enter_quota_pause()`, `exit_quota_pause()`):
  - `enter_quota_pause()`:
    1. Set pipeline state to QUOTA_PAUSED (new state in lib/state.sh)
    2. Disable AGENT_ACTIVITY_TIMEOUT (save current value, set to 0)
    3. Disable AUTONOMOUS_TIMEOUT countdown (save remaining time)
    4. Log event to Watchtower: "Pipeline paused — waiting for quota refresh"
    5. Write QUOTA_PAUSED marker file with timestamp and retry schedule
    6. Begin retry loop: attempt a lightweight CLI probe every
       QUOTA_RETRY_INTERVAL seconds (default 300 = 5 minutes)
    7. The probe is a minimal `claude` call (single-turn, short prompt) to
       check if quota has refreshed. NOT a full agent invocation.
  - `exit_quota_pause()`:
    1. Remove QUOTA_PAUSED marker file
    2. Restore AGENT_ACTIVITY_TIMEOUT to saved value
    3. Restore AUTONOMOUS_TIMEOUT countdown (remaining time, not full reset)
    4. Set pipeline state back to previous state
    5. Log event to Watchtower: "Quota refreshed — resuming pipeline"
    6. Return to the agent call that triggered the pause (retry it)

  **Proactive quota check (Tier 2, optional):**
  - `check_quota_remaining()` — If CLAUDE_QUOTA_CHECK_CMD is configured,
    execute it and parse the output for remaining percentage.
    Default: empty (disabled). Users can set this to a custom script that
    checks their account's usage via whatever mechanism is available.
    Example: `CLAUDE_QUOTA_CHECK_CMD="python3 ~/.tekhton/check_usage.py"`
    The script must output a single number 0-100 (percentage remaining).
  - `should_pause_proactively()` — If quota check available AND remaining
    percentage < QUOTA_RESERVE_PCT (default 10), return 0 (should pause).
  - When proactive pause triggers: same pause/resume flow as reactive, but
    the Watchtower message says "Paused at X% remaining (reserve threshold)"
    instead of "Rate limited."

  **Integration with agent_retry.sh:**
  - Modify `_retry_on_transient()` to call `is_rate_limit_error()` BEFORE
    the existing transient error retry logic.
  - If rate limit detected: call `enter_quota_pause()` instead of normal
    backoff retry. Normal transient retries are for server errors (500, 503).
    Rate limits get the full pause/resume treatment.
  - After `exit_quota_pause()` returns, the retry proceeds as if it were
    the first attempt (counter not incremented for quota pauses).

Files to modify:
- `lib/orchestrate.sh` — **Milestone success resets outer loop:**
  In the `--complete` outer loop, after a milestone is successfully completed
  (mark_milestone_done returns 0), reset the pipeline attempt counter:
  ```bash
  if milestone_completed_successfully; then
      pipeline_attempts=0  # Reset — we're making progress
      log_info "Milestone complete. Resetting attempt counter."
  fi
  ```
  Also reset on successful milestone split (split produces valid sub-milestones):
  ```bash
  if milestone_split_successfully; then
      pipeline_attempts=0  # Split is forward progress
      log_info "Milestone split. Resetting attempt counter."
  fi
  ```
  The MAX_PIPELINE_ATTEMPTS counter now ONLY increments on full pipeline
  cycles that produce no forward progress (no milestone completed, no
  split performed, no useful rework applied). This means:
  - 5 successful milestones in a row: counter stays at 0 the whole time
  - 3 failures then a success: counter goes 1, 2, 3, then resets to 0
  - 5 consecutive failures with no progress: pipeline stops (existing behavior)

  **Increase default limits:**
  - MAX_PIPELINE_ATTEMPTS: 5 → 5 (unchanged — it's now failure-only)
  - MAX_AUTONOMOUS_AGENT_CALLS: 20 → remove hard cap (replaced by quota system).
    Keep as a safety valve at 200 (effectively unlimited for normal use, catches
    true runaways). Log a warning at 100 calls.
  - MILESTONE_MAX_SPLIT_DEPTH: 3 → 6 (PM agent catches bad milestones before
    they waste budget on deep splitting)

- `lib/orchestrate_helpers.sh` — Update `_check_progress()` to distinguish
  between "no progress" (counter increments) and "progress made but incomplete"
  (counter doesn't increment). Progress indicators:
  **Primary (causal log, when available via M13):**
  - Event count for current pipeline attempt > 0 (work was done)
  - Non-error events emitted after the last error (recovery happened)
  - Verdict events with forward-progress outcomes (APPROVED, TWEAKED, PASS)
  - rework_cycle events that produced file changes (productive rework)
  **Fallback (when causal log unavailable):**
  - Files changed in git
  - New test files created
  - Milestone acceptance criteria partially met
  - Security findings fixed
  The causal log provides richer progress signals because it captures work
  that doesn't necessarily produce file changes (e.g., a security scan that
  found zero issues is still progress — the scan completed). The git-diff
  fallback remains for backward compatibility and for cases where the causal
  log is disabled.

- `lib/agent_retry.sh` — Add rate-limit detection before transient retry:
  ```bash
  if is_rate_limit_error "$exit_code" "$stderr_file"; then
      enter_quota_pause
      # After resume, retry the same call (don't increment retry counter)
      continue
  fi
  ```
  Rate limit pauses do NOT count against MAX_TRANSIENT_RETRIES.

- `lib/state.sh` — Add QUOTA_PAUSED as valid pipeline state. Add save/restore
  for timeout values during pause. Add QUOTA_PAUSED marker file path.

- `lib/agent_monitor.sh` — When pipeline state is QUOTA_PAUSED, the activity
  monitor must be fully disabled (not just extended timeout — completely off).
  The quota retry loop in quota.sh handles its own timing.

- `lib/config_defaults.sh` — Add:
  QUOTA_RETRY_INTERVAL=300 (seconds between quota refresh checks, default 5min),
  QUOTA_RESERVE_PCT=10 (proactive pause threshold, only used with Tier 2),
  CLAUDE_QUOTA_CHECK_CMD="" (optional external script for proactive checking),
  QUOTA_MAX_PAUSE_DURATION=14400 (max seconds to wait in pause before giving up,
  default 4 hours — covers a full 5-hour rolling window refresh).
  Update: MAX_AUTONOMOUS_AGENT_CALLS=200, MILESTONE_MAX_SPLIT_DEPTH=6.

- `lib/config.sh` — Validate QUOTA_* keys. QUOTA_RETRY_INTERVAL must be 60-3600.
  QUOTA_RESERVE_PCT must be 1-50. QUOTA_MAX_PAUSE_DURATION must be 300-86400.
  If CLAUDE_QUOTA_CHECK_CMD is set, verify the command exists and is executable.

- `lib/dashboard.sh` — Emit quota pause/resume events. Add quota status to
  run_state.js: `quota_status: "ok" | "paused"`, `quota_paused_at`,
  `quota_retry_count`, `quota_estimated_resume`. Watchtower Live Run tab
  shows prominent "Paused — Waiting for Quota" banner during pause.

- `lib/finalize.sh` — Include quota pause events in RUN_SUMMARY.json:
  total_pause_time_s, pause_count, was_quota_limited (boolean).

- `lib/finalize_display.sh` — If quota pauses occurred during the run,
  include in completion banner: "Quota pauses: 2 (total wait: 12m 34s)".

Acceptance criteria:
- Milestone success resets pipeline_attempts to 0 in --complete mode
- Milestone split resets pipeline_attempts to 0 in --complete mode
- Pipeline continues indefinitely through successful milestones (tested with
  3+ consecutive milestone completions — counter stays at 0)
- Pipeline still stops after MAX_PIPELINE_ATTEMPTS consecutive failures
  with no forward progress
- `is_rate_limit_error()` correctly identifies rate-limit patterns from
  claude CLI stderr output
- Rate limit triggers QUOTA_PAUSED state, not transient retry
- During QUOTA_PAUSED: activity timeout disabled, autonomous timeout frozen
- Quota retry probe runs every QUOTA_RETRY_INTERVAL seconds
- Pipeline resumes automatically when quota refreshes (probe succeeds)
- Quota pause does not count against MAX_TRANSIENT_RETRIES
- Pipeline gives up after QUOTA_MAX_PAUSE_DURATION with clear error message
- When CLAUDE_QUOTA_CHECK_CMD is configured and returns <QUOTA_RESERVE_PCT,
  pipeline pauses proactively before hitting the rate limit
- When CLAUDE_QUOTA_CHECK_CMD is not configured, Tier 2 is silently disabled
- MAX_AUTONOMOUS_AGENT_CALLS raised to 200 (effective safety valve only)
- MILESTONE_MAX_SPLIT_DEPTH raised to 6
- Watchtower shows quota pause/resume events in timeline
- Watchtower Live Run tab shows prominent pause banner during QUOTA_PAUSED
- RUN_SUMMARY.json includes quota pause statistics
- Completion banner shows quota pause summary when pauses occurred
- All existing tests pass
- `bash -n lib/quota.sh` passes
- `shellcheck lib/quota.sh` passes
- New test file `tests/test_quota.sh` covers: rate limit pattern detection,
  pause/resume state transitions, timeout disable/restore, milestone-success
  counter reset, progress detection

Watch For:
- The quota probe must be truly lightweight. A single-turn `claude` call with
  a trivial prompt ("respond with OK") and --max-turns 1. If even this is
  rate-limited, the quota hasn't refreshed yet. Don't use a full agent call.
- AUTONOMOUS_TIMEOUT must be frozen (remaining time saved), not disabled,
  during quota pause. When resumed, the timer continues from where it left off.
  Otherwise a long quota pause could allow the pipeline to run indefinitely
  after resume.
- The milestone-success reset means MAX_PIPELINE_ATTEMPTS is now effectively
  "max consecutive failures." Update all documentation and comments to reflect
  this semantic change.
- Rate limit error patterns vary by Claude CLI version. Use a broad regex
  matching approach (case-insensitive, multiple patterns) rather than exact
  string matching. Test against actual CLI error messages.
- The CLAUDE_QUOTA_CHECK_CMD runs as a subprocess. It must timeout (5s max)
  and never block the pipeline. If it fails, silently fall back to Tier 1.
- Consider: what if the user's quota refreshes at 4am and the pipeline has
  been paused since 11pm? The periodic probe will catch it. But the user
  might want to know when it resumed. The Watchtower timeline event + a
  possible terminal notification (bell character) handles this.
- The 200 MAX_AUTONOMOUS_AGENT_CALLS is a SAFETY VALVE, not a workflow limit.
  If a run hits 200 agent calls, something is genuinely wrong (infinite rework
  loop, misconfigured pipeline). Log a prominent warning at 100 and error at 200.

Seeds Forward:
- V4 parallel execution: each parallel worker gets its own quota tracking.
  Shared quota pool prevents N workers from exhausting quota N times faster.
- V4 tech debt agent: runs on its own quota budget (separate from main pipeline).
  Can be configured with lower priority (pauses first, resumes last).
- The CLAUDE_QUOTA_CHECK_CMD interface is a plugin point. V4 could ship
  default check scripts for common setups (Pro subscription, API key, team plan).
- Quota statistics from RUN_SUMMARY.json feed into Watchtower Trends:
  "Average quota utilization per run", "Peak quota periods to avoid".
