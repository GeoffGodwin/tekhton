# Reviewer Report — m41

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
None

## Simple Blockers (jr coder)
None

## Non-Blocking Notes
- `lib/finalize_commit.sh` is at 287 lines — within the 300-line ceiling but a single future addition will breach it. Consider extracting `_do_git_commit` or the bookkeeping helpers into a `finalize_commit_helpers.sh` before the next touch.
- `stages/coder.sh` is at 1202 lines — far over the 300-line bash ceiling. This is a pre-existing debt (predates m41); the m41 change was a minimal two-warn-lines-and-remove-call edit. Flag for a dedicated refactor milestone.

## Coverage Gaps
None

## Drift Observations
- `stages/coder.sh:1202` — The file has ballooned well past the 300-line ceiling through accumulated sub-stage sourcing and feature accretion. The scout / build-fix sub-stages have their own files (`coder_prerun.sh`, `coder_buildfix.sh`) but `run_stage_coder` itself has not been split. A dedicated refactor milestone to extract `_run_coder_milestone_setup`, `_run_coder_main`, and `_run_coder_gates` into companion files would bring this back under control.
- `lib/finalize_commit.sh:_run_commit_bookkeeping` — execs a `tekhton commit-bookkeeping` subcommand that is not listed in the Architecture Map's Cobra subcommand inventory. If this was added after m21, the architecture map entry should be updated to document it.

---

## Verification Summary

All three m41 goals are present and correct in the already-shipped code (commit `74652dc`):

**Goal 1 — Dotted-id resolution + bold-label support**
- `lib/milestone_window.sh:74`: `^[0-9]+(\.[0-9]+)?$` regex correctly handles dotted IDs like `49.2` and `40.1`.
- `lib/milestone_window.sh:110-153` (`_read_milestone_file`): DAG-path wins with glob fallback for `<id>-*.md` and zero-padded variants. `shopt -s nullglob` prevents phantom literal expansions.
- `lib/milestone_window_build.sh:112` (`_extract_first_paragraph_and_acceptance`): regex `(#+[[:space:]]+|\*\*)?` matches both `## Acceptance Criteria` and `**Acceptance Criteria:**`. `Watch For` / `Seeds Forward` are explicitly exempted from the heading-end check at line 123.

**Goal 2 — Block-unavailable is non-fatal**
- `stages/coder.sh:256-262`: `set_focused_milestone_block` failure emits two `warn` lines and falls through; no `trip_commit_gate` call.
- Grep over `stages/` and `lib/` for `trip_commit_gate.*milestone_block_unavailable`: zero matches in production code (only appears in test assertions confirming its absence).
- Existing hollow-run gates (`coder_did_not_produce_summary`, `completion_gate_failed_substantive_work_only`, `reviewer_did_not_produce_report`, `tester_did_not_produce_report`) remain untouched.

**Goal 3 — Honest single-line diagnostic**
- `lib/finalize_commit_sentinel.sh:41-53` (`_final_check_reason_read`): reads line 2 of `.final_check_result`, strips `# ` prefix, trims whitespace.
- `lib/finalize_commit.sh:183-198` (`_hook_commit`): calls `_final_check_reason_read` and prints `Commit blocked: <reason> (see .tekhton/.final_check_result)`. The contradictory `FINAL_CHECK_RESULT=0 / persisted=1` string is demoted to `log_verbose` only.

**Test files**: `tests/test_milestone_window_focused.sh`, `tests/test_coder_block_unavailable_gate.sh`, and `tests/test_finalize_commit_block_reason.sh` are all present on disk. The coder reports 504 shell PASS / 0 FAIL.
