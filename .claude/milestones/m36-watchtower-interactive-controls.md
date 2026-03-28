# Milestone 36: Watchtower Interactive Controls (Input Layer)

## Overview

Watchtower is currently read-only — a glass pane for observing pipeline execution.
This milestone adds an input layer: users can submit human notes (bugs, features,
polish), create new milestones, and queue ad hoc tasks directly from the Watchtower
UI. All input is file-based (Watchtower writes structured files that Tekhton reads
on the next run), preserving the zero-server architecture.

## Motivation

Today, submitting work to Tekhton requires terminal access:
- New milestones: manually create `.md` file + edit `MANIFEST.cfg`
- Bug reports: manually edit `HUMAN_NOTES.md` with correct `[BUG]` tag format
- Feature requests: edit `HUMAN_NOTES.md` with `[FEAT]` tag
- Ad hoc tasks: run `tekhton.sh "task description"` from CLI

Watchtower already has the user's browser open. Adding input forms turns it from
a monitoring tool into a lightweight project management interface, closing the loop
between observing pipeline output and feeding it new work.

## Scope

### 1. New "Actions" Tab

Add a fifth tab to the Watchtower nav bar: **Actions**. This tab contains forms
for submitting work items. The tab is always available regardless of pipeline state
(unlike Live Run which is most useful during execution).

Layout: card-based form sections, similar to Reports accordion style.

**Files:** `templates/watchtower/index.html`, `templates/watchtower/app.js`,
`templates/watchtower/style.css`

### 2. Human Notes Submission

A form for submitting bug reports, feature requests, and polish items.

**Form fields:**
- **Type** (required): Radio buttons — BUG | FEAT | POLISH
- **Title** (required): Single-line text input (max 120 chars)
- **Description** (optional): Textarea for details (max 2000 chars)
- **Priority** (optional): Low | Medium | High (default: Medium)
- **Submit** button

**On submit:** Watchtower writes a structured file to `.claude/watchtower_inbox/`
(a new staging directory) with naming convention:
`note_<timestamp>_<type>.md`

File format:
```markdown
<!-- watchtower-note -->
- [ ] [BUG] Title goes here

Description text goes here.

Priority: Medium
Submitted: 2025-01-15T10:30:00Z
Source: watchtower
```

**Pipeline integration:** At pipeline startup, Tekhton checks
`.claude/watchtower_inbox/` for `note_*.md` files. Each file's content is appended
to `HUMAN_NOTES.md` using the existing `add_note()` function from `lib/notes_cli.sh`,
then the inbox file is moved to `.claude/watchtower_inbox/processed/`.

**Validation:** Client-side validation prevents empty titles. Type is required.
Description is optional but encouraged.

**Files:** `templates/watchtower/app.js`, `lib/notes_cli.sh` (inbox reader),
`tekhton.sh` (startup inbox check)

### 3. Milestone Submission

A form for creating new milestones from the Watchtower UI.

**Form fields:**
- **ID** (required): Auto-generated as next `mNN` (reads current manifest), editable
- **Title** (required): Single-line text input (max 100 chars)
- **Description** (required): Textarea for scope description (max 5000 chars)
- **Depends on** (optional): Multi-select from existing milestone IDs
- **Parallel group** (optional): Text input (existing groups shown as suggestions)
- **Submit** button

**On submit:** Watchtower writes two files to `.claude/watchtower_inbox/`:
1. `milestone_<id>.md` — The milestone file content:
   ```markdown
   # Milestone NN: Title

   ## Overview

   Description text from form.

   ## Scope

   (To be detailed during planning or execution)

   ## Acceptance Criteria

   - (To be defined)

   ## Watch For

   - (To be defined)
   ```
2. `manifest_append_<id>.cfg` — A single manifest line:
   ```
   mNN|Title|pending|deps|milestone_mNN.md|parallel_group
   ```

**Pipeline integration:** At pipeline startup, Tekhton checks for
`manifest_append_*.cfg` files in the inbox. Each is validated (ID doesn't collide,
deps exist) and appended to `MANIFEST.cfg`. The corresponding `.md` file is moved
to the milestones directory. Processed inbox files move to `processed/`.

**Form intelligence:**
- Auto-reads `TK_MILESTONES` to suggest next ID and show dependency options
- Shows existing parallel groups as datalist suggestions
- Disables submit if ID conflicts with existing milestone
- Preview section shows how the milestone will appear in the Milestone Map tab

