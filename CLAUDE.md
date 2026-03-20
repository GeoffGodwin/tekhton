# Tekhton — Project Configuration

## What This Is

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on
the Claude CLI. It orchestrates a Coder → Reviewer → Tester cycle with automatic
rework routing, build gates, state persistence, and resume support.

**One intent. Many hands.**

## Repository Layout

```
tekhton/
├── tekhton.sh              # Main entry point
├── lib/                    # Shared libraries (sourced by tekhton.sh)
│   ├── common.sh           # Colors, logging, prerequisite checks
│   ├── config.sh           # Config loader + validation
│   ├── agent.sh            # Agent wrapper, metrics, run_agent()
│   ├── agent_monitor.sh    # Agent monitoring, activity detection, process management
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   ├── plan_state.sh       # Planning state persistence + resume
│   ├── context.sh          # [2.0] Token accounting + context compiler
│   ├── milestones.sh       # [2.0] Milestone state machine + acceptance checking
│   ├── clarify.sh          # [2.0] Clarification protocol + replan trigger
│   ├── specialists.sh      # [2.0] Specialist review framework
│   ├── metrics.sh          # [2.0] Run metrics collection + adaptive calibration
│   └── errors.sh           # [2.0] Error taxonomy, classification + reporting
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Stage 0: Architect audit (conditional)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   ├── tester.sh           # Stage 3: Test writing + validation
│   ├── cleanup.sh          # [2.0] Post-success debt sweep stage
│   ├── plan_interview.sh   # Planning: interactive interview agent
│   └── plan_generate.sh    # Planning: CLAUDE.md generation agent
├── prompts/                # Prompt templates with {{VAR}} substitution
│   ├── architect.prompt.md
│   ├── architect_sr_rework.prompt.md
│   ├── architect_jr_rework.prompt.md
│   ├── architect_review.prompt.md
│   ├── coder.prompt.md
│   ├── coder_rework.prompt.md
│   ├── jr_coder.prompt.md
│   ├── reviewer.prompt.md
│   ├── scout.prompt.md
│   ├── tester.prompt.md
│   ├── tester_resume.prompt.md
│   ├── build_fix.prompt.md
│   ├── build_fix_minimal.prompt.md
│   ├── analyze_cleanup.prompt.md
│   ├── seed_contracts.prompt.md
│   ├── plan_interview.prompt.md          # Planning interview system prompt
│   ├── plan_interview_followup.prompt.md # Planning follow-up interview prompt
│   ├── plan_generate.prompt.md           # CLAUDE.md generation prompt
│   ├── cleanup.prompt.md                 # [2.0] Debt sweep agent prompt
│   ├── replan.prompt.md                  # [2.0] Brownfield replan prompt
│   ├── clarification.prompt.md           # [2.0] Clarification integration prompt
│   ├── specialist_security.prompt.md     # [2.0] Security review prompt
│   ├── specialist_performance.prompt.md  # [2.0] Performance review prompt
│   └── specialist_api.prompt.md          # [2.0] API contract review prompt
├── templates/              # Templates copied into target projects by --init
│   ├── pipeline.conf.example
│   ├── coder.md
│   ├── reviewer.md
│   ├── tester.md
│   ├── jr-coder.md
│   └── architect.md
├── templates/plans/        # Design doc templates by project type
│   ├── web-app.md
│   ├── web-game.md
│   ├── cli-tool.md
│   ├── api-service.md
│   ├── mobile-app.md
│   ├── library.md
│   └── custom.md
├── tests/                  # Self-tests
└── examples/               # Sample dependency constraint validation scripts
    ├── architecture_constraints.yaml  # Sample constraint manifest
    ├── check_imports_dart.sh          # Dart/Flutter import validator
    ├── check_imports_python.sh        # Python import validator
    └── check_imports_typescript.sh    # TypeScript/JS import validator
```

## How It Works

Tekhton is invoked from a target project's root directory. It reads configuration
from `<project>/.claude/pipeline.conf` and agent role definitions from
`<project>/.claude/agents/*.md`. All pipeline logic (lib, stages, prompts) lives
in the Tekhton repo — nothing is copied into target projects except config and
agent roles.

