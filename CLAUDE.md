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
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   └── plan_state.sh       # Planning state persistence + resume
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Stage 0: Architect audit (conditional)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   ├── tester.sh           # Stage 3: Test writing + validation
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
│   └── plan_generate.prompt.md           # CLAUDE.md generation prompt
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
| `PLAN_DESIGN_CONTENT` | Contents of DESIGN.md during generation (planning) |
| `PLAN_INCOMPLETE_SECTIONS` | List of incomplete sections for follow-up (planning) |
| `PLAN_INTERVIEW_MODEL` | Model for interview agent (default: sonnet) |
| `PLAN_INTERVIEW_MAX_TURNS` | Turn limit for interview (default: 50) |
| `PLAN_GENERATION_MODEL` | Model for generation agent (default: sonnet) |
| `PLAN_GENERATION_MAX_TURNS` | Turn limit for generation (default: 30) |

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

## Current Initiative: Planning Phase (`--plan`)

The execution pipeline is feature-complete. We are now implementing the planning
phase, which takes a developer from "I want to build X" to a production-ready
CLAUDE.md and DESIGN.md. See `DESIGN.md` for the full specification.

### Key Constraints for This Initiative

- **Zero execution pipeline changes.** All new code goes in `lib/plan.sh`,
  `stages/plan_interview.sh`, `stages/plan_generate.sh`, new prompt templates
  under `prompts/`, and new templates under `templates/plans/`. Do NOT modify
  existing stage files, lib files, or prompt templates.
- **The `--plan` flag** is handled as an early-exit command in `tekhton.sh`
  (same pattern as `--init`), before config is loaded. It sources only the
  libraries it needs.
- **Interactive interview** uses Claude in conversational mode (not `-p` batch).
  This is an intentional departure from the execution pipeline's batch-mode agents.
- **Structural completeness** is checked programmatically (grep/awk) — not by
  asking the LLM if it thinks the doc is done.
- All new `.sh` files must follow `set -euo pipefail` and pass shellcheck.
- Templates in `templates/plans/` are static markdown — no shell logic.

### Milestone Plan

#### Milestone 1: Foundation — CLI Flag, Library Skeleton, Project Type Selection
Create the `--plan` entry point in `tekhton.sh`, the `lib/plan.sh` orchestration
library, and the project type selection menu. At the end of this milestone, running
`tekhton --plan` displays.a project type menu, the user picks one, and the selected
template path is resolved. No interview yet — just the skeleton and the first
interactive step.

Files to create or modify:
- `tekhton.sh` — add `--plan` early-exit block (same pattern as `--init`)
- `lib/plan.sh` — planning phase orchestration: `run_plan()`, project type menu,
  template resolution
- `templates/plans/` — all 7 design doc templates (web-app.md, web-game.md,
  cli-tool.md, api-service.md, mobile-app.md, library.md, custom.md)

Acceptance criteria:
- `tekhton --plan` shows project type menu with 7 options
- User selects a type and the correct template path is resolved
- Selecting an invalid option shows an error and re-prompts
- Templates exist with proper section headings and guidance comments
- All new shell code passes `bash -n` syntax check

#### Milestone 2: Interactive Interview Agent
Implement the interview stage that walks the user through the selected template
section-by-section. Claude asks questions, the user answers, Claude fills in
DESIGN.md. The interview must run in conversational mode (not batch `-p` mode).

Files to create or modify:
- `stages/plan_interview.sh` — `run_plan_interview()` function
- `prompts/plan_interview.prompt.md` — system prompt for the interview agent
- `lib/plan.sh` — wire interview into the `run_plan()` flow after type selection

Acceptance criteria:
- Interview agent receives the template content as context
- Agent asks one question at a time, covering each template section
- Agent writes DESIGN.md progressively as sections are filled
- Conversation is logged to `.claude/logs/`
- Interview can be interrupted (Ctrl+C) without losing progress — partial
  DESIGN.md is preserved on disk

#### Milestone 3: Completeness Check + Follow-Up
Implement the structural completeness checker that validates DESIGN.md after the
interview, and a follow-up loop for incomplete sections.

