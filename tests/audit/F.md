# Bucket F Audit — Watchtower / Dashboard / Output Bus

Audited 25 tests. Verdict counts: KEEP=25, DELETE-STALE=0, PORT-TO-GO=0, NEEDS-REVIEW=0.

## Verdicts

| Test | Verdict | Reason |
|---|---|---|
| test_dashboard_data.sh | KEEP | Exercises `lib/dashboard.sh`, `lib/dashboard_emitters.sh`, `lib/dashboard_parsers.sh` (all live bash); JSON-emission and `init_dashboard`/`cleanup_dashboard`/`emit_dashboard_*` still bash-only. Uses `causality.sh`'s bash-fallback writer which the shim still ships. |
| test_dashboard_parsers_bugfix.sh | KEEP | Targets bugs in `lib/dashboard_parsers.sh` + `lib/dashboard_emitters.sh` Python/grep fallbacks, both live bash with no Go equivalent. |
| test_dashboard_parsers_delegation.sh | KEEP | Verifies `lib/dashboard_parsers.sh` → `lib/dashboard_parsers_runs.sh` source delegation; both files exist and define the tested functions. |
| test_dashboard_parsers_json_escape.sh | KEEP | Exercises `_json_escape` injection-safety in the bash/sed fallback paths of `lib/dashboard_parsers.sh` — still live bash. |
| test_dashboard_zero_turn_edge_cases.sh | KEEP | Exercises `_parse_run_summaries` zero-turn filtering in `lib/dashboard_parsers.sh` — live bash. |
| test_output_bus.sh | KEEP | M103 unit tests for `_out_emit`, `log/warn/header` wrappers, NO_COLOR; targets `lib/output.sh` + `lib/common.sh` — both live bash, no Go port. |
| test_output_bus_context_store.sh | KEEP | M99 unit tests for `out_init`/`out_set_context`/`out_ctx`; `lib/output.sh` is live bash. |
| test_output_format.sh | KEEP | Display-helper coverage for `lib/output_format.sh` (`_out_color`, `_out_repeat`, `out_banner`, `out_kv`, `out_progress`, etc.) — all live bash. |
| test_output_format_json.sh | KEEP | Exercises `_out_append_action_item` and `_out_json_escape` in `lib/output_format.sh` + bash-n/shellcheck lint — live bash. |
| test_output_format_tui.sh | KEEP | TUI-mode branch coverage of `lib/output_format.sh` (`_TUI_ACTIVE=true` LOG_FILE routing) — live bash. |
| test_output_lint.sh | KEEP | Repo-wide lint that no direct ANSI `echo -e` calls live outside the output module — still relevant for live bash in `lib/` and `stages/`. |
| test_output_tui_sync.sh | KEEP | M103 — exercises `_tui_json_build_status` in `lib/tui.sh` (live bash sidecar manager) feeding from `_OUT_CTX`; both modules live bash. |
| test_watchtower_actions_auto_refresh.sh | KEEP | Static JS assertions against `templates/watchtower/app.js` — pure HTML/CSS/JS dashboard, no Go port. |
| test_watchtower_css_sync.sh | KEEP | Checks `templates/watchtower/style.css` ↔ `.claude/dashboard/style.css` parity — static asset domain. |
| test_watchtower_dashboard.sh | KEEP | End-to-end test of `init_dashboard`, `sync_dashboard_static_files`, `_regenerate_timeline_js` in `lib/dashboard.sh` and the emitters — live bash. |
| test_watchtower_distribution_toggle.sh | KEEP | Verifies `getDistMode`/`setDistMode` and toggle markup in `templates/watchtower/app.js` — static asset. |
| test_watchtower_html.sh | KEEP | Asserts `templates/watchtower/{index.html,style.css,app.js}` structure — static asset. |
| test_watchtower_msIdMatch.sh | KEEP | Regression test for `msIdMatch()` JS function in `templates/watchtower/app.js` — static asset. |
| test_watchtower_parallel_groups_datalist.sh | KEEP | JS datalist behaviour in `templates/watchtower/app.js` — static asset. |
| test_watchtower_perstage_jsonl.sh | KEEP | Exercises sed/awk fallback in `_parse_run_summaries_from_jsonl` (`lib/dashboard_parsers*.sh`) — live bash. |
| test_watchtower_refresh_data_completeness.sh | KEEP | Cross-checks `templates/watchtower/{index.html,app.js}` for refresh data-file array completeness — static asset. |
| test_watchtower_spacing_improvements.sh | KEEP | CSS assertions on `templates/watchtower/style.css` — static asset. |
| test_watchtower_test_audit_rendering.sh | KEEP | Emitter↔renderer contract test: `lib/dashboard_emitters.sh` shape vs `templates/watchtower/app.js` `renderTestAuditBody` — both live. |
| test_watchtower_trends_filter_fix.sh | KEEP | JS filter-default regression in `templates/watchtower/app.js` — static asset. |
| test_watchtower_wcag_font_sizes.sh | KEEP | WCAG font-size assertions on `templates/watchtower/style.css` — static asset. |

## Coverage gaps noted

- No test directly exercises `lib/dashboard_parsers_runs_files.sh` — the delegation test covers it transitively via `_parse_run_summaries_from_files`, but no targeted unit test was observed.
- `out_complete` (in `lib/output.sh`) and `out_reset_pass` are not exercised by any test seen in this bucket; the existing output-bus tests stop at `_out_emit` / context-store coverage.
