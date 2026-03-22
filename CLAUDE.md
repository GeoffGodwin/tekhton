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
│   ├── errors_helpers.sh   # Error classification helpers
│   ├── milestone_dag.sh    # [3.0] Milestone DAG infrastructure + manifest parser
│   ├── milestone_dag_migrate.sh # [3.0] Inline→file milestone migration
│   ├── milestone_window.sh # [3.0] Character-budgeted milestone sliding window
│   ├── indexer.sh          # [3.0] Repo map orchestration + Python tool invocation
│   └── mcp.sh              # [3.0] MCP server lifecycle management (Serena)
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
├── tools/                  # [3.0] Python tooling (optional dependency)
│   ├── repo_map.py         # Tree-sitter repo map generator + PageRank
│   ├── tag_cache.py        # Disk-based tag cache with mtime tracking
│   ├── tree_sitter_languages.py  # Language detection + grammar loading
│   ├── requirements.txt    # Pinned Python dependencies
│   ├── setup_indexer.sh    # Indexer virtualenv setup script
│   ├── setup_serena.sh     # Serena MCP server setup script
│   ├── serena_config_template.json  # MCP config template
│   └── tests/              # Python unit tests
│       ├── conftest.py
│       ├── test_repo_map.py
│       ├── test_tag_cache.py
│       └── test_history.py
├── tests/                  # Self-tests
│   └── fixtures/indexer_project/  # [3.0] Multi-language fixture project
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
| `MILESTONE_DAG_ENABLED` | Use manifest+files vs inline CLAUDE.md (default: true) |
| `MILESTONE_DIR` | Directory for milestone files (default: .claude/milestones) |
| `MILESTONE_MANIFEST` | Manifest filename within MILESTONE_DIR (default: MANIFEST.cfg) |
| `MILESTONE_WINDOW_PCT` | % of context budget allocated to milestones (default: 30) |
| `MILESTONE_WINDOW_MAX_CHARS` | Hard cap on milestone window chars (default: 20000) |
| `MILESTONE_AUTO_MIGRATE` | Auto-extract inline milestones on first run (default: true) |
| `REPO_MAP_ENABLED` | Enable tree-sitter repo map generation (default: false) |
| `REPO_MAP_TOKEN_BUDGET` | Max tokens for repo map output (default: 2048) |
| `REPO_MAP_CACHE_DIR` | Index cache directory (default: .claude/index) |
| `REPO_MAP_LANGUAGES` | Languages to index, or "auto" (default: auto) |
| `REPO_MAP_CONTENT` | Generated repo map markdown (injected by lib/indexer.sh) |
| `REPO_MAP_SLICE` | Task-relevant subset of repo map (per-stage) |
| `REPO_MAP_HISTORY_ENABLED` | Track task→file associations (default: true) |
| `REPO_MAP_HISTORY_MAX_RECORDS` | Max history entries before pruning (default: 200) |
| `SERENA_ENABLED` | Enable Serena LSP via MCP (default: false) |
| `SERENA_PATH` | Serena installation directory (default: .claude/serena) |
| `SERENA_CONFIG_PATH` | Path to generated MCP config (auto-generated) |
| `SERENA_LANGUAGE_SERVERS` | LSP servers to use, or "auto" (default: auto) |
| `SERENA_STARTUP_TIMEOUT` | Seconds to wait for Serena startup (default: 30) |
| `SERENA_MAX_RETRIES` | Retry attempts for Serena health check (default: 2) |

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

## Initiative: Tekhton 3.0 — Milestone DAG, Intelligent Indexing & Cost Reduction

Tekhton 3.0 makes the pipeline **context-aware** at two levels. First, a
**Milestone DAG** with a sliding context window replaces inline milestone storage
in CLAUDE.md — milestones live as individual files with dependency tracking, and
only the relevant frontier is injected into agent prompts. This eliminates context
waste from future milestones and enables future parallel execution. Second,
**intelligent indexing** via tree-sitter repo maps (optionally enriched with Serena
LSP via MCP) replaces blind architecture injection — agents receive ranked,
token-budgeted file signatures relevant to their task.

Full design document: `DESIGN_v3.md`.

### Key Constraints

- **Backward compatible.** Users who don't enable new features see identical 2.0
  behavior. DAG features auto-detect (manifest exists → use it). Indexer features
  are opt-in via `REPO_MAP_ENABLED`. All new features default-off until proven stable.
- **No new shell dependencies for DAG.** The milestone DAG uses only bash 4+ builtins
  (associative arrays, parameter expansion). No jq, no Python for DAG operations.
- **Python is optional.** The repo map generator requires Python 3.8+ and
  tree-sitter, but Tekhton must remain functional without them. Shell detects
  availability and falls back gracefully to 2.0 context injection.
- **Shell controls flow.** Python tools are invoked as subprocesses and produce
  structured output (JSON/text). No Python process holds state across stages.
- **Bash 4+ for all .sh files.** The indexer orchestration is bash; the analysis
  tool is Python. Both must be independently testable.
- **Character budget is king.** The milestone window and repo map output both fit
  within configurable character budgets. Ranking and priority determine what gets
  included, not truncation.
- **Parallel-ready data model.** DAG edges, parallel groups, and dependency
  tracking exist from day one. The data structures support future parallel
  execution without modification.
