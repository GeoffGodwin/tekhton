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

#### [DONE] Milestone 19: Smart Init Orchestrator
<!-- milestone-meta
id: "19"
estimated_complexity: "large"
status: "in_progress"
-->


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
