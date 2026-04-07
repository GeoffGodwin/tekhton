#### Milestone 7: Cross-Run Cache & Personalized Ranking
<!-- milestone-meta
id: "7"
status: "done"
-->

Make the indexer persistent and adaptive across pipeline runs. The tag cache
survives between runs with mtime-based invalidation. Task→file association
history improves PageRank personalization over time — files that were relevant
to similar past tasks rank higher automatically. Integrate with v2's metrics
system for tracking indexer performance.

Files to modify:
- `tools/repo_map.py` — add `--history-file <path>` flag. When provided, load
  task→file association records and use them to build a personalization vector
  that blends: (1) task keyword matches (current behavior, weight 0.6),
  (2) historical file relevance from similar past tasks (weight 0.3),
  (3) file recency from git log (weight 0.1). Add `--warm-cache` flag that
  parses all project files and populates the tag cache without producing output
  (for use during `tekhton --init`).
- `tools/tag_cache.py` — add cache statistics: hit count, miss count, total
  parse time saved. Add `prune_cache(root_dir)` that removes entries for files
  that no longer exist. Add cache versioning — if cache format changes between
  Tekhton versions, invalidate and rebuild rather than crash.
- `lib/indexer.sh` — add `warm_index_cache()` (called during `--init` or
  `--setup-indexer`), `record_task_file_association(task, files[])` (called
  after coder stage with the files from CODER_SUMMARY.md),
  `get_indexer_stats()` (returns cache hit rate and timing for metrics).
  History file: `.claude/index/task_history.jsonl` (append-only JSONL, same
  pattern as v2 metrics).
- `lib/metrics.sh` — add indexer metrics to `record_run_metrics()`: cache hit
  rate, repo map generation time, token savings vs full architecture injection.
  Add indexer section to `summarize_metrics()` dashboard output.
- `stages/coder.sh` — after coder completes, call
  `record_task_file_association()` with the task and modified file list.
- `tekhton.sh` — during `--init`, if indexer is available, call
  `warm_index_cache()` to pre-populate the tag cache. Display progress.
- `templates/pipeline.conf.example` — add `REPO_MAP_HISTORY_ENABLED=true`,
  `REPO_MAP_HISTORY_MAX_RECORDS=200` config keys

History record format (JSONL):
```json
{"ts":"2026-03-21T10:00:00Z","task":"add user authentication","files":["src/auth/login.py","src/models/user.py","src/api/routes.py"],"task_type":"feature"}
```

Acceptance criteria:
- Tag cache persists between runs in `.claude/index/tags.json`
- Changed files (new mtime) are re-parsed; unchanged files use cache
- Deleted files are pruned from cache on next run
- `--warm-cache` pre-populates the entire project cache in one pass
- Task→file history is recorded after each successful coder stage
- Personalization vector blends keyword, history, and recency signals
- With 10+ history records, the repo map noticeably favors files that were
  relevant to similar past tasks (measurable in ranking output)
- `REPO_MAP_HISTORY_MAX_RECORDS` caps history file size (oldest records pruned)
- Indexer metrics appear in `tekhton --metrics` dashboard
- Cache version mismatch triggers rebuild with warning, not crash
- All existing tests pass
- New Python tests verify: history loading, personalization blending, cache
  pruning, version migration, JSONL append safety

Watch For:
- JSONL is append-only by design. Never read-modify-write. Pruning creates a
  new file and atomically replaces the old one.
- Task similarity is keyword-based (bag of words overlap), not semantic. Keep
  it simple — semantic similarity would require embeddings and adds complexity
  and cost for marginal gain at this stage.
- Git recency signal requires a git repo. For non-git projects, drop weight 0.1
  and redistribute to keywords (0.7) and history (0.3).
- History file can contain sensitive task descriptions. It lives in `.claude/`
  which should be gitignored, but add a warning to the setup output.
- Cache warming on large projects (10k+ files) may take 30-60 seconds. Show
  a progress bar or periodic status line.

Seeds Forward:
- Future v3 milestones (parallel execution) can use task→file history to
  predict which milestones will touch overlapping files and schedule them
  to avoid merge conflicts
- The metrics integration provides data for future adaptive token budgeting —
  if the indexer consistently saves 70% of tokens, the pipeline can allocate
  the savings to richer prompt content