- **All existing tests must pass** (`bash tests/run_tests.sh`) at every milestone.
- **All new `.sh` files must pass `bash -n` and `shellcheck`.**

### Architecture Overview

```
Pipeline Stage Flow (v3):

  tekhton.sh startup
       │
       ├──▶ Milestone DAG Layer
       │    ┌──────────────────────┐
       │    │  lib/milestone_dag   │ ← MANIFEST.cfg + .md files
       │    │  lib/milestone_win   │ → MILESTONE_BLOCK (budgeted)
       │    └──────────────────────┘
       │
       ├──▶ Indexer Layer (opt-in)
       │    ┌─────────────────┐    ┌──────────────────────┐
       │    │  lib/indexer.sh  │───▶│  tools/repo_map.py   │
       │    │  (orchestrator)  │    │  (tree-sitter parse  │
       │    │                  │◀───│   + PageRank + emit)  │
       │    └─────────────────┘    └──────────────────────┘
       │         │
       │         ▼
       │    REPO_MAP.md (ranked signatures, token-budgeted)
       │
       ▼
  Agent Stages (with budgeted context)
       ├──▶ Scout    (full map for discovery)
       ├──▶ Coder    (task-relevant slice + active milestone)
       ├──▶ Reviewer (changed-file slice)
       └──▶ Tester   (test-relevant slice)

  Optional: Serena MCP (live symbol queries)
       └──▶ Agents use find_symbol / references
            tools alongside static repo map
```

### Milestone Plan

#### [DONE] Milestone 1: Milestone DAG Infrastructure
Add the DAG-based milestone storage system: a pipe-delimited manifest tracking
dependencies and status, individual `.md` files per milestone, DAG query functions
(frontier detection, cycle validation), and auto-migration from inline CLAUDE.md
milestones. This milestone replaces the sequential-only milestone model with a
dependency-aware DAG that enables future parallel execution.

Files to create:
- `lib/milestone_dag.sh` — manifest parser (`load_manifest()`, `save_manifest()`
  using atomic tmpfile+mv), DAG query functions (`dag_get_frontier()`,
  `dag_deps_satisfied()`, `dag_find_next()`, `dag_get_active()`), validation
  (`validate_manifest()` with cycle detection via DFS), ID↔number conversion
  (`dag_id_to_number()`, `dag_number_to_id()`). Data structures: parallel bash
  arrays (`_DAG_IDS[]`, `_DAG_TITLES[]`, `_DAG_STATUSES[]`, `_DAG_DEPS[]`,
  `_DAG_FILES[]`, `_DAG_GROUPS[]`) with associative index `_DAG_IDX[id]=index`.
- `lib/milestone_dag_migrate.sh` — `migrate_inline_milestones(claude_md, milestone_dir)`
  extracts all inline milestones from CLAUDE.md into individual files in
  `.claude/milestones/`, generates `MANIFEST.cfg`. Uses existing
  `_extract_milestone_block()` for block extraction. File naming:
  `m{NN}-{slugified-title}.md`. Dependencies inferred from sequential order
  (each depends on previous) unless explicit "depends on Milestone N" references
  found in text.

Files to modify:
- `lib/milestones.sh` — add `parse_milestones_auto()` dual-path wrapper: if
  manifest exists, returns milestone data from it in the same
  `NUMBER|TITLE|ACCEPTANCE_CRITERIA` format as `parse_milestones()`. All
  downstream consumers work unchanged.
- `lib/milestone_ops.sh` — `find_next_milestone()` gains DAG-aware path calling
  `dag_find_next()`. `mark_milestone_done()` gains DAG path calling
  `dag_set_status(id, "done")` + `save_manifest()`.
- `lib/milestone_archival.sh` — adapt for file-based milestones: read milestone
  file directly via `dag_get_file()`, append to archive, no CLAUDE.md block
  extraction needed.
- `lib/milestone_split.sh` — adapt for file-based milestones: write sub-milestone
  files + insert manifest rows instead of replacing CLAUDE.md blocks.
- `lib/milestone_metadata.sh` — write metadata into milestone files instead of
  CLAUDE.md headings.
- `lib/config_defaults.sh` — add defaults: `MILESTONE_DAG_ENABLED=true`,
  `MILESTONE_DIR=".claude/milestones"`, `MILESTONE_MANIFEST="MANIFEST.cfg"`,
  `MILESTONE_AUTO_MIGRATE=true`, `MILESTONE_WINDOW_PCT=30`,
  `MILESTONE_WINDOW_MAX_CHARS=20000`. Add clamps for PCT (80) and MAX_CHARS (100000).
- `tekhton.sh` — source new modules, add DAG-aware milestone initialization,
  add auto-migration at startup (if manifest missing but inline milestones found).
- `templates/pipeline.conf.example` — add milestone DAG config section with
  explanatory comments.

Manifest format (`.claude/milestones/MANIFEST.cfg`):
```
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|pending||m01-dag-infra.md|foundation
m02|Sliding Window|pending|m01|m02-sliding-window.md|foundation
```

