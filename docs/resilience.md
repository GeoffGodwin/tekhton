# Agent Resilience

> This page used to live in the main README. It was split out in
> [M79](../.claude/milestones/m79-readme-restructure-docs-split.md)
> to keep the README focused on the happy path.

Tekhton uses FIFO-isolated agent invocation with multiple layers of fault tolerance:

- **Interrupt handling** — Ctrl+C works immediately, even if the agent is hung. Claude runs in a background subshell writing to a named pipe; the foreground read loop exits on signal.
- **Activity timeout** — If an agent produces no output or file changes for 10 minutes (`AGENT_ACTIVITY_TIMEOUT`), it's killed automatically. Catches hung API connections and stuck retry loops. File-change detection prevents false kills when agents work silently.
- **Total timeout** — Hard wall-clock limit of 2 hours (`AGENT_TIMEOUT`) as a backstop.
- **Transient error retry** — API errors (500, 429, 529), OOM kills, and network failures trigger automatic retry with exponential backoff (30s -> 60s -> 120s, up to 3 attempts). Rate-limit responses respect `retry-after` headers.
- **Turn-exhaustion continuation** — When a coder or tester hits its turn limit but made substantive progress (`Status: IN PROGRESS` + file changes), the pipeline automatically re-invokes with full prior-progress context and a fresh turn budget. Up to 3 continuations before escalating to milestone split or exit.
- **Null-run detection** — Agents that die during discovery (<=2 turns, non-zero exit) are flagged. Combined with file-change detection to distinguish real null runs from silent completions. API failures are never misclassified as null runs.
- **Error taxonomy** — Structured error classification (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE) with transience detection, recovery suggestions, and sensitive data redaction. Errors are displayed in formatted boxes with actionable next steps.
- **Windows compatibility** — Detects Windows-native `claude.exe` running via WSL interop or Git Bash and uses `taskkill.exe` for cleanup (Windows processes ignore POSIX signals).
- **TUI sidecar health monitoring** — When the Python TUI sidecar unexpectedly exits (e.g., watchdog timeout), the parent pipeline detects it within ~10 status updates, emits a warning, and continues in CLI mode. This prevents the pipeline from stalling while writing status to a dead process.

## Build-fix continuation loop (M128)

When the post-coder build gate fails, Tekhton runs a bounded build-fix
loop in `stages/coder_buildfix.sh` (`run_build_fix_loop`) instead of a
single short retry. The loop:

1. **Routes via M127** — reads `LAST_BUILD_CLASSIFICATION` (set by
   `lib/error_patterns_classify.sh`). If the routing token is
   `noncode_dominant`, the loop short-circuits to `HUMAN_ACTION_REQUIRED.md`
   and exits with `env_failure` — no agent attempt is spent on
   environment errors. `mixed_uncertain` triggers a one-shot
   `BUILD_ROUTING_DIAGNOSIS.md` write before entering the loop.
2. **Adaptive turn budgets** — attempt 1 uses `EFFECTIVE_CODER_MAX_TURNS / BUILD_FIX_BASE_TURN_DIVISOR`
   turns; attempt 2 multiplies by 1.5 (integer arithmetic: `* 3 / 2`);
   attempt 3 doubles. All clamped to `[8, EFFECTIVE_CODER_MAX_TURNS * BUILD_FIX_MAX_TURN_MULTIPLIER / 100]`.
3. **Cumulative cap** — `BUILD_FIX_TOTAL_TURN_CAP` (default 120) caps
   the sum of all attempt budgets. When the remaining cap drops below
   8, the loop exits with `OUTCOME=exhausted`.
4. **Progress gate** — after each failed attempt, the loop computes the
   error-line-count delta and the last-20-non-blank-line tail. If the
   signal is `unchanged` or `worsened` on attempt N≥2 and
   `BUILD_FIX_REQUIRE_PROGRESS=true`, the loop halts with
   `OUTCOME=no_progress` instead of burning more turns on a stalled
   pass.
5. **Postmortem artifact** — `BUILD_FIX_REPORT_FILE` records every
   attempt with turn budget, agent terminal class, gate result, progress
   signal, error-count delta, and routing classification. The
   `PIPELINE_STATE.md` notes on terminal failure include the report
   pointer and final attempt count.

### Outcome vocabulary (frozen by M128)

The build-fix loop exports four env vars on every exit path that
M132's RUN_SUMMARY enrichment reads verbatim:

| Variable | Values |
|----------|--------|
| `BUILD_FIX_OUTCOME` | `passed` \| `exhausted` \| `no_progress` \| `not_run` |
| `BUILD_FIX_ATTEMPTS` | integer, 0..`BUILD_FIX_MAX_ATTEMPTS` |
| `BUILD_FIX_TURN_BUDGET_USED` | cumulative turns spent in build-fix |
| `BUILD_FIX_PROGRESS_GATE_FAILURES` | times the progress gate aborted (0 unless `no_progress`) |

`not_run` covers the gate-passed-first-time case, the
`BUILD_FIX_ENABLED=false` opt-out, and the M127 `noncode_dominant`
short-circuit. Setting `BUILD_FIX_MAX_ATTEMPTS=1` reproduces pre-M128
single-attempt behavior for rollback safety.
