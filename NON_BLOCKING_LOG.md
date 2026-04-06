# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-05 | "Milestone 66"] `lib/metrics.sh`: `test_audit_duration_s` and `analyze_cleanup_duration_s` are never emitted to metrics.jsonl. `_STAGE_DURATION["test_audit"]` and `_STAGE_DURATION["analyze_cleanup"]` are set during pipeline execution (tester.sh:357-360, hooks.sh:285-288) but `record_run_metrics()` doesn't read them. The acceptance criteria say "turns + durations" for these stages. Impact is limited — the frontend shows `-` in Avg Time for these sub-steps and the bash parser hardcodes `_sd=0` for them, so behavior is internally consistent. Future fix: add `test_audit_duration_s` and `analyze_cleanup_duration_s` reads from `_STAGE_DURATION` alongside the existing security/cleanup reads (lib/metrics.sh:94-101).
- [ ] [2026-04-05 | "Milestone 66"] `templates/watchtower/app.js`: Specialist stages (`specialist_security`, `specialist_perf`, `specialist_api`) are captured in metrics.jsonl and parsed, but `stageGroupOrder` doesn't include a specialist group, so they never appear in the Per-Stage Breakdown. The milestone spec says "consider grouping specialists under a 'Specialist Reviews' parent only when at least one ran" — this was left unimplemented. Log for a follow-on milestone when specialist usage warrants it.
- [ ] [2026-04-05 | "Milestone 66"] `lib/metrics.sh` is 341 lines (41 over the 300-line ceiling). The M66 additions are necessary additions, not padding, but the file continues to grow. Consider extracting the extended-stage block (lines 104-191) into `lib/metrics_extended.sh` sourced at end of `metrics.sh`.
- [ ] [2026-04-05 | "Milestone 66"] `lib/hooks.sh` (366 lines), `lib/specialists.sh` (371 lines), `stages/review.sh` (391 lines), `stages/tester.sh` (513 lines) all exceed the 300-line ceiling — pre-existing but the M66 additions extended them further. Log for the next cleanup pass.
- [ ] [2026-04-05 | "M59"] `lib/specialists.sh` is now 365 lines, over the 300-line soft ceiling. The new UI specialist block (auto-enable logic, `ui)` diff relevance case, `UI_FINDINGS_BLOCK` export) is ~25 lines. Consider extracting `_specialist_diff_relevant()` or the UI block to a helper module at the next cleanup pass.

## Resolved