Files to create or modify:
- `lib/plan.sh` — `check_design_completeness()` function: grep/awk-based
  section validation
- `stages/plan_interview.sh` — follow-up loop for incomplete sections
- Templates may need `<!-- REQUIRED -->` markers added to distinguish
  required vs optional sections

Acceptance criteria:
- Completeness check identifies sections that are empty, still contain
  guidance comments, or have placeholder-only content
- Incomplete sections are reported to the user with clear descriptions
- A follow-up interview pass targets only the incomplete sections
- When all required sections pass, the phase advances to generation
- The check is deterministic — same DESIGN.md always produces same result

#### Milestone 4: CLAUDE.md Generation Agent
Implement the second agent pass that reads the completed DESIGN.md and generates
a full CLAUDE.md with project rules, milestone plan, architecture guidelines,
and testing strategy.

Files to create or modify:
- `stages/plan_generate.sh` — `run_plan_generate()` function
- `prompts/plan_generate.prompt.md` — generation agent prompt template
- `lib/plan.sh` — wire generation into `run_plan()` flow after completeness check

Acceptance criteria:
- Generation agent reads DESIGN.md as input context
- Output CLAUDE.md contains: project identity, non-negotiable rules,
  ordered milestone plan, architecture guidelines, testing strategy
- Milestones are numbered and have clear acceptance criteria
- Each milestone description works as a standalone task argument for
  `tekhton --milestone "Implement Milestone N: <description>"`
- Generation is logged to `.claude/logs/`

#### Milestone 5: Milestone Review UI + File Output
Implement the milestone review/approval step and the final file writing.
The user sees the plan, can approve, edit, or re-generate before files are
committed to disk.

Files to create or modify:
- `lib/plan.sh` — milestone display, approval prompt, editor integration,
  file writing logic
- `stages/plan_generate.sh` — re-generation support

Acceptance criteria:
- Milestone summary displays in a clear numbered format after generation
- `[y]` writes DESIGN.md and CLAUDE.md to the project directory
- `[e]` opens CLAUDE.md in `$EDITOR` for manual edits before writing
- `[r]` re-runs the generation agent with the same DESIGN.md
- `[n]` aborts without writing files
- After writing, prints next-steps instructions (`tekhton --init`)

#### Milestone 6: Planning State Persistence + Config Integration
Add resume support for interrupted planning sessions and integrate planning
config keys into `pipeline.conf`.

Files to create or modify:
- `lib/plan.sh` — state save/restore for planning phase
- `lib/config.sh` — add planning config defaults (models, turn limits)
- `templates/pipeline.conf.example` — add planning config section
- `tekhton.sh` — detect and resume interrupted `--plan` sessions

Acceptance criteria:
- Interrupting during interview preserves partial DESIGN.md and the
  current section index
- Re-running `tekhton --plan` detects the partial state and offers to resume
- Planning config keys (`CLAUDE_PLAN_MODEL`, `PLAN_INTERVIEW_MAX_TURNS`, etc.)
  are documented in `pipeline.conf.example` with sensible defaults
- `--init` auto-sets `DESIGN_FILE="DESIGN.md"` in pipeline.conf when
  DESIGN.md exists in the project root

#### Milestone 7: Tests + Documentation
Write self-tests for the planning phase and update README, CLAUDE.md, and
ARCHITECTURE.md to reflect the new feature.

Files to create or modify:
- `tests/test_plan_*.sh` — test files covering template loading, completeness
  checking, type selection, and config defaults
- `README.md` — add Planning Phase section with usage examples
- `CLAUDE.md` — update repository layout and template variables
- `ARCHITECTURE.md` — add planning phase to system map

Acceptance criteria:
- All new tests pass via `bash tests/run_tests.sh`
- README documents `tekhton --plan` with a quick-start example
- CLAUDE.md layout tree includes all new files
- ARCHITECTURE.md describes lib/plan.sh, stages/plan_*.sh, and the
  planning data flow
- All `.sh` files pass `bash -n` syntax check
