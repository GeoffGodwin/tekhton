# Bucket G Audit — coder / build / run

Audited 28 tests. Verdict counts: KEEP=28, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_build_continuation_context.sh | KEEP | Exercises `build_continuation_context()` in live `lib/agent_helpers.sh`; placeholder/recreate logic still bash. |
| test_build_errors_phase2_header.sh | KEEP | Exercises `run_build_gate()` in live `lib/gates.sh` + `lib/gates_phases.sh`; build-gate logic still bash. |
| test_build_fix_helpers.sh | KEEP | Exercises pure helpers `_build_fix_progress_signal` / `_compute_build_fix_budget` in live `stages/coder_buildfix_helpers.sh` (M128). |
| test_build_fix_loop.sh | KEEP | Exercises `run_build_fix_loop()` in live `stages/coder_buildfix.sh` (M128 loop, all-bash). |
| test_build_fix_loop_fixtures_passthrough.sh | KEEP | Verifies the shared `filter_code_errors` stub used by other live build-fix tests; fixtures are still bash. |
| test_build_gate_timeouts.sh | KEEP | Exercises `run_build_gate()` and `_check_headless_browser()` in live `lib/gates.sh` / `lib/gates_ui.sh` / `lib/ui_validate.sh`. |
| test_coder_buildfix_unknown_token_warning.sh | KEEP | Greps `stages/coder_buildfix.sh` for M127 catch-all arm; file still bash. |
| test_coder_buildgate_retry_removed.sh | KEEP | Greps `stages/coder.sh` for absence of legacy `BUILD_GATE_RETRY`; coder stage still bash. |
| test_coder_placeholder_detection.sh | KEEP | Exercises `_reconstruct_coder_summary` + `is_substantive_work` in live `stages/coder.sh`. |
| test_coder_prompt_role_consistency.sh | KEEP | Static checks on `prompts/coder.prompt.md` and `templates/coder.md`; prompts/templates unchanged by V4. |
| test_coder_prompt_scope.sh | KEEP | Static checks on `prompts/coder.prompt.md` content; live artifact. |
| test_coder_role_before_code.sh | KEEP | Static checks on `templates/coder.md`; live artifact. |
| test_coder_role_status_field.sh | KEEP | Static checks on `templates/coder.md`; live artifact. |
| test_coder_role_summary_structure.sh | KEEP | Static checks on `templates/coder.md` CODER_SUMMARY skeleton; live artifact. |
| test_coder_scout_tools_integration.sh | KEEP | Exercises `run_stage_coder()` scout tool reduction (M45) in live `stages/coder.sh`. |
| test_coder_stage_split_wiring.sh | KEEP | Exercises pre-flight + null-run + turn-limit branches in live `stages/coder.sh`; sources milestone_split.sh / milestones.sh (all bash). |
| test_coder_summary_reconstruction.sh | KEEP | Exercises `_reconstruct_coder_summary` in live `stages/coder.sh`. |
| test_coder_tag_execution.sh | KEEP | Tests mirrored helpers for scout-decision / turn-budget logic in `stages/coder.sh`; coder stage still bash. |
| test_run_command.sh | KEEP | Integration smoke for the Go `tekhton run` subcommand (m19); also asserts legacy bash orch files stay deleted — load-bearing for V4 phase gates. |
| test_run_final_checks_test_fix.sh | KEEP | Exercises `run_final_checks()` retry loop in live `lib/hooks_final_checks.sh`; Go orchestrator still calls this as a hook. |
| test_run_memory_emission.sh | KEEP | Already self-skips when `lib/run_memory.sh` missing (m21 deleted it); harmless no-op until cleanup. |
| test_run_memory_keyword_filter.sh | KEEP | Self-skips on missing `lib/run_memory.sh`; safe to leave until coordinated cleanup. |
| test_run_memory_pruning.sh | KEEP | Self-skips on missing `lib/run_memory.sh`; safe to leave. |
| test_run_memory_special_chars.sh | KEEP | Self-skips on missing `lib/run_memory.sh`; safe to leave. |
| test_run_op_lifecycle.sh | KEEP | Exercises `run_op()` + `tui_substage_begin` in live `lib/tui_ops.sh` / `lib/tui_ops_substage.sh` (M104/M115). |
| test_run_tests_output_capture.sh | KEEP | Exercises `run_test()` in live `tests/run_tests.sh` harness; test runner itself is bash. |
| test_run_tests_single_invocation.sh | KEEP | Same `tests/run_tests.sh` `run_test()` regression coverage; bash test runner still live. |
| test_runtime_version_source.sh | KEEP | Exercises `bash ./tekhton.sh --version` reading `VERSION`; dispatcher entry still bash. |

## Coverage gaps noted

- The four `test_run_memory_*.sh` tests already self-skip — they could be either deleted as fully-redundant (parity confirmed by `internal/finalize/emit_run_memory_test.go`) or left until a batch test-suite cleanup. They are not stale in the strict sense because their skip-guards make them safe; they are vestigial.
- `test_run_command.sh` is bash-side smoke for a Go subcommand. The harder parity gate lives in `scripts/run-parity-check.sh` per the comment header; worth confirming that gate is still wired in CI.
- `test_run_op_lifecycle.sh` covers the bash `run_op` substage API thoroughly, but I did not see a Go-side equivalent for the TUI substage protocol — if the TUI sidecar contract ever moves, this becomes a port candidate. Today it is correctly KEEP.
- `test_runtime_version_source.sh` still invokes `bash ./tekhton.sh --version`. Once the bash dispatcher is fully retired this test will need to switch to the Go binary; flagging for the post-dispatcher cleanup pass.