**Files:** `templates/watchtower/app.js`, `lib/milestone_dag.sh` (inbox reader),
`tekhton.sh` (startup inbox check)

### 4. Ad Hoc Task Queue

A simple form for queuing one-off tasks.

**Form fields:**
- **Task description** (required): Textarea (max 2000 chars)
- **Submit** button

**On submit:** Writes `task_<timestamp>.txt` to `.claude/watchtower_inbox/`.
The file contains the raw task description.

**Pipeline integration:** `tekhton.sh` checks for `task_*.txt` files and offers
them in the next `--human` or `--complete` run. Not auto-executed — surfaced as
available tasks.

**Files:** `templates/watchtower/app.js`, `tekhton.sh`

### 5. Inbox Status Display

The Actions tab shows a "Pending Submissions" section listing items currently in
the inbox (not yet processed by a pipeline run). Uses existing `TK_RUN_STATE` or
a new `TK_INBOX` data file to surface queued items.

**New emitter:** `emit_dashboard_inbox()` reads `.claude/watchtower_inbox/` and
generates `data/inbox.js` listing pending items by type.

**Files:** `lib/dashboard_emitters.sh`, `templates/watchtower/app.js`,
`templates/watchtower/index.html` (new script tag for inbox.js)

### 6. File Write Mechanism

Watchtower runs as a static HTML page opened from `file://` protocol. Writing
files from JavaScript in a browser is restricted. Two approaches:

**Approach A (recommended): Download prompt**
- On submit, generate file content as a Blob
- Trigger browser download via `<a download="filename">` click
- User saves the file to `.claude/watchtower_inbox/` directory
- Show clear instructions: "Save this file to: [path shown]"

**Approach B (http server mode): Direct write via POST**
- When served via `python3 -m http.server` or similar, add a tiny CGI/handler
  that accepts POST requests and writes files
- `tools/watchtower_server.py` — lightweight HTTP server with a `/api/submit`
  endpoint that writes to the inbox directory
- Auto-detected by Watchtower: if `fetch('/api/ping')` succeeds, use POST;
  otherwise fall back to Approach A

**Recommended default:** Ship both. Approach A works everywhere. Approach B is
opt-in for users who want seamless submission. The server script is <100 lines.

**Files:** `templates/watchtower/app.js`, `tools/watchtower_server.py` (new)

## Acceptance Criteria

- Actions tab appears in Watchtower navigation
- Human Notes form validates input and generates correctly formatted note files
- Milestone form auto-suggests next ID and validates against collisions
- Milestone form shows dependency options from current manifest
- Ad hoc task form generates task files
- Pending submissions section shows queued items from inbox
- Download-prompt approach works on `file://` protocol (Chrome, Firefox)
- HTTP server mode (opt-in) allows direct file writing via POST
- Pipeline startup processes inbox items: notes appended to HUMAN_NOTES.md,
  milestones added to MANIFEST.cfg, task files surfaced
- Processed inbox items moved to `processed/` subdirectory
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n` passes for any modified `.sh` files
- `shellcheck` passes for any modified `.sh` files
- New `tools/watchtower_server.py` passes basic smoke test

## Watch For

- **Security:** The HTTP server (Approach B) binds to `localhost` only. Never
  expose to `0.0.0.0`. The server must validate file paths to prevent directory
  traversal (all writes constrained to `.claude/watchtower_inbox/`).
- **File:// restrictions:** `file://` cannot make `fetch()` POST requests.
  The download-prompt fallback is essential. Test that the generated Blob
  content is valid and complete.
- **Race condition:** Pipeline may start while user is mid-submission. Inbox
  processing should use `mv` (atomic) not read-then-delete.
- **Manifest validation:** Duplicate milestone IDs must be rejected at both
  form level (JS) and pipeline level (bash). Belt and suspenders.
- **Existing M32 integration:** M32 already provides a browser-based planning
  interview. The Actions tab should link to the planning UI URL when available,
  not duplicate it.

## Seeds Forward

- M37 uses the Actions tab infrastructure for parallel team management controls
- The `watchtower_server.py` HTTP server could be extended in V4 for real-time
  WebSocket push notifications
- The inbox pattern is extensible: future submission types (config changes,
  replan triggers) follow the same file-based protocol
