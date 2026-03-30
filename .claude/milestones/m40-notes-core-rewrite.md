# Milestone 40: Human Notes Core Rewrite
<!-- milestone-meta
id: "40"
status: "pending"
-->

## Overview

The human notes system (`lib/notes.sh`, `lib/notes_single.sh`, `lib/notes_cli.sh`,
`lib/notes_cli_write.sh`) was built in V1 and has accumulated structural debt across
V2 and V3. Note identity relies on exact text matching (fragile when users edit notes
mid-run), the tag system is hardcoded in six locations, claim/resolve logic has two
divergent paths (bulk and single) with documented edge cases in finalization, and
notes carry no metadata (no timestamps, no estimates, no triage state). This milestone
rewrites the notes internals with stable IDs, a metadata layer, a unified
claim/resolve path, a data-driven tag registry, and safety guarantees for mid-run
watchtower injection and rollback.

The file format (`HUMAN_NOTES.md`) remains human-editable. Backward compatibility is
preserved via lazy migration — legacy notes without IDs continue to work via text
matching and receive IDs when first touched by the pipeline.

## Scope

### 1. Note ID System

**Problem:** `claim_single_note()` and `resolve_single_note()` use exact string
matching (`[[ "$line" = "$note_line" ]]`). If the user edits note text between claim
and resolve (which is the entire point of out-of-band editing), resolution silently
fails. The bulk path in `resolve_human_notes()` parses free-text from
CODER_SUMMARY.md using regex — also fragile.

**Fix:**
- Notes get stable IDs via HTML comment metadata appended to the checkbox line:
  ```
  - [ ] [BUG] Fix login when email has plus sign <!-- note:n07 created:2026-03-28 priority:high source:watchtower -->
    > Login fails on Safari 17. Steps: register with user+test@example.com, log in.
  ```
- IDs are auto-assigned by `add_human_note()` (format: `n01`, `n02`, ..., monotonic
  within the file). Next ID is derived by scanning existing IDs in `HUMAN_NOTES.md`.
- All claim/resolve operations use ID-based matching as primary, with text-matching
  fallback for legacy notes.
- Description blocks (indented `>` lines below the checkbox) are preserved by all
  operations that modify the file.

**New functions:**
- `_next_note_id()` — scan HUMAN_NOTES.md for highest existing ID, return next
- `_find_note_by_id(id)` — return the full line for a note by its ID
- `_parse_note_metadata(line)` — extract id, created, priority, source, triage fields
- `_set_note_metadata(id, key, value)` — update a single metadata field in-place

**Files:** `lib/notes_core.sh` (new), `lib/notes_cli.sh` (update `add_human_note`)

### 2. Unified Claim/Resolve

**Problem:** Two divergent code paths exist:
- **Bulk:** `claim_human_notes()` / `resolve_human_notes()` in `notes.sh` — marks ALL
  unchecked notes as `[~]`, resolves by parsing CODER_SUMMARY.md free text
- **Single:** `claim_single_note()` / `resolve_single_note()` in `notes_single.sh` —
  marks one note by exact text match

The finalization hook (`_hook_resolve_notes` in `finalize.sh:102`) branches on
`HUMAN_MODE` to decide which path to use, with a documented edge case where
`HUMAN_MODE=true` but `CURRENT_NOTE_LINE` is empty.

**Fix:**
- Single unified API: `claim_note(id)` and `resolve_note(id, outcome)` where outcome
  is `complete` or `reset`. Both operate by note ID.
- `claim_notes_batch(filter)` — claims all matching notes, returns list of claimed IDs.
  Used by `--with-notes` and `--notes-filter` paths (replaces `claim_human_notes()`).
- `resolve_notes_batch(ids, exit_code)` — resolves a list of IDs based on exit code.
  Replaces the CODER_SUMMARY.md parsing path — the pipeline tracks which IDs were
  claimed and resolves them based on pipeline outcome.
- `_hook_resolve_notes` in `finalize.sh` simplified to one path: resolve whatever IDs
  are in `CLAIMED_NOTE_IDS` (set during claiming). No HUMAN_MODE branching needed.
- The `CURRENT_NOTE_LINE` variable is replaced by `CURRENT_NOTE_ID`.

**Deleted code:**
- `claim_human_notes()`, `resolve_human_notes()` from `notes.sh`
- `claim_single_note()`, `resolve_single_note()` from `notes_single.sh`
- CODER_SUMMARY.md `## Human Notes Status` parsing logic

**Files:** `lib/notes_core.sh` (new), `lib/notes.sh` (gutted), `lib/notes_single.sh`
(gutted or deleted), `lib/finalize.sh` (simplify hook), `stages/coder.sh` (use new API),
`tekhton.sh` (replace CURRENT_NOTE_LINE with CURRENT_NOTE_ID)

### 3. Tag Registry

**Problem:** BUG/FEAT/POLISH is hardcoded in `_validate_tag()`, `_section_for_tag()`,
`_tag_to_section()`, `pick_next_note()` awk scripts, `list_human_notes_cli()` color
mapping, and `coder.sh` guidance strings. Adding a new tag requires touching six files.

