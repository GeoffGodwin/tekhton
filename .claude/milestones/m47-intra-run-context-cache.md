# Milestone 47: Intra-Run Context Cache
<!-- milestone-meta
id: "47"
status: "pending"
-->

## Overview

Every agent invocation in a pipeline run independently re-reads the same files
from disk: architecture content, drift log, human notes, clarifications, and
milestone window. For a 6-agent run, architecture content alone is read 6 times.
The milestone window (DAG parse + file reads + budget arithmetic) is computed 6
times with identical results.

This milestone implements a read-once-use-many pattern for shared context within
a single pipeline run.

Depends on Milestone 46 (Instrumentation) to measure the before/after impact.

## Scope

### 1. Startup Context Pre-Read

**File:** `tekhton.sh`

After config load, pre-read and cache in exported shell variables:
- `_CACHED_ARCHITECTURE_CONTENT` — from `ARCHITECTURE_FILE`
- `_CACHED_DRIFT_LOG_CONTENT` — from `DRIFT_LOG_FILE`
- `_CACHED_HUMAN_NOTES_BLOCK` — filtered notes
- `_CACHED_CLARIFICATIONS_CONTENT` — from CLARIFICATIONS.md
- `_CACHED_ARCHITECTURE_LOG_CONTENT` — from `ARCHITECTURE_LOG_FILE`

### 2. Prompt Rendering Integration

**File:** `lib/prompts.sh`

Modify `render_prompt()` to check for `_CACHED_*` variables before reading from
disk. If cached variable is set, use it directly. If not (e.g., during planning
mode where caching isn't initialized), fall back to file read.

### 3. Milestone Window Compute-Once

**File:** `lib/milestone_window.sh`

Compute the milestone window once at startup (and re-compute only after
milestone transitions via `mark_milestone_done`). Export as
`_CACHED_MILESTONE_BLOCK`. Clear the cache variable in `mark_milestone_done()`
to force recomputation.

### 4. Context Compiler Caching

**Files:** `lib/context_compiler.sh`, `lib/context_budget.sh`

- Cache keyword extraction results from task string (computed once, reused by
  context compiler across all agents)
- Cache `_estimate_block_tokens()` results and invalidate only when blocks are
  compressed

## Acceptance Criteria

- Architecture content, drift log, notes, and clarifications are read from disk
  exactly once per pipeline run (verifiable via timing report)
- Milestone window is computed once per milestone, not per agent
- Context budget arithmetic runs once per agent, not 3-5 times
- No behavioral change — identical prompts generated with and without caching
- All existing tests pass
- Timing report shows reduced context assembly time vs. M46 baseline

Tests:
- Cached variables are populated at startup when files exist
- Cached variables are empty when files don't exist (graceful)
- Milestone window cache clears on `mark_milestone_done()`
- Prompt output is byte-identical with and without caching

Watch For:
- If a file is modified DURING a pipeline run (e.g., drift log updated by
  reviewer), the cached version will be stale. For drift log specifically, the
  cache should be invalidated after the review stage appends observations.
- Subshell boundaries: cached variables set in the main shell are visible to
  subshells via `export`, but changes in subshells don't propagate back. This
  is fine for read-only caches.
- Don't cache `CODER_SUMMARY.md` or `REVIEWER_REPORT.md` — these change
  between stages and are only read by the next stage.

Seeds Forward:
- Reduced I/O overhead benefits all subsequent milestones
- Cache pattern can extend to repo map slicing in a future optimization
