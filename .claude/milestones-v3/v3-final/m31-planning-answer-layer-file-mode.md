#### Milestone 31: Planning Answer Layer & File Mode

<!-- milestone-meta
id: "31"
status: "done"
-->

The `--plan` interview currently collects answers in a transient Bash array that
exists only in memory during the session. If interrupted, all answers are lost.
The interview flow is locked to CLI-only interaction, which is tedious for the
multi-paragraph, deeply structured answers that good planning requires.

This milestone extracts answer collection into a **mode-agnostic answer layer**
backed by a persistent YAML file (`.claude/plan_answers.yaml`). It adds **file
mode** as an alternative input path — users export a question template, fill it
out in their editor of choice, and point the pipeline at the completed file.
Finally, it adds a **draft review step** before synthesis, letting users see all
their answers at once and go back to edit before committing to Claude generation.

This is the foundation for M32 (Browser-Based Planning Interview), which adds a
third input mode that writes to the same answer layer.

Files to modify:
- `stages/plan_interview.sh` — Refactor to use the answer layer:
  **Current flow:**
  1. Loop over template sections
  2. Collect answers into `answers[$i]` array
  3. Build `$INTERVIEW_ANSWERS_BLOCK` string
  4. Call Claude for synthesis

  **New flow:**
  1. Check for existing `.claude/plan_answers.yaml` — offer to resume or start fresh
  2. Loop over template sections (CLI mode) OR load from file (file mode)
  3. Write each answer to `.claude/plan_answers.yaml` as it's collected
  4. On completion (all sections answered), show draft review
  5. Build `$INTERVIEW_ANSWERS_BLOCK` from the YAML file
  6. Call Claude for synthesis (unchanged)

  The mode selection happens after project type selection (which stays in CLI):
  ```
  How would you like to answer the planning questions?
    1) CLI Mode     — answer questions one by one in the terminal
    2) File Mode    — export questions to YAML, fill out in your editor
    3) Browser Mode — fill out a form in your browser (requires M32)
  ```
  Option 3 is shown but gated on M32 being implemented (check for
  `lib/plan_browser.sh` existence).

- `lib/plan_answers.sh` — **NEW** Answer persistence layer:
  **Core functions:**
  - `init_answer_file()` — Create `.claude/plan_answers.yaml` with header metadata
    (project_type, template, timestamp, tekhton_version)
  - `save_answer()` — Write/update a single section's answer to the YAML file.
    Uses section ID (slugified section title) as the key. Handles multi-line text
    via YAML block scalars (`|`).
  - `load_answer()` — Read a single section's answer from the YAML file.
    Returns empty string if section not yet answered.
  - `load_all_answers()` — Read all answers into parallel arrays (section_ids,
    section_titles, answers). Used by draft review and synthesis.
  - `has_answer_file()` — Check if `.claude/plan_answers.yaml` exists with valid
    header metadata.
  - `answer_file_complete()` — Check if all REQUIRED sections have non-empty,
    non-TBD answers.
  - `export_question_template()` — Generate a YAML file with all sections from
    the template as keys, guidance as comments, and empty values. Write to
    stdout or a specified path.
  - `import_answer_file()` — Parse a user-filled YAML file, validate structure,
    load into the answer layer. Returns non-zero if required sections are missing.
  - `build_answers_block()` — Construct the `$INTERVIEW_ANSWERS_BLOCK` string
    from the YAML file, matching the format the existing synthesis prompt expects.

  **YAML schema:**
  ```yaml
  # Tekhton Planning Answers
  # Project: my-project
  # Template: web-app
  # Generated: 2026-03-26T12:00:00Z
  # Tekhton: 3.31.0

  sections:
    developer_philosophy:
      title: "Developer Philosophy & Constraints"
      phase: 1
      required: true
      answer: |
        This project follows a composition-over-inheritance pattern...

    project_overview:
      title: "Project Overview"
      phase: 1
      required: true
      answer: |
        A real-time collaborative editing tool for...

    tech_stack:
      title: "Tech Stack"
      phase: 1
      required: true
      answer: ""  # Not yet answered
  ```

  **YAML parsing constraint:** No external YAML parser dependency. Use `awk`
  and `sed` for reading/writing. The schema is intentionally flat — no nested
  objects beyond `sections → section_id → {title, phase, required, answer}`.
  Multi-line answers use YAML block scalar (`|`) which is parseable with a
  simple state machine: read lines until the next key at the same indentation.

