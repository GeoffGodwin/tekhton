# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-23 | "Implement Milestone 7: Cross-Run Cache & Personalized Ranking and then continue to other milestones afterwards."] `lib/indexer.sh:7-9` — The `Provides:` comment still lists `warm_index_cache()`, `record_task_file_association()`, `get_indexer_stats()` as if they live in this file. They were correctly extracted to `indexer_history.sh`. Update the comment to say "See also: indexer_history.sh for warm_index_cache, record_task_file_association, get_indexer_stats."
- [ ] [2026-03-23 | "Implement Milestone 7: Cross-Run Cache & Personalized Ranking and then continue to other milestones afterwards."] `lib/indexer_history.sh:128-133` — Task classification duplicates `_classify_task_type()` from `metrics.sh` with a slightly narrower bug pattern (missing `regression|broken|crash`). A "regression" task would be classified "feature" in history but "bug" in metrics. Consider delegating to `_classify_task_type` or documenting the intentional difference.
- [ ] [2026-03-23 | "Implement Milestone 7: Cross-Run Cache & Personalized Ranking and then continue to other milestones afterwards."] `lib/indexer_history.sh:72` — `warm_index_cache()` passes `--stats` to `repo_map.py` but the while-loop filter discards all output not prefixed with `[indexer]`, so stats JSON on stderr is silently dropped. Drop the `--stats` flag from the warm-cache invocation or capture it explicitly.

## Resolved
