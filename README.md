<div align="center">
  <img src="assets/tekhton-logo.svg" alt="Tekhton" width="120" />

  <h1>Tekhton</h1>

  <p><strong>One intent. Many hands.</strong></p>

  <p><em>v2.0 — Adaptive Pipeline</em></p>
</div>

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on the [Claude CLI](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/cli-usage).
Give it a task description and it orchestrates a **Scout → Coder → Reviewer → Tester** cycle
with automatic rework routing, build gates, dynamic turn limits, architecture drift
prevention, transient error retry, turn-exhaustion continuation, milestone splitting,
state persistence, and resume support — or hand it `--complete` and walk away.

## What's New in v2.0

Tekhton 2.0 makes the pipeline **adaptive** — aware of its own context economics,
capable of milestone-to-milestone progression, able to interrupt itself when
assumptions break, and able to improve from its own run history. All v2 features
are additive or opt-in; existing v1 workflows remain unchanged.

**Highlights:**

- **`--complete` autonomous loop** — wraps the entire pipeline in an outer loop that retries until the task passes acceptance or recovery options are exhausted
- **`--auto-advance` milestone chaining** — after each milestone passes acceptance, the pipeline advances to the next automatically
- **`--human` notes mode** — pick the next item from `HUMAN_NOTES.md` as the task; combine with `--complete` to process all notes in batch
- **`--replan` brownfield replanning** — delta-based update of DESIGN.md and CLAUDE.md from accumulated drift and codebase evolution
- **`--metrics` dashboard** — run history, per-task-type averages, scout accuracy, and adaptive turn calibration
- **`--init` brownfield intelligence** — auto-detects tech stack, crawls the project, and generates production-quality CLAUDE.md and DESIGN.md from codebase evidence
- **Transient error retry** — API errors (500, 429, 529), OOM kills, and network failures trigger automatic retry with exponential backoff
- **Turn-exhaustion continuation** — agents that hit their turn limit with substantive progress are automatically re-invoked with a fresh budget
- **Milestone auto-split** — oversized milestones are automatically decomposed into sub-milestones and retried
- **Context budgeting** — token accounting prevents context window overflow with configurable compression strategies
- **Specialist reviews** — opt-in security, performance, and API contract review passes after the main reviewer approves
- **Autonomous debt sweeps** — post-success cleanup stage addresses non-blocking technical debt automatically
- **Error taxonomy** — structured error classification with transience detection, recovery suggestions, and sensitive data redaction
- **Security hardening** — safe config parsing, per-session temp files, prompt injection mitigation, git safety checks
- **Milestone archival** — completed milestones are automatically archived from CLAUDE.md to keep it under context limits
- **Post-coder turn recalibration** — reviewer/tester turn limits are recalculated using actual coder data instead of scout guesses

## Requirements

- **Bash 4+** — Linux, macOS, or WSL2 (Git Bash also supported)
- **Claude CLI** — authenticated and on `PATH` (`claude --version` should work)
- **Git** — used for commit integration
- **Python 3** — used for JSON parsing of agent output
- **Your project's build/test tools** — configured via `ANALYZE_CMD`, `TEST_CMD`, `BUILD_CHECK_CMD`

## Quick Start

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
│   └── logs/                  # Run logs, metrics (gitignored)
├── CLAUDE.md                  # Project rules (read by all agents)
├── CODER_SUMMARY.md           # (generated per-run)
├── REVIEWER_REPORT.md         # (generated per-run)
└── TESTER_REPORT.md           # (generated per-run)
```

## How the Pipeline Works

```
tekhton "Implement feature X"
        │
        ├─ Pre-stage 1: Task intake (clarity evaluation)
        ├─ Pre-stage 2: Architect audit (conditional — drift thresholds)
        │
        ├─ Stage 1: Scout + Coder
        │    ├─ Scout → estimates complexity, adjusts turn limits
        │    ├─ Coder → writes code + CODER_SUMMARY.md
        │    ├─ Turn continuation → auto-resume if coder hits turn limit with progress
        │    └─ Build gate → auto-fix on failure (Jr → Sr escalation)
        │
        ├─ Stage 2: Reviewer
        │    ├─ Reviewer → REVIEWER_REPORT.md
        │    ├─ Complex blockers → Senior coder rework
        │    ├─ Simple blockers → Jr coder fix
        │    ├─ Build gate after fixes
        │    ├─ Specialist reviews (security, performance, API — opt-in)
        │    └─ (repeats up to MAX_REVIEW_CYCLES)
        │
        ├─ Stage 3: Tester
        │    └─ Writes tests for coverage gaps → TESTER_REPORT.md
        │
        ├─ Stage 4: Cleanup (opt-in — autonomous debt sweep)
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
| Jr Coder | Haiku | Simple fixes, build repairs, debt sweeps |
| Scout | Haiku | File discovery, complexity estimation |
| Reviewer | Sonnet | Code review, drift observation |
| Architect | Sonnet | Drift audit, remediation planning |
| Tester | Haiku (Sonnet in `--milestone`) | Test writing and validation |
| Specialists | Sonnet | Security, performance, API reviews (opt-in) |

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

