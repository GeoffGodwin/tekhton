# Bucket D Audit — Project intelligence (detect + indexer)

Audited 29 tests. Verdict counts: KEEP=29, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

All targets live in `lib/detect*.sh`, `lib/indexer*.sh`, and `tools/repo_map.py`. None of these subsystems have been touched by V4 wedges (m01–m22, m26). No Go package under `internal/` re-implements detection or indexing — the only Go references are `internal/stagerunner/helpers.go` whitelisting these `.sh` files for sourcing and `internal/tui/sidecar.go` resolving the `indexer-venv` path. Every function the tests target was confirmed present in `lib/detect*.sh` or `lib/indexer*.sh`.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_detect_ai_artifacts.sh | KEEP | Targets `detect_ai_artifacts`, `classify_ai_tool`, `_scan_for_directive_language`, `_detect_directive_markdowns` — all live in `lib/detect_ai_artifacts.sh`. |
| test_detect_brownfield.sh | KEEP | Exercises `detect_workspaces`, `detect_services`, `detect_ci_config`, `detect_infrastructure`, `detect_test_frameworks`, `assess_doc_quality`, `detect_commands` — all live in bash. |
| test_detect_brownfield_coverage.sh | KEEP | Targets `detect_infrastructure` (Ansible), `detect_workspaces` (pnpm/Nx), `_format_ci_section`, `_generate_smart_config` — all live in `lib/detect_*.sh` + `lib/init_config.sh`. |
| test_detect_claude_md_fallback.sh | KEEP | Tests `detect_languages` CLAUDE.md fallback in live `lib/detect.sh`. |
| test_detect_cleanup.sh | KEEP | Tests `detect_frameworks` lang-label invariant + `_DETECT_EXCLUDE_DIRS` regex escaping in live `lib/detect.sh`. |
| test_detect_commands.sh | KEEP | Exercises `detect_commands` in live `lib/detect_commands.sh`. |
| test_detect_coverage_gaps.sh | KEEP | Tests Cargo `[lib]` + Spring Boot + ASP.NET paths in `detect_project_type` / `detect_frameworks` — all live. |
| test_detect_csharp_sln_only.sh | KEEP | Tests C# detection branch in live `detect_languages` (`lib/detect.sh`). |
| test_detect_entry_points.sh | KEEP | Tests `detect_entry_points` in live `lib/detect_commands.sh`. |
| test_detect_languages.sh | KEEP | Core `detect_languages` + `detect_frameworks` tests against live `lib/detect.sh`. |
| test_detect_languages_edge_cases.sh | KEEP | Covers malformed CLAUDE.md fallback paths in live `detect_languages`. |
| test_detect_languages_fallback_guard.sh | KEEP | Tests fallback-skip-when-files-found guard in live `detect_languages`. |
| test_detect_languages_fallback_prose.sh | KEEP | Tests prose grep fallback in live `detect_languages`. |
| test_detect_languages_multiple_langs.sh | KEEP | Tests multi-language CLAUDE.md bullet parsing in live `detect_languages`. |
| test_detect_project_type.sh | KEEP | Tests `detect_project_type` classification in live `lib/detect_commands.sh`. |
| test_detect_report.sh | KEEP | Tests `format_detection_report` in live `lib/detect_report.sh`. |
| test_detect_ui_framework.sh | KEEP | Tests `detect_ui_framework` in live `lib/detect.sh` (25 cases). |
| test_detect_ui_test_cmd.sh | KEEP | Tests `detect_ui_test_cmd` in live `lib/detect_commands.sh`. |
| test_indexer.sh | KEEP | Tests `validate_indexer_config`, `detect_repo_languages`, `get_repo_map_slice` in live `lib/indexer_helpers.sh` + `lib/indexer.sh`. |
| test_indexer_audit_shell.sh | KEEP | Tests M123 `_indexer_run_startup_audit` in live `lib/indexer_audit.sh`. |
| test_indexer_cache.sh | KEEP | Tests M61 cache helpers (`_save_repo_map_run_cache`, `_load_repo_map_run_cache`, `invalidate_repo_map_run_cache`, `get_repo_map_cache_stats`, `_get_cached_repo_map`) in live `lib/indexer_cache.sh`. |
| test_indexer_emit_stderr_tail.sh | KEEP | Tests M122 `_indexer_emit_stderr_tail` in live `lib/indexer_helpers.sh`. |
| test_indexer_extract_files.sh | KEEP | Tests `extract_files_from_coder_summary` in live `lib/indexer_helpers.sh`. |
| test_indexer_grammar_audit.sh | KEEP | Tests M123 `--audit-grammars` in live `tools/repo_map.py`; gracefully skips when venv absent. |
| test_indexer_history.sh | KEEP | Tests `record_task_file_association`, `_prune_task_history`, `warm_index_cache`, `get_indexer_stats` in live `lib/indexer_history.sh`. |
| test_indexer_infer_counterparts.sh | KEEP | Tests `infer_test_counterparts` in live `lib/indexer_helpers.sh`. |
| test_indexer_line_ceiling.sh | KEEP | Asserts `lib/indexer.sh` stays under the 300-line bash ceiling (CLAUDE.md non-negotiable rule #8); file currently sits at 299 lines. Structural guard, still meaningful. |
| test_indexer_slice_suffix.sh | KEEP | Tests `get_repo_map_slice` basename/suffix matching in live `lib/indexer.sh`. |
| test_indexer_typescript_smoke.sh | KEEP | End-to-end smoke of `run_repo_map` against live Python tooling; skips when grammars unavailable. |

## Coverage gaps noted

- `test_indexer_line_ceiling.sh` is one byte from triggering (`lib/indexer.sh` is at 299 lines vs. the 300 hard ceiling). Any change to that file is one line away from tripping this test — worth flagging during ordinary maintenance.
- No tests appear to cover `lib/detect_workspaces.sh` Gradle Kotlin-DSL (`settings.gradle.kts`) workspace enumeration — only the Groovy `settings.gradle` path is exercised. Not in scope to fix, just noting.
- `lib/detect_doc_quality.sh:assess_doc_quality` only has a coarse high/low score sanity check in `test_detect_brownfield.sh`. The intermediate scoring components (readme/contributing/api-docs/arch-docs/inline-docs breakdown) are not asserted against expected values, even though `_INIT_DOC_QUALITY` consumers depend on the breakdown format.
