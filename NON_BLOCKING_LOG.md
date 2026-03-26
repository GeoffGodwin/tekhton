# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-26 | "[BUG] Fix Watchtower Reports and Trends tabs (three bugs) 1. `lib/dashboard_emitters.sh:155-156` — `grep -c ... || echo "0"` produces `"0
0"` when zero matches found (grep -c outputs "0" but exits 1, triggering the fallback which appends a second "0"). Fix: use `|| true` instead of `|| echo "0"` and add `: "${var:=0}"` fallback, matching the pattern already used on line 149 for audit_verdict 2. `lib/dashboard_parsers.sh:159-163` — `_parse_run_summaries` Python parser reads `total_turns` and `total_time_s` but RUN_SUMMARY.json uses `total_agent_calls` and `wall_clock_seconds`. Fix: fall back to the actual field names: `d.get('total_turns', d.get('total_agent_calls', 0))` and `d.get('total_time_s', d.get('wall_clock_seconds', 0))`. Apply same fix to the grep fallback on lines 175-177. 3. Both the Python path and grep fallback in `_parse_run_summaries` also miss the `milestone` and `stages` fields from the actual JSON — the grep fallback doesn't extract them at all. Low priority since the Python path covers most environments."] `lib/ui_validate.sh` (621 lines), `lib/gates.sh` (359 lines), `lib/config_defaults.sh` (411 lines) all exceed the 300-line soft ceiling. Log for next cleanup pass — all files function correctly.
- [ ] [2026-03-26 | "[BUG] Fix Watchtower Reports and Trends tabs (three bugs) 1. `lib/dashboard_emitters.sh:155-156` — `grep -c ... || echo "0"` produces `"0
0"` when zero matches found (grep -c outputs "0" but exits 1, triggering the fallback which appends a second "0"). Fix: use `|| true` instead of `|| echo "0"` and add `: "${var:=0}"` fallback, matching the pattern already used on line 149 for audit_verdict 2. `lib/dashboard_parsers.sh:159-163` — `_parse_run_summaries` Python parser reads `total_turns` and `total_time_s` but RUN_SUMMARY.json uses `total_agent_calls` and `wall_clock_seconds`. Fix: fall back to the actual field names: `d.get('total_turns', d.get('total_agent_calls', 0))` and `d.get('total_time_s', d.get('wall_clock_seconds', 0))`. Apply same fix to the grep fallback on lines 175-177. 3. Both the Python path and grep fallback in `_parse_run_summaries` also miss the `milestone` and `stages` fields from the actual JSON — the grep fallback doesn't extract them at all. Low priority since the Python path covers most environments."] `_check_npm_package()` defined at `ui_validate.sh:34-38` is not called from within `_check_headless_browser()` (the subshell duplicates the `npm ls` logic inline). The function is tested independently and is available as a public helper, but the module itself doesn't use it — a small inconsistency worth noting for future refactoring.
- [ ] [2026-03-26 | "Implement Milestone 30: Build Gate Hardening & Hang Prevention"] `lib/ui_validate.sh` (621 lines), `lib/gates.sh` (359 lines), `lib/config_defaults.sh` (411 lines) all exceed the 300-line soft ceiling. Log for next cleanup pass — all files function correctly.
- [ ] [2026-03-26 | "Implement Milestone 30: Build Gate Hardening & Hang Prevention"] `_check_npm_package()` defined at `ui_validate.sh:34-38` is not called from within `_check_headless_browser()` (the subshell duplicates the `npm ls` logic inline). The function is tested independently and is available as a public helper, but the module itself doesn't use it — a small inconsistency worth noting for future refactoring.
- [ ] [2026-03-25 | "Implement Milestone 29: UI Validation Gate & Headless Smoke Testing"] `lib/ui_validate.sh:560` — `head -n -5` is GNU-specific and fails silently on macOS BSD head. Use `head -n $(( count - 5 ))` pattern or a sort+tail workaround for portability.
- [ ] [2026-03-25 | "Implement Milestone 29: UI Validation Gate & Headless Smoke Testing"] `lib/ui_validate.sh:371-421` — retry block duplicates the full validation loop verbatim (~50 lines). Extract the per-target iteration into a `_run_validation_pass()` helper to avoid future divergence.
- [ ] [2026-03-25 | "Implement Milestone 29: UI Validation Gate & Headless Smoke Testing"] `lib/ui_validate_report.sh:166` — `_json_field()` uses `grep -oP` (PCRE). On Alpine Linux or minimal Docker images, grep may lack PCRE support; the `|| true` fallback silently returns empty strings, producing a report table full of `?` values. Add a comment noting the dependency.
(none)

## Resolved

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
