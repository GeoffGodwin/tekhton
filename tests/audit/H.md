# Bucket H Audit — platform adapters, UI gate/validation, nonblocking log, drift

Audited 34 tests. Verdict counts: KEEP=34, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

None of the four subsystems in this bucket have been touched by a V4 wedge.
Platform adapters (`platforms/{_base.sh, _universal/, web/, mobile_*, game_*}/`)
are live data files + shell helpers. UI gate logic (`lib/gates_ui*.sh`,
`lib/ui_validate*.sh`) is fully bash. The drift subsystem (`lib/drift.sh`,
`lib/drift_artifacts.sh`, `lib/drift_cleanup.sh`, `lib/drift_prune.sh`)
is fully bash. The "nonblocking" tests target a mix of live bash (drift
artifacts pipeline, `lib/init_wizard.sh`, `lib/pipeline_order.sh`,
`lib/dashboard_emitters.sh`, `lib/ui_validate*.sh`) — they are not a
separate subsystem. Two tests reach through the m15 prompt-shim and m16
config-shim, but they exercise live drift template content and live drift
default values respectively, so the assertion is still meaningful (now an
integration test against the Go engines). One test
(`test_nonblocking_log_fixes.sh`) has already been retro-fitted for m21:
its Fix #23 and #24 explicitly check Go-side coverage at
`internal/finalize/orchestrator{,_test}.go`, so it correctly straddles
both worlds.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_drift_cleanup.sh | KEEP | Exercises `clear_completed_nonblocking_notes` / `get_completed_nonblocking_notes` / `clear_resolved_drift_observations` / `get_resolved_drift_observations` in `lib/drift_cleanup.sh` — live bash (342 lines). |
| test_drift_config.sh | KEEP | Verifies drift default values (`DRIFT_LOG_FILE`, `DRIFT_OBSERVATION_THRESHOLD`, etc.) via `load_config`; now an integration test against the m16 Go config loader through the bash shim — defaults still emitted, behavior preserved. |
| test_drift_management.sh | KEEP | Exercises `_ensure_drift_log`, `count_drift_observations`, `append_drift_observations`, ADL helpers, human-action helpers in `lib/drift.sh` + `lib/drift_artifacts.sh` — live bash. |
| test_drift_prompts.sh | KEEP | Greps rendered ACP/Drift sections from `coder`, `reviewer`, `coder_rework`, `jr_coder` prompt templates; renders via `render_prompt` (m15 Go engine shim) but the live `prompts/*.prompt.md` content under test is unchanged. |
| test_drift_prune_realistic.sh | KEEP | Exercises `prune_resolved_drift_entries` in `lib/drift_prune.sh` — live bash (105 lines). |
| test_drift_resolution_architecture_doc.sh | KEEP | Greps `ARCHITECTURE.md` for documentation of the 5 tester sub-stages — `ARCHITECTURE.md` and all `stages/tester_*.sh` files are live. |
| test_drift_resolution_sourcing_convention.sh | KEEP | Greps `tekhton-legacy.sh` for the "tester sub-stages" sourcing convention comment + verifies `stages/tester_*.sh` files exist and parse — all targets live (tekhton-legacy.sh is 3090 lines, has the comment). |
| test_nonblock_init_array_ownership.sh | KEEP | Pure-bash unit test of the `_INIT_FILES_WRITTEN` signal-conditional append pattern in `lib/init.sh` — live bash. |
| test_nonblock_return_propagation.sh | KEEP | Exercises `_wizard_run_setup_script` exit-code propagation in `lib/init_wizard.sh` — live bash (230 lines). |
| test_nonblock_serena_log.sh | KEEP | Exercises `_run_wizard_venv_setup` separate-log behavior in `lib/init_wizard.sh` — live bash. |
| test_nonblock_stage_label_consistency.sh | KEEP | Exercises `get_display_stage_order` + `get_stage_display_label` in `lib/pipeline_order.sh` — live bash (240 lines). |
| test_nonblock_tui_stage_guards.sh | KEEP | Exercises `should_run_stage` in `lib/pipeline_order.sh` — live bash. |
| test_nonblock_wizard_signal.sh | KEEP | Exercises `_WIZARD_VENV_CREATED` export + `_wizard_reset_state` in `lib/init_wizard.sh` — live bash. |
| test_nonblocking_dashboard_emitters.sh | KEEP | Greps `lib/dashboard_emitters.sh:162` for the `dep_arr` local declaration — file is live (684 lines, dashboard is still bash). |
| test_nonblocking_log_fixes.sh | KEEP | 26-fix regression sweep across live bash files (dashboard, diagnose, finalize_*, state.sh, health_checks, detect_ci, prompts/security_rework, templates/watchtower); Fix #23 + #24 already retro-fitted for m21 to check `internal/finalize/orchestrator{,_test}.go` — file straddles bash + Go correctly. |
| test_nonblocking_no_feedback_loop.sh | KEEP | Exercises `FIX_NONBLOCKERS_MODE` / `FIX_DRIFT_MODE` suppression in `process_drift_artifacts` (`lib/drift_artifacts.sh`) — live bash. |
| test_nonblocking_notes.sh | KEEP | Exercises `_ensure_nonblocking_log`, `append_nonblocking_notes`, `_resolve_addressed_nonblocking_notes`, `count_open_nonblocking_notes` in `lib/drift.sh` + `lib/drift_cleanup.sh` — live bash. |
| test_nonblocking_ui_validate.sh | KEEP | Greps `lib/ui_validate.sh` for single `set -euo pipefail` — file is live (602 lines). |
| test_nonblocking_ui_validate_report.sh | KEEP | Greps `lib/ui_validate_report.sh` for single `set -euo pipefail` — file is live (181 lines). |
| test_platform_android_game.sh | KEEP | Exercises `platforms/mobile_native_android/detect.sh` + `platforms/game_web/detect.sh` + `detect_ui_platform` / `load_platform_fragments` in `platforms/_base.sh` — all live. |
| test_platform_base.sh | KEEP | Unit tests `detect_ui_platform` framework→platform mapping in `platforms/_base.sh` (279 lines) — all live. |
| test_platform_fragments.sh | KEEP | Unit tests `load_platform_fragments` universal+platform+override merge in `platforms/_base.sh` — live. |
| test_platform_m60_edge_cases.sh | KEEP | iOS SwiftUI/UIKit tie-breaking + user-override `detect.sh` tests against `platforms/mobile_native_ios/detect.sh` and `platforms/_base.sh` — live. |
| test_platform_m60_integration.sh | KEEP | End-to-end `source_platform_detect` integration across all four M60 platforms — live. |
| test_platform_mobile_game.sh | KEEP | Exercises `platforms/mobile_flutter/detect.sh` and `platforms/mobile_native_ios/detect.sh` — live. |
| test_platform_web_component_tokens.sh | KEEP | Component-dir + CSS token detection in `platforms/web/detect.sh` — live. |
| test_platform_web_detection.sh | KEEP | Design-system detection (Tailwind/MUI/shadcn/Chakra/Bootstrap) in `platforms/web/detect.sh` — live. |
| test_platform_web_fragments.sh | KEEP | Validates `platforms/web/{coder_guidance,specialist_checklist,tester_patterns}.prompt.md` exist + `detect.sh` passes `bash -n` — live. |
| test_ui_build_gate.sh | KEEP | 20-test sweep of `run_build_gate` UI test gate (M28 baseline + M126 deterministic-execution coverage) in `lib/gates_ui.sh` + `lib/gates_ui_helpers.sh` — live bash (183 + 190 lines). |
| test_ui_gate_force_noninteractive.sh | KEEP | M130 Priority 0 hook `TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1` in `_ui_detect_framework` (`lib/gates_ui_helpers.sh`) — live. |
| test_ui_server_hardening.sh | KEEP | M30 `_start_ui_server` curl-probe timeout + `_stop_ui_server` process-group kill in `lib/ui_validate.sh` — live. |
| test_ui_smoke_js.sh | KEEP | Node-based unit test of `pixelDiffRatio` + `parseArgs` in `tools/ui_smoke_test.js` — live. |
| test_ui_validate_functions.sh | KEEP | Exercises `_find_available_port`, `_is_port_in_use`, `_detect_ui_targets` in `lib/ui_validate.sh` — live. |
| test_ui_validate_report.sh | KEEP | Exercises `_json_field`, `_status_icon`, `get_ui_validation_summary`, `generate_ui_validation_report` in `lib/ui_validate_report.sh` — live. |

