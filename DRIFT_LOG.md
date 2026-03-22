# Drift Log

## Metadata
- Last audit: 2026-03-22
- Runs since audit: 1

## Unresolved Observations

## Resolved
- [RESOLVED 2026-03-22] `lib/milestone_archival.sh:138-171` — `archive_all_completed_milestones` has no DAG path. It discovers done milestones by grepping CLAUDE.md for `#### [DONE] Milestone` markers that do not exist in file-based DAG mode. The per-milestone function `archive_completed_milestone` correctly handles the DAG path; the bulk variant does not. Any caller relying on bulk archival will silently do nothing in DAG mode.
- [RESOLVED 2026-03-22] `lib/milestones.sh` — File has grown beyond 300 lines. The DAG-aware wrapper variants of `get_milestone_count`, `get_milestone_title`, and `is_milestone_done` added this milestone are the primary contributors. Extraction to `lib/milestone_dag_helpers.sh` would bring the file back under the limit. Track for Milestone 2.
- [RESOLVED 2026-03-22] `stages/init_synthesize.sh` — file is 533 lines, exceeding the 300-line ceiling defined in reviewer.md. The coder's changes actually removed a line, so this was not introduced here, but it should be tracked for a future split (e.g., extract `_compress_synthesis_context` and `_synthesize_*` helpers into a `lib/init_synthesize_helpers.sh`).
