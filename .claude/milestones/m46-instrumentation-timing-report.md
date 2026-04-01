# Milestone 46: Instrumentation & Timing Report
<!-- milestone-meta
id: "46"
status: "pending"
-->

## Overview

Tekhton lacks visibility into where wall-clock time is spent during a run. Users
see agents starting and finishing but cannot tell whether slowness comes from
agent execution, build gates, context assembly, or retries. This milestone adds
per-phase timing instrumentation and emits a human-readable timing report at run
end. It also establishes the baseline data needed to measure the impact of all
optimizations in this initiative.

Depends on Milestones 43-44 (Test-Aware Coding and Fix Gate) so their impact
can be measured in the timing report from day one.

## Scope

### 1. Timing Helpers

**File:** `lib/common.sh`

Add `_phase_start()` and `_phase_end()` functions:
- `_phase_start "phase_name"` — records start timestamp in associative array
- `_phase_end "phase_name"` — records end timestamp, computes duration
- Use `date +%s%N` for nanosecond precision (with `date +%s` fallback)
- Store in `_PHASE_TIMINGS` associative array

### 2. Phase Instrumentation

Instrument each phase in `tekhton.sh` and stage files:
- Startup/sourcing
- Config load + detection
- Indexer (repo map generation)
- Per-agent: prompt assembly, agent execution, output parsing
- Build gate (per-phase: analyze, compile, constraints, UI test)
- State persistence
- Finalization (per-hook)
- Preflight fix attempts (from M44)

### 3. TIMING_REPORT.md Emission

**File:** `lib/finalize_summary.sh`

At run end, emit `TIMING_REPORT.md` with per-phase breakdown:

```markdown
## Timing Report — run_20260331_143022

| Phase | Duration | % of Total |
|-------|----------|-----------|
| Scout (agent) | 45s | 12% |
| Coder (agent) | 4m 22s | 68% |
| Build gate | 28s | 7% |
| Reviewer (agent) | 38s | 10% |
| Tester (agent) | 12s | 3% |
| Context assembly | 1.2s | <1% |
| Finalization | 0.8s | <1% |

Total wall time: 6m 27s
Agent calls: 4 (of 200 max)
```

### 4. Completion Banner Enhancement

**File:** `lib/finalize_display.sh`

Add top-3 time consumers to the completion banner so users see timing at a
glance without opening the report.

## Acceptance Criteria

- Every agent invocation records prompt assembly, execution, and parse time
- Every build gate phase records wall-clock duration
- `TIMING_REPORT.md` is written at run end with per-phase breakdown
- Completion banner shows top-3 time consumers
- No measurable performance regression from instrumentation (<100ms total overhead)
- All existing tests pass
- New test coverage for timing helpers

Tests:
- `_phase_start` / `_phase_end` correctly compute durations
- Nested phases are handled (e.g., agent execution within coder stage)
- `TIMING_REPORT.md` is valid markdown with correct percentages summing to ~100%
- Missing `_phase_end` calls don't crash (graceful handling)

Watch For:
- `date +%s%N` is not available on all platforms (macOS `date` doesn't support
  `%N`). Use `gdate` fallback or fall back to second-precision.
- Instrumentation must not interfere with subshell boundaries. Use file-based
  timing (like the existing `_STAGE_DURATION` arrays) rather than shell variables
  that don't survive subshells.
- Dashboard heartbeat already emits some timing data — integrate rather than
  duplicate.

Seeds Forward:
- All subsequent milestones use timing data to validate their impact
- Timing report feeds into future adaptive turn calibration improvements