Acceptance criteria:
- `has_milestone_manifest()` returns 0 when MANIFEST.cfg exists, 1 otherwise
- `load_manifest()` correctly parses a multi-line manifest into parallel arrays
- `dag_deps_satisfied()` returns 0 only when all deps have status=done
- `dag_get_frontier()` returns only milestones whose deps are all done
- `validate_manifest()` detects: missing dep references, circular deps, missing files
- `dag_set_status()` + `save_manifest()` roundtrips correctly (read-modify-write)
- `migrate_inline_milestones()` extracts all milestones from a CLAUDE.md, creates
  individual files, generates a valid MANIFEST.cfg
- `parse_milestones_auto()` returns data from manifest in the same format as inline
- When no manifest exists, all functions fall back to existing v2 behavior unchanged
- `find_next_milestone()` respects DAG edges when manifest is present
- `mark_milestone_done()` updates manifest status when manifest is present
- `archive_completed_milestone()` and `split_milestone()` work with file-based milestones
- All existing tests pass (`bash tests/run_tests.sh`)
- `bash -n lib/milestone_dag.sh lib/milestone_dag_migrate.sh` passes
- `shellcheck lib/milestone_dag.sh lib/milestone_dag_migrate.sh` passes
- New test file `tests/test_milestone_dag.sh` covers: manifest parsing, DAG queries,
  frontier detection, cycle detection, migration, status updates

Watch For:
- `_DAG_IDX` associative array requires `declare -A` (bash 4+ — already enforced).
- Milestone IDs in the manifest (`m01`) differ from display numbers (`1`) used in
  task strings and commit messages. The `dag_id_to_number()`/`dag_number_to_id()`
  conversion must handle both formats seamlessly.
- Manifest writes must be atomic (tmpfile+mv) — same pattern as milestone_archival.
- `_extract_milestone_block()` in `milestone_archival_helpers.sh` is reused by
  migration. The migration function must use the same helper for consistent block
  boundary detection.
- Circular dependency detection: DFS with visited set. Report cycle path in error.
- `.claude/milestones/` directory must be created by migration or plan generation,
  NOT eagerly at startup if no milestones exist.

Seeds Forward:
- Milestone 2 consumes the manifest and milestone files to build the sliding window
- The `parallel_group` field and dependency edges enable future parallel execution
- `dag_get_frontier()` is directly reusable by future parallel execution logic

#### Milestone 2: Sliding Window & Plan Generation Integration
Wire the DAG into the prompt engine with a character-budgeted sliding window that
injects only relevant milestones into agent context. Update plan generation to emit
milestone files instead of inline CLAUDE.md sections. Add auto-migration at startup
for existing projects with inline milestones.

Files to create:
- `lib/milestone_window.sh` — `build_milestone_window(model)` assembles
  character-budgeted milestone context block from the manifest. Priority:
  active milestone (full content) → frontier milestones (first paragraph +
  acceptance criteria) → on-deck milestones (title + one-line description).
  Fills greedily until budget exhaustion. `_compute_milestone_budget(model)`
  calculates available chars: `min(available * MILESTONE_WINDOW_PCT/100,
  MILESTONE_WINDOW_MAX_CHARS)`. `_milestone_priority_list()` returns ordered
  IDs by priority. Integrates with `_add_context_component()` for accounting.

Files to modify:
- `stages/coder.sh` — replace static MILESTONE_BLOCK with
  `build_milestone_window()` call when manifest exists. Falls back to existing
  behavior when no manifest.
- `stages/plan_generate.sh` — after agent produces CLAUDE.md content, post-process:
  extract milestone blocks into individual files in `.claude/milestones/`, generate
  MANIFEST.cfg, remove milestone blocks from CLAUDE.md and insert pointer comment.
  Agent prompt and output format are unchanged — shell handles extraction.
- `lib/orchestrate_helpers.sh` — `_run_auto_advance_chain()` uses DAG-aware
  milestone ordering via `dag_find_next()`.
- `lib/config.sh` — add MILESTONE_DIR path resolution (relative → absolute).
- `tekhton.sh` — add auto-migration trigger at startup: if `MILESTONE_DAG_ENABLED`
  and `MILESTONE_AUTO_MIGRATE` and no manifest exists but inline milestones
  detected, run `migrate_inline_milestones()`.

Acceptance criteria:
- `build_milestone_window()` returns only the active milestone + frontier
  milestones that fit within the character budget
- When budget is exhausted, frontier milestones are truncated (first paragraph +
  acceptance criteria only) rather than omitted entirely
- On-deck milestones only included if budget remains after all frontier milestones
- The window integrates with `_add_context_component()` for context accounting
- Plan generation extracts milestones from agent output into individual files and
  generates a valid MANIFEST.cfg
- Auto-migration at startup correctly converts inline CLAUDE.md milestones to
  files + manifest
- After migration, CLAUDE.md no longer contains full milestone blocks
- `_run_auto_advance_chain()` works correctly with DAG-based ordering
- Window respects `MILESTONE_WINDOW_MAX_CHARS` hard cap
- When `MILESTONE_DAG_ENABLED=false`, all behavior is identical to v2
- All existing tests pass
- `bash -n lib/milestone_window.sh` passes
- `shellcheck lib/milestone_window.sh` passes
- New test files: `tests/test_milestone_window.sh` (budget calculation, priority
  ordering, budget exhaustion), `tests/test_milestone_dag_migrate.sh` (inline
  extraction, manifest generation, CLAUDE.md cleanup, re-migration idempotency)