**Fix:**
- Associative array registry in `notes_core.sh`:
  ```bash
  declare -A _NOTE_TAG_SECTION=( [BUG]="## Bugs" [FEAT]="## Features" [POLISH]="## Polish" )
  declare -A _NOTE_TAG_COLOR=( [BUG]="$RED" [FEAT]="$CYAN" [POLISH]="$YELLOW" )
  declare -a _NOTE_TAG_PRIORITY=( BUG FEAT POLISH )  # Priority order for pick_next_note
  ```
- All tag validation, section mapping, color lookup, and priority ordering read from
  the registry. Adding a tag = adding entries to these three structures.
- `pick_next_note()` iterates `_NOTE_TAG_PRIORITY` instead of hardcoded section list.
- `_ensure_notes_file()` generates section headings from the registry.

**Files:** `lib/notes_core.sh` (new), `lib/notes_cli.sh` (update), `lib/notes_single.sh`
(update or absorb into notes_core.sh)

### 4. Lazy Migration

**Problem:** Existing HUMAN_NOTES.md files in active projects have no IDs or metadata.
A forced migration would be disruptive.

**Fix:**
- On first pipeline run after upgrade, `migrate_legacy_notes()` scans HUMAN_NOTES.md.
  Any note line matching `^- \[[ x~]\] ` that lacks a `<!-- note:nNN` comment gets an
  ID assigned and metadata appended.
- Migration is idempotent — running it twice produces the same result.
- Migration preserves all existing content (descriptions, comments, section headings).
- Migration runs automatically at startup (like `migrate_inline_milestones()`), guarded
  by a version marker: `<!-- notes-format: v2 -->` added at top of file after migration.
- Pre-migration backup: `HUMAN_NOTES.md.v1-backup` created before modification.

**Files:** `lib/notes_migrate.sh` (new)

### 5. Watchtower Inbox Safety & Rich Parsing

**Problem:** Three safety issues exist with mid-run watchtower note injection:

1. **Git stash swallows inbox files.** `create_run_checkpoint()` (line 1759) runs
   `git stash push --include-untracked` AFTER `process_watchtower_inbox()` (line 1529).
   If a user submits a note via Watchtower mid-run, the file lands in
   `.claude/watchtower_inbox/`. On rollback, `git clean -fd` deletes it. The note is
   gone with no trace.

2. **`git add -A` sweeps inbox files.** `_do_git_commit()` stages everything. Mid-run
   inbox files get committed as raw inbox files (never processed into HUMAN_NOTES.md).
   On the next run, `process_watchtower_inbox()` won't find them because they're already
   committed and removed from the inbox.

3. **Watchtower captures priority and description but they're discarded.** `_process_note()`
   in `inbox.sh:45-76` only extracts the `- [ ] [TAG] Title` line. The description body
   and priority metadata are thrown away.

**Fix:**
- Add `.claude/watchtower_inbox/` to the `.gitignore` template generated by `--init`.
  For existing projects, the migration in Scope 4 adds the entry if missing.
- Pre-commit inbox drain: before `_do_git_commit()` in `finalize.sh`, call
  `drain_pending_inbox()` — a lightweight function that processes any new inbox files
  into HUMAN_NOTES.md. These notes won't be triaged or executed in the current run,
  but they'll be persisted in the committed file.
- `_process_note()` updated to extract the full watchtower note structure (title,
  description, priority, timestamp, source) and pass them to `add_human_note()` which
  stores them as metadata on the note line and as an indented description block.
- Duplicate detection: before adding, check if a note with identical tag + title (case-
  insensitive) already exists. If so, skip with a warning.

**Files:** `lib/inbox.sh` (update), `lib/finalize.sh` (add drain hook),
`templates/pipeline.conf.example` (add inbox to gitignore section)

### 6. HUMAN_NOTES.md Rollback Protection

**Problem:** `rollback_last_run()` uses `git revert` (for committed runs) or
`git checkout -- . && git clean -fd` (for uncommitted runs). Both destroy mid-run
edits to HUMAN_NOTES.md. Since notes are user-authored content, the pipeline should
never wholesale-revert them.

**Fix:**
- Before `create_run_checkpoint()`, snapshot note states: record which note IDs are in
  `[ ]`, `[~]`, and `[x]` state. Store in the checkpoint metadata JSON:
  ```json
  {
    "note_states": {"n01": "x", "n03": "~", "n05": " "},
    ...existing fields...
  }
  ```
- `rollback_last_run()` skips HUMAN_NOTES.md in its revert/checkout operation. After
  the main rollback completes, it restores note states from the checkpoint: any note
  that was `[~]` (claimed by this run) gets reset to `[ ]`. Notes that were `[x]`
  before the run stay `[x]`. Notes added mid-run (no entry in the snapshot) are left
  untouched.
- This means rollback undoes the pipeline's claim/resolve actions on notes without
  touching any user edits to note text, new notes added mid-run, or manual completions.

