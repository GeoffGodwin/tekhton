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

#### [DONE] Milestone 1: Model Default + Template Depth Overhaul
#### [DONE] Milestone 2: Multi-Phase Interview with Deep Probing
#### [DONE] Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md
#### [DONE] Milestone 4: Follow-Up Interview Depth + Completeness Checker Upgrade
#### [DONE] Milestone 5: Tests + Documentation Update
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

#### [DONE] Milestone 0: Security Hardening
#### [DONE] Milestone 0.5: Agent Output Monitoring And Null-Run Detection
#### [DONE] Milestone 1: Token And Context Accounting
#### [DONE] Milestone 2: Context Compiler
#### [DONE] Milestone 3: Milestone State Machine And Auto-Advance
#### [DONE] Milestone 4: Mid-Run Clarification And Replanning
#### [DONE] Milestone 5: Autonomous Debt Sweeps
#### [DONE] Milestone 6: Brownfield Replan
#### [DONE] Milestone 7: Specialist Reviewers
#### [DONE] Milestone 8: Workflow Learning
#### [DONE] Milestone 9: Post-Coder Turn Recalibration
#### [DONE] Milestone 10: Milestone Commit Signatures, Completion Signaling, And Archival
#### [DONE] Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split
#### [DONE] Milestone 12.1: Error Taxonomy, Classification Engine & Redaction
#### [DONE] Milestone 12.2: Agent Exit Analysis, Real-Time Detection & Structured Reporting
#### [DONE] Milestone 12.3: Metrics Integration & Structured Log Summaries

#### [DONE] Milestone 13.1: Retry Infrastructure — Config, Reporting, and Monitoring Reset
#### [DONE] Milestone 13.2.1.1: Retry Envelope Skeleton and Error Classification Bridge
#### [DONE] Milestone 13.2.1.2: Transient Retry Loop with Exponential Backoff
#### [DONE] Milestone 13.2.2: Stage Cleanup and Metrics Integration

#### [DONE] Milestone 14: Turn Exhaustion Continuation Loop
Based on the codebase analysis, here's the split:

Now I have enough context. Here's the split:

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

This milestone has two cleanly independent pieces that can be split into sub-milestones. Here's the split:

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
#### Milestone 15.2: Milestone Marking, Archival Cleanup, and [DONE] Migration

Fix the milestone [DONE] chicken-and-egg problem and the [DONE] line accumulation.
Add `mark_milestone_done()` to programmatically mark milestones, change archival
to fully remove [DONE] lines from CLAUDE.md, and perform a one-time migration of
existing [DONE] one-liners.

**Files to modify:**
- `lib/milestone_ops.sh` — Add `mark_milestone_done(milestone_num)` that:
  1. Reads CLAUDE.md
  2. Finds the line matching `^#### Milestone ${milestone_num}:` (without [DONE])
  3. Prepends `[DONE] ` to make it `#### [DONE] Milestone N: Title`
  4. Is idempotent — if the line already contains `[DONE]`, returns 0 without
     modification
  5. Returns 1 if the milestone heading is not found
- `lib/milestone_archival.sh` — Change `archive_completed_milestone()` to:
  1. After archiving the milestone block to MILESTONE_ARCHIVE.md, REMOVE the
     `#### [DONE] Milestone N: Title` one-liner from CLAUDE.md entirely
     (currently it leaves it behind)
  2. After removal, if no `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->`
     comment exists in the milestone plan section, add one at the top of the
     milestone list
  3. Clean up any blank lines left by the removal
- `CLAUDE.md` — One-time migration: remove all existing `#### [DONE] Milestone N: Title`
  one-liner lines (there are ~24 of them across two initiative sections). These
  milestones are already in MILESTONE_ARCHIVE.md. Add the
  `<!-- See MILESTONE_ARCHIVE.md for completed milestones -->` comment.

**Acceptance criteria:**
- `mark_milestone_done 15` changes `#### Milestone 15:` to `#### [DONE] Milestone 15:`
  in CLAUDE.md
- `mark_milestone_done 15` on an already-marked milestone is a no-op (returns 0)
- `mark_milestone_done 999` returns 1 (milestone not found)
- `archive_completed_milestone()` removes the [DONE] one-liner from CLAUDE.md
  after archiving — zero `[DONE]` lines remain for archived milestones
- The `<!-- See MILESTONE_ARCHIVE.md -->` comment is added once and not duplicated
- CLAUDE.md has zero `#### [DONE]` one-liner lines after the one-time migration
- The MILESTONE_ARCHIVE.md still contains all previously archived milestone content
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- `mark_milestone_done()` must handle milestone numbers with dots (e.g., 13.2.1.1)
  for sub-milestones. The regex must match the exact milestone number format.
- The one-time migration must not remove milestone blocks that are still active —
  only the `#### [DONE] Milestone N: Title` one-liner summaries (single lines
  with no content block following them).
