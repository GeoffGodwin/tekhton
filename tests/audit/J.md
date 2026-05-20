# Bucket J Audit — orchestrate / diagnose / health / timing / audit / context

Audited 33 tests. Verdict counts: KEEP=25, DELETE-STALE=4, PORT-TO-GO=0, NEEDS-REVIEW=4.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_audit_coverage_gaps.sh | KEEP | Exercises `lib/test_audit.sh:_collect_audit_context` and `_detect_test_weakening`, both live bash (test_audit*.sh files are 75–269 lines of real logic). |
| test_audit_sampler.sh | KEEP | Exercises `lib/test_audit_sampler.sh` (M89 rolling sampler), 148 lines of live bash. |
| test_audit_standalone.sh | KEEP | Exercises `run_standalone_test_audit` + `emit_event` guard in `lib/test_audit.sh`, live bash. |
| test_audit_symbol_orphan.sh | KEEP | Exercises `lib/test_audit_symbols.sh:_detect_stale_symbol_refs` (M88), live bash. |
| test_audit_tests.sh | KEEP | Broad coverage of `lib/test_audit*.sh` — `_collect_audit_context`, `_detect_orphaned_tests`, `_detect_test_weakening`, `_parse_audit_verdict`, `_route_audit_verdict`, `_discover_all_test_files`, rework cycle. All live bash. |
| test_audit_verdict_unknown_catch_all.sh | KEEP | Exercises `lib/test_audit_verdict.sh:_route_audit_verdict` catch-all branch, live bash. |
| test_context_accounting.sh | KEEP | Exercises `lib/context.sh:measure_context_size`, `check_context_budget`, `_add_context_component`, `log_context_report`, plus config defaults — all live bash. |
| test_context_cache.sh | KEEP | Exercises `lib/context_cache.sh` (preload, accessors, invalidation), 223 lines of live bash. |
| test_context_cache_extended.sh | KEEP | Extended `context_cache.sh` tests (prompt consistency, milestone block) — live bash. |
| test_context_compiler.sh | KEEP | Exercises `lib/context_compiler.sh` (`_extract_keywords`, `extract_relevant_sections`, `compress_context`, `_filter_block`, `build_context_packet`, `_compress_if_over_budget`) — live bash. |
| test_context_compiler_cache.sh | KEEP | Exercises keyword caching path in `lib/context_compiler.sh`, live bash. |
| test_diagnose.sh | KEEP | Exercises 18-rule `DIAGNOSE_RULES` registry + `classify_failure_diag` + `emit_dashboard_diagnosis` in `lib/diagnose*.sh` — live bash diagnostic engine (269 lines + rules files). |
| test_diagnose_recovery_command.sh | KEEP | Exercises `_diagnose_recovery_command` in `lib/diagnose.sh`, live bash. |
| test_diagnose_rules_extraction.sh | KEEP | Asserts structural invariants of `lib/diagnose_rules_resilience_preflight.sh` (M133 extraction) — live bash. |
| test_diagnose_rules_resilience.sh | KEEP | Exercises M133 resilience rules in `lib/diagnose_rules_resilience.sh` (UI gate, build-fix exhausted, preflight, mixed, max_turns_env_root) — live bash. |
| test_diagnose_rules_source_numbering.sh | KEEP | Static check on `_rule_build_fix_exhausted` docstring in `lib/diagnose_rules_resilience.sh` — live bash. |
| test_health_cli_flag.sh | KEEP | Exercises `--health` CLI flag end-to-end against `lib/health.sh` (441 lines, all bash). |
| test_health_code_quality.sh | KEEP | Exercises `_check_code_quality` in `lib/health.sh`, live bash. |
| test_health_dashboard.sh | KEEP | Exercises `emit_dashboard_health` in `lib/dashboard.sh` + `get_health_belt` in `lib/health.sh`, live bash. |
| test_health_dependency.sh | KEEP | Exercises `_check_dependency_health` in `lib/health.sh`, live bash. |
| test_health_greenfield_baseline.sh | KEEP | Exercises greenfield code/dependency scoring in `lib/health*.sh`, live bash. |
| test_health_greenfield_fix_coverage.sh | KEEP | Exercises greenfield-scoring fixes in `lib/health.sh`, live bash. |
| test_health_scoring.sh | KEEP | Exercises full health scoring orchestration in `lib/health.sh`, live bash. |
| test_orchestrate.sh | NEEDS-REVIEW | Exercises `_classify_failure`, `_check_progress`, `_compute_diff_hash`, `_hook_emit_run_summary` (already gated for m21 port), `emit_milestone_metadata`. Bash is still callable via tekhton-legacy.sh paths (lines 3031/3048), but Go (`internal/orchestrate/recovery_test.go:TestClassify`, `TestFormatCauseSummary`) covers the same routing — keep until bash `_orch_complete_run` is deleted, then DELETE-STALE. |
| test_orchestrate_helpers_milestone_count.sh | KEEP | Misleadingly named — tests `get_milestone_count` from `lib/milestone_query.sh`, not orchestrate. Live bash. |
| test_orchestrate_integration.sh | NEEDS-REVIEW | Exercises `_orch_complete_run` round-trip (success-on-attempt-2, MAX_PIPELINE_ATTEMPTS, AUTONOMOUS_TIMEOUT). Bash still callable via tekhton-legacy.sh, but Go (`internal/orchestrate/orchestrate_test.go:TestRunAttempt*`) covers all three scenarios. DELETE-STALE once tekhton-legacy.sh stops calling `_orch_complete_run`. |
| test_orchestrate_m12_acceptance.sh | NEEDS-REVIEW | Structural ACs (prohibited filename absence, orchestrate.sh ≤60 lines, _RWR_* absence, default globals). Self-referential to the m12 wedge — useful until the bash orchestrate*.sh files are deleted in a later phase, then becomes vacuous. |
| test_orchestrate_recovery.sh | NEEDS-REVIEW | Exercises M130 causal-context routing in `_classify_failure` + `_print_recovery_block`. Bash still live; Go `internal/orchestrate/recovery_test.go` covers same routing decisions. Same lifecycle as test_orchestrate.sh. |
| test_timing_cache_hits_display.sh | DELETE-STALE | Asserts line-number content in `lib/timing.sh` (lines 238/240). `lib/timing.sh` is sourced by nothing in lib/, stages/, or tekhton*.sh (grep confirms); the canonical TIMING_REPORT.md emitter is `internal/finalize/emit_timing_report.go` with full coverage in `emit_timing_report_test.go`. |
| test_timing_deadcode_removal.sh | DELETE-STALE | Asserts line-number content in dead `lib/timing.sh` (line 138 / sub-phase loop). Same dead-file rationale as test_timing_cache_hits_display.sh. |
| test_timing_helpers.sh | KEEP | Exercises `_phase_start`, `_phase_end`, `_get_phase_duration`, `_format_duration_human` from `lib/common_timing.sh` (sourced by lib/common.sh, used by live stages/tester_timing.sh) — live bash. |
| test_timing_repo_map_stats.sh | DELETE-STALE | Sources `lib/timing.sh` and tests `_hook_emit_timing_report` repo-map stats output. `lib/timing.sh` is dead (no sourcers); Go `internal/finalize/emit_timing_report.go` is canonical and has its own tests. |
| test_timing_report_generation.sh | DELETE-STALE | Sources `lib/timing.sh` and tests bash `_hook_emit_timing_report` output. Superseded by `internal/finalize/emit_timing_report_test.go` (NoSidecarSkips, WritesReportFromSidecar, EmptyPhasesSkips, FormatDurationHuman, PhaseDisplayName). |

## Coverage gaps noted

- `lib/timing.sh` is an orphan file — no caller in lib/, stages/, or any tekhton*.sh sources it. The five orchestrate hooks (`_hook_emit_timing_report` etc.) are now driven by Go's `internal/finalize.Orchestrator`. Consider deleting `lib/timing.sh` outright along with its three stale tests; the `_phase_start`/`_phase_end` runtime helpers live in `lib/common_timing.sh` which remains sourced.
- The four orchestrate NEEDS-REVIEW tests track bash code that is canonically owned by Go but still callable from `tekhton-legacy.sh` (lines 2633, 3023, 3031, 3048). When Phase 5 ports the legacy `--complete` paths to dispatch through `tekhton run --complete`, the entire `lib/orchestrate*.sh` tree (orchestrate_classify.sh 257 lines, orchestrate_complete.sh 212 lines, orchestrate_iteration.sh 286 lines, etc.) becomes deletable and these four tests can be batch-removed in the same milestone.
- `lib/health.sh` (441 lines) is well over the 300-line ceiling but the file declares no Go counterpart. Worth flagging for either an extraction or a Go port milestone.
