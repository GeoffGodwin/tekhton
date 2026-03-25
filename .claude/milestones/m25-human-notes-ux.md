#### Milestone 25: Human Notes UX Enhancement
<!-- milestone-meta
id: "25"
status: "done"
-->

Make the human notes system discoverable, easy to use, and integrated
into the pipeline feedback loop. Today HUMAN_NOTES.md is powerful but
hidden — users have to know it exists, know the format, and manually
edit a markdown file. This milestone adds CLI commands for note management
and integrates notes into the post-run experience.

Files to create:
- `lib/notes_cli.sh` — CLI note management commands:
  **Add note** (`add_human_note(text, tag)`):
  Appends a properly formatted entry to HUMAN_NOTES.md:
  `- [ ] [TAG] Note text here`
  If HUMAN_NOTES.md doesn't exist, creates it with the standard header.
  Valid tags: BUG, FEAT, POLISH (default: FEAT if omitted).
  Prints: "✓ Added [TAG] note: Note text here"

  **List notes** (`list_human_notes(filter)`):
  Prints all unchecked notes, optionally filtered by tag.
  Color-coded by tag: BUG=red, FEAT=cyan, POLISH=yellow.
  Shows count: "3 notes (1 BUG, 1 FEAT, 1 POLISH)"

  **Complete note** (`complete_human_note(number_or_text)`):
  Marks a note as checked (done). Accepts line number or text match.
  Prints: "✓ Completed: [BUG] Fix login redirect loop"

  **Clear completed** (`clear_completed_notes()`):
  Removes all checked items from HUMAN_NOTES.md. Requires confirmation.
  Prints count removed.

Files to modify:
- `tekhton.sh` — Add subcommand handling:
  - `tekhton note "Fix the login bug"` → `add_human_note "Fix the login bug"`
  - `tekhton note "Fix the login bug" --tag BUG` → `add_human_note "..." BUG`
  - `tekhton note --list` → `list_human_notes`
  - `tekhton note --list --tag BUG` → `list_human_notes BUG`
  - `tekhton note --done 3` → `complete_human_note 3`
  - `tekhton note --done "Fix login"` → `complete_human_note "Fix login"`
  - `tekhton note --clear` → `clear_completed_notes`
  Source lib/notes_cli.sh.

- `lib/finalize_display.sh` — After pipeline completion, when unchecked
  notes exist, enhance the action items display:
  ```
  ⚠ HUMAN_NOTES.md — 3 item(s) remaining
    Tip: Run `tekhton --human` to process notes, or
         `tekhton note --list` to see them
  ```
  When the pipeline is run with --human and completes a note, show:
  ```
  ✓ Completed note: [BUG] Fix login redirect loop
    2 notes remaining — run `tekhton --human` to continue
  ```

- `lib/notes.sh` — Add `get_notes_summary()` function that returns
  a structured count (total, by_tag, checked, unchecked) for use by
  other modules (Watchtower, finalize_display, report).

- `lib/init.sh` — During --init, if unchecked notes would be useful
  (e.g., health score is low, tech debt detected), suggest:
  "Tip: Use `tekhton note \"description\"` to track items for the pipeline"

- `lib/dashboard.sh` (M13) — Include notes summary in Watchtower data.
  Notes appear in the Reports tab as a "Backlog" card showing
  unchecked items by tag.

- `prompts/intake_scan.prompt.md` (M10) — When notes exist that match
  the current task's topic (keyword overlap), inject a NOTES_CONTEXT_BLOCK
  so the PM agent is aware of related human observations.

Acceptance criteria:
- `tekhton note "text"` appends properly formatted entry to HUMAN_NOTES.md
- `tekhton note "text" --tag BUG` uses specified tag
- Default tag is FEAT when --tag omitted
- `tekhton note --list` shows unchecked notes color-coded by tag with count
- `tekhton note --list --tag BUG` filters to BUG notes only
- `tekhton note --done 3` marks note on line 3 as completed
- `tekhton note --done "partial text"` finds and completes matching note
- `tekhton note --clear` removes checked items with confirmation
- HUMAN_NOTES.md created automatically if it doesn't exist
- Post-run display includes notes count with usage tip
- --human completion shows which note was processed
- Notes summary available to Watchtower and report command
- All existing notes functionality (--human, --with-notes, --notes-filter)
  continues to work unchanged
- All existing tests pass
- `bash -n lib/notes_cli.sh` passes
- `shellcheck lib/notes_cli.sh` passes

Watch For:
- The HUMAN_NOTES.md format is already established (checkbox markdown).
  The CLI commands must produce EXACTLY the same format that the existing
  parser expects. Test with `_count_unchecked_notes()` after adding.
- Note completion by text match should be fuzzy enough to be useful
  (case-insensitive substring) but not so fuzzy that it matches the wrong
  note. When multiple matches found, show all and ask user to specify.
- The `tekhton note` subcommand is the first subcommand (not a --flag).
  This is a UX precedent — if we add more subcommands later (e.g.,
  `tekhton report`, `tekhton milestone`), the parsing pattern must be
  consistent. Use positional argument detection before flag parsing.
- `--clear` should NEVER delete unchecked notes. Only checked items.
  Add a safety check that counts unchecked items before and after.

Seeds Forward:
- The subcommand pattern (`tekhton note`, `tekhton report`) establishes
  a CLI design precedent for future subcommands
- Notes integration with the PM agent enables "human observations feed
  into automated planning" — a key V4 capability
- Notes summary in Watchtower creates a backlog view that feeds into
  the future tech debt agent's work queue

Migration impact:
- New config keys: NONE
- New files in .claude/: NONE (HUMAN_NOTES.md already exists)
- Breaking changes: NONE — existing notes behavior unchanged
- Migration script update required: NO