- The `<!-- See MILESTONE_ARCHIVE.md -->` comment should go in the `### Milestone Plan`
  section, not at the top of the file.
- After removing [DONE] lines, there may be consecutive blank lines. Collapse them
  to single blank lines.

**Seeds Forward:**
- Milestone 15.3 integrates `mark_milestone_done()` and `archive_completed_milestone()`
  into the `finalize_run()` call sequence.

#### Milestone 15.3: finalize_run() Consolidation

Consolidate all scattered post-pipeline bookkeeping in `tekhton.sh` into a single
`finalize_run()` function in `lib/hooks.sh`. This is the capstone sub-milestone
that wires together all fixes from 15.1 and 15.2 into a deterministic, ordered
finalization sequence.

**Files to modify:**
- `lib/hooks.sh` — Add `finalize_run()` that calls, in this exact order:
  1. `run_final_checks()` (existing — analyze + test)
  2. `process_drift_artifacts()` (existing — from drift_artifacts.sh)
  3. `record_run_metrics()` (existing — from metrics.sh)
  4. `clear_resolved_nonblocking_notes()` (from 15.1 — only if pipeline succeeded)
  5. `resolve_human_notes_with_exit_code $pipeline_exit_code` — if
     CODER_SUMMARY.md is missing but pipeline succeeded (exit 0), mark
     all [~] → [x] instead of resetting to [ ]. Fixes the bug where
     features are implemented and committed but HUMAN_NOTES shows undone.
  6. `archive_reports "$LOG_DIR" "$TIMESTAMP"` (existing)
  7. `mark_milestone_done "$CURRENT_MILESTONE"` (from 15.2 — only if milestone
     mode AND acceptance passed)
  8. Auto-commit: if `AUTO_COMMIT=true` (now defaulting to true in milestone mode
     per 15.1), run `_do_git_commit()` without interactive prompt. If
     `AUTO_COMMIT=false`, call the existing interactive prompt (reading from
     `/dev/tty`).
  9. `archive_completed_milestone()` (from 15.2 — only after commit, only if
     milestone was marked [DONE])
  10. `clear_milestone_state()` (existing but unwired — only after successful
      milestone archival, prevents stale MILESTONE_STATE.md from leaking into
      subsequent non-milestone runs)
  The function accepts a `pipeline_exit_code` parameter. Steps 4-5, 7, 8, 9, 10
  only run if `pipeline_exit_code=0`.
- `tekhton.sh` — Replace the scattered post-pipeline section (lines ~940-1149)
  with a single call to `finalize_run $pipeline_exit_code`. Remove all inline
  commit prompt logic, inline `archive_completed_milestone()` calls, and
  inline metrics/drift/archive calls. The `_do_git_commit()` helper moves to
  `lib/hooks.sh` alongside `finalize_run()`.

**Acceptance criteria:**
- `finalize_run()` is the ONLY place post-pipeline bookkeeping happens — no
  straggler calls in `tekhton.sh`
- Post-pipeline bookkeeping runs in deterministic order as specified above
- `finalize_run 0` (success) runs all 10 steps including cleanup, notes
  resolution, commit, and archival
- `finalize_run 1` (failure) runs steps 1-3 and 6 only (metrics recorded,
  reports archived, but no cleanup/commit/archival)
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

#### Milestone 15.4: Human Notes Workflow (`--human` Flag)

Add `--human` as a first-class workflow that processes human notes one at a time
with explicit control. Notes are never auto-injected based on task text. The
`--human` flag makes notes THE task; `--with-notes` injects notes alongside
another task. Combined with `--complete` (M16), `--human --complete` chains
through all unchecked notes until done.

**Files to modify:**
- `lib/notes.sh` — Add:
  - `pick_next_note(tag_filter)` — Returns the next unchecked note by priority
    order: BUG > FEAT > POLISH. If `tag_filter` is set (e.g., "BUG"), only
    considers notes with that tag. Returns the full note line (e.g.,
    `- [ ] [BUG] Fix the thing`). Returns empty string if no unchecked notes
    remain.
  - `claim_single_note(note_line)` — Marks exactly ONE note from `[ ]` to `[~]`.
    The `note_line` is matched literally in HUMAN_NOTES.md. Only the first
    match is marked (handles duplicate text safely). Archives pre-run snapshot.
  - `resolve_single_note(note_line, exit_code)` — Resolves a single `[~]` note:
    if `exit_code=0`, mark `[~]` → `[x]`. If non-zero, mark `[~]` → `[ ]`.
    Returns 0 if the note was found and resolved, 1 if not found.
  - `extract_note_text(note_line)` — Strips the checkbox and tag prefix,
    returning the bare task description for use as TASK.
  - `count_unchecked_notes(tag_filter)` — Returns count of remaining `[ ]`
    notes, optionally filtered by tag.
