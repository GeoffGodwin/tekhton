# Milestone 41: Note Triage & Sizing Gate
<!-- milestone-meta
id: "41"
status: "done"
-->

## Overview

Human notes are currently injected into the coder prompt with no pre-evaluation of
scope, complexity, or appropriateness. A one-line polish fix and a multi-system feature
rewrite receive identical treatment. This milestone adds a triage phase that evaluates
notes before execution — estimating size, detecting oversized items, and offering to
promote milestone-scale notes into proper milestones. It also introduces a standalone
`tekhton --triage` command for backlog review without execution.

Depends on Milestone 40 (Notes Core Rewrite) for note IDs, metadata layer, and tag
registry.

## Scope

### 1. Shell Heuristic Triage

**Problem:** Notes have no sizing gate. `- [ ] [FEAT] Rewrite the auth system to use
OAuth2 with PKCE flow` is treated identically to `- [ ] [POLISH] Fix button alignment`.

**Fix:**
- `triage_note(id)` — evaluates a single note and returns a disposition:
  - **FIT** — appropriate size for a single pipeline run
  - **OVERSIZED** — likely exceeds a single run; recommend promotion to milestone
- Shell heuristics (no agent call needed for high-confidence cases):
  - **Scope keywords:** "rewrite", "redesign", "migrate", "new system", "replace",
    "overhaul", "refactor entire", "add support for" → score +3 each
  - **Scale indicators:** "all", "every", "entire", "across the codebase" → score +2
  - **Multi-system markers:** mentions of 3+ distinct system nouns (detected via
    project's architecture file keywords if available) → score +2
  - **Length heuristic:** note title > 120 chars → score +1
  - **Tag weight:** BUG notes get -2 (bugs are typically scoped), POLISH gets -1
  - Score ≥ 5 → OVERSIZED (high confidence)
  - Score ≤ 1 → FIT (high confidence)
  - Score 2-4 → low confidence (escalate to agent)
- Heuristic confidence is recorded: `high` or `low`. Only `low` triggers agent
  escalation.

**Files:** `lib/notes_triage.sh` (new)

### 2. Agent Escalation (Haiku)

**Problem:** Shell heuristics can't evaluate semantic complexity — "Add WebSocket
support" could be trivial (drop-in library) or massive (custom protocol), depending
on context.

**Fix:**
- When shell heuristics return low confidence (score 2-4), escalate to a single Haiku
  agent call for a definitive assessment.
- Prompt template: `prompts/notes_triage.prompt.md`. Input: note text, tag, project
  name, architecture file summary (first 2K chars if available), and the note's
  description block if present. Total input < 3K tokens.
- Agent output: structured response with `DISPOSITION: FIT|OVERSIZED`,
  `ESTIMATED_TURNS: N`, and one-line `RATIONALE:`.
- Model: configurable via `HUMAN_NOTES_TRIAGE_MODEL` (default: `haiku`). The triage
  call is intentionally cheap — Haiku for a 3K-token input costs fractions of a cent.
- If the agent call fails (timeout, API error), fall back to FIT with a warning. Triage
  failure should never block execution.

**Files:** `lib/notes_triage.sh` (update), `prompts/notes_triage.prompt.md` (new)

### 3. Promotion Flow

**Problem:** When a note is identified as milestone-scale, the only current option is
for the user to manually delete it from HUMAN_NOTES.md and run `--add-milestone`.

**Fix:**
- When triage returns OVERSIZED for a note, the pipeline offers promotion:
  - **Confirm mode** (default, `HUMAN_NOTES_PROMOTE_MODE=confirm`): pipeline pauses
    with a prompt:
    ```
    Note n07 [FEAT] "Rewrite auth system to use OAuth2" is estimated at ~35 turns.
    This exceeds the promotion threshold (20 turns) and would work better as a milestone.

    [p] Promote to milestone  [k] Keep as note  [s] Skip this note
    ```
  - **Auto mode** (`HUMAN_NOTES_PROMOTE_MODE=auto`): promotes silently, logs the action.
- Promotion mechanics:
  - Calls `run_intake_create()` with the note text as the milestone description
  - Marks the note `[x]` with metadata annotation: `promoted:mNN`
  - The note's description block (if any) is included in the milestone content
  - Dashboard notes panel shows the note with a "promoted → mNN" badge
- The promotion threshold is configurable: `HUMAN_NOTES_PROMOTE_THRESHOLD` (default: 20
  turns). Notes with `ESTIMATED_TURNS` above this threshold trigger the promotion flow.

**Files:** `lib/notes_triage.sh` (update), `lib/inbox.sh` or `stages/intake.sh`
(promotion integration)

### 4. Triage Metadata Persistence

**Problem:** Triage results need to persist so notes aren't re-evaluated on every run.

**Fix:**
- After triage, results are stored in the note's metadata comment:
  ```
  - [ ] [FEAT] Add dark mode <!-- note:n12 created:2026-03-29 triage:fit est_turns:8 triaged:2026-03-30 -->
  ```
- `_set_note_metadata(id, key, value)` from M40 handles the update.
- On subsequent runs, `triage_note(id)` checks for existing `triage:` and `triaged:`
  metadata. If present and the note text hasn't changed, skip re-triage.
- If the user edits the note text (detected by comparing a hash stored in metadata:
  `text_hash:abc123`), the triage is invalidated and re-runs.
- Triage metadata survives rollback because M40's rollback protection preserves
  HUMAN_NOTES.md content.

**Files:** `lib/notes_triage.sh` (update), `lib/notes_core.sh` (text hash helper)

### 5. `tekhton --triage` Standalone Command

**Problem:** Users have no way to review their note backlog's triage status without
running the full pipeline.

**Fix:**
- New CLI flag: `--triage`. Runs triage on all unchecked notes and prints a report:
  ```
  Human Notes Triage Report
  ─────────────────────────────────────────────────────────
  ID    Tag     Disposition  Est. Turns  Title
  n03   BUG     fit              5       Fix login on Safari
  n07   FEAT    oversized       35       Rewrite auth to OAuth2
  n12   FEAT    fit              8       Add dark mode toggle
  n15   POLISH  fit              3       Align settings buttons
  ─────────────────────────────────────────────────────────
  4 notes: 3 fit, 1 oversized

  Recommendation: Promote n07 to a milestone before executing.
  ```
- Accepts optional tag filter: `--triage BUG` evaluates only bug notes.
- Updates triage metadata on each note (so results persist for next pipeline run).
- Refreshes the dashboard: calls `emit_dashboard_notes()` after triage completes so
  the Notes tab reflects the latest triage results.
- Does not execute any pipeline stages. Exit 0 on success.

**Files:** `tekhton.sh` (flag parsing, dispatch), `lib/notes_triage.sh` (report formatter)

### 6. Triage Integration with Pipeline Startup

**Problem:** Triage needs to run automatically before execution in `--human` mode.

**Fix:**
- After note selection in `--human` mode (single-note or `--human --complete` loop),
  run `triage_note(id)` on the selected note before claiming it.
- If disposition is OVERSIZED, enter the promotion flow (confirm or auto per config).
- If promoted, skip this note and pick the next one (in `--human --complete` loop) or
  exit with a message (in single-note mode).
- If the user chooses "keep as note" in confirm mode, proceed with execution as normal.
  The `triage:oversized` metadata stays — the user made an informed choice.
- For `--with-notes` (bulk injection), triage runs on all matching notes before claiming.
  OVERSIZED notes are listed with a warning but not auto-promoted (bulk mode is less
  interactive). User can run `--triage` first to handle them.
- Triage is skippable: `HUMAN_NOTES_TRIAGE_ENABLED=false` bypasses all of this.

**Files:** `tekhton.sh` (human mode note selection), `stages/coder.sh` (bulk notes path)

### 7. Dashboard Triage Integration

**Fix:**
- `emit_dashboard_notes()` (from M40) extended to include triage fields in each note's
  JSON: `triage_disposition`, `estimated_turns`, `triaged_at`.
- Notes tab shows triage status: "fit" (green), "oversized" (orange), "untriaged" (grey).
- Promoted notes show a linked badge: "promoted → m14".
- `--triage` command refreshes the dashboard data after running.

**Files:** `lib/dashboard_emitters.sh` (update emitter), `templates/watchtower/app.js`
(update Notes tab rendering)

## Configuration

All new config keys with defaults (added to `lib/config_defaults.sh` and documented
in `templates/pipeline.conf.example`):

```bash
# --- Human Notes Triage ---
# HUMAN_NOTES_TRIAGE_ENABLED=true          # Run triage gate before note execution
# HUMAN_NOTES_TRIAGE_MODEL=haiku           # Model for agent escalation (haiku recommended)
# HUMAN_NOTES_PROMOTE_THRESHOLD=20         # Est. turns above which to recommend promotion
# HUMAN_NOTES_PROMOTE_MODE=confirm         # confirm = ask user; auto = promote silently
```

## Acceptance Criteria

- Shell heuristics detect scope keywords and produce FIT/OVERSIZED with high confidence
  for clear-cut cases (no agent call needed)
- Low-confidence heuristic results escalate to Haiku agent (< 3K token input)
- Agent failure falls back to FIT with a warning (triage never blocks execution)
- Promote-confirm mode pauses with clear [p/k/s] prompt
- Promote-auto mode creates milestone and marks note without user interaction
- `tekhton --triage` prints a formatted report and exits without running pipeline stages
- `tekhton --triage BUG` filters to bug notes only
- Triage results are cached in note metadata; unchanged notes skip re-triage
- Edited notes (text changed) invalidate cached triage and re-evaluate
- In `--human` mode, OVERSIZED notes trigger promotion flow before claiming
- In `--with-notes` mode, OVERSIZED notes are warned but not auto-promoted
- `HUMAN_NOTES_TRIAGE_ENABLED=false` bypasses all triage logic
- Dashboard Notes tab shows triage disposition and estimated turns
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/notes_triage.sh` passes
- `shellcheck lib/notes_triage.sh` passes
- New test file `tests/test_notes_triage.sh` covers: heuristic scoring, agent escalation
  trigger, promotion flow, metadata caching, `--triage` report output

## Watch For

- **Heuristic false positives.** "Add support for dark mode" contains "add support for"
  (a scope keyword) but is typically a moderate-sized task, not milestone-scale. The tag
  weight adjustment (POLISH gets -1) and the confidence threshold (score 2-4 = low
  confidence → escalate) should catch this. Test with real-world note examples.
- **Agent prompt size.** The triage prompt must stay under 3K tokens including the
  architecture summary excerpt. If the architecture file is large, truncate to the
  first 2K chars (file listing and key modules, not implementation details).
- **Promotion during --human --complete loop.** If note N is promoted, the loop should
  advance to note N+1 without counting the promotion as a pipeline attempt against
  `MAX_PIPELINE_ATTEMPTS`. Promotions are administrative, not execution failures.
- **Race condition: triage then edit.** If the user triages a note, then edits its text
  before the next run, the text hash mismatch invalidates the cached triage. This is
  correct behavior — the edit may have changed the scope.
- **Confirm mode UX.** The [p/k/s] prompt must handle invalid input gracefully (re-prompt,
  not crash). Also handle non-interactive mode (e.g., piped input) by defaulting to "keep"
  with a warning.

## Seeds Forward

- Milestone 42 consumes triage `estimated_turns` for tag-specific turn budget adjustment
- The triage prompt template can be extended with project-specific context in future
  versions (e.g., repo map excerpts for more accurate sizing)
- The `--triage` command establishes a pattern for non-executing pipeline analysis that
  could extend to `--audit` (architecture review without execution)