**Files:** `lib/checkpoint.sh` (update snapshot and rollback), `lib/notes_core.sh`
(add `snapshot_note_states()` and `restore_note_states()`)

### 7. Dashboard Notes Panel

**Problem:** The Watchtower dashboard shows notes only as aggregate counts in the
Action Items section. There's no way to see individual notes, their states, metadata,
or triage results.

**Fix:**
- New emitter: `emit_dashboard_notes()` reads HUMAN_NOTES.md, parses all notes with
  metadata, writes `data/notes.js` containing `window.TK_NOTES` with structured data:
  ```json
  [
    {"id": "n07", "tag": "BUG", "title": "Fix login...", "status": "open",
     "priority": "high", "source": "watchtower", "created": "2026-03-28",
     "description": "Login fails on Safari 17..."}
  ]
  ```
- New "Notes" tab (tab 6) in the dashboard UI. Table view with columns: ID, Tag
  (color-coded badge), Title, Status (open/claimed/done/promoted), Priority, Source
  (cli/watchtower icon). Sortable by priority and status. Filter by tag.
- The existing Action Items counts remain but link to the Notes tab for detail.

**Files:** `lib/dashboard_emitters.sh` (add emitter), `templates/watchtower/app.js`
(add Notes tab rendering), `templates/watchtower/index.html` (add tab),
`templates/watchtower/style.css` (note status badges)

## Acceptance Criteria

- `add_human_note()` auto-assigns IDs; new notes have `<!-- note:nNN ... -->` metadata
- `claim_note(id)` / `resolve_note(id, outcome)` work by ID for notes with IDs
- Legacy notes without IDs fall back to text matching (backward compat)
- `migrate_legacy_notes()` adds IDs to all existing notes idempotently
- Tag registry is data-driven: adding a tag requires updating only the registry arrays
- `_hook_resolve_notes` in finalize.sh uses a single code path (no HUMAN_MODE branch)
- `CURRENT_NOTE_ID` replaces `CURRENT_NOTE_LINE` throughout tekhton.sh and state.sh
- `.claude/watchtower_inbox/` is in `.gitignore` template; existing projects get it
  added during migration
- Mid-run watchtower note submissions survive both pipeline commit and rollback
- `drain_pending_inbox()` processes new inbox files before `_do_git_commit()`
- `rollback_last_run()` restores note claim states without reverting user edits or
  deleting mid-run notes
- `_process_note()` preserves watchtower description and priority as note metadata
- Duplicate notes (same tag + title) are detected and skipped on inbox processing
- `emit_dashboard_notes()` produces `data/notes.js` with per-note structured data
- Dashboard Notes tab displays all notes with status badges and tag filtering
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/notes_core.sh lib/notes_migrate.sh` passes
- `shellcheck lib/notes_core.sh lib/notes_migrate.sh` passes

## Watch For

- **HTML comment metadata and markdown rendering.** The `<!-- note:nNN -->` comments
  are invisible in GitHub/rendered markdown but visible in raw text editors. Users who
  edit HUMAN_NOTES.md must not accidentally delete them. The migration should add a
  brief comment at the top explaining the format: `<!-- IDs are auto-managed by Tekhton.
  Do not remove note: comments. -->`.
- **Note ID monotonicity.** IDs must be unique within the file but don't need to be
  sequential. If note n05 is deleted, n05 is never reused — next ID is based on the
  highest existing ID. This prevents confusion in logs and dashboard.
- **Rollback atomicity.** The note state restore must happen AFTER the main git
  rollback completes. If the git revert fails, note states should not be modified.
- **Inbox drain timing.** `drain_pending_inbox()` runs just before commit. If it finds
  notes, they're added to HUMAN_NOTES.md and included in the commit. This is correct —
  the notes exist in the committed state. But the drain must not trigger triage (that's
  Milestone 41). It just persists them as unchecked notes.
- **State.sh compatibility.** The pipeline state file stores `CURRENT_NOTE_LINE` for
  crash recovery. The migration to `CURRENT_NOTE_ID` must handle resume from a
  pre-migration state file (CURRENT_NOTE_LINE present, CURRENT_NOTE_ID absent).
- **`_NOTES_FILE` constant.** `notes_cli.sh` defines `_NOTES_FILE="HUMAN_NOTES.md"`.
  The new core should use this same constant (or a shared one) rather than introducing
  a second variable.
- **Description block parsing.** Indented `>` lines below a note are the description.
  All file-modifying operations (claim, resolve, migrate, clear) must preserve these
  blocks. The simplest approach: when iterating lines, track "current note" and treat
  subsequent `>` or `  >` lines as belonging to it.

## Seeds Forward

- Milestone 41 consumes note IDs and metadata for the triage gate
- Milestone 42 consumes the tag registry for specialized prompt template selection
- The `emit_dashboard_notes()` emitter is extended by M41 (triage fields) and M42
  (execution outcomes)
- The checkpoint note-state snapshot enables M41 to cache triage results in metadata
  without them being lost on rollback
