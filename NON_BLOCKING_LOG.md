# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-28 | "M39"] `finalize_display.sh:99`: the `IFS='|' read -r _ _ _ _ _ notes_unchecked` pattern assumes `get_notes_summary` always returns exactly 6 pipe-separated fields. A comment noting the field contract would prevent future silent failures if that count changes.
- [ ] [2026-03-28 | "M39"] `finalize_display.sh:111-119`: "normal" and "warning" severity branches for human notes both emit the same tip lines. Intentional but slightly redundant — consider a shared variable if the block grows.
- [ ] [2026-03-28 | "M38"] `stages/coder.sh`: The `declare -p _STAGE_STATUS &>/dev/null 2>&1` guard duplicates stderr redirect (`&>` already redirects both; the trailing `2>&1` is redundant but harmless).
- [ ] [2026-03-28 | "M38"] `dashboard_emitters.sh:159`: `IFS=',' read -ra _dep_arr <<< "$dep_list"` uses a leading underscore on a local array name; unconventional but harmless — the leading `_` is generally reserved for library-internal globals in this codebase.
- [ ] [2026-03-28 | "M38"] `app.js:326`: `setTimeout(..., 1500)` hardcodes the animation duration to match the CSS keyframe. If the CSS animation duration ever changes, this will silently diverge. Low risk but worth a comment.
- [ ] [2026-03-28 | "M37"] `lib/inbox.sh:86-88` — The guard `[[ "$basename" == manifest_append_* ]]` in `_process_milestone()` is dead code: the function is only called from the `milestone_*.md` glob loop, which cannot match `manifest_append_*`. Safe to remove.
- [ ] [2026-03-28 | "M37"] `lib/dashboard_emitters.sh:303` — Similarly, `[[ "$basename" != manifest_append_* ]]` in `emit_dashboard_inbox()` is dead code for the same reason (the enclosing glob is `milestone_*.md`).
- [ ] [2026-03-28 | "M37"] `lib/inbox.sh:65-75` — `_process_note()` silently drops the description, priority, and source fields when calling `add_human_note()`. Only the title is written to HUMAN_NOTES.md. This is consistent with how the flat checklist works, but worth documenting as a known limitation.
- [ ] [2026-03-28 | "M37"] `lib/dashboard_emitters.sh:280-331` — `emit_dashboard_inbox()` does not enumerate `manifest_append_*.cfg` files in the pending display. When a milestone is submitted via the UI, users will see the `.md` entry but not the associated `.cfg` entry. Minor UX gap; acceptable since they are submitted as a pair.
- [ ] [2026-03-28 | "M37"] `tools/watchtower_server.py:45` — The 100KB payload limit is a hard-coded magic number; could be a CLI arg for future extensibility, but acceptable at this scope.
- [ ] [2026-03-28 | "M36"] `lib/inbox.sh:86-88` — The guard `[[ "$basename" == manifest_append_* ]]` in `_process_milestone()` is dead code: the function is only called from the `milestone_*.md` glob loop, which cannot match `manifest_append_*`. Safe to remove.
- [ ] [2026-03-28 | "M36"] `lib/dashboard_emitters.sh:303` — Similarly, `[[ "$basename" != manifest_append_* ]]` in `emit_dashboard_inbox()` is dead code for the same reason (the enclosing glob is `milestone_*.md`).
- [ ] [2026-03-28 | "M36"] `lib/inbox.sh:65-75` — `_process_note()` silently drops the description, priority, and source fields when calling `add_human_note()`. Only the title is written to HUMAN_NOTES.md. This is consistent with how the flat checklist works, but worth documenting as a known limitation.
- [ ] [2026-03-28 | "M36"] `lib/dashboard_emitters.sh:280-331` — `emit_dashboard_inbox()` does not enumerate `manifest_append_*.cfg` files in the pending display. When a milestone is submitted via the UI, users will see the `.md` entry but not the associated `.cfg` entry. Minor UX gap; acceptable since they are submitted as a pair.
- [ ] [2026-03-28 | "M36"] `tools/watchtower_server.py:45` — The 100KB payload limit is a hard-coded magic number; could be a CLI arg for future extensibility, but acceptable at this scope.
- [ ] [2026-03-28 | "M35"] `renderedTabs` is now write-only state. `renderActiveTab()` sets non-active tabs to `false` and `switchTab()` sets the active tab to `true`, but neither function reads `renderedTabs` as a lazy-render gate before calling `renderTab()`. The variable is dead. Either restore the lazy-render check in `switchTab()` (but only for non-refresh-triggered navigation) or remove `renderedTabs` entirely and let every tab switch and every `renderActiveTab()` call unconditionally re-render.
- [ ] [2026-03-28 | "M35"] In `render()` (line 528–529), `checkRefreshLifecycle()` already calls `scheduleRefresh()` when status is `running` or `initializing`, and then the very next line redundantly calls `scheduleRefresh()` again for the same condition. `scheduleRefresh()` clears the existing timer first so it's safe, but the second call is dead code. Remove the `if (!refreshStopped) { ... scheduleRefresh(); }` block in `render()` since `checkRefreshLifecycle()` handles it.
- [ ] [2026-03-28 | "Fix two failed self tests: test_agent_counter.sh and test_agent_fifo_invocation.sh which both failed on the last run."] `renderedTabs` is now write-only state. `renderActiveTab()` sets non-active tabs to `false` and `switchTab()` sets the active tab to `true`, but neither function reads `renderedTabs` as a lazy-render gate before calling `renderTab()`. The variable is dead. Either restore the lazy-render check in `switchTab()` (but only for non-refresh-triggered navigation) or remove `renderedTabs` entirely and let every tab switch and every `renderActiveTab()` call unconditionally re-render.
- [ ] [2026-03-28 | "Fix two failed self tests: test_agent_counter.sh and test_agent_fifo_invocation.sh which both failed on the last run."] In `render()` (line 528–529), `checkRefreshLifecycle()` already calls `scheduleRefresh()` when status is `running` or `initializing`, and then the very next line redundantly calls `scheduleRefresh()` again for the same condition. `scheduleRefresh()` clears the existing timer first so it's safe, but the second call is dead code. Remove the `if (!refreshStopped) { ... scheduleRefresh(); }` block in `render()` since `checkRefreshLifecycle()` handles it.
- [ ] [2026-03-28 | "M35"] `renderedTabs` is now write-only state. `renderActiveTab()` sets non-active tabs to `false` and `switchTab()` sets the active tab to `true`, but neither function reads `renderedTabs` as a lazy-render gate before calling `renderTab()`. The variable is dead. Either restore the lazy-render check in `switchTab()` (but only for non-refresh-triggered navigation) or remove `renderedTabs` entirely and let every tab switch and every `renderActiveTab()` call unconditionally re-render.
- [ ] [2026-03-28 | "M35"] In `render()` (line 528–529), `checkRefreshLifecycle()` already calls `scheduleRefresh()` when status is `running` or `initializing`, and then the very next line redundantly calls `scheduleRefresh()` again for the same condition. `scheduleRefresh()` clears the existing timer first so it's safe, but the second call is dead code. Remove the `if (!refreshStopped) { ... scheduleRefresh(); }` block in `render()` since `checkRefreshLifecycle()` handles it.
- [ ] [2026-03-27 | "M33"] **Crash-recovery resume gap (state.sh / tekhton.sh)**: In the exec-based resume path for single-note human mode, `CURRENT_NOTE_LINE` is exported to the child process env (tekhton.sh:991) but then unconditionally overwritten by `pick_next_note` at tekhton.sh:1382. Since the claimed note is in `[~]` state and `pick_next_note` only scans `[ ]` notes, a note that was `[~]` at crash time is invisible to resume. The gap is only in crash/SIGINT scenarios where `finalize_run` never runs. Suggest a future guard: if `CURRENT_NOTE_LINE` is already set from env AND `HUMAN_SINGLE_NOTE=true`, skip `pick_next_note` and restore `TASK` from the env value directly.
- [ ] [2026-03-27 | "M33"] **Misleading log in coder.sh elif branch (stages/coder.sh:435)**: The message "Human notes exist but no notes flag set" can fire when `HUMAN_MODE=true` (single-note mode), where notes ARE being handled via `claim_single_note`. The condition matches whenever notes remain regardless of mode — confusing to operators who ran `--human`. Not harmful, just noisy.
- [ ] [2026-03-27 | "M33"] **`_hook_resolve_notes` fallthrough edge case (lib/finalize.sh:115)**: When `HUMAN_MODE=true` but `CURRENT_NOTE_LINE` is empty and the pipeline fails, no `[~]` reset occurs. Stuck `[~]` notes from this path are cleaned up only by the safety net on the next successful run. Acceptable given the scenario requires an invariant violation, but worth documenting.
- [ ] [2026-03-27 | "M33"] **Crash-recovery resume gap (state.sh / tekhton.sh)**: In the exec-based resume path for single-note human mode, `CURRENT_NOTE_LINE` is exported to the child process env (tekhton.sh:991) but then unconditionally overwritten by `pick_next_note` at tekhton.sh:1382. Since the claimed note is in `[~]` state and `pick_next_note` only scans `[ ]` notes, a note that was `[~]` at crash time is invisible to resume. The gap is only in crash/SIGINT scenarios where `finalize_run` never runs. Suggest a future guard: if `CURRENT_NOTE_LINE` is already set from env AND `HUMAN_SINGLE_NOTE=true`, skip `pick_next_note` and restore `TASK` from the env value directly.
- [ ] [2026-03-27 | "M33"] **Misleading log in coder.sh elif branch (stages/coder.sh:435)**: The message "Human notes exist but no notes flag set" can fire when `HUMAN_MODE=true` (single-note mode), where notes ARE being handled via `claim_single_note`. The condition matches whenever notes remain regardless of mode — confusing to operators who ran `--human`. Not harmful, just noisy.
- [ ] [2026-03-27 | "M33"] **`_hook_resolve_notes` fallthrough edge case (lib/finalize.sh:115)**: When `HUMAN_MODE=true` but `CURRENT_NOTE_LINE` is empty and the pipeline fails, no `[~]` reset occurs. Stuck `[~]` notes from this path are cleaned up only by the safety net on the next successful run. Acceptable given the scenario requires an invariant violation, but worth documenting.
- [ ] [2026-03-27 | "**[BUG] Milestone archival re-archives ALL completed milestones on every run**"] `stages/tester.sh` is now 426 lines, exceeding the 300-line soft ceiling. The diagnostic block adds ~50 lines of well-structured, correct code, but the file was already over ceiling before this change. Log for a future cleanup pass.
- [ ] [2026-03-26 | "[FEAT] Add debugging/diagnostic output to the Tester stage to surface why it runs disproportionately long compared to the Coder stage."] `stages/tester.sh` is now 426 lines, exceeding the 300-line soft ceiling. The diagnostic block adds ~50 lines of well-structured, correct code, but the file was already over ceiling before this change. Log for a future cleanup pass.
- [ ] [2026-03-26 | "M32"] `tests/test_plan_phase_context.sh:71-74` — The `|| true` idiom is correct and shellcheck-clean, but `if [[ -n "$var" ]]; then ...; fi` is the more idiomatic bash form for a conditional-with-no-else and would be marginally clearer to future readers. Readability preference only; no defect.
- [ ] [2026-03-26 | "M31"] `tests/test_plan_phase_context.sh:71-74` — The `|| true` idiom is correct and shellcheck-clean, but `if [[ -n "$var" ]]; then ...; fi` is the more idiomatic bash form for a conditional-with-no-else and would be marginally clearer to future readers. Readability preference only; no defect.
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
