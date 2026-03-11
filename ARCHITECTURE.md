# Tekhton — Architecture

## System Map

Tekhton is structured as a three-layer shell pipeline with a shared library core.

### Layer 1: Entry Point (`tekhton.sh`)
- Resolves `TEKHTON_HOME` and `PROJECT_DIR`
- Handles `--init`, `--status`, `--init-notes`, `--seed-contracts` early-exit commands
- Handles `--plan` as an early-exit command — sources `common.sh`, `prompts.sh`, `agent.sh`, `plan.sh`, `plan_interview.sh`, and `plan_generate.sh` (bypasses config loading)
- Sources all libraries and stage files (for execution pipeline)
- Loads config via `load_config()`
- Parses arguments, validates prerequisites, drives the three-stage pipeline
- Handles resume detection when invoked with no arguments
- Manages the commit prompt at the end

### Layer 2: Stages (`stages/*.sh`)
Each stage is a single function sourced by `tekhton.sh`:

- **`stages/architect.sh`** → `run_stage_architect()`
  - Conditional Stage 0: runs before the main task when drift thresholds are exceeded or `--force-audit` is passed
  - Loads drift log, architecture log, and architecture doc into prompt context
  - Invokes architect agent to produce `ARCHITECT_PLAN.md`
  - Parses plan sections and routes: Simplification → senior coder, Staleness/Dead Code/Naming → jr coder
  - Runs build gate after remediation coders
  - Runs expedited single-pass review (no rework loop)
  - Marks addressed observations as RESOLVED in drift log
  - Surfaces Design Doc Observations to `HUMAN_ACTION_REQUIRED.md`
  - Resets runs-since-audit counter
  - Skipped entirely when `--skip-audit` is passed

- **`stages/coder.sh`** → `run_stage_coder()`
  - Runs scout agent if HUMAN_NOTES.md has unchecked items
  - Injects architecture, glossary, milestone, prior context into coder prompt
  - Invokes senior coder agent
  - Runs build gate → escalates to build-fix agents on failure
  - Runs analyze cleanup as a completion gate
  - Archives human notes on success

- **`stages/review.sh`** → `run_stage_review()`
  - Iterates up to `MAX_REVIEW_CYCLES`
  - Invokes reviewer agent, parses verdict from `REVIEWER_REPORT.md`
  - Routes complex blockers → senior coder rework
  - Routes simple blockers → jr coder
  - Post-fix build gate after each rework pass
  - Saves state on max-cycle exhaustion

- **`stages/tester.sh`** → `run_stage_tester()`
  - Selects fresh vs resume prompt
  - Invokes tester agent
  - Detects compilation failures in log, resets affected items in report
  - Saves state on partial completion for turn-limit resume

### Layer 3: Libraries (`lib/*.sh`)

- **`lib/common.sh`** — Colors, `log()`, `warn()`, `error()`, `success()`, `header()`, `require_cmd()`
- **`lib/config.sh`** — `load_config()` reads `PROJECT_DIR/.claude/pipeline.conf`, validates required fields, applies milestone overrides via `apply_milestone_overrides()`
- **`lib/agent.sh`** — `run_agent(name, model, turns, prompt, logfile)` wraps claude CLI invocation with JSON output parsing, turn counting, timing. `print_run_summary()` formats cumulative metrics.
- **`lib/gates.sh`** — `run_build_gate(label)` runs `ANALYZE_CMD`, `BUILD_CHECK_CMD`, and optionally a dependency constraint `validation_command` from the configured `architecture_constraints.yaml`. Captures all errors to `BUILD_ERRORS.md`. `run_completion_gate()` checks coder self-reported status from `CODER_SUMMARY.md`.
- **`lib/hooks.sh`** — `archive_reports(dir, timestamp)`, `generate_commit_message(task)`, `run_final_checks(logfile)`.
- **`lib/drift.sh`** — Drift log, Architecture Decision Log, and Human Action management. `append_drift_observations()` reads reviewer report and accumulates to `DRIFT_LOG.md`. `append_architecture_decision()` records accepted ACPs to `ARCHITECTURE_LOG.md` with sequential ADL-NNN IDs. `append_human_action(source, desc)` adds items to `HUMAN_ACTION_REQUIRED.md`. `process_drift_artifacts()` is the main post-pipeline integration point. `should_trigger_audit()` checks thresholds. Counter management via `increment_runs_since_audit()` / `reset_runs_since_audit()`.
- **`lib/notes.sh`** — Three-state human notes tracking (`[ ]` → `[~]` → `[x]`). `count_human_notes()` and `extract_human_notes()` read unchecked items. `claim_human_notes()` marks filtered items `[~]` before coder runs. `resolve_human_notes()` parses CODER_SUMMARY.md structured reporting to selectively mark `[x]` or reset `[ ]`. Respects `NOTES_FILTER` global. `[~]` is transient — never persists between runs.
- **`lib/prompts.sh`** — `render_prompt(template_name)` reads `TEKHTON_HOME/prompts/<name>.prompt.md`, substitutes `{{VAR}}` from shell globals, strips `{{IF:VAR}}...{{ENDIF:VAR}}` blocks when VAR is empty.
- **`lib/state.sh`** — `write_pipeline_state(stage, reason, resume_flag, task, detail)`, `clear_pipeline_state()`. Persists to `PIPELINE_STATE_FILE` for resume.

### Layer 4: Prompt Templates (`prompts/*.prompt.md`)
Declarative agent instructions with `{{VAR}}` placeholders. Rendered by `lib/prompts.sh`.
Templates never contain project-specific content — all specifics come from config and shell globals.

### Layer 5: Agent Role Templates (`templates/*.md`)
Copied into target projects by `--init`. Customized per-project under `.claude/agents/`.
Define each agent's personality, rules, and output format requirements.

