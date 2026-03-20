# Scout Report — Milestone 15.4: Human Notes Workflow (`--human` Flag)

## Relevant Files

- `lib/notes.sh` — Human notes management. Currently has bulk claim/resolve functions. Needs single-note operations: `pick_next_note()`, `claim_single_note()`, `resolve_single_note()`, `extract_note_text()`, `count_unchecked_notes()`.
- `tekhton.sh` — Main entry point. Already has `--human` flag parsing (lines 534-543) that sets HUMAN_MODE and HUMAN_NOTES_TAG, but lacks orchestration logic to pick notes and run the pipeline in human mode.
- `lib/finalize.sh` — Post-pipeline hooks (from M15.3). The `_hook_resolve_notes()` function (lines 85-100) calls `resolve_human_notes()` unconditionally. Needs to detect `HUMAN_MODE=true` and call `resolve_single_note()` instead.
- `lib/hooks.sh` — Utility functions (commit, archive, checks). Already called by finalize.sh. No direct modifications needed but context is relevant.

## Key Symbols

- `should_claim_notes()` in lib/notes.sh — Already checks HUMAN_MODE flag (from M15.1)
- `resolve_human_notes()` in lib/notes.sh — Bulk resolver that marks all [~] items [x] or [ ] based on CODER_SUMMARY.md. Will be called indirectly for non-HUMAN_MODE runs.
- `pick_next_note()` — NEW. Returns next unchecked [ ] note by priority (BUG > FEAT > POLISH)
- `claim_single_note()` — NEW. Marks exactly one [ ] note to [~]
- `resolve_single_note()` — NEW. Marks single [~] note to [x] or [ ] based on exit_code
- `extract_note_text()` — NEW. Strips checkbox and tag prefix from note line
- `count_unchecked_notes()` — NEW. Counts remaining [ ] notes (optional tag filter)
- `finalize_run()` in lib/finalize.sh — Hook registry orchestrator. Will invoke `_hook_resolve_notes()` which needs HUMAN_MODE detection.
- `_hook_resolve_notes()` in lib/finalize.sh — Calls resolve_human_notes() at lines 85-100. Needs conditional for single-note resolver.

## Suspected Root Cause Areas

- `lib/notes.sh` — Missing single-note operations. Must implement 5 new functions following the same pattern as bulk operations (archive pre-run snapshot, escape regex chars in sed, match literal text, handle missing file gracefully).
- `tekhton.sh` — No --human orchestration. After flag parsing (already done), needs logic to:
  1. When HUMAN_MODE=true and not --complete: pick one note, extract text as TASK, claim it, run pipeline normally, finalize_run handles resolution
  2. When HUMAN_MODE=true and --complete: outer loop to chain notes until all [x] or a note fails to resolve
- `lib/finalize.sh` line 85-100 — The `_hook_resolve_notes()` function must detect HUMAN_MODE and branch: if HUMAN_MODE=true, call resolve_single_note() for the one claimed note; else call resolve_human_notes() for bulk resolution. The single-note path is simpler: one note, binary outcome.

## Complexity Estimate

Files to modify: 3
Estimated lines of change: 175
Interconnected systems: medium
Recommended coder turns: 40
Recommended reviewer turns: 9
Recommended tester turns: 25
