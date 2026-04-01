# Milestone 49: Structured Run Memory
<!-- milestone-meta
id: "49"
status: "pending"
-->

## Overview

Cross-run context injection currently relies on grep-scanning the causal event
log (JSONL) with bash string operations — slow for large logs and imprecise for
relevance matching. This milestone introduces a structured run-end summary
(`RUN_MEMORY.jsonl`) that captures decisions, outcomes, and file associations
in a format optimized for keyword-based retrieval on subsequent runs.

Depends on Milestone 46 (Instrumentation) for timing data to include in memory
records and Milestone 47 (Context Cache) for the caching patterns.

## Scope

### 1. Run Memory Emission

**File:** `lib/finalize_summary.sh`

At run end, append a structured record to `RUN_MEMORY.jsonl`:

```json
{
  "run_id": "run_20260331_143022",
  "milestone": "m43",
  "task": "Make Scout identify affected test files",
  "files_touched": ["prompts/scout.prompt.md", "stages/coder.sh"],
  "decisions": ["Added Affected Test Files section to Scout report format"],
  "rework_reasons": ["Missing test baseline injection in coder prompt"],
  "test_outcomes": {"passed": 47, "failed": 0, "skipped": 2},
  "duration_seconds": 387,
  "agent_calls": 5,
  "verdict": "PASS"
}
```

### 2. INTAKE_HISTORY_BLOCK from Structured Memory

**File:** `lib/prompts.sh`

On next run, build `INTAKE_HISTORY_BLOCK` by reading the last N entries from
`RUN_MEMORY.jsonl` filtered by keyword relevance to the current task. Keyword
matching uses simple bash string operations — word overlap between task
descriptions and stored tasks/files.

### 3. Memory Pruning

**File:** `lib/config_defaults.sh`

Add `RUN_MEMORY_MAX_ENTRIES` (default: 50). When the file exceeds this count,
prune oldest entries (FIFO). The file stays small enough for instant bash
processing.

## Acceptance Criteria

- `RUN_MEMORY.jsonl` is emitted at every run end
- Next run's `INTAKE_HISTORY_BLOCK` is built from structured memory
- Keyword relevance filtering produces useful context for related tasks
- Memory file stays under 50 entries (auto-pruned)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

Tests:
- Memory record is appended correctly with all required fields
- Keyword filtering returns relevant entries (task word overlap > threshold)
- Pruning removes oldest entries when limit exceeded
- Empty memory file doesn't cause errors
- `INTAKE_HISTORY_BLOCK` is populated in prompt templates

Watch For:
- JSON construction in bash is fragile — use the same `_json_escape()` pattern
  from `lib/causality.sh` for string escaping.
- `decisions` and `rework_reasons` fields must be extracted from agent outputs
  (CODER_SUMMARY.md, REVIEWER_REPORT.md). This extraction should be
  best-effort — missing fields produce empty arrays, not errors.
- Keyword matching should be case-insensitive and ignore common stop words.

Seeds Forward:
- If structured keyword matching proves insufficient, a future v4.0 milestone
  could add optional vector-augmented retrieval (Qdrant/ChromaDB)
- Memory records feed into future adaptive calibration improvements
