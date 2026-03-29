# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-29 | "Address all 41 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/ui_validate_report.sh:1,13` — `set -euo pipefail` appears twice (lines 1 and 13); the duplicate at line 13 can be removed
- [ ] [2026-03-29 | "Address all 41 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/ui_validate.sh:1,19` — Same duplicate `set -euo pipefail` pattern; pre-existing, worth cleaning in a future pass
- [ ] [2026-03-29 | "Address all 41 open non-blocking notes in NON_BLOCKING_LOG.md. Fix each item and note what you changed."] `lib/dashboard_emitters.sh:162,166` — `dep_arr` used in `read -ra dep_arr` but not declared alongside the other loop locals (`i`, `dep_list`, `dep_item`) on line 162; minor scope hygiene
(none)

## Resolved

### Non-Blocking Cleanup Pass (2026-03-29)
- [x] `config_defaults.sh`: Added `# --- Auto-fix on test failure ---` section header to separate AUTO_FIX_* defaults from TEST_BASELINE_* defaults.
- [x] `tester.sh`: Added `export SKIP_FINAL_CHECKS=true` on auto-fix success path to prevent duplicate finalization.
- [x] Milestone archival idempotency fix already present in codebase. Acknowledged; no code change needed.
- [x] `finalize_display.sh`: Added field contract comment for `get_notes_summary` 6-field pipe format.
- [x] `finalize_display.sh`: Deduplicated tip lines — shared block for warning+normal severity, critical has its own.
- [x] `coder.sh`: Removed redundant `2>&1` after `&>/dev/null` in `declare -p` guards.
- [x] `dashboard_emitters.sh`: Renamed `_dep_arr` → `dep_arr` (local array, not library-internal global).
- [x] `app.js`: Added comment noting setTimeout 1500ms must match CSS milestone-highlight animation.
- [x] `inbox.sh`: Removed dead-code `manifest_append_*` guard in `_process_milestone()`.
- [x] `dashboard_emitters.sh`: Removed dead-code `manifest_append_*` guard in `emit_dashboard_inbox()`.
- [x] `inbox.sh`: Documented known limitation — `_process_note()` only passes title+tag to `add_human_note()`.
- [x] `dashboard_emitters.sh`: Documented that `emit_dashboard_inbox()` does not enumerate `.cfg` files separately.
- [x] `watchtower_server.py`: Added comment noting 100KB limit is hardcoded and sufficient for dashboard payloads.
- [x] Duplicate M36/M37 items (inbox dead code, dashboard .cfg gap, watchtower limit) — resolved above.
- [x] `app.js`: `renderedTabs` already removed from codebase in a prior commit. No variable remains.
- [x] `app.js`: Redundant `scheduleRefresh()` call in `render()` already removed. `checkRefreshLifecycle()` handles it.
- [x] Duplicate M35/agent-fix items for renderedTabs and scheduleRefresh — all resolved above.
- [x] `tekhton.sh`: Crash-recovery resume gap fixed — `CURRENT_NOTE_LINE` from env is now checked before `pick_next_note`.
- [x] `coder.sh`: Misleading "no notes flag set" log now skips when `HUMAN_MODE=true`.
- [x] `finalize.sh`: `_hook_resolve_notes` edge case documented with inline comments explaining stuck-[~] cleanup.
- [x] Duplicate M33 items (crash-recovery, misleading log, resolve-notes) — resolved above.
- [x] `tester.sh` 300-line ceiling: diagnostics are woven into stage logic (not a contiguous block). Acknowledged — split deferred to a dedicated refactoring pass.
- [x] `test_plan_phase_context.sh`: Replaced `|| true` idiom with `if [[ -n ]]; then ...; fi` pattern.
- [x] File length issues (`ui_validate.sh`, `gates.sh`, `config_defaults.sh`): acknowledged. All function correctly; split deferred to dedicated refactoring pass.
- [x] `ui_validate.sh`: Documented why `_check_npm_package()` cannot be used inside `_check_headless_browser()` subshell (separate process, no function access).
- [x] `ui_validate.sh`: Replaced `head -n -5` (GNU-specific) with portable `total - 5` calculation.
- [x] `ui_validate.sh`: Extracted `_run_validation_pass()` helper to eliminate ~50-line retry duplication.
- [x] `ui_validate_report.sh`: Added PCRE dependency comment on `_json_field()`.

### Non-Blocking Cleanup Pass (2026-03-25e)
- [x] `lib/pipeline_order.sh:27-30` — NOTE block already has a blank line separating it from the `validate_pipeline_order` function docstring (added in commit cf4cd20). Marked as resolved.

### Non-Blocking Cleanup Pass (2026-03-25d)
- [x] `lib/config.sh:116` — Removed redundant `|| [[ "$val" == "."* ]]` guard from `_clamp_config_float`. The `^[0-9]+` anchor already rejects leading-dot values.

### Non-Blocking Cleanup Pass (2026-03-25)
- [x] `lib/checkpoint.sh` extracted `show_checkpoint_info` into `checkpoint_display.sh` (266 → under 300 lines).
- [x] `create_run_checkpoint` and `update_checkpoint_commit` tmpfiles now have `trap ... EXIT INT TERM` cleanup guards.
- [x] `--rollback` early-exit path now sources `config_defaults.sh` instead of hardcoding defaults.
- [x] Added comment explaining CWD assumption in no-commit rollback path.
- [x] `lib/dry_run.sh` removed redundant `_total_files` grep; reuses `_scout_file_count`.
- [x] `lib/config_defaults.sh:225` cache default — acknowledged as intentional spec deviation (`.claude/` path survives session boundaries for `--continue-preview`). No code change needed.
- [x] `lib/state.sh` not modified for Milestone 23 — acknowledged. `--continue-preview` uses direct cache validation. No code change needed.
- [x] `lib/init_config.sh` tmpfile trap added to `_merge_preserved_values()`.
- [x] `lib/init_config.sh` split: extracted `_emit_*` emitters into `init_config_emitters.sh` (429 → 226 lines).
- [x] `lib/migrate.sh` split: extracted CLI handlers and `_cleanup_old_backups` into `migrate_cli.sh` (581 → 426 lines).
- [x] `lib/migrate.sh` removed redundant outer `if` in `_applicable_migrations`.
- [x] `lib/diagnose_rules.sh` moved `_rule_unknown` doc comment to precede actual function.
- [x] `tests/test_migration.sh` rollback interactive path — acknowledged as acceptable. Future pass could pipe input. No code change needed.
- [x] `lib/migrate.sh` fixed `COMPLETE_MODE` → `COMPLETE_MODE_ENABLED` and `AUTO_ADVANCE` → `AUTO_ADVANCE_ENABLED` in `check_project_version()`.
- [x] `tekhton.sh` clean exit fix — previously resolved. Acknowledged.
- [x] `lib/finalize.sh` updated misleading SC2034 comment to "assigned for hook interface consistency".
- [x] `tekhton.sh` flag ordering behavior — consistent with existing early-exit pattern. No code change needed.
- [x] JR_CODER_SUMMARY.md absence — acknowledged. No impact on correctness. No code change needed.
- [x] `tests/test_docs_site.sh` fixed dead grep clause; simplified to single working pipe.
- [x] `docs/guides/watchtower.md` screenshots — cannot be auto-generated by coder agent. Requires manual screenshot capture from a running dashboard. No code change possible.

### Test Audit Concerns (2026-03-24)
#### COVERAGE: `rollback_migration()` is entirely untested
#### COVERAGE: `check_project_version()` is entirely untested
#### INTEGRITY: `$?` assertions after `set -euo pipefail` calls always pass
#### COVERAGE: No test for mid-chain failure behavior in `run_migrations`
#### COVERAGE: Missing edge case — `_write_config_version` when `pipeline.conf` absent
#### INTEGRITY: Weak string match in test 11.3

### Non-Blocking Cleanup Pass (2026-03-25b)
- [x] `NON_BLOCKING_LOG.md` duplicate "Test Audit Concerns (2026-03-24)" blocks — already resolved by prior cleanup pass (reduced from 3 to 1). Remaining blocks have distinct dates (2026-03-24 vs 2026-03-25) with different content. No duplicates remain. Marked stale note as resolved.

### Non-Blocking Cleanup Pass (2026-03-25c)
- [x] `stages/tester.sh:350` — Changed `exit 1` to `export SKIP_FINAL_CHECKS=true; return` in `_run_tester_write_failing()` UPSTREAM handler, matching the established pattern at line 119.
- [x] `lib/config.sh:116` — Added `|| [[ "$val" == "."* ]]` check to `_clamp_config_float` regex to reject leading-dot floats (e.g. `.5`). Negative values already rejected by the `^[0-9]+` anchor.
- [x] `lib/notes_cli_write.sh:143` — Replaced `echo -e` with `printf '%b'` in `clear_completed_notes()` for portability consistency.

### Test Audit Concerns (2026-03-25)
#### INTEGRITY: Test 13 always passes regardless of implementation behavior
#### COVERAGE: `offer_cached_dry_run()` has no test coverage
#### COVERAGE: `_parse_intake_preview` confidence value not asserted for valid reports
#### NAMING: Test 13 label embeds a runtime variable

### Test Audit Concerns (2026-03-28)
#### INTEGRITY: Tautological assertion in success branch (4.2)
#### INTEGRITY: Tautological assertion in success branch (6.3)
#### SCOPE: lib/agent.sh modified but not reported in TESTER_REPORT.md
#### NAMING: No PASS counter in test_agent_fifo_invocation.sh

### Test Audit Concerns (2026-03-28)
#### INTEGRITY: Tautological assertion in success branch (4.2)
#### INTEGRITY: Tautological assertion in success branch (6.3)
#### SCOPE: lib/agent.sh modified but not reported in TESTER_REPORT.md
#### NAMING: No PASS counter in test_agent_fifo_invocation.sh

### Test Audit Concerns (2026-03-29)
#### INTEGRITY: Edge-case test accepts any outcome — always passes
#### COVERAGE: DAG-mode missing-file path not exercised
#### WEAKENING
#### NAMING
#### SCOPE

### Test Audit Concerns (2026-03-29)
#### INTEGRITY: Edge-case test accepts any outcome — always passes
#### COVERAGE: DAG-mode missing-file path not exercised
#### WEAKENING
#### NAMING
#### SCOPE
