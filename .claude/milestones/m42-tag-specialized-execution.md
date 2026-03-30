# Milestone 42: Tag-Specialized Execution Paths
<!-- milestone-meta
id: "42"
status: "pending"
-->

## Overview

The coder agent currently receives identical prompt structure regardless of whether it's
working on a bug fix, a new feature, or a polish item. The only differentiation is a
one-line `NOTE_GUIDANCE` string embedded in `coder.sh`. This milestone introduces
tag-specific prompt templates, turn budgets, scout behavior, and acceptance heuristics
so that bugs get root-cause-first debugging, features get architecture-aware scaffolding,
and polish items get minimal-change constraints.

Depends on Milestone 40 (Notes Core Rewrite) for the tag registry and note metadata,
and Milestone 41 (Note Triage) for estimated turn counts used in budget adjustment.

## Scope

### 1. Tag-Specific Prompt Templates

**Problem:** The coder prompt (`prompts/coder.prompt.md`) has a single
`{{IF:HUMAN_NOTES_BLOCK}}` section with generic instructions. The tag-specific guidance
is a bash string in `coder.sh:278-289` (`NOTE_GUIDANCE_BUG`, etc.) — not a proper prompt
template that can be iterated on.

**Fix:**
- Three new prompt templates:
  - `prompts/coder_note_bug.prompt.md` — Root-cause-first workflow: diagnose before
    fixing. Mandatory `## Root Cause Analysis` section in CODER_SUMMARY.md. Explicit
    instruction to write a regression test covering the fix.
  - `prompts/coder_note_feat.prompt.md` — Architecture-aware: read architecture file
    and active milestone context before coding. Check for conflicts with in-progress
    milestones. Follow existing patterns (file placement, naming conventions). Flag
    architectural concerns in CODER_SUMMARY.md.
  - `prompts/coder_note_polish.prompt.md` — Minimal-change constraint: "Do not refactor
    surrounding code. Do not change logic. Do not add features beyond what the note
    describes. Touch only the files necessary for the visual/UX change."
- `render_prompt()` in `prompts.sh` selects the appropriate template based on the
  active note's tag. When `NOTES_FILTER` is set (or `HUMAN_MODE` is active with a
  claimed note), the tag determines the template. Fallback: if no tag-specific template
  exists for a tag, use the generic `coder.prompt.md` with the `HUMAN_NOTES_BLOCK`.
- The `NOTE_GUIDANCE` bash strings in `coder.sh` are removed. All guidance lives in
  the prompt templates where it belongs.

**Files:** `prompts/coder_note_bug.prompt.md` (new),
`prompts/coder_note_feat.prompt.md` (new), `prompts/coder_note_polish.prompt.md` (new),
`lib/prompts.sh` (template selection logic), `stages/coder.sh` (remove NOTE_GUIDANCE
strings, use template-based injection)

### 2. Tag-Specific Scout Behavior

**Problem:** Scout behavior has some tag awareness (`coder.sh:99-109`) — bugs always
get scouted, features only if they extend existing systems — but it's incomplete and
the logic is embedded in bash conditionals rather than being configurable.

**Fix:**
- Scout behavior per tag, driven by config:
  - **BUG:** Always scout. Scout prompt includes explicit instruction to identify the
    likely root cause location (not just "relevant files"). Scout report should include
    a `## Suspected Root Cause` section.
  - **FEAT:** Scout if the note's estimated turns (from triage metadata) > 10, or if
    the note text contains brownfield indicators (extend/modify/integrate). For small
    features (est. ≤ 10 turns), skip scout to save turns.
  - **POLISH:** Skip scout entirely. Polish items should be self-evident from the note
    description. If the user explicitly wants scouting for polish, they can use
    `--with-notes` instead of `--human POLISH`.
- Configurable: `SCOUT_ON_BUG=always`, `SCOUT_ON_FEAT=auto`, `SCOUT_ON_POLISH=never`.
  Values: `always`, `auto` (use heuristics), `never`.
- The existing brownfield detection (`grep -qiE "extend|add to|modify|..."`) is
  preserved within the `auto` logic for FEAT.

