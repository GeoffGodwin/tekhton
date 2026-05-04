# Milestone 61: Repo Map Cross-Stage Cache
<!-- milestone-meta
id: "61"
status: "done"
-->

## Overview

The tree-sitter repo map is regenerated from scratch for every pipeline stage
(scout, coder, review, tester, architect). Each invocation calls `run_repo_map()`
which spawns `tools/repo_map.py`, runs PageRank, and formats output — even though
the underlying files haven't changed between stages within a single run. Only the
*slice* differs per stage.

This milestone introduces an intra-run repo map cache so the full map is generated
once and sliced per stage without re-invoking the Python tool.

Depends on M56 (last completed milestone) for stable pipeline baseline.

## Scope

### 1. Run-Scoped Map Cache

**File:** `lib/indexer.sh`

After the first successful `run_repo_map()` call, write the full map content to
a run-scoped cache file (e.g., `.claude/logs/${TIMESTAMP}/REPO_MAP_CACHE.md`).
On subsequent calls within the same run:
- Check if cache file exists and `TIMESTAMP` matches the current run
- If cached, load from file instead of invoking Python tool
- If task context differs significantly (different task string), allow optional
  re-generation via a `force_refresh` parameter (function parameter, not config key)

**Implementation note:** Use `TIMESTAMP` (set once at tekhton.sh startup, globally
available) as the run identifier — NOT `_CURRENT_RUN_ID` from causality.sh which
is scoped to that module. The cache file path uses the same LOG_DIR that already
receives agent logs.

**Follow M47 pattern:** Model on `lib/context_cache.sh` conventions:
- Add `_CACHED_REPO_MAP_CONTENT` variable (preloaded after first generation)
- Add `_get_cached_repo_map()` accessor function
- Add `invalidate_repo_map_run_cache()` for explicit invalidation

### 2. Stage-Specific Slicing from Cache

**File:** `lib/indexer.sh`

`get_repo_map_slice()` already operates on the in-memory `REPO_MAP_CONTENT`
variable. Ensure it works identically whether content came from cache or fresh
generation. No changes needed to slice logic itself — only to the source.

**Verify:** When `get_repo_map_slice()` can't match a requested file via any of
its three strategies (exact, suffix, basename), it silently drops that file. This
is acceptable behavior — do NOT add warnings for dropped files as it would be
noisy for normal operation.

### 3. Cache Invalidation

**File:** `lib/indexer.sh`

Add `invalidate_repo_map_run_cache()` — distinct from the existing
`invalidate_repo_map_cache()` (which invalidates the persistent tree-sitter
disk cache in `.claude/index/`). The new function:
- Clears `_CACHED_REPO_MAP_CONTENT`
- Removes the run-scoped cache file
- Next `run_repo_map()` call regenerates from Python tool

The review and tester stages should call this if they detect the coder created
**new** files. Use `extract_files_from_coder_summary()` (already in
`lib/indexer_helpers.sh:129`) to get the file list, then compare against the
cached map's file inventory. If files exist in the summary that are absent from
the cached map, invalidate.

**Do NOT add a separate `detect_new_files_in_coder_summary()` function.** The
existing extraction + comparison is sufficient.

### 4. Skip Regeneration on Review Cycle 2+

**File:** `stages/review.sh`

Review cycles 2+ currently reset `REPO_MAP_CONTENT=""` at line 55 and
regenerate. Since review rework only modifies existing files (not creates new
ones), reuse the cached map and re-slice to the same file list.

**Implementation:** At `review.sh:55`, instead of blanket reset, check:
1. Is `_CACHED_REPO_MAP_CONTENT` populated?
2. Call `extract_files_from_coder_summary()` and compare file count against
   the file list used in cycle 1 (store in a local variable)
3. If same count and no new files → load from cache and re-slice
4. If new files detected → invalidate and regenerate

**File list comparison:** Use sorted basename comparison (not full path match).
Store the cycle-1 file list in `_REVIEW_MAP_FILES` (local to the review stage).

### 5. Milestone Split Invalidation

**File:** `stages/coder.sh`

When `_switch_to_sub_milestone()` runs (coder.sh:245-277), the task scope
narrows. The cached map's PageRank weighting was computed for the original task
and may not be optimal for the sub-milestone. Invalidate the run cache after
milestone split so the sub-task gets a fresh map with correct PageRank bias.

Add `invalidate_repo_map_run_cache` call after `_switch_to_sub_milestone()`.

### 6. Timing Integration

**File:** `lib/indexer.sh`

Track cache hits vs. misses. Add a counter `_REPO_MAP_CACHE_HITS` (integer,
starts at 0). Increment on each cache load; generation count is implicit
(total calls minus hits).

Report in TIMING_REPORT.md (integrate into `lib/timing.sh` display name map):
```
Repo map: 1 generation + 3 cache hits (saved ~Xs)
```

Compute "saved time" as `cache_hits × INDEXER_GENERATION_TIME_MS / 1000` using
the actual generation time recorded from the first (uncached) call. This variable
already exists at `indexer.sh:31-33`.

## Migration Impact

No new config keys required. Cache is automatic and internal. Existing
`REPO_MAP_ENABLED` and `REPO_MAP_TOKEN_BUDGET` settings continue to work
unchanged.

## Acceptance Criteria

- Full repo map generated at most once per run (unless invalidated)
- Subsequent stages load from cache file, not Python tool
- `get_repo_map_slice()` produces identical output from cached vs. fresh content
- Review cycle 2+ reuses cached map without regeneration (when file list unchanged)
- Cache invalidation triggers correctly when coder creates new files
- Cache invalidation triggers on milestone split
- TIMING_REPORT.md shows cache hit/miss statistics
- All existing tests pass
- No measurable difference in prompt content between cached and uncached runs

Tests:
- Cache file written after first `run_repo_map()` call to `LOG_DIR/REPO_MAP_CACHE.md`
- Second call within same run reads from cache (verify no Python invocation)
- `invalidate_repo_map_run_cache()` forces regeneration on next call
- Review cycle 2 reuses map without reset (when no new files)
- Review cycle 2 regenerates when new files detected in CODER_SUMMARY.md
- Different `TIMESTAMP` does not match stale cache from prior run
- Milestone split triggers cache invalidation
- Slice from cached map is byte-identical to slice from fresh map

Watch For:
- The task string passed to `run_repo_map()` affects PageRank weighting. Since
  the scout and coder may pass different task contexts, the cached map should use
  the original task. Slicing handles per-stage relevance — the full map just needs
  to include all files.
- Cache file is written to `LOG_DIR` and cleaned up by existing run log cleanup.
- Ensure `REPO_MAP_CONTENT` export still works correctly for template rendering
  after loading from cache.
- The existing `invalidate_repo_map_cache()` at `indexer.sh:268` invalidates the
  **persistent disk cache** (tree-sitter tags in `.claude/index/`). The new
  `invalidate_repo_map_run_cache()` invalidates the **intra-run content cache**.
  These are distinct — do not conflate them.

Seeds Forward:
- Reduced Python invocations directly cut run time
- Cache hit statistics feed into Watchtower dashboard metrics
