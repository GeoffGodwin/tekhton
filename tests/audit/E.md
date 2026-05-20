# Bucket E Audit — config, init, preflight

Audited 31 tests. Verdict counts: KEEP=23, DELETE-STALE=5, PORT-TO-GO=2, NEEDS-REVIEW=1.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_config.sh | KEEP | Already m16-adapted; smoke-tests the `tekhton config load` shim round trip and SKIPs cleanly if the binary is unbuilt. |
| test_config_annotations.sh | KEEP | Targets `lib/init_config_emitters.sh`/`init_config_sections.sh` `_emit_command_line`/`generate_sectioned_config` — still bash, init-time emitter logic. |
| test_config_clamp_build_fix_attempts.sh | KEEP | Already m16-adapted; drives the Go loader for `BUILD_FIX_MAX_ATTEMPTS` clamp. Complements `TestClamp_IntegerExceedsCap`. |
| test_config_defaults_claude_standard_model.sh | DELETE-STALE | Sources `lib/config_defaults.sh` (shim execs `tekhton config defaults`) and asserts bash `:=` derivation semantics + greps for old `:-` fallbacks that no longer exist; `TestDefaults_Derived` covers the model-derivation behavior in Go. |
| test_config_defaults_dedup.sh | DELETE-STALE | Greps `lib/config_defaults.sh` (45-line shim) for `BUILD_FIX_REPORT_FILE` absence and `artifact_defaults.sh` for presence — the original 250-line defaults file is gone; the dedup invariant is now enforced by the single Go defaults table (`internal/config/defaults.go`). |
| test_config_leading_dot_float.sh | KEEP | Already m16-adapted; smoke-checks the loader on leading-dot/negative floats. SKIPs if binary unbuilt. |
| test_config_loading.sh | KEEP | End-to-end check: writes a pipeline.conf, sources `lib/config.sh`, calls `load_config`. Drives the m16 shim and validates the surface contract callers depend on. |
| test_config_reviewer_model.sh | KEEP | Same as above — sources the shim and asserts `CLAUDE_REVIEWER_MODEL` derivation/override behavior end-to-end through the loader. |
| test_config_validation_failures.sh | KEEP | Drives `load_config` through the shim and asserts exit-1 on missing required keys — complements `TestLoad_MissingRequired` by exercising the bash entry path. |
| test_init_addenda_dedup.sh | KEEP | Exercises `_append_addenda` in `lib/init.sh` — still bash, init-time agent role assembly. |
| test_init_design_file_autoset.sh | KEEP | End-to-end `tekhton.sh --init` invocation; `lib/init*.sh` still live. |
| test_init_merge_preserved.sh | KEEP | Targets `_merge_preserved_values` in `lib/init_config.sh` — still bash. |
| test_init_recommendation.sh | KEEP | Targets `_init_pick_recommendation`/`emit_init_summary`/`_init_render_files_written` in `lib/init_report_banner.sh` — still bash. |
| test_init_report_architecture_config.sh | KEEP | Targets `emit_init_summary`/`_report_attention_items`/`emit_init_report_file` in `lib/init_report.sh` — still bash. |
| test_init_report_banner_extraction.sh | KEEP | Structural check that `init_report_banner_next.sh` exists, is sourced, and parent is <300 lines — still relevant to the live bash file. |
| test_init_report_dashboard_compat.sh | KEEP | Round-trips `emit_init_report_file` → `emit_dashboard_init`; `lib/init_report.sh` + `lib/dashboard_emitters.sh` both still bash. |
| test_init_report_greenfield_suppression.sh | KEEP | Exercises greenfield-suppression branches in `lib/init_report.sh` — still bash. |
| test_init_report_stub_detection.sh | KEEP | Self-contained pattern test for the `<!-- TODO:.*--plan` matcher used in `lib/init_report.sh:130` — still relevant. |
| test_init_scaffold.sh | KEEP | Full `tekhton.sh --init` end-to-end scaffold check — bash init path still primary. |
| test_init_smart_config.sh | KEEP | Targets `_generate_smart_config` + `_detect_required_tools` in `lib/init_config.sh` — still bash. |
| test_init_smart_init.sh | KEEP | Full `tekhton.sh --init` integration with fixture projects (Node/Rust/Python) — still bash. |
| test_init_synthesize.sh | KEEP | Exercises `stages/init_synthesize.sh` helpers + prompt structure — still bash. |
| test_init_synthesize_marker_appending.sh | KEEP | Drives `_synthesize_claude` in `stages/init_synthesize.sh` — still bash. |
| test_init_synthesize_preamble_trim.sh | KEEP | Drives `_synthesize_design`/`_synthesize_claude` preamble trimming — still bash. |
| test_init_wizard.sh | KEEP | Targets `run_feature_wizard`/`_emit_section_features` in `lib/init_wizard.sh`/`init_config_sections.sh` — still bash. |
| test_init_wizard_attention_lines.sh | KEEP | Direct unit test of `_wizard_attention_lines` in `lib/init_wizard.sh` — still bash. |
| test_preflight.sh | DELETE-STALE | Already a skip-stub (echoes "SKIPPED: superseded by internal/preflight/*_test.go"); harness preserves filename for pass count, scheduled for removal per its own header. |
| test_preflight_fix.sh | NEEDS-REVIEW | Tests `_try_preflight_fix` in `lib/orchestrate_preflight.sh` — confusingly named but unrelated to the deleted m22 preflight env scanner; it is the orchestrate-loop pre-finalization fix retry, still live bash. However the test also sources `lib/config_defaults.sh` (shim) and asserts bash-defined `PREFLIGHT_FIX_*` defaults — those values now come from the Go defaults table at shim-eval time. Behavior may pass with binary built but the assertion is fragile; flag for human. |
| test_preflight_infer_degenerate.sh | DELETE-STALE | Already a skip-stub for the deleted `_pf_infer_from_compose` helper; Go coverage in `services_infer_test.go`. |
| test_preflight_parity.sh | PORT-TO-GO | Drives the new `tekhton preflight` binary against frozen fixtures and diffs `PREFLIGHT_REPORT.md` — this is exactly the kind of golden-file parity gate that should live under `internal/preflight` or `cmd/tekhton` as a Go integration test (currently bash; m22 calls it Goal-7 parity). Functional today, but native Go would survive the Phase-5 "no .sh in lib/stages" end state. |
| test_preflight_ui_config.sh | DELETE-STALE | Already a skip-stub for the deleted `lib/preflight_checks_ui.sh`; Go coverage in `ui_audit_test.go`. |

## Coverage gaps noted

- `test_preflight_parity.sh` is currently the only end-to-end parity gate for the m22 preflight port and lives as a bash test that shells out to the Go binary. It would be more durable as a Go integration test under `cmd/tekhton/` or `internal/preflight/` using the same `testdata/preflight_parity` fixtures (already in repo).
- The three preflight skip-stubs (`test_preflight.sh`, `test_preflight_infer_degenerate.sh`, `test_preflight_ui_config.sh`) each self-document their intended deletion once `tests/run_tests.sh` is updated to not require the filenames — that cleanup is still pending.
- `test_config_defaults_claude_standard_model.sh` and `test_config_defaults_dedup.sh` are the only remaining tests that directly grep / source `lib/config_defaults.sh` for assignment semantics. With the bash file reduced to a 45-line shim, both tests now assert properties of the *Go* defaults table indirectly; if the shim's behavior on a missing `tekhton` binary changes (currently silent no-op), both tests would break in non-obvious ways.
- `test_preflight_fix.sh` lives in the bucket because of its name but actually exercises `lib/orchestrate_preflight.sh` (orchestrate loop), not the m22 preflight subsystem. Worth renaming during a future tidy pass to avoid the confusion.
