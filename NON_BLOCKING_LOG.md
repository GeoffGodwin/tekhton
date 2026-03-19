# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-03-19 | "Implement the next 2 items in the NON_BLOCKING_LOG.md file."] `lib/hooks.sh:121` uses `head -n -1` (GNU-specific: all lines except the last). Works on Linux/WSL2 but will silently break on macOS. Carried over from prior cycle — consider replacing with `awk 'NR>1{print prev} {prev=$0}'` for portability.
- [ ] [2026-03-19 | "Implement the next 2 items in the NON_BLOCKING_LOG.md file."] `check_usage_threshold()` at `lib/common.sh:184` — the `grep -oE '[0-9]+(.[0-9]+)?%'` pattern silently falls back to 0 if `claude usage` output format changes. A brief comment noting the expected output format (e.g., "expects a line containing 'N%' from `claude usage`") would help future maintainers diagnose silent fallback behavior.
## Resolved
- [x] [2026-03-19] `_print_box_frame --width` parameter implemented at `lib/common.sh:88-105`. The helper now accepts `--width N` (defaults to 60), allowing variable-width boxes. Both current callers use the default width of 60, so behavior is unchanged.
- [x] [2026-03-19] `lib/agent_monitor.sh` split already completed — `_reset_monitoring_state`, `_detect_file_changes`, and `_count_changed_files_since` live in `lib/agent_monitor_helpers.sh` (84 lines). `agent_monitor.sh` is now 287 lines, under the 300-line ceiling. (Item 2 resolved.)
- [x] [2026-03-19] `_reset_monitoring_state()` now clears `_TEKHTON_AGENT_PID=""` at `lib/agent_monitor_helpers.sh:26` after killing the process. Multiple calls in succession now safely handle stale PIDs. (Item 3 resolved.)
- [x] [2026-03-19] UPSTREAM errors in `run_agent()` now call `_append_agent_summary()` before the early return, so exhausted transient retries produce a tail-friendly log summary block.
- [x] [2026-03-19] OOM retry delay now uses exponential backoff with 15s floor (was flat 15s override). Repeated OOM retries back off to 30s, 60s, etc. like other transient errors.
- [x] [2026-03-19] `lib/agent_helpers.sh` split already completed — `_run_with_retry`, `_classify_agent_exit`, and `_should_retry_transient` live in `lib/agent_retry.sh` (199 lines). `agent_helpers.sh` is now 278 lines, under the 300-line ceiling.
- [x] [2026-03-19] `lib/agent_monitor.sh` split already completed — `_reset_monitoring_state`, `_detect_file_changes`, and `_count_changed_files_since` live in `lib/agent_monitor_helpers.sh` (84 lines). `agent_monitor.sh` is now 287 lines, under the 300-line ceiling.
- [x] [2026-03-19] `ARCHITECTURE.md` lib/agent.sh description updated to list all 5 sourced files (`agent_monitor_platform.sh`, `agent_monitor.sh`, `agent_monitor_helpers.sh`, `agent_retry.sh`, `agent_helpers.sh`).
- [x] [2026-03-19] `lib/metrics.sh` split — extracted `calibrate_turn_estimate()` into `lib/metrics_calibration.sh`, reducing metrics.sh from ~477 to ~384 lines.
- [x] [2026-03-19] `_pct()` nested function inlined — replaced with direct `$(( var * 100 / total ))%` arithmetic in `summarize_metrics()`, eliminating global namespace pollution.
- [x] [2026-03-19] CODER_SUMMARY.md accuracy — added `_warn_summary_drift()` to `run_completion_gate()` in `lib/gates.sh` that cross-checks the "Files Modified" section against `git diff --stat`. Warns when summary underreports or claims no files modified while git shows changes.
- [x] [2026-03-18] `split_milestone()` in `lib/milestone_split.sh` — changed `export` to plain shell variable assignment for `MILESTONE_DEFINITION`, `SCOUT_ESTIMATE`, `TURN_CAP`, `PRIOR_RUN_HISTORY`. `render_prompt()` reads these via `${!var_name}` indirect expansion in the same shell scope, so export was unnecessary environment bloat.
- [x] [2026-03-18] `lib/milestone_archival.sh` now explicitly listed in CODER_SUMMARY.md Files Modified section. Process tracking issue resolved.
- [x] [2026-03-18] Em-dash (U+2014) removed from all 5 regex character classes in `lib/milestone_archival.sh` (lines 35, 80, 101, 163, 225). Replaced `([:.\ -]|—)` with portable `[^[:alnum:]]` which matches any non-alphanumeric delimiter.
- [x] [2026-03-18] Recursion depth log line added to null-run auto-split path in `stages/coder.sh` at lines 348-350 and 470-473: `warn "Auto-split complete — re-running coder stage for milestone ... (depth N/M)..."`.
- [x] [2026-03-18] Comment added to `_switch_to_sub_milestone` in `stages/coder.sh` lines 21-22 explaining `get_milestone_title` fallback behavior when split agent uses a non-matching heading format.
- [x] [2026-03-18] `MILESTONE_SPLIT_MAX_TURNS` hard cap of 50 documented in `templates/pipeline.conf.example` line 285: "Hard cap: 50 (values above 50 are clamped automatically)".
- [x] [2026-03-18] Integration tests added to `tests/test_milestone_split.sh` covering 3 coder stage wiring paths: pre-flight sizing gate (split + re-scout), null-run auto-split (handle_null_run_split + recursive coder), and turn-limit minimal-output auto-split. Tests stub `run_agent`, `split_milestone`, `init_milestone_state`, and verify call sequences.
- [x] [2026-03-18] `lib/milestone_split.sh:42` — Split `local threshold=$((...))` into separate declaration and assignment to avoid SC2155.
- [x] [2026-03-18] `lib/milestone_archival.sh:250` — Dead `local awk_rc=$?` code path already resolved in prior run: `_replace_milestone_block` now uses `|| { rm -f ...; return 1; }` pattern which catches awk failure before `set -e` fires.
- [x] [2026-03-18] `lib/milestone_archival.sh:252` — `$rep_file` cleanup already resolved in prior run: the `|| { }` block now cleans up both `$tmp_file` and `$rep_file` on awk failure.
- [x] [2026-03-18] `handle_null_run_split()` `git diff HEAD` comment already present in prior run at lines 233-237 explaining intentional use of `git diff HEAD` vs bare `git diff`.
- [x] [2026-03-17] Coder scope drift — audited all items instead of task-specified quantity. Resolved by adding scope-adherence directive to `prompts/coder.prompt.md` and softening the "address what you can" language in `stages/coder.sh` non-blocking injection to defer to task scope.
- [x] [2026-03-17] (consolidated) `milestones.sh` exceeded the 300-line guideline. Resolved by extracting acceptance checking, commit signatures, and auto-advance helpers into `lib/milestone_ops.sh`. `milestones.sh` is now ~312 lines, `milestone_ops.sh` ~260 lines.
- [x] [2026-03-17] Three duplicate "milestones.sh too long" entries consolidated into a single resolved entry above.
