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
│   └── drift.sh            # Drift log, ADL, human action management
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   └── tester.sh           # Stage 3: Test writing + validation
├── prompts/                # Prompt templates with {{VAR}} substitution
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
│   └── seed_contracts.prompt.md
├── templates/              # Templates copied into target projects by --init
│   ├── pipeline.conf.example
│   ├── coder.md
│   ├── reviewer.md
│   ├── tester.md
│   └── jr-coder.md
├── tests/                  # Self-tests
└── examples/               # Example project configs
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
