# Tekhton

**One intent. Many hands.**

Tekhton is a multi-agent development pipeline built on the [Claude CLI](https://docs.anthropic.com/en/docs/build-with-claude/claude-code/cli-usage).
Give it a task description and it orchestrates a Coder → Reviewer → Tester cycle
with automatic rework routing, build gates, and resume support.

## Quick Start

```bash
# Clone Tekhton
git clone https://github.com/youruser/tekhton.git
cd tekhton && chmod +x tekhton.sh

# Initialize a project
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

## What Happens When You Run It

```
tekhton "Implement feature X"
        │
        ├─ Scout (if HUMAN_NOTES.md has items)
        ├─ Coder → writes code + CODER_SUMMARY.md
        │    └─ Build gate → auto-fix on failure
        │
        ├─ Reviewer → REVIEWER_REPORT.md
        │    ├─ Complex blockers → Senior coder rework
        │    ├─ Simple blockers → Jr coder fix
        │    └─ Build gate after fixes
        │    (repeats up to MAX_REVIEW_CYCLES)
        │
        ├─ Tester → TESTER_REPORT.md
        │    └─ Writes tests for coverage gaps
        │
        └─ Commit prompt with auto-generated message
```

## Features

- **Three-agent pipeline**: Coder, Reviewer, Tester — each with distinct models and turn limits
- **Automatic rework routing**: Complex blockers → senior coder, simple → jr coder
- **Build gates**: Compile check after coding and after each rework pass
- **Resume support**: Pipeline state saved on interruption, resume with no args
- **Milestone mode**: `--milestone` for longer turns and more review cycles
- **Human notes**: Write `HUMAN_NOTES.md` between runs to inject bug reports/features
- **Architecture drift prevention**: Automatic detection, logging, and remediation of architectural drift
- **Architect audit agent**: Conditional Stage 0 that reviews accumulated drift and routes fixes
- **Dependency constraints**: Optional deterministic layer-boundary enforcement in build gate
- **Config-driven**: All models, turn limits, commands, and paths in `pipeline.conf`
- **Template engine**: Prompt templates with `{{VAR}}` substitution and `{{IF:VAR}}` conditionals

## Requirements

- **Bash 4+** (Linux, macOS, WSL2)
- **Claude CLI** authenticated and on PATH
- **Git** for commit integration
- Your project's build/test tools (configured in `pipeline.conf`)

## Project Structure After `--init`

```
your-project/
├── .claude/
│   ├── pipeline.conf          # Pipeline configuration
│   ├── agents/
│   │   ├── coder.md           # Coder role definition
│   │   ├── reviewer.md        # Reviewer role definition
│   │   ├── tester.md          # Tester role definition
│   │   └── jr-coder.md        # Jr coder role definition
│   └── logs/                  # Run logs (gitignored)
├── CLAUDE.md                  # Project rules (read by all agents)
├── CODER_SUMMARY.md           # (generated per-run)
├── REVIEWER_REPORT.md         # (generated per-run)
└── TESTER_REPORT.md           # (generated per-run)
```

## Key Flags

| Flag | Purpose |
|------|---------|
| `--init` | First-time project setup |
| `--milestone` | Higher turn limits, more review cycles |
| `--start-at review` | Skip coder, start at reviewer |
| `--start-at test` | Skip coder + reviewer, start at tester |
| `--start-at tester` | Resume incomplete tester run |
| `--notes-filter BUG` | Only inject `[BUG]` tagged notes |
| `--status` | Print saved pipeline state |
| `--seed-contracts` | Seed inline system contracts in source |

## Configuration

Edit `.claude/pipeline.conf` in your project:

```bash
PROJECT_NAME="My App"
ANALYZE_CMD="cargo clippy -- -D warnings"
TEST_CMD="cargo test"
BUILD_CHECK_CMD="cargo check"
CLAUDE_CODER_MODEL="claude-opus-4-6"
MAX_REVIEW_CYCLES=2
```

See [templates/pipeline.conf.example](templates/pipeline.conf.example) for all options.

## Architecture Drift Prevention

Tekhton automatically detects and manages architectural drift across pipeline runs.

### How It Works

1. **Reviewer observes drift**: During code review, the reviewer notes naming inconsistencies, layer violations, dead code, or stale patterns in a `## Drift Observations` section of `REVIEWER_REPORT.md`.

2. **Observations accumulate**: After each run, `DRIFT_LOG.md` collects unresolved observations with timestamps and task context.

3. **Audit triggers**: When unresolved observations exceed `DRIFT_OBSERVATION_THRESHOLD` (default: 8) or runs since last audit exceed `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` (default: 5), the Architect agent activates.

4. **Architect remediates**: The Architect reads the drift log, architecture doc, and decision log, then produces `ARCHITECT_PLAN.md` with categorized remediation items — routing Simplification tasks to the senior coder and Staleness/Dead Code/Naming tasks to the jr coder.

5. **Observations resolve**: After successful remediation, addressed observations are marked RESOLVED in the drift log.

### Architecture Change Proposals (ACPs)

When the coder needs to make a structural change, they propose an ACP in `CODER_SUMMARY.md`. The reviewer evaluates it and marks ACCEPT or REJECT. Accepted ACPs are recorded in `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs, creating an institutional memory of *why* the architecture evolved.

### Human Action Required

When the pipeline detects contradictions between the design document and the code, it creates `HUMAN_ACTION_REQUIRED.md` with actionable items. A banner displays at every pipeline completion until all items are resolved. This file is for design doc updates that the pipeline cannot make autonomously.

### Drift Configuration

```bash
# In pipeline.conf:
DRIFT_LOG_FILE="DRIFT_LOG.md"                  # Observation accumulation
ARCHITECTURE_LOG_FILE="ARCHITECTURE_LOG.md"    # Accepted ACP records
HUMAN_ACTION_FILE="HUMAN_ACTION_REQUIRED.md"   # Items for human attention
DRIFT_OBSERVATION_THRESHOLD=8                  # Trigger audit at N observations
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD=5             # Trigger audit after N runs
DESIGN_FILE=""                                 # Design doc path (enables cross-referencing)
```

## Dependency Constraints

Optional deterministic enforcement of layer boundaries — no LLM judgment needed.

### Setup

1. Create an `architecture_constraints.yaml` in your project root defining layer rules and a `validation_command`:

```yaml
validation_command: ".claude/scripts/check_imports.sh"

layers:
  - name: "engine/rules"
    description: "Pure rule evaluation"
    may_depend_on: ["engine/state", "core/config"]
    must_not_depend_on: ["features", "persistence"]
```

2. Create a validation script (see `examples/` for Dart, Python, TypeScript starters):

```bash
cp /path/to/tekhton/examples/check_imports_dart.sh .claude/scripts/check_imports.sh
chmod +x .claude/scripts/check_imports.sh
# Edit RULES array for your project's layers
```

3. Enable in `pipeline.conf`:

```bash
DEPENDENCY_CONSTRAINTS_FILE="architecture_constraints.yaml"
```

The build gate will now run your validation script after analyze and compile checks. Nonzero exit = build failure. The architect agent also reads the constraint file during audits to verify observations against declared rules.

## Architect Agent

The Architect is a conditional Stage 0 that runs *before* the main task when drift thresholds are exceeded (or when `--force-audit` is passed).

```
tekhton --force-audit "Implement feature X"
        │
        ├─ Stage 0: Architect audit
        │    ├─ Read drift log + architecture doc + decision log
        │    ├─ Produce ARCHITECT_PLAN.md
        │    ├─ Route Simplification → senior coder
        │    ├─ Route Staleness/Dead Code/Naming → jr coder
        │    ├─ Build gate
        │    ├─ Expedited review (single pass)
        │    └─ Resolve drift observations
        │
        ├─ Stage 1–3: Normal pipeline continues...
```

### Architect Flags

| Flag | Purpose |
|------|---------|
| `--force-audit` | Run architect audit regardless of thresholds |
| `--skip-audit` | Skip architect audit even if thresholds exceeded |

### Architect Configuration

```bash
ARCHITECT_ROLE_FILE=".claude/agents/architect.md"
ARCHITECT_MAX_TURNS=25
# MILESTONE_ARCHITECT_MAX_TURNS=50
# CLAUDE_ARCHITECT_MODEL=""        # Defaults to CLAUDE_STANDARD_MODEL
```

## Configuration Reference

All configuration lives in `.claude/pipeline.conf`. See [templates/pipeline.conf.example](templates/pipeline.conf.example) for the full annotated reference.

### Required Keys

| Key | Purpose |
|-----|---------|
| `PROJECT_NAME` | Display name |
| `REQUIRED_TOOLS` | CLI tools that must be on PATH |
| `CLAUDE_CODER_MODEL` | Model for senior coder |
| `CLAUDE_JR_CODER_MODEL` | Model for jr coder |
| `CLAUDE_STANDARD_MODEL` | Model for reviewer/tester |
| `CLAUDE_TESTER_MODEL` | Model for tester |
| `CODER_MAX_TURNS` | Senior coder turn limit |
| `JR_CODER_MAX_TURNS` | Jr coder turn limit |
| `REVIEWER_MAX_TURNS` | Reviewer turn limit |
| `TESTER_MAX_TURNS` | Tester turn limit |
| `MAX_REVIEW_CYCLES` | Review loop iterations |
| `ANALYZE_CMD` | Static analysis command |
| `TEST_CMD` | Test runner command |
| `PIPELINE_STATE_FILE` | Resume state path |
| `LOG_DIR` | Run log directory |
| `CODER_ROLE_FILE` | Coder role definition |
| `REVIEWER_ROLE_FILE` | Reviewer role definition |
| `TESTER_ROLE_FILE` | Tester role definition |
| `JR_CODER_ROLE_FILE` | Jr coder role definition |
| `PROJECT_RULES_FILE` | Project rules file (e.g. CLAUDE.md) |

### Optional Keys

| Key | Default | Purpose |
|-----|---------|---------|
| `PROJECT_DESCRIPTION` | `"multi-agent development pipeline"` | One-line description |
| `BUILD_CHECK_CMD` | `""` | Compile check (empty = skip) |
| `ARCHITECTURE_FILE` | `""` | Architecture doc path |
| `GLOSSARY_FILE` | `""` | Glossary doc path |
| `DESIGN_FILE` | `""` | Design doc (enables drift cross-referencing) |
| `DRIFT_LOG_FILE` | `"DRIFT_LOG.md"` | Drift observation log |
| `ARCHITECTURE_LOG_FILE` | `"ARCHITECTURE_LOG.md"` | Architecture decision log |
| `HUMAN_ACTION_FILE` | `"HUMAN_ACTION_REQUIRED.md"` | Human action items |
| `DRIFT_OBSERVATION_THRESHOLD` | `8` | Trigger audit at N observations |
| `DRIFT_RUNS_SINCE_AUDIT_THRESHOLD` | `5` | Trigger audit after N runs |
| `ARCHITECT_ROLE_FILE` | `".claude/agents/architect.md"` | Architect role |
| `ARCHITECT_MAX_TURNS` | `25` | Architect turn limit |
| `DEPENDENCY_CONSTRAINTS_FILE` | `""` | Constraint manifest (empty = skip) |
| `NOTES_FILTER_CATEGORIES` | `"BUG\|FEAT\|POLISH"` | Valid `--notes-filter` tags |
| `SEED_CONTRACTS_ENABLED` | `false` | Enable inline contract seeding |

## License

MIT