Watch For:
- Plan generation post-processing must handle variable heading depth (####, #####)
  since agents may vary formatting. Use the same regex as `parse_milestones()`.
- Auto-migration must be idempotent. If MANIFEST.cfg already exists, skip.
  If interrupted mid-way, next run should detect partial state and complete.
- CLAUDE.md trimming after milestone extraction must preserve all non-milestone
  content exactly. Use existing `_extract_milestone_block()` +
  `_replace_milestone_block()` pattern.
- Character budget must account for the instruction header (~300 chars) prepended
  by `build_milestone_window()`. Subtract before filling with file content.
- When the active milestone file exceeds the entire budget, truncate it (keep
  acceptance criteria at minimum) rather than failing. Log a warning.

Seeds Forward:
- The DAG data model supports future parallel execution: `dag_get_frontier()`
  returns all parallelizable milestones
- The sliding window pattern can be extended for repo map integration: pre-compute
  the repo map slice from the milestone's "Files to create/modify" section
- Auto-migration creates the `.claude/milestones/` directory structure that future
  tooling (milestone dashboards, progress tracking) can consume

#### Milestone 3: Indexer Infrastructure & Setup Command
Add the shell-side orchestration layer, Python dependency detection, setup command,
and configuration keys. This milestone builds the framework that Milestones 4-8
plug into. No actual indexing logic yet — just the plumbing.

Files to create:
- `lib/indexer.sh` — `check_indexer_available()` (returns 0 if Python + tree-sitter
  found), `run_repo_map(task, token_budget)` (invokes Python tool, captures output),
  `get_repo_map_slice(file_list)` (extracts entries for specific files from cached
  map), `invalidate_repo_map_cache()`. All functions are no-ops returning fallback
  values when Python is unavailable.
- `tools/setup_indexer.sh` — standalone setup script: checks Python version (≥3.8),
  creates virtualenv in `.claude/indexer-venv/`, installs `tree-sitter`,
  `tree-sitter-languages` (or individual grammars), `networkx`. Idempotent — safe
  to re-run. Prints clear error messages if Python is missing.

Files to modify:
- `tekhton.sh` — add `--setup-indexer` early-exit path that runs
  `tools/setup_indexer.sh`. Source `lib/indexer.sh`. Call
  `check_indexer_available()` at startup and set `INDEXER_AVAILABLE=true/false`.
- `lib/config.sh` — add defaults: `REPO_MAP_ENABLED=false`,
  `REPO_MAP_TOKEN_BUDGET=2048`, `REPO_MAP_CACHE_DIR=".claude/index"`,
  `REPO_MAP_LANGUAGES="auto"` (auto-detect from file extensions),
  `SERENA_ENABLED=false`, `SERENA_CONFIG_PATH=""`.
- `templates/pipeline.conf.example` — add indexer config section with explanatory
  comments

Acceptance criteria:
- `tekhton --setup-indexer` creates virtualenv and installs dependencies
- `check_indexer_available` returns 0 when venv + tree-sitter exist, 1 otherwise
- When `REPO_MAP_ENABLED=true` but Python unavailable, pipeline logs a warning
  and falls back to 2.0 behavior (no error, no abort)
- Config keys are validated (token budget must be positive integer, etc.)
- `.claude/indexer-venv/` is added to the default `.gitignore` warning check
- All existing tests pass
- `bash -n lib/indexer.sh tools/setup_indexer.sh` passes
- `shellcheck lib/indexer.sh tools/setup_indexer.sh` passes

Watch For:
- virtualenv creation must work on Linux, macOS, and Windows (Git Bash). Use
  `python3 -m venv` not `virtualenv` command.
- tree-sitter grammar installation varies by platform. The setup script should
  handle failures gracefully per-grammar (some languages may fail on some platforms).
- The `.claude/indexer-venv/` directory can be large. It must never be committed.
- `REPO_MAP_LANGUAGES="auto"` detection should scan file extensions in the project
  root (1 level deep to stay fast), not walk the entire tree.

Seeds Forward:
- Milestone 4 implements the Python tool that `run_repo_map()` invokes
- Milestone 5 wires the repo map output into pipeline stages
- Milestone 6 extends the setup command with `--with-lsp` for Serena

#### Milestone 4: Tree-Sitter Repo Map Generator
Implement the Python tool that parses source files with tree-sitter, extracts
definition and reference tags, builds a file-relationship graph, ranks files by
PageRank relevance to the current task, and emits a token-budgeted repo map
containing only function/class/method signatures — no implementations.

Files to create:
- `tools/repo_map.py` — main entry point. CLI: `repo_map.py --root <dir>
  --task "<task string>" --budget <tokens> --cache-dir <path> [--files f1,f2]`.
  Steps: (1) walk project tree respecting `.gitignore`, (2) parse each file with
  tree-sitter to extract tags (definitions: class, function, method; references:
  call sites, imports), (3) build a directed graph: file A → file B if A references
  a symbol defined in B, (4) run PageRank with personalization vector biased toward
  files matching task keywords, (5) emit ranked file entries with signatures only,
  stopping when token budget is exhausted. Output format: markdown with
  `## filename` headings and indented signatures.
- `tools/tag_cache.py` — disk-based tag cache using JSON. Key: file path +
  mtime. On cache hit, skip tree-sitter parse. Cache stored in
  `REPO_MAP_CACHE_DIR/tags.json`. Provides `load_cache()`, `save_cache()`,
  `get_tags(filepath, mtime)`, `set_tags(filepath, mtime, tags)`.
- `tools/tree_sitter_languages.py` — language detection and grammar loading.
  Maps file extensions to tree-sitter grammars. Provides `get_parser(ext)` which
  returns a configured parser or `None` for unsupported languages. Initial
  language support: Python, JavaScript, TypeScript, Java, Go, Rust, C, C++,
  Ruby, Bash, Dart, Swift, Kotlin, C#.
- `tools/requirements.txt` — pinned dependencies: `tree-sitter>=0.21`,
  `tree-sitter-languages>=1.10` (or individual grammar packages),
  `networkx>=3.0`.

Files to modify:
- `lib/indexer.sh` — implement `run_repo_map()` to invoke
  `tools/repo_map.py` via the project's indexer virtualenv Python. Parse
  exit code: 0 = success (stdout is the map), 1 = partial (some files
  failed, map is best-effort), 2 = fatal (fall back to 2.0). Write output
  to `REPO_MAP_CACHE_DIR/REPO_MAP.md`.

Output format example:
```markdown
## src/models/user.py
  class User
    def __init__(self, name, email)
    def validate(self) -> bool
    def to_dict(self) -> dict

## src/api/routes.py
  def register_routes(app)
  def handle_user_create(request) -> Response
  def handle_user_get(user_id) -> Response

## src/db/connection.py
  class DatabasePool
    def get_connection(self) -> Connection
    def release(self, conn)
```

Acceptance criteria:
- `repo_map.py --root . --task "add user auth" --budget 2048` produces a
  ranked markdown repo map that fits within the token budget
- Files matching task keywords rank higher than unrelated files
- Tag cache eliminates re-parsing unchanged files (mtime-based)
- Unsupported file types are silently skipped (no error, no output)
- `.gitignore` patterns are respected (no `node_modules/`, `.venv/`, etc.)
- Output contains only signatures — no function bodies, no comments
- Exit code 1 (partial) still produces a usable map from parseable files
- `python3 -m pytest tools/` passes (unit tests for tag extraction, graph
  building, ranking, budget enforcement, cache hit/miss)
- All existing bash tests pass

Watch For:
- tree-sitter grammar API changed significantly between 0.20 and 0.21+. Pin to
  >=0.21 and use the new API. The `tree-sitter-languages` package bundles
  grammars conveniently but may lag behind — support both bundled and individual
  grammar packages.
- PageRank personalization vector must handle the case where task keywords match
  zero files — fall back to uniform personalization (standard PageRank).
- Token budget enforcement must count tokens in the OUTPUT, not the input files.
  Use `len(text) / 4` as the token estimate (matching v2's CHARS_PER_TOKEN).
- `.gitignore` parsing is non-trivial. Use `pathspec` library or shell out to
  `git ls-files` for git repos. For non-git projects, skip `.gitignore` handling.
- Large monorepos (10k+ files) must complete in under 30 seconds on first run
  and under 5 seconds on cached runs. Profile early.

Seeds Forward:
- Milestone 5 consumes `REPO_MAP.md` in pipeline stages
- Milestone 7 extends the cache with cross-run task→file associations
- The tag extraction format is reused by Milestone 6's Serena integration
  for cache warming

#### Milestone 5: Pipeline Stage Integration
Wire the repo map into all pipeline stages, replacing or supplementing full
ARCHITECTURE.md injection. Each stage receives a different slice of the map
optimized for its role. Integrate with v2's context accounting for
budget-aware injection. Graceful degradation to 2.0 when map unavailable.

Files to modify:
- `stages/coder.sh` — when `REPO_MAP_ENABLED=true` and `INDEXER_AVAILABLE=true`:
  (1) regenerate repo map with task-biased ranking before coder invocation,
  (2) inject `REPO_MAP_CONTENT` into the coder prompt instead of full
  `ARCHITECTURE_CONTENT` (architecture file is still available via scout report),
  (3) if scout identified specific files, call `get_repo_map_slice()` to produce
  a focused slice showing those files plus their direct dependencies. When
  indexer unavailable, fall back to existing ARCHITECTURE_CONTENT injection.
- `stages/review.sh` — when enabled: extract file list from CODER_SUMMARY.md,
  call `get_repo_map_slice()` for those files + their callers (reverse
  dependencies), inject as `REPO_MAP_CONTENT`. Reviewer sees the changed files
  in full context of what calls them and what they call.
- `stages/tester.sh` — when enabled: extract file list from CODER_SUMMARY.md,
  call `get_repo_map_slice()` for those files + their test file counterparts
  (heuristic: `foo.py` → `test_foo.py`, `foo.ts` → `foo.test.ts`). Inject as
  `REPO_MAP_CONTENT`.
- `stages/architect.sh` — when enabled: inject full repo map (not sliced).
  Architect needs the broadest view for drift detection.
- `lib/prompts.sh` — add `REPO_MAP_CONTENT` and `REPO_MAP_SLICE` as template
  variables. Add `{{IF:REPO_MAP_CONTENT}}` conditional blocks.
- `lib/context.sh` — add repo map as a named context component in
  `log_context_report()`. Include it in budget calculations.
- `prompts/coder.prompt.md` — add `{{IF:REPO_MAP_CONTENT}}` block with
  instructions: "The following repo map shows ranked file signatures relevant
  to your task. Use it to understand the codebase structure and identify files
  to read or modify. Signatures show the public API — read full files before
  making changes."
- `prompts/reviewer.prompt.md` — add repo map block with instruction: "The
  repo map below shows the changed files and their callers/callees. Use it
  to verify that changes are consistent with the broader codebase structure."
- `prompts/tester.prompt.md` — add repo map block with instruction: "The
  repo map below shows the changed files and their test counterparts. Use it
  to identify which test files need updates and what interfaces to test against."
- `prompts/scout.prompt.md` — add full repo map block with instruction: "Use
  this repo map to identify relevant files without needing to search the
  filesystem. The map is ranked by likely relevance to the task."
- `prompts/architect.prompt.md` — add full repo map block for drift analysis

Acceptance criteria:
- Coder stage injects repo map instead of full ARCHITECTURE.md when available
- Reviewer sees changed files + reverse dependencies in map slice
- Tester sees changed files + test counterparts in map slice
- Scout sees full ranked map (dramatically reducing exploratory reads)
- Context report shows repo map as a named component with token count
- When `REPO_MAP_ENABLED=false` or indexer unavailable, all stages behave
  identically to v2 (no warnings, no changes)
- Prompt templates use conditional blocks — no repo map content appears in
  prompts when feature is disabled
- Token budget is respected: repo map + other context stays within
  `CONTEXT_BUDGET_PCT`
- All existing tests pass
- `shellcheck` passes on all modified `.sh` files

Watch For:
- The scout stage benefits MOST from the repo map — it replaces blind `find`
  and `grep` with a ranked file list. This is where the biggest token savings
  come from.
- ARCHITECTURE.md still has value for high-level design intent that tree-sitter
  can't capture. Consider injecting a truncated architecture summary (first
  N lines) alongside the repo map, not replacing it entirely.
- The test file heuristic (`foo.py` → `test_foo.py`) is language-specific.
  Keep it simple and configurable. A missed test file just means the tester
  falls back to normal discovery.
- Reverse dependency lookup (callers of changed files) can be expensive for
  highly-connected files. Cap at top 20 callers by PageRank.

Seeds Forward:
- Milestone 6 (Serena) enhances the repo map with live symbol data, giving
  agents even more precise context
- Milestone 7 (Cross-Run Cache) uses task→file history from this milestone
  to improve future repo map rankings
- The prompt template patterns established here (`{{IF:REPO_MAP_CONTENT}}`)
  are reused by Milestone 6 for LSP tool instructions

#### Milestone 6: Serena MCP Integration
Add optional LSP-powered symbol resolution via Serena as an MCP server. When
enabled, agents gain `find_symbol`, `find_referencing_symbols`, and
`get_symbol_definition` tools that provide live, accurate cross-reference data.
This supplements the static repo map with runtime precision — the map tells
agents WHERE to look, Serena tells them EXACTLY what's there.

Files to create:
- `tools/setup_serena.sh` — setup script for Serena: clones or updates the
  Serena repo into `.claude/serena/`, installs its dependencies, generates
  project-specific configuration. Detects available language servers for the
  target project's languages (e.g., `pyright` for Python, `typescript-language-server`
  for TS/JS, `gopls` for Go). Idempotent. Invoked via
  `tekhton --setup-indexer --with-lsp`.
