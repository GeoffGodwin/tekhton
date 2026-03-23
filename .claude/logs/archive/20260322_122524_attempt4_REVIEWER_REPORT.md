# Reviewer Report — Milestone 2: Sliding Window & Plan Generation Integration

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `test_startup_auto_migrate.sh` does not set `MILESTONE_DIR` explicitly (unlike `test_milestone_window.sh` and `test_milestone_dag_migrate.sh` which both set `MILESTONE_DIR=".claude/milestones"`). The test relies on `_dag_milestone_dir()`'s internal default. This is benign but inconsistent — add `MILESTONE_DIR=".claude/milestones"` to the config stubs block at the top of `test_startup_auto_migrate.sh` for consistency.
- In `build_milestone_window()`, when a frontier milestone's title alone exceeds the remaining character budget, it is silently dropped (`break` at lines 248-251). The active milestone path logs a warning on truncation; frontier omission should too. A single `warn "[milestone_window] Frontier milestone ${id} omitted — budget exhausted"` before the break would match the observability pattern already used for active truncation.
- `_extract_title_line()` uses `echo "$first_line"` (line 152) rather than `printf '%s\n' "$first_line"`. While milestone titles are controlled content, `echo` interprets `-e`, `-n`, and backslash sequences on some systems. Low risk, but `printf '%s\n'` is the project's preferred pattern.

## Coverage Gaps
- No integration test for the `run_plan_generate()` post-processing path — `migrate_inline_milestones()` is tested in isolation, but the full `stages/plan_generate.sh` code path (agent output → write CLAUDE.md → call migrate_inline_milestones → insert pointer) has no end-to-end test. If `parse_milestones()` changes its exit-code semantics, this path could silently skip extraction.
- `_run_auto_advance_chain()` DAG-aware ordering is mentioned as verified in CODER_SUMMARY.md but no new test covers it. The existing orchestrate_helpers tests (if any) should be confirmed to exercise the DAG path.

## Drift Observations
- `stages/plan_generate.sh` line 97 constructs `milestone_dir` as `${PROJECT_DIR}/${MILESTONE_DIR:-.claude/milestones}`. Since `--plan` bypasses `load_config()`, `MILESTONE_DIR` is unset and the default is used, so this is correct in practice. However, if `MILESTONE_DIR` is ever set to an absolute path in the environment before `--plan` is invoked (e.g., by a wrapper script), the path would double-prepend `PROJECT_DIR`. A guard like `if [[ "${MILESTONE_DIR:-}" != /* ]]; then milestone_dir="${PROJECT_DIR}/..."; else milestone_dir="$MILESTONE_DIR"; fi` would be more robust and consistent with the pattern in `lib/config.sh` lines 155–157.
