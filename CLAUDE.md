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
│   ├── config_defaults.sh  # Default values for all config keys
│   ├── agent.sh            # Agent wrapper, metrics, run_agent()
│   ├── agent_helpers.sh    # Agent invocation helpers
│   ├── agent_monitor.sh    # Agent monitoring, activity detection, process management
│   ├── agent_monitor_helpers.sh  # Monitor support functions
│   ├── agent_monitor_platform.sh # Platform-specific monitor code
│   ├── agent_retry.sh      # Transient error retry logic
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── finalize.sh         # Hook-based finalization sequence
│   ├── finalize_display.sh # Completion banner + action items
│   ├── finalize_summary.sh # RUN_SUMMARY.json emitter
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── turns.sh            # Turn-exhaustion continuation logic
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── drift_artifacts.sh  # Drift artifact processing
│   ├── drift_cleanup.sh    # Non-blocking log cleanup
│   ├── detect.sh           # Tech stack detection engine
│   ├── detect_commands.sh  # Build/test/lint command detection
│   ├── detect_report.sh    # Detection report formatter
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   ├── plan_state.sh       # Planning state persistence + resume
│   ├── replan.sh           # Replan orchestration
│   ├── replan_brownfield.sh # Brownfield replan with codebase summary
│   ├── replan_midrun.sh    # Mid-run replan trigger
│   ├── context.sh          # [2.0] Token accounting + context compiler
│   ├── context_budget.sh   # Context budget checking
│   ├── context_compiler.sh # Task-scoped context assembly
│   ├── milestones.sh       # [2.0] Milestone state machine + acceptance checking
│   ├── milestone_ops.sh    # Milestone marking + disposition
│   ├── milestone_acceptance.sh # Milestone acceptance criteria checking
│   ├── milestone_archival.sh   # Milestone archival to MILESTONE_ARCHIVE.md
│   ├── milestone_metadata.sh   # Milestone metadata HTML comments
│   ├── milestone_split.sh  # Pre-flight milestone splitting
│   ├── orchestrate.sh      # [2.0] Outer orchestration loop (--complete)
│   ├── orchestrate_helpers.sh  # Orchestration support functions
│   ├── orchestrate_recovery.sh # Failure classification + recovery
│   ├── clarify.sh          # [2.0] Clarification protocol + replan trigger
│   ├── specialists.sh      # [2.0] Specialist review framework
│   ├── metrics.sh          # [2.0] Run metrics collection + adaptive calibration
│   ├── metrics_calibration.sh  # Adaptive turn calibration
│   ├── errors.sh           # [2.0] Error taxonomy, classification + reporting
│   └── errors_helpers.sh   # Error classification helpers
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Stage 0: Architect audit (conditional)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   ├── tester.sh           # Stage 3: Test writing + validation
│   ├── cleanup.sh          # [2.0] Post-success debt sweep stage
│   ├── plan_interview.sh   # Planning: interactive interview agent
│   ├── plan_followup_interview.sh # Planning: follow-up interview agent
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
│   ├── milestone_split.prompt.md         # Milestone splitting prompt
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

## Versioning

`TEKHTON_VERSION` in `tekhton.sh` uses **MAJOR.MINOR.PATCH**:
- **MAJOR** = initiative version (2 for V2, 3 for V3, etc.)
- **MINOR** = last completed milestone number within this initiative (resets to 0 each major)
- **PATCH** = hotfixes between milestones

Milestone numbering restarts with each major version. When a milestone is completed,
update the `TEKHTON_VERSION` line in `tekhton.sh` to bump MINOR to the milestone
number. Example: completing V3 Milestone 4 → `3.4.0`.

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

