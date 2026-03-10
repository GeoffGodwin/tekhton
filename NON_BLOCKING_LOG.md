# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-10 | "Implement Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection"] `run_plan()` (plan.sh:84) prints "Project type '...' selected" and "Template resolved: ..." after `select_project_type()` already printed both via `success` and `log`. This is redundant output — the user sees the confirmation twice. Consider removing the duplicates from `run_plan()` (lines 99–102) and letting `select_project_type()` be the single source of truth for those messages.
- [ ] [2026-03-10 | "Implement Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection"] `select_project_type()` uses `read -r choice` directly from stdin with no `/dev/tty` fallback. This is fine for the interactive intent, but worth noting: if `--plan` is ever invoked with piped stdin (e.g., scripted testing), it will block silently. Not a problem now, but a natural edge case to handle in Milestone 6's state persistence work.
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
