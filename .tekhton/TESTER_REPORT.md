## Planned Tests
- [x] `tests/test_error_patterns_classify_threshold.sh` — Verify M127 magic literal `60` is now a named constant and used correctly in routing decision
- [x] `tests/test_coder_buildgate_retry_removed.sh` — Verify M128 vestigial BUILD_GATE_RETRY block is removed and build-fix loop owns retry logic
- [x] `tests/test_build_fix_loop_fixtures_passthrough.sh` — Verify M128 filter_code_errors stub passes positional arg, not stdin
- [x] `tests/test_coder_buildfix_unknown_token_warning.sh` — Verify M127 catch-all arm emits warning for unknown routing tokens
- [x] `tests/test_config_defaults_dedup.sh` — Verify BUILD_FIX_REPORT_FILE is only in artifact_defaults.sh, not duplicated
- [x] `tests/test_milestone_split_dag_printf.sh` — Verify M129 echo→printf fix works and prevents flag interpretation
- [x] `tests/test_diagnose_rules_extraction.sh` — Verify M133 extracted preflight rule file is sourced correctly
- [x] `tests/test_diagnose_rules_source_numbering.sh` — Verify M133 _rule_build_fix_exhausted docstring matches evaluation order
- [x] `tests/test_ensure_gitignore_count.sh` — Verify M135 gitignore comment updated from 18 to 20 entries
- [x] `tests/test_resilience_arc_json_escape.sh` — Verify M135/M134 JSON-escaped values are correctly formatted in fixtures
- [x] `tests/test_config_clamp_build_fix_attempts.sh` — Verify M136 _clamp_config_value includes BUILD_FIX_MAX_ATTEMPTS clamp
- [x] `tests/test_init_report_banner_extraction.sh` — Verify M81 extracted init_report_banner_next.sh is sourced and functions work
- [x] `tests/test_draft_milestones_prompt_dead_block.sh` — Verify M80 empty {{IF:DRAFT_SEED_DESCRIPTION}} block is removed
- [x] `tests/test_draft_milestones_count_guard.sh` — Verify M80 DRAFT_MILESTONES_SEED_EXEMPLARS non-integer falls back to default
- [x] `tests/test_tui_render_timings_comment.sh` — Verify POLISH tui_render_timings.py comment describes actual truncation fix
- [x] `tests/test_milestone_split_path_traversal_malicious.sh` — Verify coverage gap: _split_apply_dag rejects malicious sub-milestone titles with path separators

## Test Run Results
Passed: 16  Failed: 0

## Audit Rework

### Summary
Addressed all 8 findings from TEST_AUDIT_REPORT.md (6 HIGH, 2 MEDIUM) in the test suite. All 498 shell tests now pass.

### Findings Fixed

**HIGH Severity (6):**
- [x] Removed `|| true` from `test_no_assignment_in_config_defaults` (test_config_defaults_dedup.sh:34)
- [x] Removed disjunction from `test_artifact_defaults_has_build_fix_report_file` (test_config_defaults_dedup.sh:11)
- [x] Removed `|| true` from `test_no_echo_with_variable` (test_milestone_split_dag_printf.sh:23)
- [x] Removed `|| true` from `test_test_file_also_uses_printf` (test_milestone_split_dag_printf.sh:28)
- [x] Removed `|| true` from `test_no_stale_18_comment` (test_ensure_gitignore_count.sh:16)
- [x] Replaced wrong-assertion `test_dead_block_removed`/`test_endif_block_removed` with correct `test_empty_block_pair_removed` (test_draft_milestones_prompt_dead_block.sh:11,16)

**MEDIUM Severity (2):**
- [x] Rewrote `test_milestone_split_path_traversal_malicious.sh` to actually invoke `_split_apply_dag` with malicious input
- [x] Removed redundant `test_no_silent_fallthrough` from test_coder_buildfix_unknown_token_warning.sh

**LOW Severity (1):**
- [x] Renamed `test_prompt_is_valid_bash` to `test_prompt_file_exists` for accuracy

### Test Results After Rework
- Shell: 498 passed, 0 failed (was 497 passed, 1 failed)
- Python: 250 passed, 14 skipped
- All tests pass

## Bugs Found
None

## Files Modified
- [x] `tests/test_error_patterns_classify_threshold.sh`
- [x] `tests/test_coder_buildgate_retry_removed.sh`
- [x] `tests/test_build_fix_loop_fixtures_passthrough.sh`
- [x] `tests/test_coder_buildfix_unknown_token_warning.sh`
- [x] `tests/test_config_defaults_dedup.sh`
- [x] `tests/test_milestone_split_dag_printf.sh`
- [x] `tests/test_diagnose_rules_extraction.sh`
- [x] `tests/test_diagnose_rules_source_numbering.sh`
- [x] `tests/test_ensure_gitignore_count.sh`
- [x] `tests/test_resilience_arc_json_escape.sh`
- [x] `tests/test_config_clamp_build_fix_attempts.sh`
- [x] `tests/test_init_report_banner_extraction.sh`
- [x] `tests/test_draft_milestones_prompt_dead_block.sh`
- [x] `tests/test_draft_milestones_count_guard.sh`
- [x] `tests/test_tui_render_timings_comment.sh`
- [x] `tests/test_milestone_split_path_traversal_malicious.sh`
