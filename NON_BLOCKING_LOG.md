# Non-Blocking Notes Log

Accumulated reviewer notes that were not blocking but should be addressed.
Items are auto-collected from `## Non-Blocking Notes` in ${REVIEWER_REPORT_FILE}.
The coder is prompted to address these when the count exceeds the threshold.

## Open
- [ ] [2026-04-12 | "M73"] `_normalize_markdown_blank_runs()` (`lib/notes_core_normalize.sh:30`) silently drops a single blank line that appears immediately before a fenced code block: `blank_pending = 0` is set by the fence handler before the pending blank is emitted, so a lone blank before ``` is lost. The spec says "collapse runs of ≥ 2 blank lines to one" — a single blank should survive. Low-risk edge case in practice (carried from cycle 1).
<!-- Items added here by the pipeline. Mark [x] when addressed. -->

## Resolved