- `lib/plan_review.sh` — **NEW** Draft review before synthesis:
  **Core function: `show_draft_review()`**
  Displays all collected answers in a structured summary:
  ```
  ══════════════════════════════════════
    Planning Draft Review
  ══════════════════════════════════════

  Phase 1: Concept Capture
  ────────────────────────────────────
  ✓ Developer Philosophy (324 chars)
  ✓ Project Overview (189 chars)
  ✗ Tech Stack (TBD)              ← highlighted, required

  Phase 2: System Deep-Dive
  ────────────────────────────────────
  ✓ Data Model (512 chars)
  ~ Authentication (skipped)       ← optional, skipped
  ...

  3 of 12 sections complete. 1 required section needs answers.

  Actions:
    [e] Edit a section    [s] Start synthesis    [q] Quit (answers saved)
  ```

  When user selects "Edit a section", prompt for section number, open the
  answer in `$EDITOR` (or inline if no editor). Updated answer is saved
  to the YAML file immediately.

  When user selects "Start synthesis", verify all required sections are
  answered, then proceed to Claude generation.

  When user selects "Quit", print reminder that answers are saved and
  can be resumed with `tekhton --plan`.

- `stages/plan_followup_interview.sh` — Update to read/write through answer layer:
  Follow-up questions should update the answer file rather than collecting in
  a transient array. When a section needs follow-up, load the existing answer,
  show it, collect the clarification, and update the YAML file.

- `lib/plan.sh` — Update orchestration:
  - Add `--export-questions` flag handling: call `export_question_template()` and exit
  - Add `--answers <file>` flag handling: call `import_answer_file()`, skip interview
  - Add resume detection: if `.claude/plan_answers.yaml` exists, offer to resume
  - Wire draft review between interview and synthesis

- `lib/plan_state.sh` — Update state persistence:
  - Record answer file path in plan state
  - On resume, check answer file exists and offer to continue from where left off

Files to create:
- `lib/plan_answers.sh` — Answer persistence layer (described above)
- `lib/plan_review.sh` — Draft review UI (described above)

Files to modify:
- `stages/plan_interview.sh` — Refactor to use answer layer + mode selection
- `stages/plan_followup_interview.sh` — Use answer layer for follow-up
- `lib/plan.sh` — New flags, resume detection, draft review wiring
- `lib/plan_state.sh` — Answer file in state
- `tekhton.sh` — Add `--export-questions` and `--answers` flags to arg parser

Acceptance criteria:
- `--plan` in CLI mode behaves identically to current behavior but persists
  answers to `.claude/plan_answers.yaml` as they're collected
- Interrupting `--plan` mid-interview and re-running resumes from the last
  unanswered section (answers preserved)
- `--plan --export-questions` writes a valid YAML template to stdout with all
  sections from the selected project type, guidance as comments, empty values
- `--plan --answers path/to/filled.yaml` skips the interview entirely, loads
  answers from the file, proceeds to draft review then synthesis
- Draft review shows all sections with completeness status and char counts
- Draft review allows editing individual sections before synthesis
- `build_answers_block()` produces output identical in format to the current
  `$INTERVIEW_ANSWERS_BLOCK` construction
- YAML parsing handles multi-line answers with special characters (colons,
  quotes, hashes) without corruption
- All existing planning tests pass
- `bash -n lib/plan_answers.sh lib/plan_review.sh` passes
- New test file `tests/test_plan_answers.sh` covers: YAML roundtrip, export/import,
  resume detection, build_answers_block format, multi-line edge cases
- New test file `tests/test_plan_review.sh` covers: completeness calculation,
  section status display

Tests:
- YAML roundtrip: `save_answer "section_id" "multi\nline\nanswer"` then
  `load_answer "section_id"` returns exact same content
- Special characters: answers containing `: # " ' | > -` survive roundtrip
- Export template: `export_question_template "web-app"` produces valid YAML
  with all sections from `templates/plans/web-app.md`
- Import validation: `import_answer_file` rejects files missing required sections
- Resume: create partial answer file, run interview, verify it starts at the
  first unanswered section
- Block format: `build_answers_block()` output matches existing format exactly

Watch For:
- YAML parsing in pure bash is fragile. The schema must stay flat — no nested
  objects, no flow mappings, no anchors/aliases. Block scalars (`|`) are the
  only multi-line format supported. Test edge cases: empty answers, answers
  that are just whitespace, answers containing YAML-like syntax.
- The answer file must use atomic writes (tmpfile + mv) to prevent corruption
  if the pipeline is killed mid-write. Same pattern as milestone manifest writes.
- `$EDITOR` may not be set. Fall back to `vi`, then `nano`, then inline input.
  Don't crash if no editor is available.
- The mode selection prompt must use `prompts_interactive.sh` helpers and fall
  back gracefully in non-interactive environments (default to CLI mode).
- Answer file cleanup: don't leave `.claude/plan_answers.yaml` after successful
  synthesis. Move it to `.claude/plan_answers.yaml.done` so resume detection
  doesn't trigger on the next `--plan` run.

Seeds Forward:
- M32 (Browser Mode) writes to the same `.claude/plan_answers.yaml` via POST
  endpoint — the answer layer is shared across all modes
- The YAML schema is extensible: M32 can add `answered_via: "browser"` metadata
  per section without breaking M31's parser
- `export_question_template()` is reused by M32 to generate the HTML form fields
- Draft review UI pattern is reusable for other confirmation flows (e.g., pre-run
  task review, milestone acceptance review)
