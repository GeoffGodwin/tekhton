## Verdict
TWEAKED

## Confidence
62

## Reasoning
- Problem statement and motivation are excellent — concrete repro data (58 min vs 4 min, 15-turn estimate) makes the "why" unambiguous
- Scope is directionally clear: add observability to the Tester stage
- Missing: explicit files to modify, output format/destination, and testable acceptance criteria
- "Visibility into what the tester agent is actually doing at each turn" is vague — Claude agents don't expose per-turn hooks natively; the shell wraps agent calls, so "per-turn" likely means per-agent-invocation (continuation attempts, retry loops, build-fix cycles)
- No acceptance criteria means a developer won't know when they're done; added concrete, verifiable ones below
- No Migration Impact section needed (no new config keys required, all instrumentation can be log-only with optional env var toggle)

## Tweaked Content

[FEAT] Add debugging/diagnostic output to the Tester stage to surface why it runs disproportionately long compared to the Coder stage.

### Background
A basic bug fix estimated at 15 turns ran 58+ minutes in the Tester stage while the Coder stage took only 4 minutes. The root cause is unknown. Candidates: tester rewriting existing code instead of writing tests, retry loops on transient errors, turn-exhaustion continuations spinning on build failures, or acceptance gate never passing.

### Scope
Add timing instrumentation and structured diagnostic logging to the Tester stage pipeline code (not to the agent prompt). The goal is to make slowness **visible** in the run log so the root cause can be diagnosed and fixed in a follow-up milestone.

[PM: Scope boundary added — instrumentation is in shell/pipeline code only, not in agent prompts, to keep this milestone contained.]

### Files to Modify
- `stages/tester.sh` — primary stage entry point; add wall-clock timing and stage-level diagnostics
- `lib/agent.sh` — `run_agent()` function; add per-invocation elapsed time logging
- `lib/turns.sh` — continuation logic; log each continuation attempt with reason and elapsed time
- `lib/gates.sh` — build/completion gate; log each gate evaluation result and elapsed time

[PM: Files enumerated from project layout in CLAUDE.md. These are the four components that govern tester execution time.]

### Acceptance Criteria
- The run log includes a `[TESTER]` timing header at stage start: `TESTER STAGE START — $(date -u +%H:%M:%SZ)`
- Each agent invocation within the tester stage logs: invocation number, start time, elapsed time, and exit code
- Each continuation attempt (turn-exhaustion) logs: attempt number, reason, and cumulative elapsed time since stage start
- Each build/completion gate evaluation logs: gate type (build vs acceptance), pass/fail result, and elapsed time for that gate call
- If the tester stage exceeds a configurable `TESTER_SLOW_THRESHOLD_SECS` (default: 600 = 10 min), a `[TESTER SLOW]` warning line is emitted to stderr
- All new log lines are prefixed consistently (`[TESTER]`) so they are greppable in CI output
- All existing tests pass (`bash tests/run_tests.sh`)
- `shellcheck stages/tester.sh lib/agent.sh lib/turns.sh lib/gates.sh` passes with zero new warnings

[PM: Acceptance criteria added — none existed in original. Criteria are greppable/verifiable without running a full pipeline.]

### Migration Impact
- One new optional config key: `TESTER_SLOW_THRESHOLD_SECS` (default: 600). No existing behavior changes if unset.
- No new files created; all output goes to existing run log (stdout/stderr).

[PM: Migration Impact section added as required by rubric.]

### Watch For
- `run_agent()` is shared across all stages (Coder, Reviewer, Tester). Timing additions must be additive — do not change the function signature or return behavior. Use local variables; do not leak state.
- Wall-clock timing via `$SECONDS` (bash builtin) or `date +%s` — prefer `$SECONDS` for simplicity and portability.
- The `[TESTER SLOW]` warning should fire based on cumulative stage time, not per-invocation time, so a single slow invocation is distinguishable from many medium ones.
- Do not add timing to the agent prompt or system prompt — this milestone is shell instrumentation only.
