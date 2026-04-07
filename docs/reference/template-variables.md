# Template Variables

Tekhton's prompt templates use `{{VAR}}` substitution. These variables are set by
the pipeline before rendering each prompt.

## How Templates Work

Prompt templates live in `prompts/*.prompt.md` in the Tekhton directory. They
use two constructs:

- **`{{VAR}}`** — Replaced with the variable's value
- **`{{IF:VAR}}...{{ENDIF:VAR}}`** — Block included only when VAR is non-empty

## Available Variables

### Project Context

| Variable | Source | Description |
|----------|--------|-------------|
| `PROJECT_DIR` | Runtime | Absolute path to the project directory |
| `PROJECT_NAME` | `pipeline.conf` | Project name |
| `TASK` | CLI argument | The task description |
| `DESIGN_FILE` | `pipeline.conf` | Design document path |
| `ARCHITECTURE_FILE` | `pipeline.conf` | Architecture document path |
| `ARCHITECTURE_CONTENT` | File read | Contents of the architecture file |

### Agent Role Files

| Variable | Source | Description |
|----------|--------|-------------|
| `CODER_ROLE_FILE` | `pipeline.conf` | Path to coder role definition |
| `REVIEWER_ROLE_FILE` | `pipeline.conf` | Path to reviewer role definition |
| `TESTER_ROLE_FILE` | `pipeline.conf` | Path to tester role definition |
| `JR_CODER_ROLE_FILE` | `pipeline.conf` | Path to junior coder role definition |
| `ARCHITECT_ROLE_FILE` | `pipeline.conf` | Path to architect role definition |

### Build & Analysis

| Variable | Source | Description |
|----------|--------|-------------|
| `ANALYZE_CMD` | `pipeline.conf` | Linter command |
| `TEST_CMD` | `pipeline.conf` | Test command |
| `BUILD_ERRORS_CONTENT` | File read | Contents of `BUILD_ERRORS.md` |
| `ANALYZE_ISSUES` | Runtime | Output of `ANALYZE_CMD` |

### Review Context

| Variable | Source | Description |
|----------|--------|-------------|
| `REVIEW_CYCLE` | Runtime | Current review iteration number |
| `MAX_REVIEW_CYCLES` | `pipeline.conf` | Max review iterations allowed |

### Human Input

| Variable | Source | Description |
|----------|--------|-------------|
| `HUMAN_NOTES_BLOCK` | File read | Unchecked items from `HUMAN_NOTES.md` |
| `HUMAN_NOTES_CONTENT` | File read | Raw filtered notes content |
| `HUMAN_MODE` | CLI flag | Set to `true` when `--human` flag is used |
| `HUMAN_NOTES_TAG` | CLI flag | Tag filter for `--human` (`BUG`, `FEAT`, `POLISH`) |
| `CLARIFICATIONS_CONTENT` | File read | Human answers from `CLARIFICATIONS.md` |

### Drift & Architecture

| Variable | Source | Description |
|----------|--------|-------------|
| `ARCHITECTURE_LOG_FILE` | `pipeline.conf` | Architecture decision log path |
| `DRIFT_LOG_FILE` | `pipeline.conf` | Drift log path |
| `ARCHITECTURE_LOG_CONTENT` | File read | Contents of architecture decision log |
| `DRIFT_LOG_CONTENT` | File read | Contents of drift log |
| `DRIFT_OBSERVATION_COUNT` | Runtime | Count of unresolved drift observations |
| `DEPENDENCY_CONSTRAINTS_CONTENT` | File read | Dependency constraint rules |

### Milestone Context

| Variable | Source | Description |
|----------|--------|-------------|
| `MILESTONE_WINDOW_PCT` | `pipeline.conf` | Context budget % for milestones |
| `MILESTONE_WINDOW_MAX_CHARS` | `pipeline.conf` | Hard cap on milestone chars |

### Repo Map (Indexer)

| Variable | Source | Description |
|----------|--------|-------------|
| `REPO_MAP_CONTENT` | Generated | Full repo map markdown |
| `REPO_MAP_SLICE` | Generated | Task-relevant subset of repo map |

### Planning Phase

| Variable | Source | Description |
|----------|--------|-------------|
| `PLAN_TEMPLATE_CONTENT` | File read | Design doc template content |
| `DESIGN_CONTENT` | File read | Contents of DESIGN.md during generation |
| `PLAN_INCOMPLETE_SECTIONS` | Runtime | List of incomplete sections for follow-up |

### Causal History

| Variable | Source | Description |
|----------|--------|-------------|
| `INTAKE_HISTORY_BLOCK` | Generated | Historical verdict/rework data from causal log |
| `CODEBASE_SUMMARY` | Generated | Directory tree + git log (for `--replan`) |
