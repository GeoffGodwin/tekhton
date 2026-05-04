# Milestone 73: Notes Tidying — Real Line Deletion + Section Normalization
<!-- milestone-meta
id: "73"
status: "done"
-->

## Overview

Developer feedback: `HUMAN_NOTES.md` doesn't keep itself tidy when it trims
completed items. Over successive pipeline runs the file grows steadily as blank
lines accumulate where items used to live — the removal code "blanks" lines
without actually normalizing the surrounding whitespace. The same pattern
exists in `NON_BLOCKING_LOG.md`'s `## Resolved` section cleanup
(`lib/drift_cleanup.sh`).

This milestone is a surgical fix to two functions plus a small shared
normalization helper:

1. `clear_completed_human_notes()` — `lib/notes.sh:130-178`
2. `clear_resolved_nonblocking_notes()` — `lib/drift_cleanup.sh:250-300`

Both already use the correct pattern of streaming to a tmpfile and swapping,
but neither collapses redundant blank-line runs left behind after items are
dropped. The fix is to add a post-processing normalization pass that:

- Collapses any run of ≥ 2 consecutive blank lines inside a section to a
  single blank line.
- Trims leading/trailing blank lines from the file.
- Preserves at most one blank line between the last item of a section and the
  next `## ` header.

This is a small, mechanical, well-bounded milestone. It exists on its own so
the fix can land cleanly and get dedicated regression coverage.

## Design Decisions

### 1. Normalization helper in new `lib/notes_core_normalize.sh`

Add one helper — `_normalize_markdown_blank_runs <file>` — that reads a file
and rewrites it with:

- Leading blank lines stripped.
- Trailing blank lines stripped (but keep a single trailing newline).
- Interior runs of ≥ 2 blank lines collapsed to a single blank line.

