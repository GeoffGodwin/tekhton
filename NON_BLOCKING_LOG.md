# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-25 | "Implement Milestone 27: Configurable Pipeline Order (TDD Support)"] Stage header display regression (standard mode): scout occupies position 1 in the dynamic order array, so the coder stage now shows "Stage 2 / 5 — Coder" instead of the prior "Stage 1 / 4 — Coder". Scout is never displayed as a standalone stage (the loop `continue`s), so users see stage numbers that skip 1 and count 5 total where only 4 are visible. The defaults `_stage_pos=1` and `_stage_count=4` in `run_stage_coder()` are always bypassed because tekhton.sh sets both globals before calling the function.
- [ ] [2026-03-25 | "Implement Milestone 27: Configurable Pipeline Order (TDD Support)"] `TESTER_WRITE_FAILING_MAX_TURNS` default of 10 is likely too low. The test-write agent must read its role file, read SCOUT_REPORT.md, identify test patterns, write test files, run the test suite to confirm they load, and produce TESTER_PREFLIGHT.md. 10 turns is tight for a non-trivial project. Consider raising the default to 15 or 20.
- [ ] [2026-03-25 | "Implement Milestone 27: Configurable Pipeline Order (TDD Support)"] `_run_tester_write_failing()` has no UPSTREAM error check. The full `run_stage_tester()` explicitly handles `AGENT_ERROR_CATEGORY=UPSTREAM` with `write_pipeline_state`. The write-failing path silently swallows API errors via the null-run fallback — API failures during TDD pre-flight leave no trace in the state file.
- [ ] [2026-03-25 | "Implement Milestone 27: Configurable Pipeline Order (TDD Support)"] `CODER_TDD_TURN_MULTIPLIER` has no upper-bound clamp. The `_clamp_config_value` machinery only matches integers (`^[0-9]+$`), so floats are never clamped. A large value (e.g., `100.0`) would multiply the already-capped base turn budget by 100×, bypassing `CODER_MAX_TURNS_CAP`. Low risk (admin-only config), but worth noting for completeness.
- [ ] [2026-03-25 | "Implement Milestone 26: Express Mode (Zero-Config Execution)"] `lib/express.sh` is 331 lines — 31 over the 300-line soft ceiling. If this module grows (e.g. more manifest formats, persist strategies), consider splitting persist/role sub-concerns into a `lib/express_persist.sh`.
- [ ] [2026-03-25 | "Implement Milestone 26: Express Mode (Zero-Config Execution)"] `persist_express_config()` has no cleanup trap on its tmpfile. If the process is killed between `mktemp` and `mv`, a stale `.claude/express_conf_XXXXXX` is left in `.claude/`. Same LOW-severity pattern as the security-agent finding in `init_config.sh` — add `trap 'rm -f "$tmpfile"' EXIT INT TERM` immediately after the `mktemp` call.
- [ ] [2026-03-25 | "Implement Milestone 26: Express Mode (Zero-Config Execution)"] `_hook_express_persist` always logs "Express config saved to .claude/pipeline.conf. Edit to customize." even when `persist_express_config()` no-ops (conf already exists on run 2+). The inner function also logs its own success message on actual write, so run 1 produces two "saved" lines. Add a guard or move the outer log inside the function.
- [ ] [2026-03-25 | "Implement Milestone 26: Express Mode (Zero-Config Execution)"] `_detect_express_project_name()` uses `grep -oP` (PCRE), which is not available on macOS/BSD grep. Acceptable for the current Linux/WSL2 target, but worth noting if portability goals expand.
- [ ] [2026-03-25 | "Implement Milestone 26: Express Mode (Zero-Config Execution)"] Test 6.2 comment reads "resolve_role_file emits a log() line to stdout before the path" — this is incorrect. The `log` call inside `resolve_role_file()` is explicitly redirected to stderr (`>&2`). The `| tail -1` in the test is therefore unnecessary (though harmless). Update the comment to match reality.
- [ ] [2026-03-25 | "Implement Milestone 25: Human Notes UX Enhancement"] `lib/notes_cli.sh` remains ~395 lines, exceeding the 300-line soft ceiling. Consider extracting file-write helpers into `notes_cli_write.sh` in a future cleanup pass.
- [ ] [2026-03-25 | "Implement Milestone 25: Human Notes UX Enhancement"] `list_human_notes_cli()` still uses `output+="... "` / `echo -e "$output"`. A direct `printf` per line would be more portable and avoid the large single-variable allocation.
(none)

## Resolved

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

### Test Audit Concerns (2026-03-25)
#### INTEGRITY: Test 13 always passes regardless of implementation behavior
#### COVERAGE: `offer_cached_dry_run()` has no test coverage
#### COVERAGE: `_parse_intake_preview` confidence value not asserted for valid reports
#### NAMING: Test 13 label embeds a runtime variable
