# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-22 | "Implement Milestone 1: Milestone DAG Infrastructure"] `lib/milestone_split.sh` header comment lists dependencies as "milestones.sh, milestone_archival.sh" but the DAG-aware split path calls `_slugify()` which is defined in `milestone_dag_migrate.sh`. Add `milestone_dag_migrate.sh` to the sourced-first list in the header. (No runtime risk — sourcing order in tekhton.sh is correct; documentation gap only.)
- [ ] [2026-03-22 | "Implement Milestone 1: Milestone DAG Infrastructure"] `milestone_dag_validate.sh` relies on bash dynamic scoping to make `declare -A _visited` and `_in_stack` visible inside the nested `_dfs_cycle_check` function. This is correct bash behaviour but non-obvious. A brief comment explaining "declared in validate_manifest, visible via dynamic scoping" would help future maintainers.
- [ ] [2026-03-21 | "Resolve all observations in NON_BLOCKING_LOG.md. For each unresolved item, apply the fix, then mark it resolved. Continue until no unresolved observations remain."] `stages/init_synthesize.sh` is 533 lines — well over the 300-line ceiling. Pre-existing from Milestone 21, not introduced here, but a cleanup pass was a natural opportunity to split it.

## Resolved