**Files:** `stages/coder.sh` (refactor scout decision logic),
`lib/config_defaults.sh` (add scout config keys)

### 3. Tag-Specific Turn Budgets

**Problem:** All notes get the same `CODER_MAX_TURNS` regardless of expected scope.
A 3-turn polish fix burns the same turn budget as a 30-turn feature.

**Fix:**
- Per-tag turn budget multipliers:
  - **BUG:** `BUG_TURN_MULTIPLIER=1.0` (default, bugs use full budget — debugging is
    unpredictable)
  - **FEAT:** `FEAT_TURN_MULTIPLIER=1.0` (default, features use full budget)
  - **POLISH:** `POLISH_TURN_MULTIPLIER=0.6` (default, polish gets 60% of budget —
    if a polish item needs more, it probably should have been a FEAT)
- If triage estimated turns are available (from M41 metadata), use them directly:
  `ADJUSTED_CODER_TURNS = min(estimated_turns * 1.5, CODER_MAX_TURNS * multiplier)`.
  The 1.5x buffer accounts for estimation error.
- Turn budget adjustment happens in `coder.sh` after scout (same location as the
  existing `apply_scout_turn_limits` and TDD multiplier logic).

**Files:** `stages/coder.sh` (turn budget logic), `lib/config_defaults.sh` (multiplier
defaults)

### 4. Tag-Specific Acceptance Heuristics

**Problem:** Note completion is currently self-graded — the coder says "COMPLETED" in
CODER_SUMMARY.md and the pipeline trusts it. Milestones have structured acceptance
criteria checked by the pipeline. Notes have nothing comparable.

**Fix:**
- Lightweight, tag-specific acceptance checks run during finalization (after coder
  completes, before note is resolved). These are heuristic — warnings, not hard blocks.
  Results are logged to CODER_SUMMARY.md and recorded in note metadata.

- **BUG acceptance:**
  - Check: did the git diff include changes to at least one test file? (Pattern:
    `*test*`, `*spec*`, `*_test.*`, `test_*.*` in the diff)
  - If no test file was touched: warning "Bug fix has no regression test coverage.
    Consider adding a test that reproduces the original bug."
  - Check: does CODER_SUMMARY.md contain a `## Root Cause Analysis` section?
  - If missing: warning "No root cause analysis provided. Future debugging may repeat
    the same investigation."

- **FEAT acceptance:**
  - Check: do new files follow existing directory conventions? (Heuristic: if the
    project has `src/models/`, a new model should be in `src/models/`, not in `src/`
    root). Implementation: compare new file paths against the most common directory
    patterns in the git tree.
  - If unconventional placement detected: warning "New file {path} may not follow
    project conventions. Expected location: {suggested_path}."
  - This is advisory only — the heuristic can be wrong for valid reasons.

- **POLISH acceptance:**
  - Check: were any "logic files" modified? (Pattern: `*.py`, `*.js`, `*.ts`, `*.sh`,
    `*.go`, `*.rs`, `*.java`, `*.rb`, `*.c`, `*.cpp`, `*.h` — configurable via
    `POLISH_LOGIC_FILE_PATTERNS`).
  - If logic files were modified: warning "Polish note modified logic files: {files}.
    This may indicate scope creep beyond the visual/UX change."
  - Exclusions: if the only logic file change is in a test file, suppress the warning
    (tests for polish are fine).

- Acceptance results stored in note metadata: `acceptance:pass` or
  `acceptance:warn_no_test`, `acceptance:warn_logic_modified`, etc.

**Files:** `lib/notes_acceptance.sh` (new), `lib/finalize.sh` (hook acceptance check
into finalization before note resolution), `lib/config_defaults.sh` (pattern configs)

### 5. Feature Notes: Milestone Context Injection

**Problem:** When executing a FEAT note, the coder has no awareness of in-progress
milestones. A feature note might add functionality that conflicts with or duplicates
work in an active milestone.

