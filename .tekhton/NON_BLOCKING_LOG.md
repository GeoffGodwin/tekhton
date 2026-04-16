# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-15 | "Fix 10 failing shell tests. All failures are stale test expectations from the b3b6aff CLI flag refactor. Modify ONLY files under tests/. Run bash run_tests.sh to verify — must exit 0."] `tests/test_review_cache_invalidation.sh` (line 41) and `tests/test_run_memory_emission.sh` (lines 20–22) reference `${TEKHTON_DIR}` without a `:-` default, unlike the other three modified tests which consistently use `${TEKHTON_DIR:-.tekhton}`. With `set -euo pipefail` (`-u`), running either test directly (outside `run_tests.sh`) without TEKHTON_DIR exported would abort immediately with "TEKHTON_DIR: unbound variable". Not blocking given the task specifies `bash run_tests.sh` as the verification path and `run_tests.sh` was also modified, but the inconsistency is worth hardening.
- [ ] [2026-04-15 | "Fix 10 failing shell tests. All failures are stale test expectations from the b3b6aff CLI flag refactor. Modify ONLY files under tests/. Run bash run_tests.sh to verify — must exit 0."] CODER_SUMMARY.md lists 5 modified files but `tests/run_tests.sh` also appears modified in git status and is not mentioned. Whether it exports TEKHTON_DIR (which the two tests above depend on) is undocumented. Future reviewers will not know why those tests are not self-contained.
- [ ] [2026-04-15 | "M88"] All M88 acceptance criteria verified: `emit_test_symbol_map`, `_detect_stale_symbol_refs`, `--emit-test-map` flag, `TEST_SYMBOL_MAP_FILE` export, noise filtering, and gating on `REPO_MAP_ENABLED` are all correctly implemented.
- [ ] [2026-04-15 | "M88"] Python tests (`TestEmitTestMap`) pass. Shell tests (`test_audit_symbol_orphan.sh`) pass.
- [ ] [2026-04-15 | "M88"] Shellcheck clean on all modified lib files.
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh` hardcodes the literal string `.tekhton/` in its pattern check rather than using a dynamic `${TEKHTON_DIR}` reference. If TEKHTON_DIR is ever changed to a non-default value, the test would produce false failures. Low probability in practice, but the fragility is worth noting.
- [ ] [2026-04-14 | "M87"] CODER_SUMMARY.md was deleted (old M86 content) but not regenerated for M87. The review proceeded from git diff and the milestone spec. Not a code defect, but the missing summary is a process gap.
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh:62` — The `NOT_PATHS` exclusion of `POLISH_LOGIC_FILE_PATTERNS` is dead code: the variable name ends in `_PATTERNS`, not `_FILE`, so `grep '_FILE$'` never matches it. The exclusion entry does no harm but is misleading.
- [ ] [2026-04-14 | "M87"] `tests/test_tekhton_dir_root_cleanliness.sh:75` — The pass condition `[[ "$value" == .tekhton/* ]]` compares against the literal string `.tekhton/` rather than `${TEKHTON_DIR}/`. If TEKHTON_DIR is ever customized to a non-default value this would produce false negatives, but the test's intent (check defaults, not runtime config) makes this acceptable.
- [ ] [2026-04-14 | "M84"] `lib/milestone_progress.sh:159-165` — pre-existing LOW security finding (not introduced by M84): `_diagnose_recovery_command` embeds `$milestone` and `$task` verbatim into a displayed command string; double-quotes in those fields would produce a syntactically broken suggestion. No injection risk (output is echoed, not eval'd). Fix in a cleanup pass: `milestone="${milestone//"/\"}"`.
- [ ] [2026-04-13 | "M83"] `_vc_is_noop_cmd()` regex `': $'` won't match bare `:` (colon without trailing space). Minor edge case unlikely to bite in practice. Carried from cycle 1.
- [ ] [2026-04-13 | "M82"] `_render_progress_bar` (milestone_progress_helpers.sh:176–180) still forks a subshell for every bar character — 40+ forks per render. Correct, low priority given display-only context; a `printf -v` approach would be faster.

## Resolved