## Specialist Reviews (Opt-In)

After the main reviewer approves, optional specialist agents can run focused review passes:

- **Security** — injection risks, auth bypass, secrets exposure, input validation
- **Performance** — N+1 queries, unbounded loops, memory leaks, expensive operations
- **API contracts** — schema consistency, error format compliance, backward compatibility

`[BLOCKER]` findings re-enter the rework loop. `[NOTE]` findings go to `NON_BLOCKING_LOG.md`.

Enable per specialist in `pipeline.conf`:
```bash
SPECIALIST_SECURITY_ENABLED=true
SPECIALIST_PERFORMANCE_ENABLED=true
SPECIALIST_API_ENABLED=true
```

Custom specialists are supported via `SPECIALIST_CUSTOM_*` config keys with your own prompt templates.

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
- **Project crawler** — generates `PROJECT_INDEX.md` with file inventory, directory
  tree, dependency analysis, and sampled key file content, bounded to a configurable
  token budget

Used by `--init` to auto-populate `pipeline.conf` and by `--replan` to produce
higher-quality document updates.

## CLI Reference

| Flag | Purpose |
|------|---------|
| `--plan` | Interactive planning — generates DESIGN.md and CLAUDE.md |
| `--replan` | Delta-based update of DESIGN.md and CLAUDE.md from current codebase |
| `--init` | Scaffold pipeline config and agent roles for a new project |
| `--init-notes` | Create blank HUMAN_NOTES.md template |
| `--complete` | Autonomous loop — retry pipeline until task passes or bounds exhausted |
| `--milestone` | Milestone mode — 2× turns, extra review, acceptance checking (implies `--complete`) |
| `--auto-advance` | Chain milestones autonomously (implies `--milestone`) |
| `--human [TAG]` | Pick next note from HUMAN_NOTES.md as task (optional: BUG, FEAT, POLISH) |
| `--start-at coder` | Full pipeline (default) |
| `--start-at review` | Skip coder, start at reviewer (requires CODER_SUMMARY.md) |
| `--start-at test` | Skip to tester (requires REVIEWER_REPORT.md) |
| `--start-at tester` | Resume incomplete tester from TESTER_REPORT.md |
| `--notes-filter BUG` | Only inject `[BUG]` tagged human notes |
| `--force-audit` | Run architect audit regardless of thresholds |
| `--skip-audit` | Skip architect audit even if thresholds exceeded |
| `--seed-contracts` | Seed inline system contracts in source files |
| `--no-commit` | Skip auto-commit (prompt instead) |
| `--metrics` | Print run metrics dashboard and exit |
| `--status` | Print saved pipeline state and exit |
| `--version`, `-v` | Print version and exit |
| `--help` | Show usage information |

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

### v2.0 — Adaptive Pipeline (March 2026)

22 milestones delivered across the Adaptive Pipeline initiative. Key changes by category:

**Autonomous Operation**
- Outer orchestration loop (`--complete`) with safety bounds: max pipeline attempts, wall-clock timeout, agent call limits, stuck-detection
- Milestone state machine with acceptance checking and `--auto-advance` for multi-milestone chaining
- `--human` mode for processing `HUMAN_NOTES.md` items as tasks, with batch support via `--complete`
- Turn-exhaustion continuation — agents that hit turn limits with progress automatically get a fresh budget (up to 3 continuations)
- Pre-flight milestone sizing gate with automatic splitting when scope exceeds turn budget
- Null-run auto-split — failed milestone attempts trigger decomposition and retry without human intervention

