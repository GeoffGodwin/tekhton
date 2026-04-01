# Milestone 50: Progress Transparency
<!-- milestone-meta
id: "50"
status: "pending"
-->

## Overview

Tekhton's pipeline is opaque during execution. Users see agent spinners but
cannot tell what the pipeline is doing, why it made a routing decision, or how
long the current phase is expected to take. This milestone adds real-time
progress display, decision explanation logging, and enhanced run-end summaries.

Depends on Milestone 46 (Instrumentation) for timing data and Milestone 48
(Reduce Agents) for routing decisions to log.

## Scope

### 1. Stage Progress Display

**Files:** `stages/coder.sh`, `stages/review.sh`, `stages/tester.sh`

Before each agent invocation, print a clear status line:
```
[tekhton] Stage 2/4: Reviewer (cycle 1/3) — estimated 2-4 min based on history
```

After each agent, print outcome:
```
[tekhton] Reviewer: REWORK (3 issues) — 2m 14s — rework coder next
```

### 2. Decision Explanation Logging

**Files:** `lib/orchestrate.sh`, `lib/specialists.sh`, `stages/coder.sh`

When the pipeline makes a routing decision, log the reason:
```
[tekhton] Trying Jr Coder fix — 2 test failures detected (PREFLIGHT_FIX_ENABLED=true)
[tekhton] Skipping security specialist — diff doesn't touch auth files
[tekhton] Continuing coder — turn limit hit, progress detected (attempt 2/3)
[tekhton] Scout using repo map verification mode (REPO_MAP_CONTENT available)
```

### 3. Live Dashboard Enhancement

**File:** `lib/dashboard.sh`

Add current phase, elapsed time, and estimated remaining time to the dashboard
state emitted via `emit_dashboard_run_state()`.

### 4. Run-End Summary Enhancement

**File:** `lib/finalize_summary.sh`

Add a "Pipeline Decisions" section to `RUN_SUMMARY.json` listing every routing
decision made and why. Add "Time Breakdown" section with per-phase timings
from Milestone 46.

## Acceptance Criteria

- Every agent invocation is preceded by a human-readable status line
- Every routing decision is logged with its reason
- Run-end summary includes a decisions log and timing breakdown
- Dashboard shows current phase and elapsed time
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

Tests:
- Status lines include stage number, name, and timing estimate
- Decision log entries include config key that triggered the decision
- `RUN_SUMMARY.json` includes decisions and timing sections
- Status lines don't appear in agent output (only in pipeline stderr/log)

Watch For:
- Status lines must go to stderr or the log file, NOT stdout — stdout is
  reserved for agent communication via FIFO.
- Timing estimates based on history may be wildly wrong for novel tasks. Show
  "no estimate" rather than a misleading prediction when history is sparse.
- Decision logging should use the existing `log()` function pattern, not a
  separate mechanism.

Seeds Forward:
- Decision logging feeds into future run analytics / Watchtower enhancements
- Timing estimates improve with each run as metrics history grows