### Two-directory model:
- `TEKHTON_HOME` — where `tekhton.sh` lives (this repo)
- `PROJECT_DIR` — the target project (caller's CWD)

## Non-Negotiable Rules

1. **Project-agnostic.** Tekhton must never contain project-specific logic.
   All project configuration is in `pipeline.conf` and agent role files.
2. **Bash 4+.** All scripts use `set -euo pipefail`. No bashisms beyond bash 4.
3. **Shellcheck clean.** All `.sh` files pass `shellcheck` with zero warnings.
4. **Deterministic.** Given the same config.conf and task, pipeline behavior is identical.
5. **Resumable.** Pipeline state is saved on interruption. Re-running resumes.
6. **Template engine.** Prompts use `{{VAR}}` substitution and `{{IF:VAR}}...{{ENDIF:VAR}}`
   conditionals. No other templating system.

## Template Variables (Prompt Engine)

Available variables in prompt templates — set by the pipeline before rendering:

| Variable | Source |
|----------|--------|
| `PROJECT_DIR` | `pwd` at tekhton.sh startup |
| `PROJECT_NAME` | pipeline.conf |
| `TASK` | CLI argument |
| `CODER_ROLE_FILE` | pipeline.conf |
| `REVIEWER_ROLE_FILE` | pipeline.conf |
| `TESTER_ROLE_FILE` | pipeline.conf |
| `JR_CODER_ROLE_FILE` | pipeline.conf |
| `PROJECT_RULES_FILE` | pipeline.conf |
| `ARCHITECTURE_FILE` | pipeline.conf |
| `ARCHITECTURE_CONTENT` | File contents of ARCHITECTURE_FILE |
| `ANALYZE_CMD` | pipeline.conf |
| `TEST_CMD` | pipeline.conf |
| `REVIEW_CYCLE` | Current review iteration |
| `MAX_REVIEW_CYCLES` | pipeline.conf |
| `HUMAN_NOTES_BLOCK` | Extracted unchecked items from HUMAN_NOTES.md |
| `HUMAN_NOTES_CONTENT` | Raw filtered notes content |
| `INLINE_CONTRACT_PATTERN` | pipeline.conf (optional) |
| `BUILD_ERRORS_CONTENT` | Contents of BUILD_ERRORS.md |
| `ANALYZE_ISSUES` | Output of ANALYZE_CMD |
| `DESIGN_FILE` | pipeline.conf (optional — design doc path) |
| `ARCHITECTURE_LOG_FILE` | pipeline.conf (default: ARCHITECTURE_LOG.md) |
| `DRIFT_LOG_FILE` | pipeline.conf (default: DRIFT_LOG.md) |
| `HUMAN_ACTION_FILE` | pipeline.conf (default: HUMAN_ACTION_REQUIRED.md) |
| `DRIFT_OBSERVATION_THRESHOLD` | pipeline.conf (default: 8) |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | pipeline.conf (default: 5) |
| `ARCHITECT_ROLE_FILE` | pipeline.conf (default: .claude/agents/architect.md) |
| `ARCHITECT_MAX_TURNS` | pipeline.conf (default: 25) |
| `CLAUDE_ARCHITECT_MODEL` | pipeline.conf (default: CLAUDE_STANDARD_MODEL) |
| `ARCHITECTURE_LOG_CONTENT` | File contents of ARCHITECTURE_LOG_FILE |
| `DRIFT_LOG_CONTENT` | File contents of DRIFT_LOG_FILE |
| `DRIFT_OBSERVATION_COUNT` | Count of unresolved observations |
| `DEPENDENCY_CONSTRAINTS_CONTENT` | File contents of dependency constraints (optional) |
| `PLAN_TEMPLATE_CONTENT` | Contents of selected design doc template (planning) |
| `DESIGN_CONTENT` | Contents of DESIGN.md during generation (planning) |
| `PLAN_INCOMPLETE_SECTIONS` | List of incomplete sections for follow-up (planning) |
| `PLAN_INTERVIEW_MODEL` | Model for interview agent (default: opus) |
| `PLAN_INTERVIEW_MAX_TURNS` | Turn limit for interview (default: 50) |
| `PLAN_GENERATION_MODEL` | Model for generation agent (default: opus) |
| `PLAN_GENERATION_MAX_TURNS` | Turn limit for generation (default: 50) |
| `CONTEXT_BUDGET_PCT` | Max % of context window for prompt (default: 50) |
| `CONTEXT_BUDGET_ENABLED` | Toggle context budgeting (default: true) |
| `CHARS_PER_TOKEN` | Conservative char-to-token ratio (default: 4) |
| `CONTEXT_COMPILER_ENABLED` | Toggle task-scoped context assembly (default: false) |
| `AUTO_ADVANCE_ENABLED` | Require --auto-advance flag (default: false) |
| `AUTO_ADVANCE_LIMIT` | Max milestones per invocation (default: 3) |
| `AUTO_ADVANCE_CONFIRM` | Prompt between milestones (default: true) |
| `CLARIFICATION_ENABLED` | Allow agents to pause for questions (default: true) |
| `CLARIFICATIONS_CONTENT` | Human answers from CLARIFICATIONS.md |
| `REPLAN_ENABLED` | Allow mid-run replan triggers (default: true) |
| `CLEANUP_ENABLED` | Enable autonomous debt sweeps (default: false) |
| `CLEANUP_BATCH_SIZE` | Max items per sweep (default: 5) |
| `CLEANUP_MAX_TURNS` | Turn budget for cleanup agent (default: 15) |
| `CLEANUP_TRIGGER_THRESHOLD` | Min items before triggering (default: 5) |
| `REPLAN_MODEL` | Model for --replan (default: PLAN_GENERATION_MODEL) |
| `REPLAN_MAX_TURNS` | Turn limit for --replan (default: PLAN_GENERATION_MAX_TURNS) |
| `CODEBASE_SUMMARY` | Directory tree + git log for --replan |
| `SPECIALIST_*_ENABLED` | Toggle per specialist (default: false each) |
| `SPECIALIST_*_MODEL` | Model per specialist (default: CLAUDE_STANDARD_MODEL) |
| `SPECIALIST_*_MAX_TURNS` | Turn limit per specialist (default: 8) |
| `METRICS_ENABLED` | Enable run metrics collection (default: true) |
| `METRICS_MIN_RUNS` | Min runs before adaptive calibration (default: 5) |
| `METRICS_ADAPTIVE_TURNS` | Use history for turn calibration (default: true) |
| `MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER` | Multiplier for AGENT_ACTIVITY_TIMEOUT in milestone mode (default: 3) |
| `MILESTONE_TAG_ON_COMPLETE` | Create git tag on milestone completion (default: false) |
| `MILESTONE_ARCHIVE_FILE` | Path to milestone archive (default: MILESTONE_ARCHIVE.md) |
| `MILESTONE_SPLIT_ENABLED` | Enable pre-flight milestone splitting (default: true) |
| `MILESTONE_SPLIT_MODEL` | Model for splitting agent (default: CLAUDE_CODER_MODEL) |
| `MILESTONE_SPLIT_MAX_TURNS` | Turn limit for splitting agent (default: 15) |
| `MILESTONE_SPLIT_THRESHOLD_PCT` | Split when scout estimate exceeds cap by this % (default: 120) |
| `MILESTONE_AUTO_RETRY` | Auto-split and retry on null-run (default: true) |
| `MILESTONE_MAX_SPLIT_DEPTH` | Max recursive split depth (default: 3) |
| `MAX_TRANSIENT_RETRIES` | Max retries on transient errors per agent call (default: 3) |
| `TRANSIENT_RETRY_BASE_DELAY` | Initial backoff delay in seconds (default: 30) |
| `TRANSIENT_RETRY_MAX_DELAY` | Max backoff delay in seconds (default: 120) |
| `TRANSIENT_RETRY_ENABLED` | Toggle transient error retry (default: true) |
| `MAX_CONTINUATION_ATTEMPTS` | Max turn-exhaustion continuations per stage (default: 3) |
| `CONTINUATION_ENABLED` | Toggle turn-exhaustion continuation (default: true) |
| `COMPLETE_MODE_ENABLED` | Toggle --complete outer loop (default: true) |
| `MAX_PIPELINE_ATTEMPTS` | Max full pipeline cycles in --complete mode (default: 5) |
| `AUTONOMOUS_TIMEOUT` | Wall-clock timeout for --complete in seconds (default: 7200) |
| `MAX_AUTONOMOUS_AGENT_CALLS` | Max total agent invocations in --complete mode (default: 20) |
| `AUTONOMOUS_PROGRESS_CHECK` | Enable stuck-detection between loop iterations (default: true) |
| `HUMAN_MODE` | Set by `--human` flag (default: false) |
| `HUMAN_NOTES_TAG` | Optional tag filter for `--human` (BUG, FEAT, POLISH) |

## Testing

```bash
# Run self-tests
cd tekhton && bash tests/run_tests.sh

# Verify shellcheck
shellcheck tekhton.sh lib/*.sh stages/*.sh
```

## Adding Tekhton to a New Project

```bash
cd /path/to/your/project
/path/to/tekhton/tekhton.sh --init
# Edit .claude/pipeline.conf
# Edit .claude/agents/*.md
/path/to/tekhton/tekhton.sh "Your first task"
```

## Completed Initiative: Planning Phase Quality Overhaul

The `--plan` pipeline was overhauled to produce deep, interconnected output. The
DESIGN.md and CLAUDE.md it generates now match the depth of professional design
documents (multi-phase interview, depth-scored completeness checks, 12-section
CLAUDE.md generation). All milestones below are complete.

### Reference: What "Good" Looks Like

The gold standard is `loenn/docs/GDD_Loenn.md` and `loenn/CLAUDE.md`. Key qualities:

**DESIGN.md (GDD) qualities:**
- Opens with a Developer Philosophy section establishing non-negotiable architectural
  constraints before any feature content
- Each game system gets its own deep section with sub-sections, tables, config examples,
  edge cases, balance warnings, and explicit interaction rules with other systems
- Configurable values are called out specifically with defaults and rationale
- Open design questions are tracked explicitly rather than glossed over
- Naming conventions section maps lore names to code names
- ~1,600 lines for a complex project

**CLAUDE.md qualities:**
- Architecture Philosophy section with concrete patterns (composition over inheritance,
  interface-first, config-driven)
- Full project structure tree with every directory and key file annotated
- Key Design Decisions section resolving ambiguities with canonical rulings
- Config Architecture section with example config structures and key values
- Milestones with: scope, file paths, acceptance criteria, `Tests:` block,
  `Watch For:` block, `Seeds Forward:` block explaining what future milestones depend on
- Critical Game Rules section — behavioral invariants the engine must enforce
- "What Not to Build Yet" section — explicitly deferred features
- Code Conventions section (naming, git workflow, testing requirements, state management pattern)
- ~970 lines for a complex project

### Key Constraints

- **No `--dangerously-skip-permissions`.** The shell drives all file I/O. Claude
  generates text only via `_call_planning_batch()`.
- **Zero execution pipeline changes.** Modify only: `lib/plan.sh`, `stages/plan_interview.sh`,
  `stages/plan_generate.sh`, `prompts/plan_*.prompt.md`, `templates/plans/*.md`, and tests.
- **Default model: Opus.** Planning is a one-time cost per project. Use the best model.
- **All new `.sh` files must pass `bash -n` syntax check.**
- **All existing tests must continue to pass** (`bash tests/run_tests.sh`).

### Milestone Plan

<!-- See MILESTONE_ARCHIVE.md for completed milestones -->

## Current Initiative: Adaptive Pipeline 2.0

Tekhton 2.0 makes the pipeline **adaptive**: aware of its own context economics,
capable of milestone-to-milestone progression, able to interrupt itself when
assumptions break, and able to improve from run history. All features are additive
or opt-in. Existing 1.0 workflows remain unchanged.

Full design document: `DESIGN_v2.md`.

### Key Constraints

- **Backward compatible.** Users who don't enable 2.0 features see identical 1.0
  behavior. All new features are opt-in or default-off.
- **Shell controls flow.** Agents advise; the shell decides. No agent autonomously
  modifies pipeline control flow.
- **Measure first.** Token accounting and context measurement in Milestone 1 before
  any compression or pruning in Milestone 2. Data before optimization.
- **Self-applicable.** Each milestone is scoped for a single `tekhton --milestone`
  run. The pipeline implements its own improvements.
- **All existing tests must pass** (`bash tests/run_tests.sh`) at every milestone.
- **All new `.sh` files must pass `bash -n` and `shellcheck`.**

### Milestone Plan

<!-- See MILESTONE_ARCHIVE.md for completed milestones -->

#### Milestone 15.1.1: Notes Gating — Flag-Only Claiming, Coder Cleanup, and --human Flag

Make human notes injection 100% explicit opt-in. Simplify `should_claim_notes()` to
check only `HUMAN_MODE` and `WITH_NOTES` flags (removing task-text pattern matching).
Update coder.sh to gate claiming behind the simplified check and remove the phantom
COMPLETE→IN PROGRESS downgrade. Add `--human [TAG]` flag parsing to tekhton.sh.

**Files to modify:**
- `lib/notes.sh` — Simplify `should_claim_notes()` (lines 12-31): remove the
  `grep -qE -i 'human.?notes|HUMAN_NOTES'` task-text matching block (lines 25-28).
  Keep the `WITH_NOTES` check (line 16) and rename the `NOTES_FILTER` check to
  also check `HUMAN_MODE=true`. The function should return 0 only when
  `WITH_NOTES=true`, `HUMAN_MODE=true`, or `NOTES_FILTER` is set. Remove
  the `task_text` parameter since it's no longer used. Update the usage comment.
- `stages/coder.sh` — The `claim_human_notes` call (line 327) is already gated
  behind `should_claim_notes "$TASK"`. Update to `should_claim_notes` (no arg)
  after the parameter removal. Similarly update the resolve call (line 441).
  Ensure the `elif` branch (lines 329-331) still sets `HUMAN_NOTES_BLOCK=""`
  when notes exist but aren't claimed — but change the condition to match the
  new parameterless `should_claim_notes`. Remove the COMPLETE→IN PROGRESS
  downgrade block if it exists (scout report references lines ~440-452, but
  current code may have shifted).
- `tekhton.sh` — Add `--human` flag parsing in the argument loop. `--human`
  sets `HUMAN_MODE=true`. If the next argument is one of BUG, FEAT, or POLISH,
  consume it as `HUMAN_NOTES_TAG`. Add both `HUMAN_MODE` and `HUMAN_NOTES_TAG`
  initialization (defaulting to `false` and empty string) near the other flag
  defaults.

**Acceptance criteria:**
- `should_claim_notes` returns 1 (false) when neither flag is set, regardless
  of task text
- `HUMAN_MODE=true should_claim_notes` returns 0 (true)
- `WITH_NOTES=true should_claim_notes` returns 0 (true)
- Task text matching ("human notes", "HUMAN_NOTES") no longer triggers claiming
- Coder prompt has empty `HUMAN_NOTES_BLOCK` when notes are not claimed
- `{{IF:HUMAN_NOTES_BLOCK}}` section does not render when notes are not claimed
- COMPLETE→IN PROGRESS downgrade no longer exists in coder.sh (if present)
- `--human` flag is accepted and sets `HUMAN_MODE=true`
- `--human BUG` sets `HUMAN_NOTES_TAG=BUG`
- `--human FEAT` sets `HUMAN_NOTES_TAG=FEAT`
- `--human POLISH` sets `HUMAN_NOTES_TAG=POLISH`
- `--human` without a tag argument does not consume the next positional argument
  as a tag (only BUG/FEAT/POLISH are valid tag values)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- `HUMAN_NOTES_BLOCK` must be set to `""` (empty string), not left unset, when
  notes are not claimed. The template engine treats unset variables differently
  from empty ones.
- `should_claim_notes` is called in two places in coder.sh (claiming and resolving).
  Both must be updated to the parameterless form.
- The `--human` flag parser must handle edge cases: `--human` as the last argument
  (no tag), `--human` followed by a non-tag argument (e.g., `--human --complete`
  should not consume `--complete` as a tag).
- `HUMAN_MODE` and `HUMAN_NOTES_TAG` must be exported so they're visible to
  sourced libraries (notes.sh checks `HUMAN_MODE`).

**Seeds Forward:**
- Milestone 15.1.2 is independent and can run in parallel.
- Milestone 15.4 builds the `--human` workflow on top of the flag-only gating
  established here.
- Milestone 15.3 depends on `should_claim_notes` being flag-only for reliable
  `finalize_run()` behavior.

#### Milestone 15.1.2.1: Resolved Cleanup Function for NON_BLOCKING_LOG.md

Add `clear_resolved_nonblocking_notes()` to lib/drift_cleanup.sh that empties the
`## Resolved` section of NON_BLOCKING_LOG.md on successful pipeline completion.
The function prints cleared items to stdout for metrics capture, then removes them
while preserving the section heading.

**Files to modify:**
- `lib/drift_cleanup.sh` — Add `clear_resolved_nonblocking_notes()` function
  after the existing `clear_completed_nonblocking_notes()` (line ~207). The
  function reads all items from the `## Resolved` section of NON_BLOCKING_LOG.md,
  prints them to stdout (for metrics capture by the caller), then removes the
  items while preserving the `## Resolved` heading. Follow the same while-read
  pattern used by `clear_completed_nonblocking_notes()` for consistency. Return 0
  on success or if no resolved items exist. Return 0 if NON_BLOCKING_LOG.md
  doesn't exist.

**Acceptance criteria:**
- `clear_resolved_nonblocking_notes()` empties `## Resolved` section items and
  prints them to stdout
- `clear_resolved_nonblocking_notes()` preserves the `## Resolved` heading itself
- `clear_resolved_nonblocking_notes()` returns 0 when no resolved items exist
- `clear_resolved_nonblocking_notes()` returns 0 when NON_BLOCKING_LOG.md doesn't
  exist
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/drift_cleanup.sh`

**Watch For:**
- `clear_resolved_nonblocking_notes()` must preserve the `## Resolved` heading
  itself — only clear the items underneath it. Don't delete blank lines between
  the heading and the first item.
- Follow the same pattern as `clear_completed_nonblocking_notes()` which uses
  a while-read loop with a tmpfile, not AWK for the actual rewrite. The AWK
  is only used for counting.
- Items in the Resolved section use `- [x]` checkbox format. Match that pattern
  when counting and filtering.

**Seeds Forward:**
- Milestone 15.3 calls `clear_resolved_nonblocking_notes()` from `finalize_run()`.
- This sub-milestone is independent of 15.1.2.2 and can run in parallel.

#### Milestone 15.1.2.2: AUTO_COMMIT Conditional Default

Change `AUTO_COMMIT` default in lib/config_defaults.sh to be conditional: `true`
when `MILESTONE_MODE=true`, `false` otherwise. Update the existing test file to
verify the conditional behavior.

**Files to modify:**
- `lib/config_defaults.sh` — Change the `AUTO_COMMIT` default (lines 128-129)
  to be conditional on `MILESTONE_MODE`. Replace the unconditional
  `: "${AUTO_COMMIT:=true}"` with a conditional block: if `MILESTONE_MODE=true`,
  default to `true`; otherwise default to `false`. The existing `:=` syntax
  means explicit user config in pipeline.conf still overrides (it's set before
  defaults are loaded). The conditional must check `MILESTONE_MODE` which is set
  during flag parsing in tekhton.sh before `config_defaults.sh` is sourced.
- `tests/test_auto_commit_conditional_default.sh` — Read the existing test file
  first. Update or verify it covers: milestone mode defaults to true,
  non-milestone defaults to false, explicit override works in both modes.

**Acceptance criteria:**
- `AUTO_COMMIT` defaults to `true` in milestone mode
- `AUTO_COMMIT` defaults to `false` in non-milestone mode
- Explicit `AUTO_COMMIT=false` in pipeline.conf overrides the milestone default
- Explicit `AUTO_COMMIT=true` in pipeline.conf overrides the non-milestone default
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/config_defaults.sh`

**Watch For:**
- The `AUTO_COMMIT` conditional default must be set AFTER `MILESTONE_MODE` is
  determined in the config loading sequence. Verify the sourcing order in
  tekhton.sh: flag parsing → config load → config_defaults.sh. If
  `config_defaults.sh` is sourced before flag parsing, the conditional won't
  work and the assignment must move to a later point.
- The existing test file `tests/test_auto_commit_conditional_default.sh` already
  exists — read it first to understand what's already covered before modifying.
- `AUTO_COMMIT` was previously defaulting to `true` unconditionally. The change
  to default `false` in non-milestone mode is a behavior change for users who
  relied on the `true` default. The comment in config_defaults.sh should note this.

**Seeds Forward:**
- Milestone 15.2 depends on the `AUTO_COMMIT` conditional default for
  auto-commit integration in `finalize_run()`.
- This sub-milestone is independent of 15.1.2.1 and can run in parallel.

#### Milestone 15.2.1: mark_milestone_done() Function

Add `mark_milestone_done(milestone_num)` to `lib/milestone_ops.sh` that programmatically
marks a milestone heading as `[DONE]` in CLAUDE.md. This is the foundational function
that archival cleanup (15.2.2) and finalize_run (15.3) depend on.

**Files to modify:**
- `lib/milestone_ops.sh` — Add `mark_milestone_done(milestone_num)` after the existing
  `clear_milestone_state()` function (line ~285). The function:
  1. Reads the project's CLAUDE.md (path from `PROJECT_RULES_FILE` or default
     `"$PROJECT_DIR/CLAUDE.md"`)
  2. Finds the line matching `^#### Milestone ${milestone_num}:` (without `[DONE]`)
     using grep. The regex must handle dotted numbers like `13.2.1.1` — escape dots
     in the pattern: `^#### Milestone ${milestone_num//./\\.}:`
  3. If found, uses sed to prepend `[DONE] ` making it `#### [DONE] Milestone N: Title`
  4. Is idempotent — if the line already contains `#### [DONE] Milestone ${milestone_num}:`,
     returns 0 without modification
  5. Returns 1 if neither the plain nor [DONE] heading is found
  6. Uses a tmpfile + mv pattern (consistent with other file-modifying functions in
     the codebase) rather than sed -i for portability

**Acceptance criteria:**
- `mark_milestone_done 15` changes `#### Milestone 15:` to `#### [DONE] Milestone 15:` in CLAUDE.md
- `mark_milestone_done 15` on an already-marked milestone is a no-op (returns 0)
- `mark_milestone_done 999` returns 1 (milestone not found)
- `mark_milestone_done 13.2.1.1` correctly handles dotted sub-milestone numbers
- The function does not modify any other lines in CLAUDE.md
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/milestone_ops.sh`

**Watch For:**
- The milestone number may contain dots (e.g., `13.2.1.1`). Dots must be escaped in
  the grep/sed regex so `13.2` doesn't match `13X2`.
- `PROJECT_RULES_FILE` is the canonical path to CLAUDE.md in the target project. Check
  how other functions in milestone_ops.sh locate CLAUDE.md and follow the same pattern.
- The function must handle CLAUDE.md files where the milestone heading has trailing
  content on subsequent lines (full block) OR is a one-liner (just the heading).
  `mark_milestone_done` only modifies the heading line itself.

**Seeds Forward:**
- Milestone 15.2.2 depends on `mark_milestone_done()` being available for the archival
  flow and uses the `[DONE]` marker as the trigger for removal.
- Milestone 15.3 calls `mark_milestone_done()` from `finalize_run()`.

#### Milestone 15.2.2.1: Archive Function — Remove [DONE] Lines Instead of One-Liner Summaries

Modify `archive_completed_milestone()` in `lib/milestone_archival.sh` so that after
archiving a milestone block to MILESTONE_ARCHIVE.md, the AWK rewrite removes the
`[DONE]` line entirely from CLAUDE.md (instead of inserting a one-liner summary).
Also add insertion of the `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->`
pointer comment and collapse consecutive blank lines after removal.

**Files to modify:**
- `lib/milestone_archival.sh` — Modify `archive_completed_milestone()` (lines 110-190):
  1. Remove `local summary_line` (line 150) — no longer needed since we're deleting
     rather than replacing with a summary
  2. Change the AWK block (lines 157-184): instead of `print summary` when the
     milestone heading is matched, output nothing (just `next`). The `in_block`
     logic that skips the body lines remains unchanged. The net effect is that
     the entire milestone block (heading + body) is removed from the output
  3. After the AWK rewrite produces the tmpfile, add a second pass: check if
     `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->` already exists
     in the file. If not, find the `### Milestone Plan` heading that contained
     this milestone (use `_get_initiative_name` to identify the section) and
     insert the comment on the line after that heading. Use grep to check
     existence first to avoid duplicates
  4. Add a third pass on the tmpfile: collapse 3+ consecutive blank lines down
     to 2 using `awk 'BEGIN{n=0} /^$/{n++; if(n<=2) print; next} {n=0; print}'`
     or equivalent

**Acceptance criteria:**
- `archive_completed_milestone()` removes the `[DONE]` heading AND body from
  CLAUDE.md after archiving — no one-liner summary remains
- `archive_completed_milestone()` appends the full block to MILESTONE_ARCHIVE.md
  (existing behavior preserved)
- The `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->` comment is
  inserted once per `### Milestone Plan` section and not duplicated on
  subsequent archival calls
- Calling `archive_completed_milestone` twice on the same milestone is safe
  (idempotent — second call returns 1 since milestone is already archived)
- No consecutive triple-blank-lines remain in CLAUDE.md after archival
- `archive_all_completed_milestones()` still works (it delegates to the modified
  function)
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/milestone_archival.sh`

**Watch For:**
- The AWK block currently uses `print summary` on line 166 to insert the one-liner.
  Change this to just `next` (skip the line entirely). Do NOT print an empty line —
  just skip. The blank-line collapsing pass handles any resulting gaps.
- The `_get_initiative_name` function returns the initiative name, but to find the
  correct `### Milestone Plan` heading you need to search for `### Milestone Plan`
  within that initiative's section. The file may have multiple `### Milestone Plan`
  headings (one per initiative).
- The archive pointer comment insertion must happen AFTER the AWK rewrite (on the
  tmpfile or after mv), not before, to avoid the AWK pass interfering with the
  comment.
- The blank-line collapsing must preserve single and double blank lines — only
  collapse when 3+ consecutive blanks appear.

**Seeds Forward:**
- Milestone 15.2.2.2 uses the updated archival function behavior — after the
  one-time migration, future archival calls will leave CLAUDE.md clean.
- Milestone 15.3 integrates `archive_completed_milestone()` (with removal behavior)
  into the `finalize_run()` call sequence.

#### Milestone 15.2.2.2: One-Time CLAUDE.md Migration — Remove Accumulated [DONE] One-Liners

Perform a one-time migration of CLAUDE.md to remove all 26 existing `#### [DONE]
Milestone N: Title` one-liner lines that accumulated from prior archival runs. Add
the archive pointer comment in each `### Milestone Plan` section. These one-liners
have no content block — the full blocks are already in MILESTONE_ARCHIVE.md.

**Files to modify:**
- `CLAUDE.md` — One-time migration:
  1. Remove all `#### [DONE] Milestone N: Title` one-liner lines under the
     "Completed Initiative: Planning Phase Quality Overhaul" section (lines
     272-276: milestones 1-5)
  2. Remove all `#### [DONE] Milestone N: Title` one-liner lines under the
     "Current Initiative: Adaptive Pipeline 2.0" section (lines 301-323:
     milestones 0 through 14)
  3. A line is a "one-liner" if the next non-blank line starts with `####`,
     `###`, `##`, or is EOF. Active milestones with content blocks below
     the heading must NOT be removed
  4. Add `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->` comment
     immediately after each `### Milestone Plan` heading where [DONE] lines
     were removed
  5. Remove the orphaned agent output lines ("Based on the codebase analysis,
     here's the split:" and "Now I have enough context. Here's the split:")
     that appear between the [DONE] block and the active milestones
  6. Collapse any resulting triple-or-more consecutive blank lines down to
     double blank lines
  7. Verify MILESTONE_ARCHIVE.md still contains all previously archived content
     (this migration only touches CLAUDE.md, not the archive)

**Acceptance criteria:**
- CLAUDE.md has zero `#### [DONE]` one-liner lines after migration
- Active milestone blocks (15.1.1, 15.1.2.1, 15.1.2.2, 15.2.1, 15.2.2, 15.3,
  15.4, 16, 17-21) are fully intact with all their content
- `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->` appears once in
  each `### Milestone Plan` section
- The orphaned agent output text ("Based on the codebase analysis...") is removed
- MILESTONE_ARCHIVE.md is unchanged (verify with `git diff` on the archive file)
- No consecutive triple-blank-lines remain
- All existing tests pass
- `bash -n` and `shellcheck` pass on all `.sh` files (CLAUDE.md is not a shell
  file but verify no shell files were accidentally modified)

**Watch For:**
- The one-time migration must distinguish between one-liner summaries and active
  milestones. A safe heuristic: if the next non-blank line starts with `####`,
  `###`, `##`, or is EOF, it's a one-liner. Lines 328+ have active milestone
  content — those must be preserved.
- Lines 324-326 contain orphaned agent output text that leaked into CLAUDE.md
  from a prior splitting run. These are not milestone headings but should be
  cleaned up as part of this migration.
- After removing ~26 [DONE] lines plus the orphaned text, verify the section
  structure is correct: each initiative section should have `### Milestone Plan`
  → `<!-- See MILESTONE_ARCHIVE.md -->` → active milestones.
- Do NOT touch MILESTONE_ARCHIVE.md. This migration only modifies CLAUDE.md.
  Run `git diff MILESTONE_ARCHIVE.md` after the migration to confirm zero changes.

**Seeds Forward:**
- With the migration complete, the updated `archive_completed_milestone()` from
  15.2.2.1 ensures no new [DONE] one-liners accumulate in future runs.
- Milestone 15.3 can rely on a clean CLAUDE.md structure when `finalize_run()`
  calls the archival function.
#### Milestone 15.3: finalize_run() Consolidation

Consolidate all scattered post-pipeline bookkeeping in `tekhton.sh` into a single
`finalize_run()` function in `lib/hooks.sh`. This is the capstone sub-milestone
that wires together all fixes from 15.1 and 15.2 into a deterministic, ordered
finalization sequence.

**Files to modify:**
- `lib/hooks.sh` — Add a hook registry and `finalize_run()` orchestrator:
  1. Add `declare -a FINALIZE_HOOKS=()` array and `register_finalize_hook()`
     function. Each hook is a function name; `finalize_run()` iterates the
     array in registration order, passing `pipeline_exit_code` to each hook.
     Hooks that fail log a warning but do not abort the sequence (||
     log_warn pattern). This makes `finalize_run()` open for extension by
     V3 without modifying the core sequence — V3 adds dashboard generation,
     lane completion signaling, and graph updates by registering additional
     hooks.
  2. Register the following hooks in this exact order (registration order
     IS execution order):
     a. `_hook_final_checks` — wraps `run_final_checks()` (analyze + test)
     b. `_hook_drift_artifacts` — wraps `process_drift_artifacts()`
     c. `_hook_record_metrics` — wraps `record_run_metrics()`
     d. `_hook_cleanup_resolved` — wraps `clear_resolved_nonblocking_notes()`
        (only if pipeline succeeded)
     e. `_hook_resolve_notes` — wraps `resolve_human_notes_with_exit_code
        $pipeline_exit_code`. If CODER_SUMMARY.md is missing but pipeline
        succeeded (exit 0), mark all [~] → [x] instead of resetting to [ ].
        Fixes the bug where features are implemented and committed but
        HUMAN_NOTES shows undone.
     f. `_hook_archive_reports` — wraps `archive_reports "$LOG_DIR" "$TIMESTAMP"`
     g. `_hook_mark_done` — wraps `mark_milestone_done "$CURRENT_MILESTONE"`
        (only if milestone mode AND acceptance passed)
     h. `_hook_commit` — Auto-commit: if `AUTO_COMMIT=true` (now defaulting
        to true in milestone mode per 15.1), run `_do_git_commit()` without
        interactive prompt. If `AUTO_COMMIT=false`, call the existing
        interactive prompt (reading from `/dev/tty`).
     i. `_hook_archive_milestone` — wraps `archive_completed_milestone()`
        (only after commit, only if milestone was marked [DONE])
     j. `_hook_clear_state` — wraps `clear_milestone_state()` (only after
        successful milestone archival, prevents stale MILESTONE_STATE.md)
  3. `finalize_run()` itself is simple: accept `pipeline_exit_code`, iterate
     `FINALIZE_HOOKS`, call each with the exit code. Hooks d-e, g-j only
     execute their inner logic when `pipeline_exit_code=0` (each hook checks
     internally).
  4. Hooks are registered at source-time (when hooks.sh is sourced), not at
     call-time. This ensures the sequence is deterministic across all code
     paths. V3 modules register additional hooks after hooks.sh is sourced.
- `tekhton.sh` — Replace the scattered post-pipeline section (lines ~940-1149)
  with a single call to `finalize_run $pipeline_exit_code`. Remove all inline
  commit prompt logic, inline `archive_completed_milestone()` calls, and
  inline metrics/drift/archive calls. The `_do_git_commit()` helper moves to
  `lib/hooks.sh` alongside `finalize_run()`.

**Acceptance criteria:**
- `finalize_run()` is the ONLY place post-pipeline bookkeeping happens — no
  straggler calls in `tekhton.sh`
- Post-pipeline bookkeeping runs in deterministic order as specified above
- `finalize_run 0` (success) runs all 10 hooks including cleanup, notes
  resolution, commit, and archival
- `finalize_run 1` (failure) runs hooks a-c and f only (metrics recorded,
  reports archived, but no cleanup/commit/archival)
- `register_finalize_hook` appends to `FINALIZE_HOOKS` array and hooks
  execute in registration order
- A failing hook logs a warning but does not abort the remaining hooks
- Pipeline runs in milestone mode auto-commit without interactive prompt
- Non-milestone mode with `AUTO_COMMIT=false` still shows interactive prompt
- Commit includes the milestone's code changes (archival happens AFTER commit)
- Metrics are recorded BEFORE resolved-item cleanup (counts are captured)
- `generate_commit_message()` is called within `finalize_run()` before commit
- `resolve_human_notes` marks [~] → [x] when CODER_SUMMARY.md is missing but
  pipeline exit code is 0 (success), instead of resetting to [ ]
- `clear_milestone_state()` is called after milestone archival, leaving no
  stale MILESTONE_STATE.md for subsequent runs
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The `finalize_run()` ordering is load-bearing:
  - Metrics BEFORE cleanup (so resolved counts are captured)
  - Notes resolution BEFORE archive (so [x] marks are in the archived snapshot)
  - Commit BEFORE archival (so the commit includes milestone code changes)
  - `mark_milestone_done` BEFORE commit (so the commit message can reference
    the milestone status)
  - `clear_milestone_state()` AFTER archival (state file no longer needed)
- `finalize_run()` must handle the case where `run_final_checks()` fails.
  The function should still run metrics/reports/cleanup even if final checks
  fail — but should NOT commit or archive on failure.
- The `_do_git_commit()` helper needs access to variables set in tekhton.sh
  (LOG_DIR, TIMESTAMP, COMMIT_MSG). These should be passed as parameters or
  exported before calling `finalize_run()`.
- The interactive commit prompt (`read` from `/dev/tty`) must remain available
  for non-milestone, non-auto-commit runs. Don't remove it entirely — just
  move it into `finalize_run()`.
- `resolve_human_notes_with_exit_code` must still call the existing
  `resolve_human_notes()` when CODER_SUMMARY.md IS present — the new
  exit-code-aware path is only the fallback when the summary is missing.
- `clear_milestone_state()` must only run in milestone mode. In non-milestone
  runs there is no state file to clear and calling it is harmless but noisy.

**Seeds Forward:**
- Milestone 16 (Outer Loop) calls `finalize_run()` as its single post-iteration
  hook. The consolidated function eliminates the need for the outer loop to
  know about individual bookkeeping steps.
- Auto-commit in milestone mode (from 15.1's config change, wired here)
  eliminates the interactive prompt that would block the autonomous loop.
- Milestone 15.4 (`--human --complete`) reuses `finalize_run()` as its
  per-note post-pipeline hook.
- V3 modules extend `finalize_run()` by calling `register_finalize_hook` after
  hooks.sh is sourced — no modification to the core hook sequence required.
  Dashboard generation, lane completion signaling, and milestone graph updates
  each register as additional hooks.

Now I have a clear picture. Here's the split:

#### Milestone 15.4.1: Single-Note Utility Functions in lib/notes.sh

Add the five single-note utility functions to `lib/notes.sh` that form the foundation
for the `--human` workflow. These functions operate on individual notes rather than
bulk operations, enabling precise one-at-a-time note processing.

**Files to modify:**
- `lib/notes.sh` — Add after the existing `resolve_human_notes()` function (line ~197):
  - `pick_next_note(tag_filter)` — Scans HUMAN_NOTES.md sections in priority order:
    `## Bugs` first, then `## Features`, then `## Polish`. Within each section,
    returns the first `- [ ]` line. If `tag_filter` is set (e.g., "BUG"), only
    scans the corresponding section (`BUG` → `## Bugs`, `FEAT` → `## Features`,
    `POLISH` → `## Polish`). Returns the full note line including checkbox and tag.
    Returns empty string if no unchecked notes remain.
  - `claim_single_note(note_line)` — Marks exactly ONE note from `[ ]` to `[~]` in
    HUMAN_NOTES.md. The `note_line` parameter is the literal line returned by
    `pick_next_note`. Escapes regex special characters (brackets, parentheses, dots)
    in the note text before using sed. Only the first match is marked. Archives
    pre-run snapshot via existing `_archive_notes_snapshot()` if available, or copies
    HUMAN_NOTES.md to `HUMAN_NOTES.md.bak`.
  - `resolve_single_note(note_line, exit_code)` — Resolves a single in-progress note:
    if `exit_code=0`, sed-replace the `[~]` version of `note_line` with `[x]`. If
    non-zero, replace `[~]` back to `[ ]`. Returns 0 if the note was found and
    resolved, 1 if not found.
  - `extract_note_text(note_line)` — Strips the `- [ ] ` or `- [~] ` or `- [x] `
    checkbox prefix, returning the rest (including tag like `[BUG]`). Uses parameter
    expansion or sed.
  - `count_unchecked_notes(tag_filter)` — Counts remaining `- [ ]` lines in
    HUMAN_NOTES.md. If `tag_filter` is set, counts only within the matching section.
    Returns the count as stdout. Returns 0 if file doesn't exist.

**Acceptance criteria:**
- `pick_next_note ""` returns the first unchecked note from Bugs, then Features, then Polish (priority order)
- `pick_next_note "BUG"` only returns notes from the `## Bugs` section
- `pick_next_note "FEAT"` only returns notes from the `## Features` section
- `pick_next_note "POLISH"` only returns notes from the `## Polish` section
- `pick_next_note` returns empty string when all notes are `[x]` or `[~]`
- `claim_single_note` marks exactly ONE note `[~]`, leaving all others unchanged
- `claim_single_note` correctly escapes regex special characters in note text (brackets, parens, dots)
- `resolve_single_note "$note" 0` changes `[~]` → `[x]`
- `resolve_single_note "$note" 1` changes `[~]` → `[ ]`
- `resolve_single_note` returns 1 when the note line is not found
- `extract_note_text "- [ ] [BUG] Fix the thing"` returns `[BUG] Fix the thing`
- `count_unchecked_notes ""` returns total count of `[ ]` notes across all sections
- `count_unchecked_notes "BUG"` returns count of `[ ]` notes in Bugs section only
- All functions return 0 / empty gracefully when HUMAN_NOTES.md doesn't exist
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/notes.sh`

**Watch For:**
- `pick_next_note` must handle section structure. HUMAN_NOTES.md has `## Bugs`,
  `## Features`, `## Polish` headings. The function must track which section it's
  in and stop scanning a section when it hits the next `## ` heading.
- `claim_single_note` must escape ALL sed-special characters in the note text:
  `[`, `]`, `(`, `)`, `.`, `*`, `+`, `?`, `{`, `}`, `\`, `/`, `&`. Use a helper
  function `_escape_sed_pattern()` or `sed 's/[[\.*^$()+?{|/]/\\&/g'`.
- The priority mapping is: tag `BUG` → section `## Bugs`, tag `FEAT` → section
  `## Features`, tag `POLISH` → section `## Polish`. This is NOT alphabetical.
- Use tmpfile + mv pattern for all file modifications (consistent with existing
  notes.sh functions). Never use `sed -i` for portability.

**Seeds Forward:**
- Milestone 15.4.2 uses these functions for `--human` mode orchestration in tekhton.sh
- Milestone 15.4.3 integrates `resolve_single_note()` into `finalize_run()` hooks

#### Milestone 15.4.2: `--human` Mode Orchestration in tekhton.sh

Wire the single-note functions from 15.4.1 into tekhton.sh to implement the
`--human` single-note workflow and `--human --complete` chaining loop. Add flag
validation to reject invalid combinations (`--human --milestone`, `--human "task"`).

**Files to modify:**
- `tekhton.sh` — Add `--human` mode orchestration after flag parsing and config
  loading (before `_run_pipeline_stages`):
  1. **Flag validation** (after all flags are parsed, before pipeline runs):
     - If `HUMAN_MODE=true` and `MILESTONE_MODE=true`: log error
       "Cannot combine --human with --milestone" and exit 1
     - If `HUMAN_MODE=true` and `TASK` is non-empty (user passed a task string):
       log error "Cannot combine --human with an explicit task" and exit 1
     - If `HUMAN_MODE=true` and `WITH_NOTES=true`: log warning
       "--with-notes is redundant with --human (notes are already active)" but
       continue (not an error)
  2. **Single-note mode** (when `HUMAN_MODE=true` and `COMPLETE_MODE` is not set):
     - Call `pick_next_note "$HUMAN_NOTES_TAG"`
     - If empty: log "No unchecked notes" (or "No unchecked [TAG] notes") and exit 0
     - Call `extract_note_text` on the picked note and set `TASK` to the result
     - Call `claim_single_note` for the picked note
     - Store the picked note line in `CURRENT_NOTE_LINE` (exported) for
       `resolve_single_note` in finalize hooks
     - Proceed to `_run_pipeline_stages()` normally
  3. **Human-complete mode** (when `HUMAN_MODE=true` and `COMPLETE_MODE=true`):
     - Initialize `HUMAN_ATTEMPT=0` and record start time
     - Outer loop: while `count_unchecked_notes "$HUMAN_NOTES_TAG"` > 0:
       a. Increment `HUMAN_ATTEMPT`, check against `MAX_PIPELINE_ATTEMPTS`
       b. Check `AUTONOMOUS_TIMEOUT` against elapsed wall-clock time
       c. Call `pick_next_note` → `extract_note_text` → set `TASK`
       d. Call `claim_single_note`
       e. Set `CURRENT_NOTE_LINE`, export it
       f. Run `_run_pipeline_stages()`
       g. Call `finalize_run $?` (which resolves the note via hook)
       h. Check if note is still `[ ]` (read back from file) → break on failure
       i. Continue to next note on success
     - Each iteration is independent: `AUTO_COMMIT=true` ensures commit between notes

**Acceptance criteria:**
- `--human` with no unchecked notes exits 0 with "No unchecked notes" message
- `--human` picks the highest-priority unchecked note (BUG > FEAT > POLISH)
- `--human BUG` only picks `[BUG]` notes
- `--human FEAT` only picks `[FEAT]` notes
- TASK is set to the note's text content (e.g., `[BUG] Fix the thing`)
- Pipeline runs the coder with the note text as the task
- `--human --milestone` is rejected with a clear error message
- `--human "some task"` is rejected with a clear error message
- `--with-notes --human` logs a warning but continues
- `--human` without a task argument does NOT require a task string
- `--human --complete` chains through multiple notes, one per iteration
- `--human --complete` stops on first failure (note still `[ ]`)
- `--human --complete` respects `AUTONOMOUS_TIMEOUT` and `MAX_PIPELINE_ATTEMPTS`
- Each note in `--human --complete` gets its own commit
- `CURRENT_NOTE_LINE` is exported and available to finalize hooks
- All existing tests pass
- `bash -n` and `shellcheck` pass on `tekhton.sh`

**Watch For:**
- The `--human --complete` loop must NOT reuse M16's outer loop directly. M16
  retries the SAME task on failure; `--human --complete` advances to the NEXT
  note on success and stops on failure. Different iteration pattern.
- `CURRENT_NOTE_LINE` must be set BEFORE `_run_pipeline_stages()` and remain
  available through `finalize_run()`. Export it so sourced libraries can access it.
- The `--human` flag parsing already exists (lines 534-543 in tekhton.sh). The
  orchestration logic goes AFTER config loading, not in the flag parsing section.
- When checking if a note is still `[ ]` after `finalize_run`, re-read the file —
  don't cache. `resolve_single_note` modifies the file in place.
- `MAX_PIPELINE_ATTEMPTS` and `AUTONOMOUS_TIMEOUT` may not be defined yet if M16
  isn't implemented. Use `: "${MAX_PIPELINE_ATTEMPTS:=5}"` and
  `: "${AUTONOMOUS_TIMEOUT:=7200}"` defaults inline.

**Seeds Forward:**
- Milestone 15.4.3 wires `resolve_single_note()` into the finalize hook to
  complete the workflow end-to-end
- M16's `--complete` flag provides the same safety bounds reused here

#### Milestone 15.4.3: Finalize Hook Integration for Single-Note Resolution

Modify the `_hook_resolve_notes` hook in `lib/finalize.sh` to detect `HUMAN_MODE`
and call `resolve_single_note()` instead of bulk `resolve_human_notes()`. This
completes the end-to-end `--human` workflow: pick → claim → pipeline → resolve.

**Files to modify:**
- `lib/finalize.sh` — Modify `_hook_resolve_notes()` (lines 85-100):
  1. At the top of the function, check if `HUMAN_MODE=true` AND
     `CURRENT_NOTE_LINE` is non-empty
  2. If yes: call `resolve_single_note "$CURRENT_NOTE_LINE" "$exit_code"`
     and return. Skip the bulk `resolve_human_notes` path entirely.
  3. If no: fall through to the existing bulk resolution logic (unchanged)
  4. Log which path was taken: "Resolving single note" vs "Resolving all
     claimed notes"
- `tests/test_human_workflow.sh` — Create a test file that validates the
  end-to-end `--human` workflow:
  1. Test `pick_next_note` priority ordering with a multi-section HUMAN_NOTES.md
  2. Test `claim_single_note` marks exactly one note
  3. Test `resolve_single_note` success and failure paths
  4. Test `extract_note_text` strips checkbox prefix correctly
  5. Test `count_unchecked_notes` with and without tag filter
  6. Test flag validation: `--human --milestone` rejected, `--human "task"` rejected

**Acceptance criteria:**
- `finalize_run 0` in `HUMAN_MODE` calls `resolve_single_note` with exit code 0,
  marking the note `[x]`
- `finalize_run 1` in `HUMAN_MODE` calls `resolve_single_note` with exit code 1,
  resetting the note to `[ ]`
- `finalize_run` without `HUMAN_MODE` still calls bulk `resolve_human_notes`
  (existing behavior preserved)
- `CURRENT_NOTE_LINE` empty in `HUMAN_MODE` logs a warning and falls through to
  bulk resolution (defensive)
- On success (exit 0), the note is marked `[x]` in HUMAN_NOTES.md
- On failure (exit non-zero), the note is reset to `[ ]` in HUMAN_NOTES.md
- Notes are never auto-injected based on task text matching (flag-only gating)
- Test file validates all single-note functions and flag validation
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- `resolve_single_note` is defined in `lib/notes.sh` but called from
  `lib/finalize.sh`. Ensure `notes.sh` is sourced before `finalize.sh` in
  `tekhton.sh` (check the source order).
- `CURRENT_NOTE_LINE` contains the ORIGINAL note line (with `[ ]` prefix) but
  after `claim_single_note` it's `[~]` in the file. `resolve_single_note` must
  match the `[~]` version. Either: (a) store the claimed version, or (b) have
  `resolve_single_note` reconstruct the `[~]` pattern from the original. Option
  (b) is safer — the function knows it's looking for `[~]`.
- The test file must create a temporary HUMAN_NOTES.md with realistic section
  structure (## Bugs, ## Features, ## Polish) and multiple notes per section.
- Don't modify the existing `_hook_resolve_notes` behavior for non-human-mode
  runs. The conditional must be a clean if/else, not a replacement.

**Seeds Forward:**
- The single-note claim/resolve pattern established here could eventually replace
  bulk `claim_human_notes()` / `resolve_human_notes()` entirely.
- V3 could add `--human --watch` that monitors HUMAN_NOTES.md for new items
  and processes them automatically using these functions.
- M16's `--complete` outer loop reuses the safety bounds (`MAX_PIPELINE_ATTEMPTS`,
  `AUTONOMOUS_TIMEOUT`) validated here.
#### Milestone 16: Outer Orchestration Loop (Milestone-to-Completion)

Add a `--complete` flag that wraps the entire pipeline in an outer orchestration
loop with a clear contract: **run this milestone until it passes acceptance or all
recovery options are exhausted.** This is the capstone of V2 — combining transient
retry (M13), turn continuation (M14), milestone splitting (M11), and error
classification (M12) into a single autonomous loop that eliminates the human
re-run cycle.

**Files to modify:**
- `tekhton.sh` — Add `--complete` flag parsing. When active, wrap
  `_run_pipeline_stages()` in an outer loop:
  ```
  PIPELINE_ATTEMPT=0
  while true; do
      PIPELINE_ATTEMPT=$((PIPELINE_ATTEMPT + 1))
      
      _run_pipeline_stages  # coder → review → tester
      
      if check_milestone_acceptance; then
          break  # SUCCESS — commit, archive, done
      fi
      
      # Acceptance failed — diagnose and recover
      if [ $PIPELINE_ATTEMPT -ge $MAX_PIPELINE_ATTEMPTS ]; then
          save state, exit with full diagnostic
          break
      fi
      
      # Check for progress between attempts
      if no_progress_since_last_attempt; then
          # Degenerate loop detected
          save state, exit with "stuck" diagnostic
          break
      fi
      
      log "Acceptance not met. Re-running pipeline (attempt $PIPELINE_ATTEMPT/$MAX_PIPELINE_ATTEMPTS)..."
      # Loop back — coder gets prior progress context automatically
  done
  ```
- `tekhton.sh` — Add safety bounds enforced in the outer loop:
  1. `MAX_PIPELINE_ATTEMPTS=5` — hard cap on full pipeline cycles
  2. `AUTONOMOUS_TIMEOUT=7200` (2 hours) — wall-clock kill switch checked at
     the top of each loop iteration
  3. `MAX_AUTONOMOUS_AGENT_CALLS=20` — cumulative agent invocations across all
     loop iterations (prevents runaway in pathological rework cycles)
  4. Progress detection: compare `git diff --stat` between loop iterations. If
     the diff is identical, the pipeline is stuck. Exit after 2 no-progress
     iterations.
- `lib/config.sh` — Add defaults: `COMPLETE_MODE_ENABLED=true`,
  `MAX_PIPELINE_ATTEMPTS=5`, `AUTONOMOUS_TIMEOUT=7200`,
  `MAX_AUTONOMOUS_AGENT_CALLS=20`, `AUTONOMOUS_PROGRESS_CHECK=true`
- `lib/state.sh` — Extend `write_pipeline_state()` with `## Orchestration Context`
  section: pipeline attempt number, cumulative agent calls, cumulative turns used,
  wall-clock elapsed, and outcome of each prior attempt (one-line summary). On
  resume, this context is available to diagnose why the loop stopped.
- `lib/hooks.sh` — In the outer loop's post-acceptance path: run the existing
  commit flow, then call `archive_completed_milestone()`. If `--auto-advance` is
  also set, advance to next milestone and continue the outer loop for the next
  milestone (combining `--complete` with `--auto-advance` chains milestone
  completion).
- `lib/milestones.sh` — Add `record_pipeline_attempt(milestone_num, attempt,
  outcome, turns_used, files_changed)` that logs attempt metadata for the
  progress detector and metrics. Add `emit_milestone_metadata(milestone_num,
  depends_on, seeds_forward)` that writes an HTML comment block into CLAUDE.md
  immediately after the milestone heading. Format:
  ```
  <!-- milestone-meta
  id: "16"
  depends_on: ["15.3", "15.4"]
  seeds_forward: ["17", "18"]
  estimated_complexity: "large"
  status: "in_progress"
  -->
  ```
  This comment is invisible to agents (they ignore HTML comments) but parseable
  by the V3 milestone graph builder. `mark_milestone_done()` updates the
  `status` field to `"done"` when marking a milestone complete. The metadata
  block is idempotent — if already present, it is updated in-place rather than
  duplicated. Complexity is inferred from the milestone's acceptance criteria
  count and file-list length: ≤3 criteria + ≤2 files = "small", ≤8 criteria +
  ≤5 files = "medium", else "large".
- `lib/common.sh` — Add `report_orchestration_status(attempt, max, elapsed,
  agent_calls)` that prints a banner at the start of each loop iteration showing
  the autonomous loop state.
- `lib/metrics.sh` — Add `pipeline_attempts` and `total_agent_calls` fields to
  JSONL record.
- `lib/hooks.sh` — Add `_hook_emit_run_summary` registered as a finalize hook
  (via `register_finalize_hook` from M15.3). This hook writes
  `RUN_SUMMARY.json` to `$LOG_DIR` at the end of each pipeline run (success
  or failure). Contents:
  ```json
  {
    "milestone": "16",
    "outcome": "success|failure|timeout|stuck",
    "attempts": 2,
    "total_agent_calls": 8,
    "wall_clock_seconds": 1847,
    "files_changed": ["lib/hooks.sh", "tekhton.sh"],
    "error_classes_encountered": ["turn_exhaustion"],
    "recovery_actions_taken": ["continuation"],
    "rework_cycles": 1,
    "split_depth": 0,
    "timestamp": "2026-03-19T14:30:00Z"
  }
  ```
  The hook collects data from variables already tracked by the outer loop
  (PIPELINE_ATTEMPT, cumulative agent calls, wall clock, exit stage) and
  from `git diff --name-only` for files_changed. This structured output is
  consumed by V3's milestone steward for adaptive scheduling: turn budget
  calibration, parallelization decisions, and file-overlap conflict prediction.
- `templates/pipeline.conf.example` — Add `--complete` config keys with comments

**Recovery decision tree inside the loop:**
```
After _run_pipeline_stages returns non-zero:
├── Was it a transient error? → Already retried by M13. If still failing,
│   save state and exit (sustained outage — human should check API status)
├── Was it turn exhaustion? → Already continued by M14. If still exhausting
│   after MAX_CONTINUATION_ATTEMPTS, trigger split (existing M11)
├── Was it a null run? → Already split by M11. If split depth exhausted,
│   save state and exit (milestone irreducible)
├── Was it a review cycle max? → Bump MAX_REVIEW_CYCLES by 2 (one time only),
│   re-run from review stage. If still failing, save state and exit.
├── Was it a build gate failure after rework? → Re-run from coder stage with
│   BUILD_ERRORS_CONTENT injected (one retry). If still failing, save state
│   and exit.
└── Was it an unclassified error? → Save state and exit immediately.
    Never retry an unknown error.
```

**Acceptance criteria:**
- `--complete` runs the pipeline in a loop until milestone acceptance passes
- `MAX_PIPELINE_ATTEMPTS=5` prevents infinite loops
- `AUTONOMOUS_TIMEOUT=7200` (2 hours) is a hard wall-clock kill switch
- `MAX_AUTONOMOUS_AGENT_CALLS=20` caps total agent invocations across all attempts
- Progress detection exits the loop if `git diff --stat` is unchanged between
  iterations (stuck detection after 2 no-progress attempts)
- Recovery decisions follow the documented decision tree — transient, turn
  exhaustion, null run, review max, build failure, and unclassified each have
  distinct handling
- Review cycle max gets ONE bump of +2 cycles before giving up
- Build failure after rework gets ONE coder re-run before giving up
- Unclassified errors are NEVER retried
- `--complete` combined with `--auto-advance` chains milestone completions
- Orchestration state is persisted in `PIPELINE_STATE.md` on interruption
- Resume from `PIPELINE_STATE.md` restores attempt counter and cumulative metrics
- Each loop iteration prints a status banner showing attempt, elapsed time, and
  agent call count
- `metrics.jsonl` records pipeline attempts and total agent calls
- `RUN_SUMMARY.json` is written to `$LOG_DIR` on every pipeline completion
  (success and failure) with structured outcome data
- `RUN_SUMMARY.json` includes: milestone, outcome, attempts, total_agent_calls,
  wall_clock_seconds, files_changed, error_classes_encountered,
  recovery_actions_taken, rework_cycles, split_depth, timestamp
- Milestone metadata HTML comments (`<!-- milestone-meta ... -->`) are written
  to CLAUDE.md when milestone state changes (start, complete)
- Metadata comments are idempotent — updating an existing comment replaces it
  rather than duplicating
- Metadata comments do not affect agent behavior (invisible in prompt rendering)
- Without `--complete`, behavior is identical to current (single attempt, exit on
  failure)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The outer loop DOES NOT re-run stages that already succeeded in the same
  iteration. If coder + review succeeded but tester failed, the next iteration
  should `--start-at tester`, not re-run coder. Use `EXIT_STAGE` from the state
  file to determine the restart point.
- Progress detection must compare MEANINGFUL state, not just diff output. A
  rework cycle that reverts and re-applies the same changes looks like "progress"
  in terms of diff but is actually stuck. Compare diff CONTENT hashes, not just
  line counts.
- The cumulative agent call counter must account for retries (M13) and
  continuations (M14). A single "coder" stage might invoke 3 retries × 2
  continuations = 6 agent calls. All count toward the cap.
- Wall-clock timeout should be checked at the TOP of each loop iteration, not
  inside stages. This ensures clean state persistence before timeout exit.
- `--complete` without `--milestone` should work for non-milestone tasks too: run
  the pipeline, check if build/test pass, retry if not. The acceptance check
  falls back to "build gate passes" when no milestone criteria exist.
- Do NOT attempt to automatically resolve REPLAN_REQUIRED verdicts. If the
  reviewer says the milestone is mis-scoped, the outer loop should save state
  and exit with a clear message. Replanning requires human judgment.
- Do NOT allow the outer loop to run cleanup sweeps between attempts. Cleanup
  only runs after final success. Running cleanup mid-loop risks introducing
  new failures from debt resolution.
- The `--complete` + `--auto-advance` combination is the closest V2 gets to
  fully autonomous operation. It chains: complete milestone N → advance to
  N+1 → complete N+1 → ... up to `AUTO_ADVANCE_LIMIT`. This is deliberately
  capped. V3 removes the cap.
- `RUN_SUMMARY.json` must be written via the finalize hook registry (M15.3's
  `register_finalize_hook`), NOT as inline code in the outer loop. This ensures
  it runs in the correct sequence relative to other hooks and is extensible.
- The milestone metadata HTML comment must use `<!-- milestone-meta ... -->`
  delimiters exactly — no variations. The V3 graph parser will match this
  literal prefix. The comment must be on lines immediately following the
  `#### Milestone N:` heading, before any prose content.
- `emit_milestone_metadata()` must handle CLAUDE.md files that already have
  metadata comments (update in-place) AND files that don't (insert after
  heading). Use a sed block that matches the heading line and checks whether
  the next line starts with `<!-- milestone-meta`. If yes, replace the block.
  If no, insert after the heading.
- `RUN_SUMMARY.json` must be valid JSON. Use `printf` with proper escaping
  for string values, not heredoc with unescaped variables. File paths in
  `files_changed` may contain special characters.
- The `_hook_emit_run_summary` hook should run on BOTH success and failure
  paths (unlike hooks d-j in M15.3 which are success-only). The `outcome`
  field distinguishes the cases. V3's steward needs failure data as much as
  success data for scheduling decisions.

**What NOT To Do:**
- Do NOT add a `--build-project` flag. That's V3 scope. `--complete` operates on
  one milestone (or a limited chain with `--auto-advance`).
- Do NOT add cost budgeting. V3 scope. V2 uses invocation counts and wall-clock
  time as proxy limits.
- Do NOT add scheduled execution or daemon mode. V3 scope.
- Do NOT modify the inner pipeline stages. The outer loop wraps them; it does not
  change their behavior. Stages see a single invocation — they don't know they're
  inside a loop.
- Do NOT retry REPLAN_REQUIRED verdicts. The reviewer is saying the task is wrong.
  Retrying the same wrong task is wasteful.
- Do NOT override user config inside the loop. If `MAX_REVIEW_CYCLES=3` and the
  one-time bump makes it 5, that's the maximum. The loop cannot keep bumping.

**Seeds Forward:**
- V3 `--build-project` extends the outer loop to span ALL milestones without the
  `AUTO_ADVANCE_LIMIT` cap
- V3 cost budgeting adds dollar-amount tracking alongside the invocation cap
- V3 adaptive strategy selection replaces the fixed decision tree with a
  metrics-informed classifier that learns which recovery strategy works best
  for each project
- The orchestration state (attempt count, cumulative metrics, per-attempt outcomes)
  becomes the foundation for V3's project-level progress reporting
- V3 milestone graph builder parses `<!-- milestone-meta -->` comments from
  CLAUDE.md to construct the DAG representation (`MILESTONE_GRAPH.yaml`). The
  structured metadata eliminates the need for NLP-based dependency extraction
  from prose `Seeds Forward` blocks — dependencies are already declared as
  `depends_on` and `seeds_forward` arrays in the metadata comments.
- V3 milestone steward reads `RUN_SUMMARY.json` history to calibrate scheduling:
  turn budgets are adjusted based on historical agent call counts per milestone,
  parallelization decisions use `files_changed` overlap analysis across past
  milestones, and error pattern detection uses `error_classes_encountered` to
  predict which milestones are likely to need retry infrastructure.
- The `register_finalize_hook` pattern (from M15.3) allows V3 to add dashboard
  generation, lane completion signaling, and graph rebalancing hooks without
  modifying M16's outer loop code.

## Future Initiative: Brownfield Intelligence (Smart Init)

Tekhton's `--init` today is a bare scaffold: copy templates, stub CLAUDE.md, tell
the user to fill in the blanks. This locks out every project that isn't greenfield.
The Brownfield Intelligence initiative makes `--init` a deep, context-aware onboarding
experience. A shell-driven crawler indexes the project structure, detects the tech
stack, infers build/test/lint commands, samples key files, and feeds that index to
an agent-assisted synthesis pipeline that produces a production-quality CLAUDE.md
and DESIGN.md — no 30-minute interview required.

The end state: Tekhton can be dropped into any repository — 50-file CLI tool or
500k-line monorepo — and produce an accurate project model on the first run.

### Design Philosophy

- **Shell crawls, agent synthesizes.** The crawler is pure bash with no LLM calls.
  It produces a structured, token-efficient project manifest (PROJECT_INDEX.md).
  The agent reads the manifest + sampled key files and synthesizes CLAUDE.md and
  DESIGN.md. This separation keeps crawling fast, deterministic, and free.
- **Breadth-first, depth-bounded.** Large repos have deep directory trees. The
  crawler visits every directory but only descends into files at configurable depth.
  Breadth-first ensures top-level structure is always captured even if the crawl
  budget is exhausted mid-tree.
- **Heuristic detection, agent verification.** Shell heuristics detect tech stack,
  entry points, and commands with high recall but imperfect precision. The synthesis
  agent validates and corrects heuristic output. This avoids the "garbage in,
  garbage out" problem of pure heuristic approaches without paying for full-LLM
  indexing.
- **One-time cost, persistent artifact.** The project index (PROJECT_INDEX.md) is
  generated once and committed alongside CLAUDE.md. Future `--replan` runs consume
  the index rather than re-crawling.
- **Incremental by default.** After initial crawl, `--rescan` only processes files
  changed since the last scan (via `git diff`). Full re-crawl available via
  `--rescan --full`.

### Key Constraints

- **No new runtime dependencies.** Crawler uses only bash builtins, `find`, `file`,
  `wc`, `head`, `awk`, `sed`, and `git`. No Python, no jq, no external indexers.
- **Budget-bounded.** Crawler output (PROJECT_INDEX.md) must fit within a
  configurable token budget (default: 30k tokens / ~120k chars). Larger projects
  get coarser granularity, not truncated output.
- **Deterministic.** Same repo state → same index output. No randomization,
  no sampling variability.
- **Safe.** Crawler never executes project code, never reads `.env` or key files,
  never follows symlinks outside the project tree.
- **All existing tests must pass** at every milestone.
- **All new `.sh` files must pass `bash -n` and `shellcheck`.**

### Milestone Plan

#### Milestone 17: Tech Stack Detection Engine

Pure shell library that detects project language(s), framework(s), package manager,
build system, and infers ANALYZE_CMD / TEST_CMD / BUILD_CHECK_CMD. No agent calls.
Returns structured detection results that `--init` and the crawler consume.

**Files to create:**
- `lib/detect.sh` — Tech stack detection library:
  - `detect_languages()` — scans file extensions, shebangs, and manifest files.
    Returns ranked list: `LANG|CONFIDENCE|MANIFEST`. Example:
    `typescript|high|package.json`, `python|medium|requirements.txt`.
    Confidence levels: `high` (manifest + source files), `medium` (manifest OR
    source files), `low` (only a few source files, possible vendored code).
    Languages detected: JavaScript/TypeScript, Python, Rust, Go, Java/Kotlin,
    C/C++, Ruby, PHP, Dart/Flutter, Swift, C#/.NET, Elixir, Haskell, Lua, Shell.
  - `detect_frameworks()` — reads manifest files for framework signatures.
    Returns: `FRAMEWORK|LANG|EVIDENCE`. Example:
    `next.js|typescript|"next" in package.json dependencies`,
    `flask|python|"flask" in requirements.txt`.
    Frameworks detected (non-exhaustive — extensible via pattern file):
    React, Next.js, Vue, Angular, Svelte, Express, Fastify, Django, Flask,
    FastAPI, Rails, Spring Boot, ASP.NET, Flutter, SwiftUI, Gin, Actix, Axum.
  - `detect_commands()` — infers build, test, and lint commands from manifest
    files and common conventions. Returns:
    `CMD_TYPE|COMMAND|SOURCE|CONFIDENCE`. Example:
    `test|npm test|package.json scripts.test|high`,
    `analyze|eslint .|node_modules/.bin/eslint exists|medium`,
    `build|cargo build|Cargo.toml present|high`.
    Detection order: explicit manifest scripts → well-known tool binaries →
    conventional Makefile targets → fallback suggestions.
  - `detect_entry_points()` — identifies likely application entry points:
    `main.py`, `index.ts`, `src/main.rs`, `cmd/*/main.go`, `lib/main.dart`,
    `Program.cs`, `App.java`, `Makefile`, `docker-compose.yml`. Returns
    file paths that exist.
  - `detect_project_type()` — classifies the project into one of the `--plan`
    template categories: `web-app`, `api-service`, `cli-tool`, `library`,
    `mobile-app`, or `custom`. Uses language, framework, and entry point signals.
  - `format_detection_report()` — renders all detection results as a structured
    markdown block for inclusion in PROJECT_INDEX.md and agent prompts.

**Files to modify:**
- `tekhton.sh` — source `lib/detect.sh`

**Acceptance criteria:**
- `detect_languages` correctly identifies TypeScript from `package.json` +
  `tsconfig.json` + `.ts` files with `high` confidence
- `detect_languages` correctly identifies Python from `pyproject.toml` +
  `.py` files with `high` confidence
- `detect_commands` extracts `npm test` from `package.json` `scripts.test`
- `detect_commands` extracts `pytest` from `pyproject.toml` `[tool.pytest]`
- `detect_commands` extracts `cargo test` from `Cargo.toml` presence
- `detect_frameworks` identifies Next.js from `"next"` in package.json deps
- `detect_project_type` classifies a project with `package.json` + React +
  `src/pages/` as `web-app`
- `detect_entry_points` finds `src/main.rs` in a Rust project
- All detection functions are safe on empty directories, non-git directories,
  and directories with only binary files
- Does not execute any project code, read `.env` files, or follow symlinks
  outside the project
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/detect.sh`

**Watch For:**
- Monorepos may have multiple manifests at different levels. `detect_languages`
  should scan the top 2 directory levels, not just the root.
- Vendored code (e.g., `vendor/`, `third_party/`) should be excluded from
  language detection to avoid skewing results. Use the same exclusion list as
  `_generate_codebase_summary()`.
- `detect_commands` should prefer explicit manifest scripts over inferred
  commands. A `package.json` with `"test": "jest --coverage"` is more reliable
  than guessing `npx jest`.
- Some projects use Makefiles as the universal entry point. If a `Makefile`
  exists with `test:` and `lint:` targets, those should be high-confidence
  detections regardless of language.
- Confidence levels matter for `--init` UX: high-confidence detections get
  auto-set in pipeline.conf, medium-confidence get set with a `# VERIFY:`
  comment, low-confidence get commented out with a suggestion.

**Seeds Forward:**
- Milestone 18 (crawler) uses `detect_languages()` and `detect_entry_points()`
  to decide which files to sample
- Milestone 19 (smart init) uses `detect_commands()` to auto-populate
  pipeline.conf and `detect_project_type()` to select the plan template
- Milestone 21 (synthesis) uses `format_detection_report()` as input context

#### Milestone 18: Project Crawler & Index Generator

Shell-driven breadth-first crawler that traverses a project directory and produces
PROJECT_INDEX.md — a structured, token-budgeted manifest of the project's
architecture, file inventory, dependency structure, and sampled key files. No LLM
calls. The index is the foundation for all downstream synthesis.

**Files to create:**
- `lib/crawler.sh` — Project crawler library:
  - `crawl_project(project_dir, budget_chars)` — Main entry point. Orchestrates
    the crawl phases and writes PROJECT_INDEX.md. Budget defaults to 120,000
    chars (~30k tokens). Returns 0 on success.
  - `_crawl_directory_tree(project_dir, max_depth)` — Breadth-first directory
    traversal. Produces annotated tree with: directory purpose heuristic (src,
    test, docs, config, build output, assets), file count per directory, total
    lines per directory. Respects `.gitignore` via `git ls-files` when in a git
    repo, falls back to hardcoded exclusion list otherwise. Max depth default: 6.
  - `_crawl_file_inventory(project_dir)` — Catalogues every tracked file with:
    path, extension, line count, last-modified date, size category (tiny <50
    lines, small <200, medium <500, large <1000, huge >1000). Groups by directory
    and annotates purpose. Output is a markdown table.
  - `_crawl_dependency_graph(project_dir, languages)` — Extracts dependency
    information from manifest files: `package.json` (dependencies,
    devDependencies), `Cargo.toml` ([dependencies]), `pyproject.toml`
    ([project.dependencies]), `go.mod` (require blocks), `Gemfile`,
    `build.gradle`, `pom.xml` (simplified). Produces a "Key Dependencies"
    section with version constraints and purpose annotations for well-known
    packages (e.g., `express` → "HTTP server framework", `pytest` → "Testing
    framework").
  - `_crawl_sample_files(project_dir, file_list, budget_remaining)` — Reads
    and includes the content of high-value files: README.md, CONTRIBUTING.md,
    ARCHITECTURE.md (or similar), main entry point(s), primary config files,
    one representative test file, one representative source file. Each file
    include is prefixed with path and truncated to fit budget. Priority order:
    README > entry points > config > architecture docs > test samples > source
    samples.
  - `_crawl_test_structure(project_dir)` — Identifies test directory layout,
    test framework (from detection results), approximate test count, and
    coverage configuration if present. Produces a "Test Infrastructure" section.
  - `_crawl_config_inventory(project_dir)` — Lists all configuration files
    (dotfiles, YAML/TOML/JSON configs, CI/CD pipelines, Docker files,
    environment templates) with one-line purpose annotations.
  - `_budget_allocator(total_budget, section_sizes)` — Distributes the token
    budget across index sections. Fixed allocations: tree (10%), inventory (15%),
    dependencies (10%), config (5%), tests (5%). Remaining 55% goes to sampled
    file content. If a section underflows its allocation, surplus redistributes
    to file sampling.

**Files to modify:**
- `tekhton.sh` — source `lib/crawler.sh`

**Acceptance criteria:**
- `crawl_project` produces a valid PROJECT_INDEX.md with all sections populated
  for a project with 100+ files
- Output size stays within the specified budget (±5%) regardless of project size
- Breadth-first traversal captures all top-level directories even in repos with
  deep nesting
- `.gitignore` patterns are respected — node_modules, .git, build artifacts are
  excluded
- File inventory correctly categorizes files by size and groups by directory
- Dependency extraction correctly parses package.json, Cargo.toml, and
  pyproject.toml
- Sampled files are truncated to fit budget, not omitted entirely
- Budget allocator redistributes surplus from thin sections to file sampling
- Crawler completes in under 30 seconds for a 10,000-file repo (no LLM calls)
- Safe on repos with binary files, symlinks, empty directories, and no git
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/crawler.sh`

**Watch For:**
- Monorepos need special handling. If the root contains a `packages/` or
  `apps/` directory with independent manifests, each should be crawled as a
  sub-project with its own dependency block. Cap at 5 sub-projects to prevent
  budget explosion.
- Binary files must be detected and skipped during sampling. Use `file --mime`
  or check for null bytes in the first 512 bytes.
- Very large files (>1000 lines) should only have their first 50 + last 20
  lines sampled, with a `... (N lines omitted)` marker.
- The budget allocator must be conservative. It's better to produce a slightly
  under-budget index than to exceed the context window downstream.
- `git ls-files` may not be available in non-git directories. The fallback
  exclusion list must match the patterns used by `_generate_codebase_summary()`
  for consistency.
- Line counting with `wc -l` on thousands of files can be slow. Consider
  batching with `find ... -exec wc -l {} +` rather than one `wc` per file.

**Seeds Forward:**
- Milestone 19 (smart init) embeds the index in the --init flow
- Milestone 20 (incremental rescan) reuses `_crawl_file_inventory` with a
  git-diff filter
- Milestone 21 (synthesis) feeds PROJECT_INDEX.md to the agent for CLAUDE.md
  generation

#### Milestone 19: Smart Init Orchestrator

Replace the current `--init` with an intelligent, interactive initialization flow
that uses tech stack detection (M17) and the project crawler (M18) to auto-populate
pipeline.conf, generate a rich PROJECT_INDEX.md, detect greenfield vs. brownfield,
and guide the user to the appropriate next step (--plan or --replan).

**Files to modify:**
- `tekhton.sh` — Replace the `--init` block (lines ~167-240) with a call to
  `run_smart_init()`. Keep the early-exit pattern (runs before config load).
- `lib/common.sh` — Add `prompt_choice(question, options_array)` and
  `prompt_confirm(question, default)` helpers for interactive prompts (read
  from /dev/tty for pipeline safety).

**Files to create:**
- `lib/init.sh` — Smart init orchestrator:
  - `run_smart_init(project_dir, tekhton_home)` — Main entry point. Phases:
    1. **Pre-flight**: Check for existing `.claude/pipeline.conf`. If found,
       offer `--reinit` (destructive, requires confirmation) or exit.
    2. **Detection**: Run `detect_languages()`, `detect_frameworks()`,
       `detect_commands()`, `detect_project_type()`. Display results with
       confidence indicators. Allow user to correct detections interactively.
    3. **Crawl**: Run `crawl_project()` with progress indicator. Write
       PROJECT_INDEX.md to project root.
    4. **Config generation**: Build `.claude/pipeline.conf` from detection
       results. High-confidence commands auto-set, medium-confidence marked
       `# VERIFY:`, low-confidence commented out with suggestions.
    5. **Agent role customization**: Copy base agent templates, then append
       tech-stack-specific addenda: language idioms, framework conventions,
       common anti-patterns to flag, preferred patterns. Addenda are loaded
       from `templates/agents/addenda/{language}.md` if they exist.
    6. **Stub artifacts**: Create CLAUDE.md stub (if missing) seeded with
       detection results instead of bare placeholders.
    7. **Next-step routing**: If project has >50 tracked files (brownfield),
       suggest `tekhton --plan-from-index` next. If <50 files (greenfield),
       suggest `tekhton --plan`. Print the exact command.
  - `_generate_smart_config(detection_results)` — Builds pipeline.conf content
    from detection results. Maps detected commands to config keys:
    - `TEST_CMD` ← `detect_commands()` test entry
    - `ANALYZE_CMD` ← `detect_commands()` analyze entry
    - `BUILD_CHECK_CMD` ← `detect_commands()` build entry
    - `REQUIRED_TOOLS` ← detected CLIs (npm, cargo, python, etc.)
    - `CLAUDE_STANDARD_MODEL` ← default (sonnet)
    - `CLAUDE_CODER_MODEL` ← opus for large projects, sonnet for small
    - Agent turns ← scaled by project size (more files → more turns)
  - `_seed_claude_md(project_dir, detection_report)` — Creates an initial
    CLAUDE.md with: detected tech stack, directory structure summary, detected
    entry points, and TODO markers for sections the user should fill in.
    Not a full generation — that's Milestone 21's job.

**Acceptance criteria:**
- `--init` on a Node.js project auto-detects TypeScript, sets `TEST_CMD="npm test"`,
  `ANALYZE_CMD="npx eslint ."`, and `REQUIRED_TOOLS="claude git node npm"`
- `--init` on a Rust project auto-detects Rust, sets `TEST_CMD="cargo test"`,
  `ANALYZE_CMD="cargo clippy"`, and `REQUIRED_TOOLS="claude git cargo"`
- `--init` on a Python project auto-detects Python, sets `TEST_CMD="pytest"`,
  `ANALYZE_CMD="ruff check ."`, and `REQUIRED_TOOLS="claude git python"`
- Medium-confidence detections appear in pipeline.conf with `# VERIFY:` comments
- PROJECT_INDEX.md is generated and contains all crawler sections
- User is offered interactive correction for detected tech stack
- Brownfield projects (>50 files) get routed to `--plan-from-index`
- Greenfield projects (<50 files) get routed to `--plan`
- Existing `--init` behavior preserved when detection finds nothing (empty dirs)
- `--reinit` available with destructive warning for re-initialization
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/init.sh`

**Watch For:**
- Interactive prompts must read from `/dev/tty`, not stdin, to work when
  tekhton is invoked via pipe or script.
- Detection results should be displayed BEFORE the user is asked to confirm,
  so they can spot errors early.
- `--init` must remain fast even for large repos. The crawl is the slowest
  phase — show a progress indicator (file count processed).
- Agent role addenda must be APPENDED to the base template, not replacing it.
  The base template has security directives and output format requirements
  that must be preserved.
- The config generator should include comments explaining each auto-detected
  value and how to override it.

**Seeds Forward:**
- Milestone 20 (incremental rescan) adds `--rescan` for index updates
- Milestone 21 (agent synthesis) uses PROJECT_INDEX.md to generate full
  CLAUDE.md and DESIGN.md

#### Milestone 20: Incremental Rescan & Index Maintenance

Add `--rescan` command that updates PROJECT_INDEX.md incrementally using git diff
since the last scan. This keeps the project index current without repeating the
full crawl cost. Integrates with the existing `--replan` flow so brownfield
projects can keep their index and documents in sync as the codebase evolves.

**Files to create:**
- `lib/rescan.sh` — Incremental rescan library:
  - `rescan_project(project_dir, budget_chars)` — Main entry point. If
    PROJECT_INDEX.md exists and has a `Last-Scan` timestamp, performs
    incremental scan. Otherwise falls back to full crawl.
  - `_get_changed_files_since_scan(project_dir, last_scan_commit)` — Uses
    `git diff --name-status` to get added, modified, deleted, and renamed
    files since the recorded scan commit. Returns structured list.
  - `_update_index_sections(index_file, changed_files, detection_results)` —
    Surgically updates the affected sections of PROJECT_INDEX.md:
    - File inventory: add new files, remove deleted files, update modified
      file line counts
    - Directory tree: regenerate only if new directories were created or
      directories were removed
    - Dependencies: regenerate if any manifest file changed
    - Sampled files: re-sample if any sampled file was modified or deleted
    - Config inventory: regenerate if config files changed
  - `_record_scan_metadata(index_file, commit_hash)` — Writes scan metadata
    to PROJECT_INDEX.md header: scan timestamp, git commit hash, file count,
    total lines, scan duration.
  - `_detect_significant_changes(changed_files)` — Flags changes that likely
    require CLAUDE.md/DESIGN.md updates: new directories, new manifest files,
    new entry points, deleted core files, framework changes. Returns a
    "change significance" score: `trivial` (only content changes),
    `moderate` (new files in existing structure), `major` (structural changes,
    new dependencies, new directories).

**Files to modify:**
- `tekhton.sh` — Add `--rescan` flag parsing. When active, run rescan and exit.
  Add `--rescan --full` variant that forces full re-crawl.
- `lib/replan_brownfield.sh` — In `_generate_codebase_summary()`, if
  PROJECT_INDEX.md exists and is recent (within 5 runs), use it instead of
  the ad-hoc tree+git-log generation. Fall back to the existing approach if
  no index exists.

**Acceptance criteria:**
- `--rescan` on a repo with 10 changed files completes in under 5 seconds
- `--rescan` updates the file inventory to reflect added, deleted, and
  modified files
- `--rescan` regenerates the dependency section when package.json changes
- `--rescan` re-samples modified key files while preserving unchanged samples
- `--rescan --full` performs a complete re-crawl regardless of change volume
- Scan metadata (commit hash, timestamp) is correctly recorded and used for
  subsequent incremental scans
- Change significance correctly identifies structural changes (new dirs, new
  deps) vs trivial changes (content edits)
- `--replan` consumes PROJECT_INDEX.md when available, improving replan quality
- Missing git history (non-git repo) falls back to full crawl gracefully
- All existing tests pass
- `bash -n` and `shellcheck` pass on all new/modified files

**Watch For:**
- `git diff --name-status` may not capture all changes if the user has
  uncommitted work. Consider using `git status --porcelain` as well to
  capture working tree changes.
- Renamed files (`R100 old/path new/path`) need special handling — the old
  path should be removed from inventory and the new path added.
- The scan commit hash must be validated on rescan. If the recorded commit
  no longer exists (rebased away), fall back to full crawl.
- Incremental dependency parsing must handle the case where a manifest file
  was deleted (remove that language's dependency section entirely).

**Seeds Forward:**
- Milestone 21 uses the up-to-date index for synthesis
- Future V3 `--watch` mode could trigger automatic rescan on file changes

#### Milestone 21: Agent-Assisted Project Synthesis

The capstone milestone. Uses PROJECT_INDEX.md from the crawler (M18) plus tech
stack detection (M17) as input to an agent-assisted synthesis pipeline that
generates production-quality CLAUDE.md and DESIGN.md for brownfield projects. This
is the brownfield equivalent of `--plan` — but instead of interviewing the user
about a project that doesn't exist yet, it reads the project that already exists
and synthesizes the design documents from evidence.

**Files to create:**
- `stages/init_synthesize.sh` — Synthesis stage orchestrator:
  - `_run_project_synthesis(project_dir)` — Main entry point. Phases:
    1. **Context assembly**: Load PROJECT_INDEX.md, detection report, and
       sampled key files. Apply context budget (reuse `check_context_budget()`
       from context.sh). If over budget, compress index sections using
       `compress_context()` from context_compiler.sh.
    2. **DESIGN.md generation**: Call `_call_planning_batch()` with the
       synthesis prompt + project index. Agent produces a full DESIGN.md
       following the same template structure as `--plan` output but populated
       from codebase evidence rather than interview answers.
    3. **Completeness check**: Run `check_design_completeness()` on the
       generated DESIGN.md. If sections are incomplete, run a second synthesis
       pass with the incomplete sections flagged (same pattern as
       plan_generate.sh follow-up).
    4. **CLAUDE.md generation**: Call `_call_planning_batch()` with DESIGN.md
       + project index. Agent produces a full CLAUDE.md with: architecture
       rules inferred from codebase patterns, directory structure from index,
       milestones scoped around existing technical debt and improvement areas.
    5. **Human review**: Display generated artifacts, offer
       [a]ccept / [e]dit / [r]egenerate menu.
  - `_assemble_synthesis_context(project_dir)` — Builds the agent prompt
    context from: PROJECT_INDEX.md, detection report, existing README.md,
    existing ARCHITECTURE.md (if any), git log summary.

**Files to create:**
- `prompts/init_synthesize_design.prompt.md` — Prompt for DESIGN.md synthesis:
  - Role: "You are a software architect analyzing an existing codebase."
  - Input: project index, detection report, sampled files
  - Output: Full DESIGN.md following the project-type template structure
  - Key instruction: "You are documenting what EXISTS, not what should be
    built. Describe the current architecture, patterns, and conventions you
    observe in the codebase evidence. Flag inconsistencies and technical debt
    as open questions, not prescriptions."
- `prompts/init_synthesize_claude.prompt.md` — Prompt for CLAUDE.md synthesis:
  - Role: "You are a project configuration agent."
  - Input: DESIGN.md + project index + detection report
  - Output: Full CLAUDE.md with architecture rules, conventions, milestones
  - Key instruction: "Milestones should address observed technical debt,
    missing test coverage, incomplete documentation, and architectural
    improvements — not new features. The user will add feature milestones."

**Files to modify:**
- `tekhton.sh` — Add `--plan-from-index` flag that triggers the synthesis
  pipeline. Requires PROJECT_INDEX.md to exist (run `--init` first). Also add
  `--init --full` variant that runs init + crawl + synthesis in one command.
- `lib/plan.sh` — Extract `_call_planning_batch()` guards (if not already
  externally callable) so synthesis can reuse them.

**Acceptance criteria:**
- `--plan-from-index` on a real 100+ file project produces a DESIGN.md with
  all required sections populated from actual codebase evidence
- Generated DESIGN.md references actual file paths, actual dependencies, and
  actual patterns observed in the code
- Generated CLAUDE.md contains milestones scoped around technical debt and
  improvements, not fictitious new features
- Context budget is respected — synthesis works on projects where
  PROJECT_INDEX.md + sampled files exceed the model's context window
- Completeness check catches thin sections and triggers re-synthesis
- Human review menu works correctly (accept, edit in $EDITOR, regenerate)
- `--init --full` chains: detect → crawl → synthesize in one invocation
- Generated documents match the quality bar set by the planning initiative
  (multi-section, cross-referenced, concrete file paths and acceptance criteria)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all new/modified files

**Watch For:**
- The synthesis agent must distinguish between "the codebase does this" and
  "the codebase should do this." DESIGN.md should describe reality; CLAUDE.md
  milestones should prescribe improvements. Mixing these produces documents
  that are neither accurate descriptions nor useful prescriptions.
- Large projects will exceed context even with the index. The compression
  strategy from context_compiler.sh must be applied. Sampled file content is
  the first thing to compress (truncate to headings only), followed by file
  inventory (collapse to directory-level summaries).
- The agent may hallucinate patterns that don't exist in the code. The prompt
  must emphasize: "Only describe patterns you can point to in the project
  index. If you're uncertain, flag it as an open question."
- CLAUDE.md milestone generation for brownfield projects is fundamentally
  different from greenfield. Brownfield milestones are: "add tests for
  untested module X", "refactor tangled dependency Y", "document undocumented
  subsystem Z." Greenfield milestones are: "build feature A from scratch."
  The prompt must make this distinction explicit.
- Opus is the right model for synthesis. It's a one-time cost per project
  and the quality difference matters enormously for project documents that
  will guide all future work.

**Seeds Forward:**
- V3 `--build-project` consumes the milestones generated here
- V3 incremental synthesis updates documents as the project evolves
- The synthesis pipeline becomes the standard onboarding path for all
  new Tekhton projects, eventually replacing the interview-based `--plan`
  for any project that already has code