**Fix:**
- When a FEAT note is being executed and milestones exist, inject a brief milestone
  context block into the prompt: "Active milestones: {list of pending/in-progress
  milestone titles}. If this feature overlaps with any of these milestones, note the
  overlap in CODER_SUMMARY.md."
- This uses the existing `MILESTONE_BLOCK` variable (already computed by
  `build_context_packet`) but the FEAT-specific prompt template explicitly calls
  attention to it with instructions to check for conflicts.
- No new data plumbing needed — just prompt template wording that references the
  existing milestone context.

**Files:** `prompts/coder_note_feat.prompt.md` (prompt wording)

### 6. Polish Notes: Reviewer Skip Heuristic

**Problem:** A CSS-only or config-only change from a POLISH note doesn't benefit from
a full code review cycle. The reviewer stage adds turns and latency for no value on
trivial visual changes.

**Fix:**
- After the coder stage completes for a POLISH note, check the git diff for file types.
  If ALL changed files match non-logic patterns (`*.css`, `*.scss`, `*.less`, `*.json`,
  `*.yaml`, `*.yml`, `*.toml`, `*.cfg`, `*.ini`, `*.svg`, `*.png`, `*.md` —
  configurable via `POLISH_SKIP_REVIEW_PATTERNS`), skip the reviewer stage.
- Log: "Polish note: all changes are non-logic files. Skipping reviewer."
- If ANY logic file is in the diff, reviewer runs as normal.
- Configurable: `POLISH_SKIP_REVIEW=true` (default: true). Set to false to always
  review polish.
- The skip is implemented in `tekhton.sh` or `stages/review.sh` as a pre-check before
  invoking the reviewer agent.

**Files:** `stages/review.sh` (skip logic), `lib/config_defaults.sh` (patterns and
toggle)

### 7. Dashboard Execution Outcome Display

**Fix:**
- `emit_dashboard_notes()` (from M40, extended in M41) further extended with execution
  outcome fields:
  ```json
  {
    "id": "n07", "tag": "BUG", "title": "Fix login...",
    "status": "done",
    "completed_at": "2026-03-30T14:22:00Z",
    "turns_used": 12,
    "acceptance_result": "warn_no_test",
    "acceptance_warnings": ["Bug fix has no regression test coverage"],
    "rca_present": true,
    "reviewer_skipped": false
  }
  ```
- Dashboard Notes tab shows:
  - Green check for clean acceptance, yellow warning icon for acceptance warnings
  - Turns used vs estimated turns (if triage ran)
  - Expandable acceptance warnings
  - "Reviewer skipped" badge for polish items that bypassed review

**Files:** `lib/dashboard_emitters.sh` (update emitter),
`templates/watchtower/app.js` (Notes tab rendering)

### 8. Note Throughput Metrics

**Fix:**
- `record_run_metrics()` (in `lib/metrics.sh`) extended to capture note-specific data
  when a `--human` run completes:
  - `note_id`, `note_tag`, `turns_used`, `estimated_turns` (from triage),
    `acceptance_result`, `reviewer_skipped`
- `emit_dashboard_metrics()` aggregates note data across runs for the Trends tab:
  - Notes completed per run (by tag)
  - Average turns per note (by tag)
  - Promotion rate (notes promoted to milestones vs executed)
  - Acceptance warning rate (by tag)
- This gives users visibility into backlog velocity and whether their notes are
  appropriately sized.

**Files:** `lib/metrics.sh` (extend), `lib/dashboard_emitters.sh` (extend Trends data)

## Configuration

All new config keys with defaults (added to `lib/config_defaults.sh` and documented
in `templates/pipeline.conf.example`):

```bash
# --- Tag-Specific Execution ---
# SCOUT_ON_BUG=always                      # always|auto|never
# SCOUT_ON_FEAT=auto                       # always|auto|never
# SCOUT_ON_POLISH=never                    # always|auto|never
# BUG_TURN_MULTIPLIER=1.0                  # Turn budget multiplier for BUG notes
# FEAT_TURN_MULTIPLIER=1.0                 # Turn budget multiplier for FEAT notes
# POLISH_TURN_MULTIPLIER=0.6               # Turn budget multiplier for POLISH notes
# POLISH_SKIP_REVIEW=true                  # Skip reviewer for non-logic-only changes
# POLISH_SKIP_REVIEW_PATTERNS="*.css *.scss *.less *.json *.yaml *.yml *.toml *.cfg *.svg *.png *.md"
# POLISH_LOGIC_FILE_PATTERNS="*.py *.js *.ts *.sh *.go *.rs *.java *.rb *.c *.cpp *.h"
```

