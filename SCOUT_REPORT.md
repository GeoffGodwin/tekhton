# Scout Report: Milestone 42 — Tag-Specialized Execution Paths

## Relevant Files

- **lib/notes_acceptance.sh** — Core M42 library: implements tag-specific acceptance heuristics (BUG/FEAT/POLISH), turn budget multipliers, scout decision policies, and reviewer-skip logic
- **prompts/coder_note_bug.prompt.md** — Tag-specialized prompt for BUG notes (regression test + RCA requirements)
- **prompts/coder_note_feat.prompt.md** — Tag-specialized prompt for FEAT notes (file convention + placement rules)
- **prompts/coder_note_polish.prompt.md** — Tag-specialized prompt for POLISH notes (non-logic change emphasis)
- **tests/test_notes_acceptance.sh** — Test suite validating turn budget calculation, acceptance checks, and reviewer skip heuristics
- **lib/notes_triage.sh** — Existing triage infrastructure (M41) that scores and gates notes; M42 builds on this for tag-based decision making
- **lib/config_defaults.sh** — Requires new config keys for per-tag turn multipliers and acceptance policies (not yet visible in current file state)
- **stages/coder.sh** — Must be modified to call get_tag_coder_template() and apply_tag_turn_budget() when executing tagged notes
- **stages/review.sh** — Must be modified to call should_skip_review() for POLISH notes to bypass reviewer when appropriate
- **tekhton.sh** — Must source lib/notes_acceptance.sh at startup and provide NOTES_FILTER/CLAIMED_NOTE_IDS context
- **templates/pipeline.conf.example** — Must document new M42 config keys (BUG_TURN_MULTIPLIER, FEAT_TURN_MULTIPLIER, POLISH_TURN_MULTIPLIER, etc.)

## Key Symbols

- **get_tag_coder_template(tag)** — lib/notes_acceptance.sh — Returns tag-specific prompt name (coder_note_bug, coder_note_feat, coder_note_polish) or falls back to "coder"
- **apply_tag_turn_budget(tag, base_turns, est_turns)** — lib/notes_acceptance.sh — Applies per-tag multiplier (BUG=1.0, FEAT=1.0, POLISH=0.6) with triage estimate awareness
- **run_note_acceptance(tag)** — lib/notes_acceptance.sh — Dispatcher that calls check_bug_acceptance, check_feat_acceptance, or check_polish_acceptance
- **check_bug_acceptance()** — lib/notes_acceptance.sh — Validates bug fixes have regression tests + root cause analysis in CODER_SUMMARY.md
- **check_feat_acceptance()** — lib/notes_acceptance.sh — Validates new files follow project directory conventions
- **check_polish_acceptance()** — lib/notes_acceptance.sh — Warns if logic files (*.py, *.js, *.sh, etc.) are modified in a polish note
- **should_skip_review()** — lib/notes_acceptance.sh — Returns 0 (true) if all changed files are non-logic (CSS, YAML, JSON, Markdown, SVG, etc.) for POLISH bypass
- **should_scout_for_tag(tag, task_text, notes_text, est_turns)** — lib/notes_acceptance.sh — Policy-based scout decision: BUG=always, FEAT=auto (scout if >10 turns or brownfield keywords), POLISH=never

## Suspected Root Cause Areas

- **Integration with coder stage**: stages/coder.sh must call get_tag_coder_template() to select the right prompt template when NOTES_FILTER is set and a note has a tag. Current coder.sh likely uses static "coder" template regardless of tag.
- **Integration with turn budget**: stages/coder.sh must call apply_tag_turn_budget() to adjust CODER_MAX_TURNS based on the note's tag before invoking the agent. Current stages likely apply base turn limits without tag awareness.
- **Integration with reviewer bypass**: stages/review.sh must check should_skip_review() for POLISH notes after coder completes, and conditionally skip the entire review stage when conditions are met.
- **Config key definitions**: lib/config_defaults.sh is missing new M42 config keys (BUG_TURN_MULTIPLIER, FEAT_TURN_MULTIPLIER, POLISH_TURN_MULTIPLIER, SCOUT_ON_BUG, SCOUT_ON_FEAT, SCOUT_ON_POLISH, NOTE_TURN_BUDGET_MIN, POLISH_LOGIC_FILE_PATTERNS, POLISH_SKIP_REVIEW, POLISH_SKIP_REVIEW_PATTERNS). These must be added as fallback defaults.
- **Pipeline state context**: tekhton.sh must export CLAIMED_NOTE_IDS (from notes claiming logic) and NOTES_FILTER (tag name) so lib/notes_acceptance.sh can reference them. May need to be set by stages/coder.sh when claiming filtered notes.

## Complexity Estimate

Files to modify: 8
Estimated lines of change: 450
Interconnected systems: medium
Recommended coder turns: 45
Recommended reviewer turns: 10
Recommended tester turns: 30

## UI Components in Scope

No UI components directly in scope. The milestone focuses on pipeline orchestration and decision logic. However, if dashboard/watchtower emitters are modified (lib/dashboard_emitters.sh in git status), the watchtower UI may need to display tag-specific execution metadata (tags used, acceptance results, reviewer skip status).