Shared by both fix sites. The helper is ≤ 25 lines but `lib/notes_core.sh`
is already at 332 lines (over M71's 300-line cap), so the helper lives in
a new sibling file `lib/notes_core_normalize.sh` that is sourced alongside
`notes_core.sh`. This keeps both files comfortably under the cap.

### 2. Why normalization instead of smarter skip logic

Both `clear_completed_human_notes()` and `clear_resolved_nonblocking_notes()`
already drop the content they intend to drop. The accumulation bug comes from
blank lines the user *did* write around the removed items, or from blank lines
that sit between successive `[x]` entries in a run of multi-removed items.

Rather than trying to reason about "which blank line belongs to which item,"
we do the mechanically-safe thing: drop items as today, then collapse the
result. This is idempotent — running it repeatedly on a clean file produces
the identical output.

### 3. Safety invariants — do not touch section headers or bullet content

The normalization pass works on blank lines only. It never rewrites or drops
a non-blank line. `## `, `### `, `- [ ]`, `- [x]`, `- [~]`, `> `, and HTML
metadata comments (`<!-- note:nNN ... -->`) pass through untouched.

### 4. Fenced code blocks are respected

Inside a fenced code block (between ``` markers) blank lines are meaningful
and must not be collapsed. The helper tracks fence state and skips
normalization while `in_fence=true`. HUMAN_NOTES files rarely contain fenced
code blocks, but the helper gets it right so it's safe to reuse anywhere.

### 5. Regression test: line-count stability over repeated runs

The core bug is "file grows over time." The test asserts that running the
cleanup function N times in a row on a file with no removable items produces
the same byte-for-byte output each time. A second test asserts that removing
items from a file with inter-item blank lines produces a file whose blank-line
count matches expectation — not a one-less-than-before stagger.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Functions fixed | 2 | `clear_completed_human_notes`, `clear_resolved_nonblocking_notes` |
| New lib file | 1 | `lib/notes_core_normalize.sh` — hosts `_normalize_markdown_blank_runs` |
| Tests added | 2 | Line-count stability + inter-item blank handling |
| Existing tests touched | 2 | `tests/test_clear_resolved_nonblocking_notes.sh`, `tests/test_cleanup_notes.sh` — add blank-line assertions |
| New config variables | 0 | Pure bug fix; no config surface change |
| New template variables | 0 | — |
| Files modified (lib) | 3 | `lib/notes.sh`, `lib/drift_cleanup.sh`, `tekhton.sh` (source new file) |

## Implementation Plan

### Step 1 — Add the normalization helper

Create **`lib/notes_core_normalize.sh`** (new file — `lib/notes_core.sh` is
already 332 lines, over M71's 300-line threshold, so do NOT add to it).
Content:

```bash
# _normalize_markdown_blank_runs FILE
#
# Rewrites FILE in-place, normalizing blank-line runs:
#   - Strips leading blank lines entirely.
#   - Strips trailing blank lines (keeps a single terminating newline).
#   - Collapses interior runs of >= 2 blank lines to a single blank line.
#   - Preserves blank lines inside fenced code blocks (``` ... ```).
#
# Idempotent: running twice on the same file produces identical output.
# Safe: never rewrites a non-blank line; header, bullet, and description
# lines pass through unchanged.
_normalize_markdown_blank_runs() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/norm_XXXXXXXX")
    awk '
        BEGIN { in_fence = 0; saw_content = 0; blank_pending = 0 }
        /^```/ { in_fence = !in_fence; print; saw_content = 1; blank_pending = 0; next }
        in_fence { print; next }
        /^[[:space:]]*$/ {
            if (saw_content) { blank_pending = 1 }
            next
        }
        {
            if (blank_pending) { print ""; blank_pending = 0 }
            print
            saw_content = 1
        }
    ' "$file" > "$tmpfile"
    mv "$tmpfile" "$file"
}
```

Source the new file from `tekhton.sh` BEFORE `lib/notes_core.sh`,
`lib/drift_cleanup.sh`, and `lib/notes_cleanup.sh` so the helper is
defined when those files' functions execute.

Validate: source the new file and run
`bash tests/run_tests.sh` — zero behavior change so far (no caller invokes
the helper yet).

### Step 2 — Call the helper from `clear_completed_human_notes`

Edit `lib/notes.sh` around line 168 (right after the `mv "$tmpfile" "$notes_file"`
that currently finalizes the rewrite, before the safety check of unchecked
counts). Add:

```bash
_normalize_markdown_blank_runs "$notes_file"
```

The unchecked-count safety check that follows must run *after* normalization,
since normalization does not touch non-blank content.

### Step 3 — Call the helper from `clear_resolved_nonblocking_notes`

Edit `lib/drift_cleanup.sh` around line 296 (right after
`mv "$tmpfile" "$nb_file"`). Add:

```bash
_normalize_markdown_blank_runs "$nb_file"
```

Note: `lib/drift_cleanup.sh` does not currently source `lib/notes_core.sh`
directly — it depends on the top-level `tekhton.sh` having sourced both.
Verify the source order in `tekhton.sh` — `notes_core.sh` must load before
`drift_cleanup.sh` for the helper call to resolve. If not, move the
`source` line in `tekhton.sh` accordingly. (Both files are currently
sourced at the same level; this is mostly a sanity check.)

### Step 4 — Also normalize after `mark_note_resolved`/`mark_note_deferred`

These functions live in `lib/notes_cleanup.sh` (per the grep output). Both
rewrite `NON_BLOCKING_LOG.md` in place to move an item from `## Open` to
`## Resolved` or `## Deferred`. They are susceptible to the same
blank-line drift over long-running projects because they never collapse
stale spacing.

Audit `lib/notes_cleanup.sh` during implementation and add a single
`_normalize_markdown_blank_runs "$nb_file"` call after each in-place rewrite.
If the code path is hot (called once per item) the overhead is negligible —
the helper is O(N) in file size and the file is small.

### Step 5 — Add line-count stability regression test

Create `tests/test_notes_normalization.sh` with three scenarios:

1. **Idempotent on a clean file.** Start with `HUMAN_NOTES.md` containing no
   `[x]` items and normal spacing. Call `clear_completed_human_notes` five
   times in a row. Assert the SHA-256 of the file is identical after each
   call.
2. **Interior-blank collapse after removal.** Start with a file that has
   `- [ ] A`, blank, `- [x] B`, `- [x] C`, blank, `- [ ] D`. After
   `clear_completed_human_notes`, assert:
   - `- [ ] A` and `- [ ] D` remain.
   - No `- [x]` lines remain.
   - There is exactly one blank line between `- [ ] A` and `- [ ] D` (not
     two, not three).
3. **Description block removal with trailing blank.** Start with
   `- [x] B\n  > Description\n  \n- [ ] C`. After
   `clear_completed_human_notes`, assert `- [x] B` and its description are
   gone and only one blank line sits between the top of the section and
   `- [ ] C`.

Wire the new test into `tests/run_tests.sh`'s main loop.

### Step 6 — Strengthen existing tests

Edit `tests/test_clear_resolved_nonblocking_notes.sh` to assert the same
"blank-line count matches expectation" invariant after the function runs —
not just "resolved items are gone."

Edit `tests/test_cleanup_notes.sh` similarly.

### Step 7 — Shellcheck + full test suite

```bash
shellcheck lib/notes.sh lib/notes_core_normalize.sh lib/drift_cleanup.sh lib/notes_cleanup.sh
bash tests/run_tests.sh
```

Must be zero warnings and zero failures.

### Step 8 — Version bump

Edit `tekhton.sh` — bump `TEKHTON_VERSION` to `3.73.0`.

## Files Touched

### Added
- `lib/notes_core_normalize.sh` — hosts `_normalize_markdown_blank_runs`
- `tests/test_notes_normalization.sh` — new regression test suite
- `.claude/milestones/m73-notes-tidying-line-deletion.md` — this file

### Modified
- `lib/notes.sh` — call helper from `clear_completed_human_notes`
- `lib/drift_cleanup.sh` — call helper from `clear_resolved_nonblocking_notes`
- `lib/notes_cleanup.sh` — call helper after `mark_note_resolved` /
  `mark_note_deferred` rewrites (if audit confirms they're needed)
- `tekhton.sh` — source `lib/notes_core_normalize.sh` BEFORE
  `lib/notes_core.sh`, `lib/drift_cleanup.sh`, and `lib/notes_cleanup.sh`
- `tests/test_clear_resolved_nonblocking_notes.sh` — add blank-line assertions
- `tests/test_cleanup_notes.sh` — add blank-line assertions
- `tests/run_tests.sh` — register `test_notes_normalization.sh`
- `tekhton.sh` — bump `TEKHTON_VERSION` to `3.73.0`
- `.claude/milestones/MANIFEST.cfg` — add M73 row

## Acceptance Criteria

- [ ] `lib/notes_core_normalize.sh` exports `_normalize_markdown_blank_runs` helper
- [ ] Helper strips leading blank lines, trailing blank lines, and collapses
      interior runs of ≥ 2 blanks to exactly one
- [ ] Helper preserves blank lines inside fenced code blocks
- [ ] Helper is idempotent — second call produces identical output
- [ ] `clear_completed_human_notes` calls the helper after its rewrite
- [ ] `clear_resolved_nonblocking_notes` calls the helper after its rewrite
- [ ] `mark_note_resolved` and `mark_note_deferred` (in `lib/notes_cleanup.sh`)
      call the helper after their in-place rewrites
- [ ] `tests/test_notes_normalization.sh` exists and is registered in
      `tests/run_tests.sh`
- [ ] Test scenario 1 (idempotent on clean file) passes — SHA-256 unchanged
      after 5 successive calls
- [ ] Test scenario 2 (interior-blank collapse) passes — exactly one blank
      line between surviving items
- [ ] Test scenario 3 (description block with trailing blank) passes
- [ ] `tests/test_clear_resolved_nonblocking_notes.sh` asserts blank-line
      count stability
- [ ] `tests/test_cleanup_notes.sh` asserts blank-line count stability
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck lib/notes.sh lib/notes_core_normalize.sh lib/drift_cleanup.sh
      lib/notes_cleanup.sh` reports zero warnings
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.73.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M73 row

## Watch For

- **Never rewrite non-blank lines.** The helper's job is purely to collapse
  whitespace runs. If it ever rewrites a bullet or a header, something went
  wrong. The awk rule is `/^[[:space:]]*$/` for blanks — everything else
  must fall through to `print`.
- **Source order.** `lib/notes_core.sh` must be sourced before
  `lib/drift_cleanup.sh` and `lib/notes_cleanup.sh` in `tekhton.sh`, so the
  helper is defined when those files' functions execute. Grep `tekhton.sh`
  for the `source` order and verify before declaring victory.
- **Fenced code block awareness.** If the helper sees ``` ... ``` it must
  toggle `in_fence` and pass blank lines through unchanged. Otherwise a note
  description that happens to contain a fenced example will lose formatting
  after the first run. HUMAN_NOTES rarely contains fenced code, but the
  helper is reused in future callers, so get it right the first time.
- **Don't regress the existing safety check.** `clear_completed_human_notes`
  already verifies `unchecked_before == unchecked_after`. Normalization
  should happen before that check so the comparison runs against the final
  on-disk state. Verify ordering in the diff.
- **`continue` vs. `:` is not the bug.** Both patterns correctly skip lines
  from being written to the tmpfile. The blank-line accumulation comes from
  pre-existing blanks the user wrote *around* the removed items. Don't
  "fix" the skip pattern — fix the downstream normalization.
- **Do NOT change the function signatures.** Any caller that expects the
  existing return value / stdout behavior must still work. In particular
  `clear_resolved_nonblocking_notes` prints resolved items to stdout — that
  contract is unchanged.
- **`lib/notes_cleanup.sh` audit first, edit second.** Don't blindly sprinkle
  normalization calls. Read each mutating function first and confirm it
  actually performs an in-place rewrite that could accumulate blanks. If a
  function only appends, normalization is unnecessary.
- **File-length guardrail.** `lib/notes_core.sh` is already **332 lines**
  (over M71's 300-line threshold). Adding the helper here would push it
  further over, so extract the helper into a new
  `lib/notes_core_normalize.sh` from the start — do NOT land it inside
  `notes_core.sh`. Source the new file from `tekhton.sh` before
  `notes_core.sh`. Follow M71 shell hygiene + M70 file-length rules.
  Check `wc -l` before committing.

## Seeds Forward

- **Broader markdown normalization.** The helper is generic enough to reuse
  on any Tekhton-managed markdown file. Future milestones that touch
  `ARCHITECTURE_LOG.md`, `DRIFT_LOG.md`, or `MILESTONE_ARCHIVE.md` could
  pipe through the same helper to keep them tidy. Out of scope here.
- **User-facing "tidy notes" command.** A `tekhton --tidy-notes` CLI
  subcommand could manually run all normalization passes for users who
  edit HUMAN_NOTES.md by hand between runs. Small add, could be a follow-up
  devx milestone if the demand exists.
- **CI lint for markdown blank runs.** Tekhton's own repo could run the
  helper against its own `.md` files in CI to keep our docs tidy. Out of
  scope for M73 — but cheap to bolt on once the helper exists.