- `tools/serena_config_template.json` — template MCP server configuration for
  Claude CLI. Contains `{{SERENA_PATH}}`, `{{PROJECT_DIR}}`, `{{LANGUAGE_SERVERS}}`
  placeholders that `setup_serena.sh` fills in.
- `lib/mcp.sh` — MCP server lifecycle management: `start_mcp_server()`,
  `stop_mcp_server()`, `check_mcp_health()`. Starts Serena as a background
  process before agent invocation, health-checks it, stops it after the stage
  completes. Uses the session temp directory for Serena's socket/pipe.

Files to modify:
- `tekhton.sh` — source `lib/mcp.sh`. Add `--with-lsp` flag parsing for
  `--setup-indexer`. When `SERENA_ENABLED=true`, call `start_mcp_server()`
  before first agent stage and `stop_mcp_server()` in the EXIT trap.
- `lib/indexer.sh` — add `check_serena_available()` that verifies Serena
  installation and at least one language server. Update `check_indexer_available()`
  to report both repo map and Serena status separately.
- `lib/config.sh` — add defaults: `SERENA_ENABLED=false`,
  `SERENA_PATH=".claude/serena"`, `SERENA_LANGUAGE_SERVERS="auto"`,
  `SERENA_STARTUP_TIMEOUT=30`, `SERENA_MAX_RETRIES=2`.
