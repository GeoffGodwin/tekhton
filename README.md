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

## License

MIT
