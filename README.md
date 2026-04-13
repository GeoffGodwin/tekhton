<div align="center">
  <img src="assets/tekhton-logo.svg" alt="Tekhton" width="120" />

  <h1>Tekhton</h1>

  <p><strong>One intent. Many hands.</strong></p>

  <p><em>v3.71.1 — Context-Aware Pipeline</em></p>
</div>

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on the [Claude CLI](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/cli-usage).
Give it a task description and it orchestrates an **Intake → Scout → Coder → Security → Reviewer → Tester** cycle
with automatic rework routing, build gates, dynamic turn limits, architecture drift
prevention, transient error retry, turn-exhaustion continuation, milestone splitting,
state persistence, and resume support — or hand it `--complete` and walk away.

## What's New in v3

Tekhton 3 makes the pipeline **context-aware** — milestones live as a dependency
graph with a sliding context window, agents receive ranked file signatures relevant
to their task, and a suite of new stages and modes make the pipeline safer, faster,
and easier to use. 66 milestones delivered across the V3 initiative; all v3 features
are additive or default-safe (a few are auto-enabled when their preconditions are
met, e.g. UI specialist on UI projects), and existing v2 workflows remain unchanged.

**Context & Indexing**

- **Milestone DAG** — file-based milestones with dependency tracking, sliding context window, parallel groups, and automatic migration from inline CLAUDE.md milestones
- **Intelligent Indexing** — tree-sitter repo maps with PageRank ranking, task-relevant context slicing per stage, cross-run file association tracking, repo map cross-stage cache, and optional Serena LSP via MCP
- **Prompt Tool Awareness** — coder/reviewer/tester prompts surface available Serena and repo map tools so agents actually use them
- **Intra-run Context Cache** — avoids redundant file reads within a single run

**Quality & Safety Stages**

- **Security Agent** — dedicated OWASP-aware security review stage with finding classification, severity scoring, automatic remediation, and waiver support
- **Task Intake / PM Agent** — complexity estimation, clarity scoring, task decomposition, and scope validation before execution
- **UI/UX Specialist** — auto-enabled on UI projects; 8-category checklist covering component structure, design system consistency, WCAG 2.1 AA accessibility, responsive behavior, state presentation, and interaction patterns
- **Test Baseline & Hygiene** — pre-existing test failure detection plus completion-gate hardening so agents aren't blamed for inherited test debt
- **Tester Surgical Fix Mode** — when tests fail, the tester spawns a scoped fix agent instead of rewriting the world
- **Build Gate Hardening** — hang prevention, timeout enforcement, and process tree cleanup for build/test commands

**Environment Intelligence**

- **Pre-flight Validation** — environment checks (toolchain, dependencies, services) before the pipeline starts, with optional auto-remediation
- **Error Pattern Registry** — structured classification of build/test failures with curated remediation hints
- **Auto-Remediation Engine** — applies known-safe fixes for cataloged failure patterns
- **Service Readiness Probing** — waits for databases, message queues, and dev servers to come up before declaring failures

**UI/UX Design Intelligence (Platform Adapters)**

- **Platform Adapter Framework** — file-based adapters in `platforms/` providing UI knowledge for the coder, specialist, and tester
- **Web** — Tailwind, MUI, shadcn, Chakra, Bootstrap detection with framework-specific guidance
- **Mobile & Game** — Flutter/Dart, SwiftUI/UIKit, Jetpack Compose, and browser game engines (Phaser, PixiJS, Three.js, Babylon.js)
- **User-extensible** — drop a `.claude/platforms/<name>/` override into any project

**Watchtower Dashboard**

- Real-time browser-based pipeline monitoring with Live Run, Milestone Map, Reports, Trends, and Security Summary tabs
- Smart refresh, context-aware layout, action items with severity colors, and interactive controls
- Full-stage metrics with hierarchical breakdown, parallel teams readiness, and run history timeline

**Brownfield Intelligence**

- Deep codebase analysis for `--init` on existing projects: tech stack detection, health scoring, AI artifact detection, workspace/service/CI enumeration
- Documentation quality assessment, test framework detection, UI framework detection, and E2E test awareness

**Notes Pipeline (rewritten)**

- Core rewrite with note triage and sizing gate, tag-specialized execution paths, injection hygiene, and an action-items UX surfaced in Watchtower
- `note` subcommand for managing HUMAN_NOTES.md from the CLI

**Developer Experience**

