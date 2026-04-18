# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in REVIEWER_REPORT.md.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-17 | "M97"] `_tui_json_build_status` emits both `"stage"` and `"stage_label"` with identical values (both sourced from `$stage_label`). The Python renderer uses only `stage_label`; the `stage` key is dead weight. Not broken — carry forward for cleanup.
- [ ] [2026-04-17 | "M96"] IA4 and IA5 (prefix semantics, commit diff truncation) — unchanged, still deferred, remain non-blocking.
- [ ] [2026-04-17 | "M93"] Note 6 (m95 doc: "four" → "seven" extracted functions) remains unaddressed due to permission gate on `.claude/milestones/*.md`; requires a manual one-line edit — no functional impact.

## Resolved