- `lib/agent.sh` — when `SERENA_ENABLED=true` and Serena is running, add
  `--mcp-config` flag to `claude` CLI invocations pointing to the generated
  MCP config. This gives agents access to Serena's tools.
- `prompts/coder.prompt.md` — add `{{IF:SERENA_ENABLED}}` block: "You have
  access to LSP tools via MCP. Use `find_symbol` to locate definitions,
  `find_referencing_symbols` to find all callers of a function, and
  `get_symbol_definition` to read a symbol's full definition with type info.
  Prefer these over grep for precise symbol lookup. The repo map gives you
  the overview; LSP tools give you precision."
- `prompts/reviewer.prompt.md` — add Serena tool instructions for verifying
  that changes don't break callers
- `prompts/scout.prompt.md` — add Serena tool instructions for discovery:
  "Use `find_symbol` to verify that functions you find in the repo map
  actually exist and to check their signatures before recommending files."
- `templates/pipeline.conf.example` — add Serena config section

Acceptance criteria:
- `tekhton --setup-indexer --with-lsp` installs Serena and detects language servers
- MCP server starts before first agent stage and stops on pipeline exit
- `check_mcp_health()` returns 0 when Serena responds, 1 otherwise
- When Serena fails to start, pipeline logs warning and continues without LSP
  tools (agents still have the static repo map)
