<div align="center">
  <img src="assets/tekhton-logo.svg" alt="Tekhton" width="120" />

  <h1>Tekhton</h1>

  <p><strong>One intent. Many hands.</strong></p>
</div>

Tekhton is a standalone, project-agnostic multi-agent development pipeline built on the [Claude CLI](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/cli-usage).
Give it a task description and it orchestrates a **Scout → Coder → Reviewer → Tester** cycle
with automatic rework routing, build gates, dynamic turn limits, architecture drift
prevention, state persistence, and resume support.

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

# Run
/path/to/tekhton/tekhton.sh "Implement user authentication"

# Or create an alias
alias tekhton='/path/to/tekhton/tekhton.sh'
tekhton "Fix: login redirect loop"
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
│   └── logs/                  # Run logs (gitignored)
├── CLAUDE.md                  # Project rules (read by all agents)
├── CODER_SUMMARY.md           # (generated per-run)
├── REVIEWER_REPORT.md         # (generated per-run)
└── TESTER_REPORT.md           # (generated per-run)
```

## How the Pipeline Works

```
tekhton "Implement feature X"
        │
        ├─ Stage 0: Architect audit (conditional — drift thresholds)
        │
        ├─ Stage 1: Scout + Coder
        │    ├─ Scout → estimates complexity, adjusts turn limits
        │    ├─ Coder → writes code + CODER_SUMMARY.md
        │    └─ Build gate → auto-fix on failure (Jr → Sr escalation)
        │
        ├─ Stage 2: Reviewer
        │    ├─ Reviewer → REVIEWER_REPORT.md
        │    ├─ Complex blockers → Senior coder rework
        │    ├─ Simple blockers → Jr coder fix
        │    └─ Build gate after fixes
        │    (repeats up to MAX_REVIEW_CYCLES)
        │
        ├─ Stage 3: Tester
        │    └─ Writes tests for coverage gaps → TESTER_REPORT.md
        │
        ├─ Drift processing (observations, ACPs, non-blocking notes)
        └─ Commit prompt with auto-generated message
```

### Agent Models

Each agent runs on its own configurable model. Defaults:

| Agent | Default Model | Purpose |
|-------|--------------|---------|
| Coder | Opus | Primary implementation |
| Jr Coder | Haiku | Simple fixes, build repairs |
| Scout | Haiku | File discovery, complexity estimation |
| Reviewer | Sonnet | Code review, drift observation |
| Architect | Sonnet | Drift audit, remediation planning |
| Tester | Haiku (Sonnet in `--milestone`) | Test writing and validation |

### Dynamic Turn Limits

When `DYNAMIC_TURNS_ENABLED=true` (the default), the Scout agent estimates task
complexity before the Coder runs. The pipeline parses the estimate and adjusts
turn limits for Coder, Reviewer, and Tester — clamped to configured min/max bounds.

A simple bug fix might get 15 coder turns. A cross-cutting milestone might get 120.
This prevents wasting tokens on trivial tasks and running out of turns on large ones.

### Resume Support

Pipeline state is saved automatically on interruption. Running `tekhton` with no
arguments detects saved state and offers to resume, start fresh, or abort.
`--start-at` lets you jump to a specific stage if reports from earlier stages exist.

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

Each milestone is a standalone task: `tekhton "Implement Milestone 1: Project scaffold"`

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
to inject only bugs on a given run. Completed items are automatically archived.

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

Tekhton uses FIFO-isolated agent invocation to ensure reliable operation:

- **Interrupt handling** — Ctrl+C works immediately, even if the agent is hung. Claude runs in a background subshell writing to a named pipe; the foreground read loop exits on signal.
- **Activity timeout** — If an agent produces no output for 10 minutes (`AGENT_ACTIVITY_TIMEOUT`), it's killed automatically. Catches hung API connections and stuck retry loops.
- **Total timeout** — Hard wall-clock limit of 2 hours (`AGENT_TIMEOUT`) as a backstop.
- **Null-run detection** — Agents that die during discovery (≤2 turns, non-zero exit) are flagged. The pipeline handles the failure gracefully instead of continuing with no work done.
- **Windows compatibility** — Detects Windows-native `claude.exe` running via WSL interop or Git Bash and uses `taskkill.exe` for cleanup (Windows processes ignore POSIX signals).

## CLI Reference

| Flag | Purpose |
|------|---------|
| `--plan` | Interactive planning — generates DESIGN.md and CLAUDE.md |
| `--init` | Scaffold pipeline config and agent roles for a new project |
| `--init-notes` | Create blank HUMAN_NOTES.md template |
| `--milestone` | Milestone mode — 2× turn limits, more review cycles, Sonnet tester |
| `--start-at coder` | Full pipeline (default) |
| `--start-at review` | Skip coder, start at reviewer (requires CODER_SUMMARY.md) |
| `--start-at test` | Skip to tester (requires REVIEWER_REPORT.md) |
| `--start-at tester` | Resume incomplete tester from TESTER_REPORT.md |
| `--notes-filter BUG` | Only inject `[BUG]` tagged human notes |
| `--force-audit` | Run architect audit regardless of thresholds |
| `--skip-audit` | Skip architect audit even if thresholds exceeded |
| `--seed-contracts` | Seed inline system contracts in source files |
| `--status` | Print saved pipeline state and exit |
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
| **Build & analysis** | `BUILD_CHECK_CMD`, `ANALYZE_CMD`, `TEST_CMD` | Your project's toolchain |
| **Drift thresholds** | `DRIFT_OBSERVATION_THRESHOLD=8` | When to trigger architect audit |
| **Agent resilience** | `AGENT_ACTIVITY_TIMEOUT=600`, `AGENT_TIMEOUT=7200` | Timeout controls |
| **Role files** | `CODER_ROLE_FILE=".claude/agents/coder.md"` | Agent persona definitions |
| **Planning** | `PLAN_INTERVIEW_MODEL="opus"` | Planning phase model/turn config |

See [templates/pipeline.conf.example](templates/pipeline.conf.example) for the full annotated reference with all options and defaults.

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

## License

MIT