## Data Flow

```
tekhton.sh (entry)
  │
  ├─ load_config() ← PROJECT_DIR/.claude/pipeline.conf
  │
  ├─ Pre-flight: should_trigger_audit() → drift threshold warning
  │
  ├─ Stage 0: run_stage_architect()  [conditional — threshold or --force-audit]
  │    ├─ render_prompt("architect") → run_agent("Architect")
  │    ├─ parse ARCHITECT_PLAN.md sections
  │    ├─ [if Simplification] → render_prompt("architect_sr_rework") → run_agent("Coder")
  │    ├─ [if Staleness/Dead Code/Naming] → render_prompt("architect_jr_rework") → run_agent("Jr Coder")
  │    ├─ run_build_gate()
  │    ├─ render_prompt("architect_review") → run_agent("Reviewer expedited")
  │    ├─ resolve_drift_observations() → DRIFT_LOG.md
  │    ├─ append_human_action() → HUMAN_ACTION_REQUIRED.md
  │    └─ reset_runs_since_audit()
  │
  ├─ Stage 1: run_stage_coder()
  │    ├─ render_prompt("scout") → run_agent("Scout")
  │    ├─ render_prompt("coder") → run_agent("Coder")
  │    ├─ run_build_gate() → [render_prompt("build_fix") → run_agent("Build Fix")]
  │    └─ run_completion_gate() → [render_prompt("analyze_cleanup") → run_agent("Cleanup")]
  │
  ├─ Stage 2: run_stage_review()  [loops up to MAX_REVIEW_CYCLES]
  │    ├─ render_prompt("reviewer") → run_agent("Reviewer")
  │    ├─ [parse ACP Verdicts → ACCEPTED_ACPS]
  │    ├─ [if CHANGES_REQUIRED + complex] → render_prompt("coder_rework") → run_agent("Coder rework")
  │    ├─ [if CHANGES_REQUIRED + simple]  → render_prompt("jr_coder") → run_agent("Jr Coder")
  │    └─ run_build_gate()
  │
  ├─ Stage 3: run_stage_tester()
  │    └─ render_prompt("tester"|"tester_resume") → run_agent("Tester")
  │
  ├─ Finalize
  │    ├─ run_final_checks()
  │    ├─ process_drift_artifacts()
  │    │    ├─ append_drift_observations() → DRIFT_LOG.md
  │    │    ├─ append_architecture_decision() → ARCHITECTURE_LOG.md
  │    │    ├─ _process_design_observations() → HUMAN_ACTION_REQUIRED.md
  │    │    └─ increment_runs_since_audit()
  │    ├─ archive_reports()
  │    ├─ generate_commit_message()
  │    ├─ human action banner (if items pending)
  │    └─ interactive commit prompt
```

## File Ownership

| File | Lives in | Purpose |
|------|----------|---------|
| `tekhton.sh` | TEKHTON_HOME | Entry point |
| `lib/*.sh` | TEKHTON_HOME | Shared libraries |
| `stages/*.sh` | TEKHTON_HOME | Stage implementations |
| `prompts/*.prompt.md` | TEKHTON_HOME | Prompt templates |
| `templates/*.md` | TEKHTON_HOME | Agent role templates (copied by --init) |
| `.claude/pipeline.conf` | PROJECT_DIR | Project-specific config |
| `.claude/agents/*.md` | PROJECT_DIR | Project-specific agent roles |
| `.claude/logs/` | PROJECT_DIR | Run logs and archives |
| `.claude/PIPELINE_STATE.md` | PROJECT_DIR | Resume state |
| `CODER_SUMMARY.md` | PROJECT_DIR | Coder output (per-run) |
| `REVIEWER_REPORT.md` | PROJECT_DIR | Reviewer output (per-run) |
| `TESTER_REPORT.md` | PROJECT_DIR | Tester output (per-run) |
| `JR_CODER_SUMMARY.md` | PROJECT_DIR | Jr coder output (per-run) |
| `ARCHITECT_PLAN.md` | PROJECT_DIR | Architect audit output (per-audit) |
| `HUMAN_NOTES.md` | PROJECT_DIR | Human-written notes for next run |
| `ARCHITECTURE_LOG.md` | PROJECT_DIR | Architecture Decision Log (accepted ACPs across runs) |
| `DRIFT_LOG.md` | PROJECT_DIR | Drift observations accumulated across runs |
| `HUMAN_ACTION_REQUIRED.md` | PROJECT_DIR | Items needing human attention (design doc updates) |
| `architecture_constraints.yaml` | PROJECT_DIR | Optional dependency constraint manifest (layer rules + validation command) |

## Dependency Constraint System (P5)

Optional, language-agnostic enforcement of layer boundaries. When configured:

1. **Constraint manifest** (`architecture_constraints.yaml`) defines layer rules and a `validation_command`
2. **Build gate** runs the `validation_command` after analyze + compile checks. Nonzero exit = build failure.
3. **Architect agent** reads the manifest during audits to verify drift observations against declared rules
4. **Sample scripts** in `examples/` provide starting points for Dart, Python, and TypeScript projects

The system is fully opt-in: when `DEPENDENCY_CONSTRAINTS_FILE` is empty (default), build gate skips validation and architect operates without layer context.

## Extension Points

New capabilities should be added as:
1. **New prompt template** in `prompts/` — for new agent tasks
2. **New library** in `lib/` — for new shared functionality
3. **New stage** in `stages/` — for new pipeline phases (require sourcing in tekhton.sh)
4. **New config key** in `pipeline.conf.example` — for new project-level settings

Never add project-specific logic to any file in TEKHTON_HOME.