- Agent CLI invocations include `--mcp-config` when Serena is available
- Prompt templates conditionally inject Serena tool usage instructions
- `SERENA_ENABLED=false` (default) produces identical behavior to Milestone 5
- Serena process is always cleaned up on exit (no orphaned processes)
- All existing tests pass
- `bash -n lib/mcp.sh tools/setup_serena.sh` passes
- `shellcheck lib/mcp.sh tools/setup_serena.sh` passes

Watch For:
- Serena startup can take 10-30 seconds while language servers index the project.
  `SERENA_STARTUP_TIMEOUT` must be generous. Show a progress indicator.
- Language server availability varies wildly. A project may have `pyright` but
  not `gopls`. Serena should work with whatever's available and report which
  languages have full LSP support vs. tree-sitter-only.
- MCP server configuration format may change between Claude CLI versions. Keep
  the config template simple and version-annotated.
- Orphaned Serena processes are a real risk. The EXIT trap must kill the process
  group, not just the main process. Test with Ctrl+C, SIGTERM, and SIGKILL.
- The MCP `--mcp-config` flag may not be available in all Claude CLI versions.
  Detect CLI version and fall back gracefully.

Seeds Forward:
- Milestone 7 can use Serena's type information to enrich the tag cache with
  parameter types and return types (richer signatures)
- Future v3 milestones for parallel agents (DAG execution) will need per-agent
  MCP server instances or a shared server with locking — design the lifecycle
  management with this in mind

#### Milestone 7: Cross-Run Cache & Personalized Ranking
Make the indexer persistent and adaptive across pipeline runs. The tag cache
survives between runs with mtime-based invalidation. Task→file association
history improves PageRank personalization over time — files that were relevant
to similar past tasks rank higher automatically. Integrate with v2's metrics
system for tracking indexer performance.

Files to modify:
- `tools/repo_map.py` — add `--history-file <path>` flag. When provided, load
  task→file association records and use them to build a personalization vector
  that blends: (1) task keyword matches (current behavior, weight 0.6),
  (2) historical file relevance from similar past tasks (weight 0.3),
  (3) file recency from git log (weight 0.1). Add `--warm-cache` flag that
  parses all project files and populates the tag cache without producing output
  (for use during `tekhton --init`).
- `tools/tag_cache.py` — add cache statistics: hit count, miss count, total
  parse time saved. Add `prune_cache(root_dir)` that removes entries for files
  that no longer exist. Add cache versioning — if cache format changes between
  Tekhton versions, invalidate and rebuild rather than crash.
- `lib/indexer.sh` — add `warm_index_cache()` (called during `--init` or
  `--setup-indexer`), `record_task_file_association(task, files[])` (called
  after coder stage with the files from CODER_SUMMARY.md),
  `get_indexer_stats()` (returns cache hit rate and timing for metrics).
  History file: `.claude/index/task_history.jsonl` (append-only JSONL, same
  pattern as v2 metrics).
- `lib/metrics.sh` — add indexer metrics to `record_run_metrics()`: cache hit
  rate, repo map generation time, token savings vs full architecture injection.
  Add indexer section to `summarize_metrics()` dashboard output.
- `stages/coder.sh` — after coder completes, call
  `record_task_file_association()` with the task and modified file list.
- `tekhton.sh` — during `--init`, if indexer is available, call
  `warm_index_cache()` to pre-populate the tag cache. Display progress.
- `templates/pipeline.conf.example` — add `REPO_MAP_HISTORY_ENABLED=true`,
  `REPO_MAP_HISTORY_MAX_RECORDS=200` config keys

History record format (JSONL):
```json
{"ts":"2026-03-21T10:00:00Z","task":"add user authentication","files":["src/auth/login.py","src/models/user.py","src/api/routes.py"],"task_type":"feature"}
```

Acceptance criteria:
- Tag cache persists between runs in `.claude/index/tags.json`
- Changed files (new mtime) are re-parsed; unchanged files use cache
- Deleted files are pruned from cache on next run
- `--warm-cache` pre-populates the entire project cache in one pass
- Task→file history is recorded after each successful coder stage
- Personalization vector blends keyword, history, and recency signals
- With 10+ history records, the repo map noticeably favors files that were
  relevant to similar past tasks (measurable in ranking output)
