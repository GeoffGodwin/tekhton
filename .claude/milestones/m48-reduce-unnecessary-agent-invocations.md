# Milestone 48: Reduce Unnecessary Agent Invocations
<!-- milestone-meta
id: "48"
status: "pending"
-->

## Overview

Beyond test-related reruns (addressed in M43-M44), the pipeline makes several
agent calls that could be skipped or reduced with smarter routing. Specialist
agents run unconditionally when enabled, turn budgets are over-provisioned
leading to unnecessary continuations, and small diffs get the same full review
as large changes.

This milestone adds data-driven routing decisions to skip unnecessary work.

Depends on Milestone 46 (Instrumentation) for baseline agent-call counts and
Milestone 47 (Context Cache) for the cache infrastructure.

## Scope

### 1. Conditional Specialist Invocation

**File:** `lib/specialists.sh`

Before spawning a specialist agent (security, perf, API), check if the diff
touches files relevant to that specialist:
- **Security:** skip if no auth/crypto/input-handling/session files changed
- **Performance:** skip if no hot-path/query/loop/cache files changed
- **API:** skip if no route/endpoint/schema/controller files changed

Detection is keyword-based on `git diff --name-only` file paths — fast, no
agent needed. Add `SPECIALIST_SKIP_IRRELEVANT` config (default: true).

### 2. Diff-Size Review Threshold

**File:** `stages/review.sh`

After Coder completes, measure diff size via `git diff --stat`. If diff is
below `REVIEW_SKIP_THRESHOLD` (default: 0, meaning always review), skip the
full Reviewer agent and auto-pass review.

Use case: single-line typo fixes, config-only changes, comment updates.

### 3. Adaptive Turn Budgets from Metrics History

**File:** `lib/metrics_calibration.sh`

When `METRICS_ADAPTIVE_TURNS=true` and sufficient run history exists
(`METRICS_MIN_RUNS`), use historical median turns for the task type rather
than the configured maximum. This reduces over-provisioned budgets that
cause unnecessary turn-exhaustion continuations.

## Acceptance Criteria

- Specialist agents only run when diff touches relevant files
- Skip decisions are logged with reasoning (for M50 transparency)
- `REVIEW_SKIP_THRESHOLD=0` means always review (backward compatible)
- Metrics-calibrated budgets reduce continuation frequency
- All optimizations are configurable and default to conservative settings
- All existing tests pass
- Timing report shows reduced agent count vs. M46 baseline

Tests:
- Specialist skip detection correctly identifies relevant file patterns
- `SPECIALIST_SKIP_IRRELEVANT=false` disables skip logic
- Review skip triggers only below threshold
- Adaptive turn calibration produces sane values (not less than minimum)

Watch For:
- Specialist skip logic must be conservative — false negatives (running an
  unnecessary specialist) are cheap; false positives (skipping a needed review)
  could miss security issues. Default keyword lists should be broad.
- Review skip should never apply in milestone mode — milestones always get
  full review.
- Adaptive turn budgets should have a floor (never below 50% of configured max)
  to prevent pathological under-provisioning.

Seeds Forward:
- Skip decisions feed into M50 (Progress Transparency) decision logging
- Turn calibration data improves with each run