## Coverage gaps noted

- `test_nonblocking_log_fixes.sh` is a 26-fix sweep that already includes
  post-m21 retro-fits (Fix #23, #24) pointing at
  `internal/finalize/orchestrator{,_test}.go`. As more bash subsystems get
  wedged to Go, this file will likely need additional retro-fits per fix
  rather than wholesale replacement — worth flagging when the dashboard,
  diagnose, or causality subsystems migrate.
- `test_drift_config.sh` quietly became an integration test against the
  m16 Go config loader; it would still be worth having a unit test inside
  `internal/config` that asserts the drift-specific defaults
  (`DRIFT_LOG_FILE=.tekhton/DRIFT_LOG.md`, `DRIFT_OBSERVATION_THRESHOLD=8`,
  `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5`) survive the loader's clamp/validate
  pipeline. Did not check whether `internal/config/defaults.go` already
  asserts these — quick `grep "DRIFT_" internal/config/*.go` returned
  empty, but I did not chase it down.
- `test_drift_prompts.sh` now exercises the m15 Go prompt engine end-to-end
  for the coder/reviewer/coder_rework templates' ACP+drift sections. If
  the Go engine's conditional handling regresses, this test will catch it
  — but only as an opaque content failure. A Go-side conditional unit test
  in `internal/prompt` would localize the failure faster.
