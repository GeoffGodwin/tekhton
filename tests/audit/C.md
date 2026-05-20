# Bucket C Audit — milestone / draft / finalize tests

Audited 31 tests. Verdict counts: KEEP=23, DELETE-STALE=2, PORT-TO-GO=2, NEEDS-REVIEW=4.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_draft_milestones_count_guard.sh | KEEP | greps `lib/draft_milestones.sh` for an integer guard; bash file is 228 lines, no Go port (`internal/stagerunner/helpers.go` lists `lib/draft_milestones.sh` as live). |
| test_draft_milestones_next_id.sh | KEEP | Exercises `draft_milestones_next_id()` in `lib/draft_milestones_write.sh` (161 lines, no Go equivalent). |
| test_draft_milestones_prompt_dead_block.sh | KEEP | Sanity check on `prompts/draft_milestones.prompt.md`; prompt is still live bash-side. |
| test_draft_milestones_validate.sh | KEEP | Exercises `draft_milestones_validate_output()` in `lib/draft_milestones_write.sh`, still live. |
| test_draft_milestones_validate_lint.sh | KEEP | Exercises validate + `lib/milestone_acceptance_lint.sh` (182 lines), both still live bash. |
| test_draft_milestones_write_manifest.sh | KEEP | Exercises `draft_milestones_write_manifest()` in `lib/draft_milestones_write.sh`, still live. |
| test_finalize_parity.sh | KEEP | m21 parity gate that drives `tekhton finalize` (Go orchestrator) end-to-end against a fixture; this is the canonical bash-side smoke for the Go port. |
| test_finalize_run.sh | KEEP | Smoke test for the `lib/finalize.sh::finalize_run` shim (48 lines) — verifies it delegates to `tekhton finalize` and that the V3 registry is gone. Exactly the post-m21 contract. |
| test_finalize_shim.sh | KEEP | Verifies `lib/finalize_shim.sh` dispatcher cases cover every named hook the Go orchestrator routes through bash. Live + load-bearing. |
| test_finalize_summary_escaping.sh | DELETE-STALE | `lib/finalize_summary.sh` was deleted in m21; test self-skips via guard. Coverage lives in `internal/finalize/emit_run_summary_test.go`. |
| test_finalize_summary_tester_guard.sh | DELETE-STALE | Same as above — guards on `lib/finalize_summary.sh` existence; file is gone. Test is a permanent SKIP no-op. |
| test_milestone_acceptance_lint.sh | KEEP | Exercises `_lint_*` helpers in `lib/milestone_acceptance_lint.sh` (182 lines, still live bash, no Go port). |
| test_milestone_acceptance_lint_codeblockhash.sh | KEEP | Regression for `_lint_extract_criteria` code-block guard in `lib/milestone_acceptance_lint.sh`. Same live target. |
| test_milestone_active_display.sh | KEEP | Tests `emit_dashboard_milestones` in `lib/dashboard_emitters.sh` — dashboard is still bash. DAG queries via m14 shim are exercised via shim surface. |
| test_milestone_archival.sh | NEEDS-REVIEW | Tests `archive_completed_milestone` / `_extract_milestone_block` / `_get_initiative_name` in `lib/milestone_archival.sh` (221 lines, still live). Bash still owns inline-mode archival (Go `internal/finalize/archive_milestone.go` only ports DAG mode). But m21 moved archival hook into Go for DAG mode — overlap unclear; flag for human. |
| test_milestone_archival_dag_rearchive.sh | NEEDS-REVIEW | Regression for bash DAG re-archival cross-initiative bug. Go `archive_milestone.go` has different gating (status=done + DAG only); whether this regression is reproducible in the Go path is unverified. |
| test_milestone_archival_number_reuse_edge.sh | NEEDS-REVIEW | Edge-case for the same bash archival path. Same overlap concern as above. |
| test_milestone_dag.sh | PORT-TO-GO | Tests m14 shim wrappers (`dag_*`, `validate_manifest`, `migrate_inline_milestones`). The shim still works, but the canonical behavior lives in `internal/dag/` (validate_test.go, migrate_test.go) and `internal/manifest/`. Some coverage gaps remain (e.g. `dag_id_to_number`/`dag_number_to_id` round-trip) — port the gap-fillers to Go and drop the bash. |
| test_milestone_dag_archival_metadata.sh | NEEDS-REVIEW | Mixes DAG archival (Go-ported in m21) with `emit_milestone_metadata` (lib/milestone_metadata.sh — 250 lines, still bash). Live and dead concerns intertwined. |
| test_milestone_dag_coverage.sh | KEEP | Tests `validate_manifest` missing-file branch, `dag_get_active` in-progress path, and `split_milestone` DAG mode. Splitting (`lib/milestone_split.sh`) is still bash; active/validate routes through shim that the Go binary backs. |
| test_milestone_dag_migrate.sh | PORT-TO-GO | Exercises `migrate_inline_milestones` and `_insert_milestone_pointer`, both of which are m13/m14 shims that exec `tekhton dag migrate` / `tekhton dag rewrite-pointer`. Go has `internal/dag/migrate_test.go` with `TestMigrateHappyPath`/`TestMigrateIdempotent`/`TestMigrateMultiDep`/`TestRewritePointer*`. Most coverage duplicates; keep until parity confirmed, then drop. |
| test_milestone_progress_display.sh | KEEP | Tests `_render_milestone_progress` in `lib/milestone_progress.sh` (180 lines) — the `--progress` UI is still bash. |
| test_milestone_query.sh | KEEP | Tests `parse_milestones_auto`/`get_milestone_count`/`get_milestone_title`/`is_milestone_done` in `lib/milestone_query.sh` (145 lines). The shim itself contains real dual-path bash logic (DAG path + inline fallback). |
| test_milestone_shorthand_parsing.sh | KEEP | Self-contained regex test for the milestone shorthand pattern still used at `tekhton-legacy.sh:2139-2140`. No production code is sourced — but the regex remains live in legacy. |
| test_milestone_split.sh | KEEP | Tests `check_milestone_size`/`get_split_depth`/`split_milestone`/`handle_null_run_split` in `lib/milestone_split.sh` (247 lines) — splitting is still bash. |
| test_milestone_split_dag_printf.sh | KEEP | Static grep for `printf` over `echo` security fix in `lib/milestone_split_dag.sh` (173 lines). File still live. |
| test_milestone_split_path_traversal.sh | KEEP | Verifies path-traversal guard in `_split_flush_sub_entry` (lib/milestone_split_dag.sh). Live. |
| test_milestone_split_path_traversal_malicious.sh | KEEP | Same target; malicious-input variant. Live. |
| test_milestone_window.sh | KEEP | Tests `_compute_milestone_budget` and `build_milestone_window` in `lib/milestone_window.sh` (298 lines). Sliding window not yet ported to Go. |
| test_milestones.sh | KEEP | Tests `parse_milestones`/`init_milestone_state`/`advance_milestone`/`find_next_milestone` state machine in `lib/milestones.sh` (281 lines) + `lib/milestone_ops.sh` (292 lines). State machine not ported to Go. |
| test_milestones_flag_smoke.sh | KEEP | Smoke for `--progress`/`--progress --all`/`--progress --deps` via `tekhton.sh` dispatcher; routes through legacy bash for `--progress`. |

## Coverage gaps noted

- `lib/milestone_metadata.sh` (250 lines, `emit_milestone_metadata`) has no dedicated test; only covered indirectly by `test_milestone_dag_archival_metadata.sh` and `test_milestone_active_display.sh`.
- `lib/milestone_progress_helpers.sh` (218 lines) has no direct test — only the higher-level `_render_milestone_progress` is exercised.
- The Go side of m13/m14 (`internal/manifest`, `internal/dag`) already has comprehensive `*_test.go` coverage; the bash DAG tests (`test_milestone_dag.sh`, `test_milestone_dag_migrate.sh`) are increasingly duplicative as the shim becomes thinner — candidates for retirement once the bash shims are deleted in a future milestone.
- The inline-vs-DAG archival overlap (test_milestone_archival* trio) needs explicit human decision: should bash inline-mode archival be removed (per V4 §"V4 wedges remove the bash they replace")?