## Acceptance Criteria

- BUG notes use `coder_note_bug.prompt.md` with root-cause-first workflow instructions
- FEAT notes use `coder_note_feat.prompt.md` with architecture and milestone awareness
- POLISH notes use `coder_note_polish.prompt.md` with minimal-change constraints
- Falling back to generic `coder.prompt.md` works when no tag-specific template exists
- Scout always runs for BUG notes (`SCOUT_ON_BUG=always`)
- Scout runs conditionally for FEAT notes based on heuristics (`SCOUT_ON_FEAT=auto`)
- Scout is skipped for POLISH notes (`SCOUT_ON_POLISH=never`)
- POLISH notes get reduced turn budget (default 60% of CODER_MAX_TURNS)
- Triage estimated turns (from M41) are used for turn budget when available
- BUG acceptance checks for regression test presence and RCA section
- FEAT acceptance checks for conventional file placement
- POLISH acceptance checks for unintended logic file modifications
- Acceptance warnings are logged to CODER_SUMMARY.md and note metadata (not hard blocks)
- POLISH notes with non-logic-only diffs skip the reviewer stage when enabled
- Dashboard Notes tab shows execution outcomes, acceptance results, and turns used
- Run metrics include per-note data; Trends tab shows note throughput by tag
- `NOTE_GUIDANCE` bash strings removed from `coder.sh` — all guidance in templates
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/notes_acceptance.sh` passes
- `shellcheck lib/notes_acceptance.sh` passes
- New test file `tests/test_notes_acceptance.sh` covers: BUG/FEAT/POLISH acceptance
  heuristics, reviewer skip logic, turn budget calculation

## Watch For

- **Template selection complexity.** The prompt rendering system already supports
  conditionals (`{{IF:VAR}}`). The tag-specific templates should be standalone files,
  not nested conditionals within the main `coder.prompt.md`. The main template stays
  as the fallback — tag templates replace it entirely when active.
- **Scout skip for POLISH vs user expectations.** Some users may expect scouting for
  polish items (e.g., "polish the settings page" needs file discovery). The
  `SCOUT_ON_POLISH=never` default is conservative. Document that users can override
  to `auto` or `always` if their polish notes are more exploratory.
- **Acceptance false positives.** The "logic file modified" check for POLISH will fire
  if a polish note legitimately requires a small logic change (e.g., adding a CSS class
  name to a component). This is why it's a warning, not a block. The warning text should
  say "may indicate" not "is definitely" scope creep.
- **Turn budget underflow.** `POLISH_TURN_MULTIPLIER=0.6` on a project with
  `CODER_MAX_TURNS=15` gives 9 turns. Enforce a minimum floor (e.g., 5 turns) to avoid
  giving the agent too little budget to even start.
- **Reviewer skip and test stage.** Skipping the reviewer for polish does NOT skip the
  tester stage. Tests should still run to catch regressions. Only the human-style code
  review is skipped.
- **Metric cardinality.** Note metrics are per-note, per-run. For users who process
  many notes per session (`--human --complete`), the metrics data could grow. Cap at
  `DASHBOARD_HISTORY_DEPTH` runs like existing metrics.

## Seeds Forward

- The tag-specific prompt template pattern is extensible to future tags (SECURITY,
  REFACTOR, etc.) — just add a template file and a registry entry (from M40)
- The acceptance heuristic framework can be extended with project-specific checks
  configured in pipeline.conf
- Note throughput metrics enable future "backlog health" scoring in the Watchtower
  dashboard
- The reviewer skip heuristic could be generalized to other scenarios (e.g., skip
  review for documentation-only changes in any mode)
