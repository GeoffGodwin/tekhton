# Drift Log

## Metadata
- Last audit: 2026-04-08
- Runs since audit: 4

## Unresolved Observations
- [2026-04-08 | "[BUG] Greenfield plan Milestone Summary incorrectly reports "0 milestones" and "No milestone headings found in CLAUDE.md" even when milestones were successfully generated in `.claude/milestones/`. The summary display logic is looking for milestone headings in CLAUDE.md (the old inline location) instead of counting files in the DAG milestone directory. Fix the milestone count and warning message in the plan review/summary display to check the milestone directory when `MILESTONE_DAG_ENABLED` is true."] `lib/plan_milestone_review.sh:40` — direct access to `_DAG_IDS[]` bypasses the DAG public API boundary. All other callers use `dag_get_*` accessors. If the array is renamed, this site won't be caught by a grep for the public API name.

## Resolved
