#### Milestone 32: Browser-Based Planning Interview

<!-- milestone-meta
id: "32"
status: "pending"
-->

The planning interview asks detailed, multi-paragraph questions about project
architecture, constraints, data models, and user flows. Answering these in a
terminal — one question at a time, no ability to scroll back, no copy-paste
from reference docs — is the worst possible UX for this kind of structured
authoring. This milestone adds a **browser-based planning form** that serves
the same questions as an HTML form, lets users navigate freely between sections,
draft answers at their own pace, and submit when ready.

The architecture follows Watchtower's pattern: generate static HTML/CSS/JS,
serve via a minimal local HTTP server, and communicate results back to the
shell via a single POST endpoint that writes to the shared answer layer from
M31.

Depends on M31 (Planning Answer Layer) — the browser mode writes to the same
`.claude/plan_answers.yaml` file as CLI and file modes.

Files to create:
- `lib/plan_browser.sh` — **NEW** Browser mode orchestrator:
  **Core function: `run_browser_interview()`**
  Workflow:
  1. Generate the form HTML from the template sections (call `_generate_plan_form()`)
  2. Write form + assets to a temp directory (`$TEKHTON_SESSION_DIR/plan-form/`)
  3. Start the local HTTP server (`_start_plan_server()`)
  4. Open the browser (`_open_plan_browser()`)
  5. Wait for submission (`_wait_for_plan_submit()`)
  6. Stop the server, clean up
  7. Return to the shell — answers are in `.claude/plan_answers.yaml`

  **`_generate_plan_form()`**
  Reads the selected template (e.g., `templates/plans/web-app.md`), extracts
  sections using `_extract_template_sections()` (existing function from
  `plan_interview.sh`), and generates an HTML form:

  For each section:
  - Section title as `<h3>` with phase badge and required/optional indicator
  - Guidance text from template HTML comments rendered as a collapsible
    `<details>` block above the textarea (collapsed by default)
  - `<textarea>` for the answer, pre-populated from existing `.claude/plan_answers.yaml`
    if resuming (call `load_answer()` from M31's answer layer)
  - Character count indicator below each textarea
  - Visual indicator: empty (red outline), in-progress (yellow), complete (green)

  Form layout:
  ```
  ┌──────────────────────────────────────────────┐
  │  Tekhton Planning Interview                  │
  │  Project: my-project  |  Type: web-app       │
  │                                              │
  │  Phase 1: Concept Capture                    │
  │  ┌────────────────────────────────────────┐  │
  │  │ Developer Philosophy * (REQUIRED)      │  │
  │  │ ▶ Guidance: What are the non-neg...    │  │
  │  │ ┌──────────────────────────────────┐   │  │
  │  │ │                                  │   │  │
  │  │ │  (textarea, ~8 rows)             │   │  │
  │  │ │                                  │   │  │
  │  │ └──────────────────────────────────┘   │  │
  │  │ 324 chars                              │  │
  │  └────────────────────────────────────────┘  │
  │                                              │
  │  Phase 2: System Deep-Dive                   │
  │  ┌────────────────────────────────────────┐  │
  │  │ Data Model * (REQUIRED)                │  │
  │  │ ...                                    │  │
  │  └────────────────────────────────────────┘  │
  │                                              │
  │  ┌──────────────────────────────────┐        │
  │  │  Save Draft  │  Submit Answers   │        │
  │  └──────────────────────────────────┘        │
  │                                              │
  │  Progress: 7/12 sections  │  3 required left │
  └──────────────────────────────────────────────┘
  ```

  The form is a single scrollable page with all sections visible. Phase
  headings act as visual dividers. No pagination, no wizard — users should
  see everything at once and jump freely between sections.

  **Submit button** is disabled until all REQUIRED sections have non-empty
  answers. A progress bar at the top and bottom shows completion status.

  **Save Draft button** sends a POST to `/save-draft` with all current
  answers. This updates `.claude/plan_answers.yaml` without completing the
  interview. The CLI shows "Draft saved" and continues waiting.

  **Auto-save:** Every 30 seconds, the form auto-saves via POST `/save-draft`
  if any textarea has changed since last save. Visual indicator: "Saved ✓"
  or "Saving..." in the header.

- `templates/plan_form/index.html` — **NEW** Form HTML template:
  A minimal HTML shell that the generator fills in. Contains:
  - `<form>` with `id="plan-form"`
  - `<div id="sections">` — populated by generator
  - `<script>` block for form behavior (submit handler, validation,
    auto-save, character counts, progress tracking)
  - `<link>` to `style.css`
  No external dependencies. No framework. Vanilla HTML/CSS/JS matching
  Watchtower's approach.

- `templates/plan_form/style.css` — **NEW** Form styling:
  Clean, readable form design optimized for long-form text entry.
  Key properties:
  - Max-width container (800px) centered on page for comfortable reading
  - Textareas: monospace font, min-height 150px, auto-grow on input
  - Phase headings: sticky position so phase context is always visible
  - Required indicators: red asterisk, border highlight when empty
  - Completion badges: red/yellow/green per section
  - Dark/light theme toggle (reuse Watchtower's CSS variable pattern)
  - Print-friendly: `@media print` hides chrome, shows all answers
  - Responsive: works on mobile (for answering on a phone while looking
    at the codebase on desktop)

- `lib/plan_server.sh` — **NEW** Local HTTP server for planning form:
  **`_start_plan_server()`**
  Starts a Python HTTP server with custom POST handler:
  ```python
  # Embedded in shell via heredoc, written to temp file, executed
  # Same pattern as Watchtower's self-test server
  from http.server import HTTPServer, SimpleHTTPRequestHandler
  import json, os, signal

  ANSWERS_FILE = os.environ["PLAN_ANSWERS_FILE"]
  COMPLETION_FILE = os.environ["PLAN_COMPLETION_FILE"]

  class PlanHandler(SimpleHTTPRequestHandler):
      def do_POST(self):
          if self.path == "/submit":
              # Read form data, write to ANSWERS_FILE in YAML format
              # Touch COMPLETION_FILE to signal the shell
              ...
          elif self.path == "/save-draft":
              # Same write, but don't touch COMPLETION_FILE
              ...
  ```

  The server:
  - Serves static files from the form directory (GET requests)
  - Handles POST `/submit` — writes answers to `.claude/plan_answers.yaml`
    using M31's YAML schema, then touches a completion sentinel file
  - Handles POST `/save-draft` — same write, no sentinel
  - Finds an available port (start at 8787, increment on EADDRINUSE)
  - Logs to `$TEKHTON_SESSION_DIR/plan_server.log`

  **`_wait_for_plan_submit()`**
  Polls for the completion sentinel file (1-second interval). Shows a
  spinner in the terminal: "Waiting for browser submission... (Ctrl-C to
  cancel)". On Ctrl-C, saves any draft answers that were auto-saved and
  exits cleanly.

  **`_stop_plan_server()`**
  Same process-group kill pattern as `_stop_ui_server()` in `ui_validate.sh`.

  **`_open_plan_browser()`**
  Opens the form URL in the default browser:
  - macOS: `open "http://localhost:$port"`
  - Linux: `xdg-open "http://localhost:$port"` or `sensible-browser`
  - WSL: `cmd.exe /c start "http://localhost:$port"`
  - Fallback: print URL and ask user to open manually
  Same detection pattern as Watchtower.

Files to modify:
- `stages/plan_interview.sh` — Enable browser mode option:
  When user selects option 3 (Browser Mode), call `run_browser_interview()`
  from `lib/plan_browser.sh`. After it returns, proceed to draft review
  (M31) and then synthesis as normal.

- `lib/plan.sh` — Source `lib/plan_browser.sh` and `lib/plan_server.sh`.
  Add `--plan-browser` flag as a shortcut to skip the mode selection prompt
  and go directly to browser mode.

- `tekhton.sh` — Add `--plan-browser` flag to arg parser. Source new library
  files.

Acceptance criteria:
- `--plan` shows browser mode as option 3 in mode selection
- Selecting browser mode generates an HTML form with all sections from the
  template, opens it in the default browser, and waits for submission
- Filling out the form and clicking "Submit" writes answers to
  `.claude/plan_answers.yaml` in the M31 YAML schema
- The shell detects submission and proceeds to draft review → synthesis
- "Save Draft" button saves current answers without completing the interview
- Auto-save triggers every 30 seconds when content changes
- Resuming `--plan` after a draft save shows existing answers in the form
- Form validates: submit button disabled until all required sections answered
- Form works in Chrome, Firefox, Safari (no framework dependencies)
- Form renders correctly at 1024px and 768px widths (responsive)
- `_start_plan_server` finds an available port and serves the form
- `_stop_plan_server` cleans up all server processes (no orphans)
- `--plan-browser` flag skips mode selection and goes straight to browser
- Ctrl-C during browser wait saves draft and exits cleanly
- All existing planning tests pass
- `bash -n lib/plan_browser.sh lib/plan_server.sh` passes
- New test `tests/test_plan_browser.sh` covers: form generation, server
  start/stop, POST handler writes valid YAML, port finding, cleanup
- Python server is only required for browser mode — CLI and file modes
  work without Python

Tests:
- Form generation: `_generate_plan_form "web-app"` produces valid HTML with
  textareas for all sections from web-app template
- Pre-populated resume: generate form with existing answers → textareas
  contain previous answers
- Server lifecycle: start → verify port responds → stop → verify port free
- POST /submit: send JSON answers → verify `.claude/plan_answers.yaml` written
  correctly and completion sentinel exists
- POST /save-draft: send JSON answers → verify YAML written, no sentinel
- Port finding: bind port 8787 manually → `_start_plan_server` finds 8788
- Cleanup: start server → kill test process → verify no orphaned server

Watch For:
- The Python HTTP server handler receives JSON from the browser but must
  write YAML to the answer file. Keep the JSON→YAML conversion simple —
  the schema is flat, so iterate keys and write `key: |` blocks. Do NOT
  pull in a YAML library for the Python side.
- CORS is not needed — the browser loads the form from the same server
  that handles POST requests (same-origin). Do not add CORS headers.
- Large answers (>10KB per section) must not cause the POST handler to
  truncate. Use `content_length = int(self.headers['Content-Length'])` and
  read the full body.
- Browser detection for auto-open: `xdg-open` may not work in headless
  server environments. Always print the URL to the terminal as fallback.
- The form's `<textarea>` elements should use `name` attributes matching
  the section IDs from the YAML schema, so the POST body maps directly.
- Security: the server binds to `127.0.0.1` only (not `0.0.0.0`). No
  external access. No authentication needed for localhost.
- The auto-save interval (30s) should be configurable via a CSS/JS constant,
  not hardcoded in multiple places.

Seeds Forward:
- The local HTTP server pattern is reusable for future interactive features
  (e.g., interactive milestone reordering, visual DAG editor)
- The form template pattern can be extended with conditional sections
  (show/hide based on project type or previous answers)
- Auto-save infrastructure enables future real-time collaboration features
  (multiple users filling out sections concurrently via shared file)