**Resilience & Error Handling**
- Transient error retry with exponential backoff (30s → 60s → 120s) for API 500/429/529, OOM, and network failures
- Error taxonomy with 4 top-level categories (UPSTREAM, ENVIRONMENT, AGENT_SCOPE, PIPELINE) and structured classification
- Sensitive data redaction in error reports, log summaries, and state files
- File-change activity detection prevents false kills when agents work silently (JSON output mode)
- Real-time API error detection in FIFO monitoring stream
- Structured error reporting boxes with Unicode/ASCII fallback

**Context & Intelligence**
- Token accounting — character counts, estimated tokens, and context window percentage for every agent call
- Context compiler — task-scoped context assembly injects only relevant sections instead of full files
- Context budget enforcement with configurable compression strategies (truncate, summarize headings, omit)
- Post-coder turn recalibration — reviewer/tester limits recalculated from actual coder turns, files modified, and diff size
- Adaptive turn calibration from run history when enough data accumulates

**Brownfield Intelligence**
- Tech stack detection engine — identifies languages, frameworks, entry points, and infers build/test/lint commands
- Project crawler & index generator — produces `PROJECT_INDEX.md` with file inventory, dependency analysis, and sampled key files
- Incremental rescan — only processes files changed since last scan via `git diff`
- Agent-assisted project synthesis — generates CLAUDE.md and DESIGN.md from codebase evidence
- `--init` now auto-detects tech stack and populates `pipeline.conf` intelligently for brownfield projects

**Review & Quality**
- Specialist review framework — opt-in security, performance, and API contract review passes
- Custom specialist support via `SPECIALIST_CUSTOM_*` config convention
- Autonomous debt sweeps — post-success cleanup stage addresses `NON_BLOCKING_LOG.md` items using jr coder model
- Mid-run clarification protocol — agents surface blocking questions, pipeline pauses for human input
- Brownfield replan (`--replan`) — delta-based DESIGN.md and CLAUDE.md updates from codebase drift

**Metrics & Observability**
- Run metrics collection to `.claude/logs/metrics.jsonl` with per-stage turns, timing, and outcomes
- `--metrics` dashboard with per-task-type averages, scout accuracy, error breakdown
- Structured agent run summary blocks appended to log files (tail-friendly diagnostics)
- Milestone commit signatures (`[MILESTONE N ✓]` / `[MILESTONE N — partial]`) in git history
- Milestone archival to `MILESTONE_ARCHIVE.md` — keeps CLAUDE.md under context limits

**Security**
- Safe config parsing — rejects `$(`, backticks, `;`, `|`, `&` in config values
- Per-session temp directory via `mktemp -d` with signal-trapped cleanup
- Pipeline locking — PID-validated lock file prevents concurrent runs
- Anti-prompt-injection directives in all agent system prompts
- File content delimiters in prompts mark untrusted content boundaries
- Git safety — warns if `.gitignore` is missing `.env` or key patterns
- Config bounds — numeric values clamped to hard upper limits
- Sensitive data redaction in error reports and state files

**Pipeline Lifecycle**
- Notes gating with flag-only claiming and `--human` orchestration
- Consolidated `finalize_run()` hook sequence
- Single-note utility functions for note selection and resolution
- Resolved note cleanup for `NON_BLOCKING_LOG.md`
- `AUTO_COMMIT` conditional default behavior

### v1.0 — Foundation (March 2026)

- Scout → Coder → Reviewer → Tester multi-agent pipeline
- Dynamic turn limits via Scout complexity estimation
- Architecture drift detection, ACPs, and architect audit remediation
- Build gate with Jr → Sr coder escalation
- `--plan` interactive planning with three-phase interview
- Deep design doc templates (15–25 sections per project type)
- CLAUDE.md generation with 12 mandated sections
- Human notes injection with `[BUG]`, `[FEAT]`, `[POLISH]` tags
- Pipeline state persistence and resume support
- FIFO-isolated agent invocation with activity timeout
- Null-run detection and Windows compatibility
- Dependency constraint validation (Dart, Python, TypeScript)
- `--milestone` mode with 2× turn limits and upgraded tester model

## License

MIT
