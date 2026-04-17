# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [x] [2026-04-17 | "M96"] `lib/finalize.sh` is 559 lines — well over the 300-line soft ceiling. Pre-existed this rework (this cycle added ~10 lines). Candidate for extraction in a future cleanup pass.
- [ ] [2026-04-17 | "M96"] NR2 archival under-emission (archive_reports() emits 0 lines) — unchanged from prior cycle, acceptable per prior report.
- [ ] [2026-04-17 | "M96"] IA4 and IA5 (prefix semantics, commit diff truncation) — unchanged, still deferred, remain non-blocking.
- [ ] [2026-04-17 | "M94"] `_rule_max_turns` reads the Exit Reason section from the state file directly (its own `awk` call) even though `_read_diagnostic_context` already populates `_DIAG_EXIT_REASON` for that purpose. Minor duplication — not a bug, but `_DIAG_EXIT_REASON` could be used instead to keep rule reads consistent with the module contract.
- [ ] [2026-04-17 | "M93"] `_save_orchestration_state` is not directly unit-tested — the test suite covers `_choose_resume_start_at` exhaustively, but there is no assertion that the `Notes` field in `PIPELINE_STATE.md` actually contains the restoration string, nor that `resume_flags` uses `_RESUME_NEW_START_AT` rather than `START_AT`. An integration test that stubs `finalize_run` and `write_pipeline_state` would close this gap, but the logic is simple and correct on inspection.
- [ ] [2026-04-17 | "Fix the failing test from the test suite"] Note 2 (m95 doc: "four" → "seven" extracted functions) remains unaddressed due to permission gate on `.claude/milestones/*.md`; requires a manual one-line edit — no functional impact.
- [ ] [2026-04-17 | "Fix the failing test from the test suite"] Three additional hardcoded `get_milestone_count "CLAUDE.md"` call sites remain at `tekhton.sh:2018`, `tekhton.sh:2031`, and `stages/coder.sh:34` — only the one explicitly called out in Note 3 was in scope, but these are candidates for a follow-up normalisation pass.

## Resolved