- `tekhton.sh` — Add `--human` mode orchestration:
  - Parse `--human [TAG]` flag. TAG is optional, one of: BUG, FEAT, POLISH.
  - When `--human` is set without `--complete`:
    1. Call `pick_next_note "$HUMAN_NOTES_TAG"`
    2. If no note found, log "No unchecked notes" and exit 0
    3. Set `TASK` to the extracted note text
    4. Set `HUMAN_MODE=true` (so `should_claim_notes` returns true)
    5. Call `claim_single_note` for that one note
    6. Run `_run_pipeline_stages()` normally
    7. `finalize_run()` handles resolution via exit code
  - When `--human --complete` is set:
    1. Outer loop: while `count_unchecked_notes` > 0:
       a. `pick_next_note` → set TASK → `claim_single_note`
       b. Run `_run_pipeline_stages()`
       c. `finalize_run()` resolves the note
       d. If note is still `[ ]` after resolution → break (failed)
       e. If note is `[x]` → continue to next note
    2. Respect `MAX_PIPELINE_ATTEMPTS` and `AUTONOMOUS_TIMEOUT` from M16
       config as safety bounds
    3. Each note iteration auto-commits (via `finalize_run()` with
       `AUTO_COMMIT=true`)
- `lib/hooks.sh` — In `finalize_run()`, detect `HUMAN_MODE=true` and call
  `resolve_single_note()` instead of `resolve_human_notes_with_exit_code()`.
  The single-note path is simpler and more reliable: one note, binary outcome.

**Acceptance criteria:**
- `--human` with no unchecked notes exits 0 with "No unchecked notes" message
- `--human` picks the highest-priority unchecked note (BUG > FEAT > POLISH)
- `--human BUG` only picks `[BUG]` notes, ignoring FEAT and POLISH
- `--human FEAT` only picks `[FEAT]` notes
- `pick_next_note` returns empty when all notes of the filtered type are `[x]`
- `claim_single_note` marks exactly ONE note `[~]`, leaving others as `[ ]`
- TASK is set to the note's text content (without checkbox/tag prefix)
- Pipeline runs the coder with the note text as the task
- On success (exit 0), the note is marked `[x]`
- On failure (exit non-zero), the note is reset to `[ ]`
- `--human --complete` chains through multiple notes, one per iteration
- `--human --complete` stops on first failure (note still `[ ]`)
- `--human --complete` respects `AUTONOMOUS_TIMEOUT` and `MAX_PIPELINE_ATTEMPTS`
- Each note in `--human --complete` gets its own commit
- Notes are never auto-injected based on task text matching (flag-only gating
  from M15.1)
- `--human` without a task argument does NOT require a task string
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- `pick_next_note` must handle the section structure of HUMAN_NOTES.md. Notes
  live under `## Features`, `## Bugs`, `## Polish` sections. Priority ordering
  (BUG > FEAT > POLISH) means scanning Bugs section first, then Features, then
  Polish — not alphabetical by tag name.
- `claim_single_note` must escape regex special characters in the note text
  when using sed to mark it. Notes may contain brackets, parentheses, etc.
- The `--human --complete` loop must NOT use the M16 outer loop directly —
  M16 retries the SAME task on failure. `--human --complete` advances to the
  NEXT note on success and stops on failure. It's a different iteration pattern.
  However, it should reuse M16's safety bounds (timeout, attempt cap).
- `--human` combined with `--milestone` is invalid — notes are not milestones.
  Reject this combination with a clear error message.
- `--human` combined with a task string is invalid — the note IS the task.
  Reject: `tekhton --human "some task"` should error.
- `--with-notes` combined with `--human` is redundant but harmless — `--human`
  already implies notes are active. Don't error, just log a note.
- The note text extracted for TASK should include the tag (e.g., "[BUG] Fix the
  thing") so the coder knows the category. Strip only the `- [ ] ` prefix.
- Auto-commit between notes in `--human --complete` ensures each fix is
  isolated in its own commit. This is important for rollback granularity.

**Seeds Forward:**
- M16's `--complete` flag provides the safety bounds (timeout, attempt cap)
  that `--human --complete` reuses.
- V3 could add `--human --watch` that monitors HUMAN_NOTES.md for new items
  and processes them automatically.
- The single-note claim/resolve pattern is more reliable than bulk operations
  and could eventually replace the bulk `claim_human_notes()` /
  `resolve_human_notes()` entirely.

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
  progress detector and metrics.
- `lib/common.sh` — Add `report_orchestration_status(attempt, max, elapsed,
  agent_calls)` that prints a banner at the start of each loop iteration showing
  the autonomous loop state.
- `lib/metrics.sh` — Add `pipeline_attempts` and `total_agent_calls` fields to
  JSONL record.
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
