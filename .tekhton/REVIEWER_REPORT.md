# Reviewer Report — M74 Non-Blocking Notes Sweep

## Verdict
APPROVED_WITH_NOTES

## Complex Blockers (senior coder)
- None

## Simple Blockers (jr coder)
- None

## Non-Blocking Notes
- `lib/notes_core_normalize.sh:27` — Security agent fix not applied while coder was touching this file. Add `trap 'rm -f "$tmpfile"' RETURN ERR` immediately after the `mktemp` call to clean up on SIGKILL or disk-full abort. Fix is one line; already specified exactly by security agent.
- `NON_BLOCKING_LOG.md` item 4 marked `[x]` (resolved) despite `.claude/agents/coder.md`, `.claude/agents/architect.md`, and `.claude/agents/jr-coder.md` still reading "Bash 4+" instead of "Bash 4.3+". The comment accurately explains the permission denial but the `[x]` status implies resolution. Either reopen as `[ ]` or add a corresponding HUMAN_ACTION_REQUIRED entry so this doesn't fall through the cracks.
- `docs/analysis/code-indexing-methods-comparison.md:302` — Same "Bash 4+" inconsistency noted by coder in Observed Issues; worth tracking alongside the agent-file fixes above.

## Coverage Gaps
- None

## Drift Observations
- None

---

## Review Notes

**`lib/milestone_acceptance.sh:151-156`** — Correct. `-ciE` is the right flag combination: `-c` (count), `-i` (case-insensitive), `-E` (extended regex for portable alternation). Patterns are meaningfully broader and well-commented. The `|| true` guard prevents pipeline failure when grep returns 1 (no match).

**`lib/prompts.sh:108-110`** — Comment is accurate. The while-loop processes one variable name per iteration extracted by `grep -o '{{IF:[A-Za-z_]...}}'`, so distinct variable names guarantee no cross-contamination between nested blocks. Good documentation.

**`lib/notes_core_normalize.sh:31-32`** — Fix is correct. Emitting the pending blank before toggling `in_fence` ensures a blank line immediately preceding a fence marker is preserved, consistent with the "single blank line before ``` is preserved" spec. The awk logic is sound and idempotent.

**`tests/test_notes_normalization.sh:207-210`** — Updated assertion (`≤ 4`) correctly accounts for the now-preserved blank before the fence. The comment enumerates all four blanks (before "Some text.", before fence, inside fence, after fence), which confirms the updated count is deliberate, not a test relaxation.

**`NON_BLOCKING_LOG.md`** — All 7 items have accurate resolution notes. Item 4 is the only one where the `[x]` status is misleading (see Non-Blocking Notes above).