- `REPO_MAP_HISTORY_MAX_RECORDS` caps history file size (oldest records pruned)
- Indexer metrics appear in `tekhton --metrics` dashboard
- Cache version mismatch triggers rebuild with warning, not crash
- All existing tests pass
- New Python tests verify: history loading, personalization blending, cache
  pruning, version migration, JSONL append safety

Watch For:
- JSONL is append-only by design. Never read-modify-write. Pruning creates a
  new file and atomically replaces the old one.
- Task similarity is keyword-based (bag of words overlap), not semantic. Keep
  it simple — semantic similarity would require embeddings and adds complexity
  and cost for marginal gain at this stage.
- Git recency signal requires a git repo. For non-git projects, drop weight 0.1
  and redistribute to keywords (0.7) and history (0.3).
- History file can contain sensitive task descriptions. It lives in `.claude/`
  which should be gitignored, but add a warning to the setup output.
- Cache warming on large projects (10k+ files) may take 30-60 seconds. Show
  a progress bar or periodic status line.

Seeds Forward:
- Future v3 milestones (parallel execution) can use task→file history to
  predict which milestones will touch overlapping files and schedule them
  to avoid merge conflicts
- The metrics integration provides data for future adaptive token budgeting —
  if the indexer consistently saves 70% of tokens, the pipeline can allocate
  the savings to richer prompt content

#### Milestone 8: Indexer Tests & Documentation
Comprehensive test coverage for all indexing functionality: shell orchestration,
Python tools, pipeline integration, fallback behavior, and Serena lifecycle.
Update project documentation and repository layout.

Files to create:
- `tests/test_indexer.sh` — shell-side tests: `check_indexer_available()` returns
  correct status for present/absent Python, `run_repo_map()` handles exit codes
  (0/1/2), `get_repo_map_slice()` extracts correct file entries, fallback to 2.0
  when indexer unavailable, config key validation (budget must be positive, etc.)
- `tests/test_mcp.sh` — MCP lifecycle tests: `start_mcp_server()` / `stop_mcp_server()`
  create and clean up processes, `check_mcp_health()` detects running/stopped
  server, EXIT trap cleanup works, orphan prevention
- `tests/test_repo_map_integration.sh` — end-to-end tests using a small fixture
  project (created in test setup): verify repo map generation, stage injection
  (coder/reviewer/tester get correct slices), context budget respected, conditional
  prompt blocks render correctly when feature on/off
- `tools/tests/test_repo_map.py` — Python unit tests: tag extraction for each
  supported language, graph construction from tags, PageRank output, token budget
  enforcement, `.gitignore` respect, error handling for unparseable files
- `tools/tests/test_tag_cache.py` — cache hit/miss, mtime invalidation, pruning
  deleted files, version migration, concurrent write safety
- `tools/tests/test_history.py` — task→file recording, JSONL append, history
  loading, personalization vector computation, max records pruning
- `tools/tests/conftest.py` — shared fixtures: small multi-language project tree,
  mock git repo, sample tag cache files
- `tests/fixtures/indexer_project/` — small fixture project with Python, JS, and
  Bash files for integration testing

Files to modify:
- `CLAUDE.md` — update Repository Layout to include `tools/` directory, `lib/indexer.sh`,
  `lib/mcp.sh`. Update Template Variables table with all new config keys and their
  defaults. Update Non-Negotiable Rules to note Python as an optional dependency.
- `templates/pipeline.conf.example` — ensure all indexer config keys have
  explanatory comments matching the detail level of existing keys
- `tests/run_tests.sh` — add new test files to the test runner. Add conditional
  Python test execution: if Python available, run `python3 -m pytest tools/tests/`;
  if not, skip with a note.

Acceptance criteria:
- All shell tests pass via `bash tests/run_tests.sh`
- All Python tests pass via `python3 -m pytest tools/tests/` (when Python available)
- Test runner gracefully skips Python tests when Python unavailable
- Fixture project exercises multi-language parsing (Python + JS + Bash minimum)
- Integration test verifies full flow: setup → generate map → inject into stage →
  verify prompt contains repo map content → verify context budget respected
- Fallback test verifies: disable indexer → run pipeline → identical to v2 output
- MCP tests verify no orphaned processes after normal exit, Ctrl+C, and error exit
- `CLAUDE.md` Repository Layout includes all new files and directories
- `CLAUDE.md` Template Variables table includes all new config keys
- `bash -n` passes on all new `.sh` files
- `shellcheck` passes on all new `.sh` files
- All pre-existing tests (37+) continue to pass unchanged

Watch For:
- Python test fixtures must be self-contained — no network access, no real
  language servers. Mock tree-sitter parsing for unit tests; use real parsing
  only in integration tests.
- The fixture project must be small (5-10 files) to keep tests fast.
- MCP lifecycle tests are inherently flaky (process timing). Use retry logic
  and generous timeouts in test assertions, not in production code.
- Shell tests that verify prompt content should check for the presence of
  `REPO_MAP_CONTENT` variable, not exact prompt text (prompts will evolve).
- Ensure Python tests work with both `tree-sitter-languages` (bundled) and
  individual grammar packages — CI environments may have either.

Seeds Forward:
- Test fixtures and patterns established here are reused by future v3 milestones
  (DAG execution, parallel agents, UI plugin) for their own testing
- The integration test pattern (fixture project → full pipeline) becomes the
  template for end-to-end testing of future features