- **Express Mode** — zero-config execution when no `pipeline.conf` exists; Tekhton auto-detects your stack and runs (macOS users must still install bash 4.3+ via Homebrew first — see [Requirements](#requirements))
- **TDD Support** — `PIPELINE_ORDER=test_first` runs the tester before the coder, with a preflight test spec that guides implementation
- **Browser Planning** — interactive `--plan-browser` mode opens a web form for the planning interview with answer persistence; YAML answer import via `--plan --answers`
- **Dry-Run Preview** — `--dry-run` runs scout + intake only and shows what the pipeline would do without executing
- **Rollback** — `--rollback` reverts the last pipeline run with clean git operations
- **Pipeline Diagnostics** — `--diagnose` analyzes the last failure with structured recovery suggestions
- **Version Migration Framework** — `--migrate` upgrades project config across Tekhton versions
- **Onboarding Flow Fix** — repaired the circular `--init` ↔ `--plan` handoff so new projects start cleanly

**Acceleration & Telemetry**

- **Test-Aware Coding** with a jr coder test-fix gate
- **Causal Event Log** — structured JSONL event logging for debugging and cross-run learning
- **Structured Run Memory** — cross-run JSONL learning store with keyword filtering and automatic pruning
- **Instrumentation & Timing Report** — per-stage and per-agent timing surfaces in metrics and Watchtower
- **Progress Transparency** — real-time stage progress reporting with timing estimates based on run history
- **Reduced Agent Invocations** — smarter skip logic when stages have no work to do
- **Project Health Scoring** — five-category assessment (tests, quality, deps, docs, hygiene) with belt ratings and trend tracking

### Foundation (v2.0)

- `--complete` autonomous loop, `--auto-advance` milestone chaining, `--human` notes mode
- Transient error retry, turn-exhaustion continuation, milestone auto-split
- Context budgeting, specialist reviews, autonomous debt sweeps
- Error taxonomy, security hardening, metrics dashboard, brownfield replanning

## Requirements

- **Bash 4.3+** — Linux and WSL2 ship with a compatible version. **macOS requires setup** — macOS ships with bash 3.2 which will not work. Run `brew install bash` and add the Homebrew bash to your PATH *before* running Tekhton. See [installation notes](docs/getting-started/installation.md#macos).
- **Claude CLI** — authenticated and on `PATH` (`claude --version` should work)
- **Git** — used for commit integration
- **Python 3** — used for JSON parsing of agent output

### Optional Dependencies

- **Python 3.8+** with **tree-sitter** — for intelligent repo map indexing (`--setup-indexer` installs automatically)
- **Serena LSP** — for live symbol lookup via MCP (`--setup-indexer --with-lsp`)
- **shellcheck** — for development on Tekhton itself

## Quick Start

> **macOS users:** macOS ships with bash 3.2 which is too old for Tekhton. Run `brew install bash` first and ensure `/opt/homebrew/bin` (Apple Silicon) or `/usr/local/bin` (Intel) is on your `PATH` ahead of `/bin`. See [Installation → macOS](docs/getting-started/installation.md#macos) for details.

```bash
# Clone Tekhton
git clone https://github.com/geoffgodwin/tekhton.git
cd tekhton && chmod +x tekhton.sh

# Initialize your project
cd /path/to/your/project
/path/to/tekhton/tekhton.sh --init

# Configure
$EDITOR .claude/pipeline.conf    # Set PROJECT_NAME, ANALYZE_CMD, TEST_CMD, etc.
$EDITOR .claude/agents/coder.md  # Customize agent roles

# Run a single task
/path/to/tekhton/tekhton.sh "Implement user authentication"

# Or create an alias
alias tekhton='/path/to/tekhton/tekhton.sh'
tekhton "Fix: login redirect loop"

# Run until completion (autonomous loop)
tekhton --complete "Resolve all NON_BLOCKING_LOG observations"

# Build an entire milestone
tekhton --milestone "Implement Milestone 3: API layer"

# Chain milestones autonomously
tekhton --auto-advance "Start with Milestone 1"

# Process all human notes in batch
tekhton --human --complete

# Onboard an existing project (brownfield)
cd /path/to/existing/project
/path/to/tekhton/tekhton.sh --init    # Detects stack, crawls, generates docs
tekhton --replan                      # Update docs after codebase changes
```

After `--init`, your project will contain:

```
your-project/
├── .claude/
│   ├── pipeline.conf          # Pipeline configuration
│   ├── agents/
│   │   ├── coder.md           # Coder role definition
│   │   ├── reviewer.md        # Reviewer role definition
│   │   ├── tester.md          # Tester role definition
│   │   ├── jr-coder.md        # Jr coder role definition
│   │   └── architect.md       # Architect role definition
│   ├── milestones/            # Milestone DAG: per-milestone files + MANIFEST.cfg
│   ├── dashboard/             # Watchtower browser dashboard (open index.html)
│   ├── index/                 # Tree-sitter repo map cache (if --setup-indexer)
│   ├── logs/                  # Run logs, metrics, CAUSAL_LOG.jsonl, RUN_MEMORY.jsonl (gitignored)
│   └── platforms/             # (optional) user UI platform adapter overrides
├── CLAUDE.md                  # Project rules (read by all agents)
├── DESIGN.md                  # Design doc (from --plan)
├── PROJECT_INDEX.md           # Brownfield crawl output (--init / --rescan)
├── HUMAN_NOTES.md             # Bug/feat/polish queue
├── MILESTONE_ARCHIVE.md       # Completed milestone history
├── CODER_SUMMARY.md           # (generated per-run)
├── REVIEWER_REPORT.md         # (generated per-run)
├── SECURITY_REPORT.md         # (generated per-run)
└── TESTER_REPORT.md           # (generated per-run)
```

## How the Pipeline Works

```
tekhton "Implement feature X"
        │
        ├─ Pre-flight: env validation, service readiness, optional auto-remediation
        ├─ Task Intake: clarity scoring, scope assessment, task tweaking
        ├─ Architect audit (conditional — drift thresholds)
        │
        ├─ Scout + Coder
        │    ├─ Scout → estimates complexity, adjusts turn limits, leverages repo map + Serena
        │    ├─ Coder → writes code + CODER_SUMMARY.md
        │    ├─ Turn continuation → auto-resume if coder hits turn limit with progress
        │    └─ Build gate → error pattern classification → auto-fix (Jr → Sr escalation)
        │
        ├─ Security Review
        │    ├─ OWASP-aware vulnerability scan → SECURITY_REPORT.md
        │    └─ High/Critical findings → auto-remediation rework loop
        │
        ├─ Code Review
        │    ├─ Reviewer → REVIEWER_REPORT.md
        │    ├─ Complex blockers → Senior coder rework
        │    ├─ Simple blockers → Jr coder fix
        │    ├─ Build gate after fixes
        │    ├─ Specialist reviews (UI/UX auto on UI projects; performance, API, custom — opt-in)
        │    └─ (repeats up to MAX_REVIEW_CYCLES)
        │
        ├─ Tester
        │    ├─ Writes tests for coverage gaps → TESTER_REPORT.md
        │    ├─ Test baseline check → ignore pre-existing failures
        │    └─ Surgical fix mode → scoped fix agent on test failures
        │
        ├─ Cleanup (opt-in — autonomous debt sweep)
        │
        ├─ Drift processing (observations, ACPs, non-blocking notes)
        ├─ Milestone acceptance check (in --milestone / --complete mode)
        └─ Commit with auto-generated message
```

With `--complete`, the entire pipeline loops until acceptance criteria pass or
resource bounds are exhausted — retrying transient API errors, continuing on
turn exhaustion, and splitting oversized milestones automatically.

### Agent Models

Each agent runs on its own configurable model. Defaults:

| Agent | Default Model | Purpose |
|-------|--------------|---------|
| Coder | Opus | Primary implementation |
| Jr Coder | Haiku | Simple fixes, build repairs, debt sweeps, test fixes |
| Scout | Haiku | File discovery, complexity estimation |
| Reviewer | Sonnet | Code review, drift observation |
| Architect | Sonnet | Drift audit, remediation planning |
| Tester | Haiku (Sonnet in `--milestone`) | Test writing, validation, surgical fix mode |
| Intake / PM | Sonnet | Task clarity scoring, scope assessment, decomposition |
| Security | Sonnet | OWASP-aware vulnerability review (built-in stage) |
| UI/UX Specialist | Sonnet | Component, accessibility, design-system review (auto on UI projects) |
| Other Specialists | Sonnet | Performance, API, custom focused reviews (opt-in) |

### Dynamic Turn Limits

When `DYNAMIC_TURNS_ENABLED=true` (the default), the Scout agent estimates task
complexity before the Coder runs. The pipeline parses the estimate and adjusts
turn limits for Coder, Reviewer, and Tester — clamped to configured min/max bounds.

A simple bug fix might get 15 coder turns. A cross-cutting milestone might get 120.
This prevents wasting tokens on trivial tasks and running out of turns on large ones.

After the coder completes, reviewer and tester turn limits are **recalibrated** using
actual coder data (turns used, files modified, diff size) — replacing the scout's
pre-coder guesses with a deterministic formula.

With `METRICS_ADAPTIVE_TURNS=true` and enough run history, turn estimates are further
refined by adaptive calibration based on your project's actual performance data.

### Resume Support

Pipeline state is saved automatically on interruption. Running `tekhton` with no
arguments detects saved state and offers to resume, start fresh, or abort.
`--start-at` lets you jump to a specific stage if reports from earlier stages exist.

## Autonomous Modes

### Complete Mode (`--complete`)

Wraps the entire pipeline in an outer loop that re-runs until the task passes
acceptance or all recovery options are exhausted:

```bash
tekhton --complete "Resolve all NON_BLOCKING_LOG observations"
```

Safety bounds prevent runaway execution:
- `MAX_PIPELINE_ATTEMPTS=5` — max full pipeline cycles
- `AUTONOMOUS_TIMEOUT=7200` — wall-clock limit (2 hours)
- `MAX_AUTONOMOUS_AGENT_CALLS=20` — cumulative agent invocations
- `AUTONOMOUS_PROGRESS_CHECK=true` — detects stuck loops (no diff between iterations)

### Milestone Mode (`--milestone`)

Doubles turn limits, adds an extra review cycle, upgrades the tester model, and
runs milestone acceptance checking. Implies `--complete` — the pipeline retries
until acceptance criteria pass.

```bash
tekhton --milestone "Implement Milestone 3: API layer"
```

If a milestone is too large for the turn budget, the pipeline automatically splits
it into sub-milestones (3.1, 3.2, ...) and retries with narrower scope. If a coder
run produces no output (null run), the milestone is split and retried without human
intervention.

Completed milestones are automatically archived from CLAUDE.md to
`MILESTONE_ARCHIVE.md`, keeping CLAUDE.md under context window limits.

### Auto-Advance (`--auto-advance`)

Chains milestone-to-milestone execution. After each milestone passes acceptance, the
pipeline advances to the next and continues:

```bash
tekhton --auto-advance "Start with Milestone 1"
```

- `AUTO_ADVANCE_LIMIT=3` — max milestones per invocation
- `AUTO_ADVANCE_CONFIRM=true` — prompt between milestones (set `false` for unattended)

### Human Notes Mode (`--human`)

Pick the next unchecked item from `HUMAN_NOTES.md` as the task. Combine with
`--complete` to process all notes in batch:

```bash
tekhton --human              # Process next note
tekhton --human BUG          # Process next [BUG] note
tekhton --human --complete   # Process all notes until done
```

## Planning Phase (`--plan`)

Don't have a CLAUDE.md or DESIGN.md yet? The planning phase takes you from "I want
to build X" to production-ready documents that the execution pipeline can consume.

```bash
tekhton --plan

# 1. Pick a project type (web-app, cli-tool, api-service, web-game, mobile-app, library, custom)
# 2. Three-phase interview fills in DESIGN.md section by section
# 3. Completeness check flags shallow sections for follow-up
# 4. Claude generates CLAUDE.md with milestones, rules, and architecture
# 5. Review the milestone plan, then approve to write files

# Then initialize and build
tekhton --init
tekhton --milestone "Implement Milestone 1: Project scaffold"
```

**Interview phases:**
1. **Concept Capture** — high-level overview, tech stack, developer philosophy
2. **System Deep-Dive** — each feature/system section, with Phase 1 context visible
3. **Architecture & Constraints** — config architecture, naming conventions, open questions

If interrupted, re-running `tekhton --plan` offers to resume where you left off.

**DESIGN.md** — Professional-grade design document (500–1600+ lines):
developer philosophy, deep system sections with sub-sections and tables,
config architecture, open design questions.

**CLAUDE.md** — Authoritative development rulebook with 12 sections (500–1500 lines):
project identity, architecture philosophy, repository layout, key design decisions,
non-negotiable rules, implementation milestones (each with scope, file paths,
tests, watch-fors, and seeds-forward), code conventions, and more.

Each milestone is a standalone task: `tekhton --milestone "Implement Milestone 1: Project scaffold"`

### Brownfield Replanning (`--replan`)

Already have a codebase? `--replan` updates DESIGN.md and CLAUDE.md based on
accumulated drift, completed milestones, and codebase evolution. It's delta-based —
human edits are preserved, and you review all changes before they're applied.

```bash
tekhton --replan
```

## Human Notes

Write `HUMAN_NOTES.md` between runs to inject bug reports, feature requests, or polish
items into the next pipeline run. Use `--init-notes` to create a blank template.

```markdown
## Bugs
- [ ] [BUG] Login page crashes when email field is empty
- [ ] [BUG] Dark mode toggle doesn't persist

## Features
- [ ] [FEAT] Add CSV export to the reports page
```

Notes are categorized with `[BUG]`, `[FEAT]`, `[POLISH]` tags. Use `--notes-filter BUG`
to inject only bugs on a given run. Use `--human --complete` to process all notes
automatically. Completed items are automatically archived.

## Architecture Drift Prevention

The pipeline automatically detects and manages architectural drift across runs.

1. **Reviewer observes drift** — naming inconsistencies, layer violations, dead code, or stale patterns noted in `REVIEWER_REPORT.md`
2. **Observations accumulate** — collected in `DRIFT_LOG.md` with timestamps and task context
3. **Architect triggers** — when observations exceed threshold (default: 8) or runs since last audit exceed threshold (default: 5)
4. **Architect remediates** — produces `ARCHITECT_PLAN.md`, routing fixes to senior or jr coder by category
5. **Observations resolve** — addressed items marked RESOLVED in the drift log

**Architecture Change Proposals (ACPs)**: When the coder makes structural changes,
they propose an ACP in `CODER_SUMMARY.md`. The reviewer evaluates it. Accepted ACPs
are recorded in `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs — institutional
memory of *why* the architecture evolved.

**Human Action Required**: When the pipeline detects contradictions between design
docs and code, it creates `HUMAN_ACTION_REQUIRED.md`. A banner displays at every
pipeline completion until resolved.

**Non-Blocking Notes**: Low-priority reviewer observations accumulate in
`NON_BLOCKING_LOG.md`. When they exceed `NON_BLOCKING_INJECTION_THRESHOLD` (default: 8),
they're injected into the coder prompt on the next run for batch cleanup.

### Dependency Constraints (Optional)

Deterministic layer-boundary enforcement — no LLM judgment needed. Create an
`architecture_constraints.yaml` defining import rules, point it at a validation
script (see `examples/` for Dart, Python, TypeScript starters), and enable it
in `pipeline.conf`. The build gate runs the validator automatically. See
[examples/architecture_constraints.yaml](examples/architecture_constraints.yaml)
for the format.

## Agent Resilience

Tekhton uses FIFO-isolated agent invocation with multiple layers of fault tolerance:

- **Interrupt handling** — Ctrl+C works immediately, even if the agent is hung. Claude runs in a background subshell writing to a named pipe; the foreground read loop exits on signal.
- **Activity timeout** — If an agent produces no output or file changes for 10 minutes (`AGENT_ACTIVITY_TIMEOUT`), it's killed automatically. Catches hung API connections and stuck retry loops. File-change detection prevents false kills when agents work silently.
- **Total timeout** — Hard wall-clock limit of 2 hours (`AGENT_TIMEOUT`) as a backstop.
- **Transient error retry** — API errors (500, 429, 529), OOM kills, and network failures trigger automatic retry with exponential backoff (30s → 60s → 120s, up to 3 attempts). Rate-limit responses respect `retry-after` headers.
- **Turn-exhaustion continuation** — When a coder or tester hits its turn limit but made substantive progress (`Status: IN PROGRESS` + file changes), the pipeline automatically re-invokes with full prior-progress context and a fresh turn budget. Up to 3 continuations before escalating to milestone split or exit.
- **Null-run detection** — Agents that die during discovery (≤2 turns, non-zero exit) are flagged. Combined with file-change detection to distinguish real null runs from silent completions. API failures are never misclassified as null runs.
- **Error taxonomy** — Structured error classification (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE) with transience detection, recovery suggestions, and sensitive data redaction. Errors are displayed in formatted boxes with actionable next steps.
- **Windows compatibility** — Detects Windows-native `claude.exe` running via WSL interop or Git Bash and uses `taskkill.exe` for cleanup (Windows processes ignore POSIX signals).

## Watchtower Dashboard

Tekhton includes a browser-based dashboard for real-time pipeline monitoring:

```bash
open .claude/dashboard/index.html    # macOS
xdg-open .claude/dashboard/index.html  # Linux
```

The dashboard provides:
- **Live Run** — current stage, agent, turn count, and elapsed time
- **Milestone Map** — dependency graph visualization with status indicators
- **Reports** — run history with stage breakdowns and outcomes
- **Trends** — success rates, timing patterns, and health score trends
- **Security Summary** — open findings by severity, remediation rate
- **Action Items** — non-blocking notes, drift observations, and human actions with severity colors

The dashboard is created automatically by `--init` and updated at the end of each pipeline stage.

## Specialist Reviews

After the main reviewer approves, focused specialist agents can run additional review passes.

**Built-in / auto-enabled:**

- **Security** — runs as a dedicated pipeline stage (not just a specialist). OWASP-aware vulnerability scanning with severity scoring and auto-remediation. Toggle with `SECURITY_AGENT_ENABLED`.
- **UI/UX** — auto-enabled when `UI_PROJECT_DETECTED=true`. 8-category checklist covering component structure, design system consistency, WCAG 2.1 AA accessibility, responsive behavior, state presentation, interaction patterns, loading/empty/error states, and keyboard/focus management. Pulls platform-specific patterns from the active platform adapter (web / Flutter / iOS / Android / game engines). Override with `SPECIALIST_UI_ENABLED` and `UI_PLATFORM`.

**Opt-in:**

- **Docs agent** — dedicated post-coder stage that reads the diff and updates README/docs/ using a Haiku-tier model. Runs between build gate and security. Enable with `DOCS_AGENT_ENABLED=true`.
- **Performance** — N+1 queries, unbounded loops, memory leaks, expensive operations
- **API contracts** — schema consistency, error format compliance, backward compatibility

`[BLOCKER]` findings re-enter the rework loop. `[NOTE]` findings go to `NON_BLOCKING_LOG.md`.

Enable per specialist in `pipeline.conf`:
```bash
SPECIALIST_PERFORMANCE_ENABLED=true
SPECIALIST_API_ENABLED=true
# UI specialist is auto-on for UI projects; force off with:
# SPECIALIST_UI_ENABLED=false
```

Custom specialists are supported via `SPECIALIST_CUSTOM_*` config keys with your own prompt templates. User platform adapters can be dropped into `.claude/platforms/<name>/` to extend or override the built-in UI knowledge.

## Autonomous Debt Sweeps (Opt-In)

After a successful pipeline run, an optional cleanup stage addresses accumulated
technical debt from `NON_BLOCKING_LOG.md` using the jr coder model (low cost):

```bash
CLEANUP_ENABLED=true
CLEANUP_BATCH_SIZE=5          # Items per sweep
CLEANUP_TRIGGER_THRESHOLD=5   # Min items before triggering
```

Items requiring architectural changes are tagged `[DEFERRED]` and skipped. Build gate
failure in cleanup logs a warning but doesn't fail the overall run.

## Metrics Dashboard

Track pipeline performance across runs with `--metrics`:

```bash
tekhton --metrics
```

```
Tekhton Metrics — last 20 runs
────────────────────────────────
Bug fixes:     12 runs, avg 22 coder turns, 92% success
Features:       6 runs, avg 45 coder turns, 83% success
Milestones:     2 runs, avg 85 coder turns, 100% success
────────────────────────────────
Scout accuracy: coder ±8 turns, reviewer ±2, tester ±5
Common blocker: "Missing test coverage" (4 occurrences)
Cleanup sweep:  15 items resolved, 3 deferred
```

Metrics are recorded automatically in `.claude/logs/metrics.jsonl`. When enough
history accumulates (`METRICS_MIN_RUNS=5`), adaptive calibration uses your project's
actual data to improve scout turn estimates.

## Context Management

The pipeline tracks how much context is injected into each agent call and enforces
a configurable budget to prevent context window overflow:

- `CONTEXT_BUDGET_PCT=50` — max percentage of the model's context window to use
- `CONTEXT_COMPILER_ENABLED=true` — task-scoped context assembly, injecting only
  relevant sections of large artifacts instead of full files

When context exceeds the budget, compression strategies are applied in priority order:
prior tester context → non-blocking notes → prior progress context. A note is injected
when compression occurs so agents are aware of the reduction.

## Clarification Protocol

Agents can surface blocking questions mid-run. The pipeline pauses, prompts you for
an answer, and resumes with the clarification injected into subsequent agent prompts:

```
┌─────────────────────────────────────┐
│ CLARIFICATION REQUIRED              │
│                                     │
│ [BLOCKING] Should the API use JWT   │
│ or session-based auth?              │
└─────────────────────────────────────┘
Your answer:
```

Non-blocking clarifications are logged without pausing. Disable with
`CLARIFICATION_ENABLED=false`.

## Project Crawling & Tech Stack Detection

Tekhton can index brownfield projects for context-aware operations:

- **Tech stack detection** — automatically identifies languages, frameworks, entry
  points, and infers build/test/lint commands from manifest files and tooling
- **Project crawler** — generates `.claude/index/` (structured data: `meta.json`,
  `inventory.jsonl`, `dependencies.json`, `configs.json`, `tests.json`, per-file
  `samples/`) and a bounded human-readable `PROJECT_INDEX.md` view, both configurable
  via `PROJECT_INDEX_BUDGET`

Used by `--init` to auto-populate `pipeline.conf` and by `--replan` to produce
higher-quality document updates.

## CLI Reference

| Flag | Purpose |
|------|---------|
| `--init` | Smart init — detect stack, generate config, agent roles, and dashboard |
| `--init --full` | Run init + synthesis (DESIGN.md + CLAUDE.md) in one command |
| `--reinit` | Re-initialize, preserving existing config while adding new defaults |
| `--plan` | Interactive planning — generates DESIGN.md and CLAUDE.md |
| `--plan --answers <f>` | Import pre-filled YAML answers, skip interview |
| `--plan-browser` | Browser-based planning interview form |
| `--export-questions` | Export planning questions as YAML template to stdout |
| `--plan-from-index` | Synthesize DESIGN.md + CLAUDE.md from PROJECT_INDEX.md |
| `--replan` | Delta-based update of DESIGN.md and CLAUDE.md from current codebase |
| `--complete` | Autonomous loop — retry pipeline until task passes or bounds exhausted |
| `--milestone` | Milestone mode — higher turns, extra review, acceptance checking |
| `--auto-advance` | Chain milestones autonomously (implies `--milestone`) |
| `--add-milestone "desc"` | Create a scoped milestone via the intake agent (no run) |
| `--human [TAG]` | Pick next note from HUMAN_NOTES.md as task (optional: BUG, FEAT, POLISH) |
| `--with-notes` | Force human notes injection regardless of task text |
| `--notes-filter TAG` | Inject only notes matching TAG (BUG, FEAT, POLISH) |
| `--triage [TAG]` | Triage all unchecked notes (size estimate) without running |
| `--dry-run` | Preview mode — run scout + intake only, show what would happen |
| `--continue-preview` | Resume from a previous `--dry-run` (uses cached results) |
| `--start-at STAGE` | Resume from: `intake`, `coder`, `security`, `review`, `tester`, `test` |
| `--skip-security` | Bypass security review stage for a single run |
| `--skip-docs` | Bypass docs agent stage for a single run |
| `--skip-audit` | Skip architect audit even if thresholds exceeded |
| `--force-audit` | Run architect audit regardless of thresholds |
| `--no-commit` | Skip auto-commit (prompt instead) |
| `--usage-threshold N` | Pause if session usage exceeds N% |
| `--rollback` | Revert the last pipeline run (clean git operations; `--check` to preview) |
| `--status` | Print saved pipeline state (includes rollback availability) |
| `--metrics` | Print run metrics dashboard and exit |
| `--diagnose` | Analyze last failure and suggest recovery steps |
| `--report` | Print summary of the last pipeline run |
| `--health` | Run standalone project health assessment |
| `--audit-tests` | Audit ALL test files for integrity issues |
| `--fix-nonblockers` | Address all open non-blocking notes |
| `--fix-drift` | Force architect audit to resolve drift observations |
| `--rescan` | Update PROJECT_INDEX.md incrementally (add `--full` for full re-crawl) |
| `--migrate` | Upgrade project config to current Tekhton version (`--check`, `--status`, `--rollback`) |
| `--migrate-dag` | Convert inline milestones to DAG file format |
| `--setup-indexer` | Install Python virtualenv for tree-sitter indexer (`--with-lsp` for Serena) |
| `--setup-completion` | Install shell completions for your shell |
| `--update` | Check for and install updates (`--check` to report only) |
| `--uninstall` | Remove Tekhton installation |
| `--docs` | Open documentation site in browser |
| `--version`, `-v` | Print version and exit |
| `--help` | Show usage information (`--help --all` for full flag list) |
| `note "text"` | Add a note to HUMAN_NOTES.md (with `--tag TAG`, `--list`, `--done`, `--clear`) |

Running `tekhton` with no arguments checks for saved pipeline state and offers to resume.

## Configuration

Edit `.claude/pipeline.conf` in your project. A minimal config:

```bash
PROJECT_NAME="My App"
ANALYZE_CMD="cargo clippy -- -D warnings"
TEST_CMD="cargo test"
BUILD_CHECK_CMD="cargo check"
```

Key configuration areas:

| Category | Key Examples | Notes |
|----------|-------------|-------|
| **Models** | `CLAUDE_CODER_MODEL`, `CLAUDE_STANDARD_MODEL`, etc. | One model per agent role |
| **Turn limits** | `CODER_MAX_TURNS=35`, `REVIEWER_MAX_TURNS=10` | Per-stage limits |
| **Dynamic turns** | `DYNAMIC_TURNS_ENABLED=true` | Scout adjusts limits based on complexity |
| **Turn bounds** | `CODER_MIN_TURNS=15`, `CODER_MAX_TURNS_CAP=200` | Clamp scout recommendations |
| **Milestone overrides** | `MILESTONE_CODER_MAX_TURNS=100` | Custom limits for `--milestone` |
| **Autonomous loop** | `MAX_PIPELINE_ATTEMPTS=5`, `AUTONOMOUS_TIMEOUT=7200` | `--complete` bounds |
| **Continuation** | `CONTINUATION_ENABLED=true`, `MAX_CONTINUATION_ATTEMPTS=3` | Turn-exhaustion resume |
| **Transient retry** | `TRANSIENT_RETRY_ENABLED=true`, `MAX_TRANSIENT_RETRIES=3` | API error recovery |
| **Milestone splitting** | `MILESTONE_SPLIT_ENABLED=true`, `MILESTONE_AUTO_RETRY=true` | Auto-decomposition |
| **Build & analysis** | `BUILD_CHECK_CMD`, `ANALYZE_CMD`, `TEST_CMD` | Your project's toolchain |
| **Drift thresholds** | `DRIFT_OBSERVATION_THRESHOLD=8` | When to trigger architect audit |
| **Agent resilience** | `AGENT_ACTIVITY_TIMEOUT=600`, `AGENT_TIMEOUT=7200` | Timeout controls |
| **Context** | `CONTEXT_BUDGET_PCT=50`, `CONTEXT_COMPILER_ENABLED=false` | Token budget management |
| **Specialists** | `SPECIALIST_SECURITY_ENABLED=false`, etc. | Opt-in focused reviews |
| **Cleanup** | `CLEANUP_ENABLED=false`, `CLEANUP_BATCH_SIZE=5` | Autonomous debt sweeps |
| **Metrics** | `METRICS_ENABLED=true`, `METRICS_ADAPTIVE_TURNS=true` | Run history & calibration |
| **Clarifications** | `CLARIFICATION_ENABLED=true` | Mid-run human Q&A |
| **Role files** | `CODER_ROLE_FILE=".claude/agents/coder.md"` | Agent persona definitions |
| **Planning** | `PLAN_INTERVIEW_MODEL="opus"` | Planning phase model/turn config |
| **Security agent** | `SECURITY_AGENT_ENABLED=true`, `SECURITY_BLOCK_SEVERITY=HIGH` | Dedicated security stage |
| **Docs agent** | `DOCS_AGENT_ENABLED=false`, `DOCS_AGENT_MODEL=claude-haiku-4-5-20251001` | Optional docs maintenance stage |
| **Intake agent** | `INTAKE_AGENT_ENABLED=true`, `INTAKE_CLARITY_THRESHOLD=40` | Task clarity/scope gate |
| **Watchtower** | `DASHBOARD_ENABLED=true`, `DASHBOARD_REFRESH_INTERVAL=10` | Browser-based dashboard |
| **Health** | `HEALTH_ENABLED=true`, `HEALTH_SHOW_BELT=true` | Project health scoring |
| **Milestone DAG** | `MILESTONE_DAG_ENABLED=true`, `MILESTONE_WINDOW_PCT=30` | File-based milestones |
| **Repo map** | `REPO_MAP_ENABLED=false`, `REPO_MAP_TOKEN_BUDGET=2048` | Tree-sitter indexing |
| **Causal log** | `CAUSAL_LOG_ENABLED=true` | Structured event logging |
| **Test baseline** | `TEST_BASELINE_ENABLED=true`, `TEST_BASELINE_PASS_ON_PREEXISTING=true` | Pre-existing failure detection + completion gate hardening |
| **Tester fix** | `TESTER_FIX_ENABLED=false`, `FINAL_FIX_ENABLED=true`, `FINAL_FIX_MAX_ATTEMPTS=2` | Surgical fix mode on test failures |
| **Pre-flight** | `PREFLIGHT_ENABLED=true`, `PREFLIGHT_AUTO_FIX=true`, `PREFLIGHT_FAIL_ON_WARN=false` | Environment validation + auto-remediation |
| **UI specialist** | `SPECIALIST_UI_ENABLED=auto`, `UI_PLATFORM=auto` | Auto-on for UI projects; platform adapter selection |
| **Run memory** | `RUN_MEMORY_MAX_ENTRIES=50` | Cross-run JSONL learning store |
| **Pipeline order** | `PIPELINE_ORDER=standard` | `standard` or `test_first` (TDD) |

See [templates/pipeline.conf.example](templates/pipeline.conf.example) for the full annotated reference with all options and defaults.

## Security

Tekhton includes defense-in-depth hardening:

- **Safe config parsing** — `pipeline.conf` values containing `$(`, backticks, `;`, `|`, `&` are rejected (no shell injection via config)
- **Per-session temp files** — all temp files use `mktemp -d` in a session directory, not predictable paths
- **Pipeline locking** — only one instance runs per project (PID-validated lock file)
- **Anti-prompt-injection** — file content in agent prompts is wrapped in explicit delimiters; all agent system prompts include anti-injection directives
- **Git safety** — warns if `.gitignore` is missing `.env` or key patterns before `git add`
- **Sensitive data redaction** — API keys, auth tokens, and credentials are stripped from error reports, log summaries, and state files
- **Agent permissions** — each agent gets only the tools it needs; destructive operations (`git push`, `rm -rf`, `curl`, `wget`) are always blocked
- **Config bounds** — numeric config values are clamped to hard upper limits to prevent resource exhaustion

## Contributing

Bug reports and pull requests welcome. All `.sh` files must pass `shellcheck` with
zero warnings. Run self-tests with `bash tests/run_tests.sh`.

If you're working on Tekhton itself, you'll need **shellcheck** installed:

```bash
# Debian/Ubuntu/WSL2
sudo apt-get install -y shellcheck

# macOS
brew install shellcheck
```

## Changelog

### v3.71.0 — Structured Project Index & Code Quality (April 2026)

5 milestones (M67–M71) delivered after V3 feature-complete:

**Structured Project Index (M67–M69)**
- `crawl_project()` now emits a structured data layer to `.claude/index/` (`meta.json`,
  `tree.txt`, `inventory.jsonl`, `dependencies.json`, `configs.json`, `tests.json`,
  `samples/`) alongside the human-readable `PROJECT_INDEX.md` view. All writes are
  atomic; `_list_tracked_files` is called exactly once per crawl (was 4×)
- New `lib/index_reader.sh` with a bounded reader API consumed by intake, synthesis,
  and replan — fixing three silent pre-existing bugs: intake was receiving empty project
  context for any project >8KB; synthesis was compressing the index down to headings
  only; replan was injecting the full raw 120KB+ file into the context window
- New `lib/index_view.sh` generates `PROJECT_INDEX.md` from structured data via record
  selection (not string truncation) — the `... (truncated to fit budget)` marker is
  gone; the ARG_MAX-risk `_replace_section` and `_truncate_section` functions are
  deleted; legacy projects auto-migrate on first rescan or crawl
- `PROJECT_INDEX_BUDGET` config key replaces hardcoded `120000` at all call sites

**Code Quality & Prompt Engineering (M70–M71)**
- Mandatory Step 5 pre-completion self-check in `prompts/coder.prompt.md` — file
  length (`wc -l` on every touched file), stale references after renames, dead code,
  and new-file consistency checks. Targets the ~60% of non-blocking reviewer findings
  the coder could catch itself
- `.claude/agents/coder.md` gains a `### Shell Hygiene` section with concrete patterns:
  `grep || true` under `set -e`, SC2155 two-line `local`, `--` option terminator,
  sourced-file `set -euo pipefail` prohibition, and the 300-line file ceiling

### v3.66 — Context-Aware Pipeline (April 2026)

66 milestones delivered across the V3 initiative. Key changes by theme:

**Milestone DAG & Context (M01–M08)**
- File-based milestones with `MANIFEST.cfg` dependency tracking and parallel groups
- Sliding context window — only active + frontier milestones injected into prompts
- Automatic migration from inline CLAUDE.md milestones (`--migrate-dag`)
- Tree-sitter repo maps with PageRank ranking and token-budgeted output
- Task-relevant context slicing per pipeline stage (scout, coder, reviewer, tester)
- Cross-run file association tracking for personalized ranking
- Optional Serena LSP integration via MCP for live symbol lookup
- Indexer tests, documentation, and setup tooling

**Quality & Safety Stages (M09–M10, M20, M28–M30)**
- Dedicated security agent stage with OWASP-aware scanning, severity scoring, and auto-remediation
- Task intake / PM agent with clarity scoring, scope assessment, and task decomposition
- Test integrity audit (`--audit-tests`) for catching weak/skipped tests
- UI test awareness, E2E prompt integration, and a UI validation gate with headless smoke testing
- Build gate hardening with hang prevention, timeout enforcement, and process tree cleanup

**Watchtower Dashboard (M13–M14, M34–M38, M66)**
- Browser-based pipeline monitoring with Live Run, Milestone Map, Reports, Trends, and Security Summary tabs
- Data fidelity passes, smart refresh, context-aware layout, and action items severity colors
- Interactive controls, parallel teams readiness (V4 prep)
- Live Run + Milestone Map UX polish, full-stage metrics with hierarchical breakdown

**Brownfield Intelligence (M11–M12, M15, M22)**
- Deep analysis during `--init`: workspace, service, CI/CD, and infrastructure detection
- AI artifact detection with archive, tidy, and ignore handling modes
- Documentation quality assessment and test framework detection
- Project health scoring with five-category assessment and belt ratings
- Init UX overhaul

**Developer Experience (M16–M19, M21, M23–M27, M52)**
- Autonomous runtime improvements
- Pipeline diagnostics (`--diagnose`) with structured recovery suggestions
- Documentation site, distribution & install experience
- Version migration framework (`--migrate`)
- Dry-run preview (`--dry-run`) and `--continue-preview`
- Run safety net + `--rollback` for reverting pipeline runs
- Human notes UX enhancement, `note` subcommand for managing HUMAN_NOTES.md from the CLI
- Express mode — zero-config execution when no `pipeline.conf` exists (bash 4.3+ still required; macOS needs Homebrew bash)
- TDD support (`PIPELINE_ORDER=test_first`) — tester runs before coder
- Onboarding flow fix — repaired the circular `--init` ↔ `--plan` handoff

**Planning UX (M31–M32)**
- Planning answer layer + file mode (YAML import via `--plan --answers`)
- Browser-based planning interview (`--plan-browser`) with answer persistence

**Notes Pipeline Rewrite (M33, M39–M42)**
- Human mode completion loop & state fidelity
- Notes injection hygiene + action items UX
- Notes core rewrite with triage & sizing gate
- Tag-specialized execution paths (BUG/FEAT/POLISH)

**Acceleration & Telemetry (M43–M50)**
- Test-aware coding with jr coder test-fix gate
- Scout prompt leverages repo map & Serena
- Instrumentation & timing report (per-stage, per-agent)
- Intra-run context cache to avoid redundant file reads
- Reduced unnecessary agent invocations via smarter skip logic
- Structured run memory (JSONL) for cross-run learning with keyword filtering
- Progress transparency with timing estimates from run history
- Causal event log (JSONL) for structured debugging
- V3 documentation & README finalization (M51)

**Environment Intelligence (M53–M56)**
- Error pattern registry with build gate classification
- Auto-remediation engine for cataloged failure patterns
- Pre-flight environment validation with optional auto-fix
- Service readiness probing & enhanced diagnosis

**UI/UX Design Intelligence (M57–M60)**
- UI platform adapter framework — file-based adapters in `platforms/`
- Web UI platform adapter — Tailwind, MUI, shadcn, Chakra, Bootstrap detection
- UI/UX specialist reviewer — auto-on for UI projects with 8-category checklist
- Mobile & game platform adapters — Flutter, SwiftUI/UIKit, Jetpack Compose, Phaser/PixiJS/Three.js/Babylon.js

**Final Polish (M61–M66)**
- Repo map cross-stage cache for indexer reuse
- Tester timing instrumentation
- Test baseline hygiene & completion gate hardening
- Tester fix surgical mode — scoped fix agents on failures
- Prompt tool awareness — Serena & repo map coverage in agent prompts
- Watchtower full-stage metrics & hierarchical breakdown

### v2.21.0 — Adaptive Pipeline (March 2026)

21 milestones: autonomous operation (`--complete`, `--auto-advance`, `--human`),
transient error retry, turn-exhaustion continuation, milestone auto-split, context
budgeting, specialist reviews, autonomous debt sweeps, error taxonomy, metrics
dashboard, brownfield init/replan, clarification protocol, security hardening.

### v1.0 — Foundation (March 2026)

Core pipeline (Scout → Coder → Reviewer → Tester), dynamic turn limits, architecture
drift detection, build gates, `--plan` interactive planning, human notes, pipeline
state persistence, FIFO-isolated agent invocation, `--milestone` mode.

## License

MIT
