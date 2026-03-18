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
│   ├── agent_monitor.sh    # Agent monitoring, activity detection, process management
│   ├── gates.sh            # Build gate + completion gate
│   ├── hooks.sh            # Archive, commit message, final checks
│   ├── notes.sh            # Human notes management
│   ├── prompts.sh          # Template engine for .prompt.md files
│   ├── state.sh            # Pipeline state persistence + resume
│   ├── drift.sh            # Drift log, ADL, human action management
│   ├── plan.sh             # Planning phase orchestration + config
│   ├── plan_completeness.sh # Design doc structural validation
│   ├── plan_state.sh       # Planning state persistence + resume
│   ├── context.sh          # [2.0] Token accounting + context compiler
│   ├── milestones.sh       # [2.0] Milestone state machine + acceptance checking
│   ├── clarify.sh          # [2.0] Clarification protocol + replan trigger
│   ├── specialists.sh      # [2.0] Specialist review framework
│   ├── metrics.sh          # [2.0] Run metrics collection + adaptive calibration
│   └── errors.sh           # [2.0] Error taxonomy, classification + reporting
├── stages/                 # Stage implementations (sourced by tekhton.sh)
│   ├── architect.sh        # Stage 0: Architect audit (conditional)
│   ├── coder.sh            # Stage 1: Scout + Coder + build gate
│   ├── review.sh           # Stage 2: Review loop + rework routing
│   ├── tester.sh           # Stage 3: Test writing + validation
│   ├── cleanup.sh          # [2.0] Post-success debt sweep stage
│   ├── plan_interview.sh   # Planning: interactive interview agent
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

#### [DONE] Milestone 1: Model Default + Template Depth Overhaul
#### [DONE] Milestone 2: Multi-Phase Interview with Deep Probing
#### [DONE] Milestone 3: Generation Prompt Overhaul for Deep CLAUDE.md
#### [DONE] Milestone 4: Follow-Up Interview Depth + Completeness Checker Upgrade
#### [DONE] Milestone 5: Tests + Documentation Update
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

#### [DONE] Milestone 0: Security Hardening
#### [DONE] Milestone 0.5: Agent Output Monitoring And Null-Run Detection
#### [DONE] Milestone 1: Token And Context Accounting
#### [DONE] Milestone 2: Context Compiler
#### [DONE] Milestone 3: Milestone State Machine And Auto-Advance
#### [DONE] Milestone 4: Mid-Run Clarification And Replanning
#### [DONE] Milestone 5: Autonomous Debt Sweeps
#### [DONE] Milestone 6: Brownfield Replan
#### [DONE] Milestone 7: Specialist Reviewers
#### [DONE] Milestone 8: Workflow Learning
#### [DONE] Milestone 9: Post-Coder Turn Recalibration
#### [DONE] Milestone 10: Milestone Commit Signatures, Completion Signaling, And Archival
#### [DONE] Milestone 11: Pre-Flight Milestone Sizing And Null-Run Auto-Split

#### Milestone 12.1: Error Taxonomy, Classification Engine & Redaction

Create the foundational `lib/errors.sh` library with the complete error taxonomy,
classification functions, transience detection, recovery suggestions, and sensitive
data redaction. This is a pure library file with no integration into the pipeline —
all functions are independently testable.

**Files to create:**
- `lib/errors.sh` — Canonical error taxonomy with classification functions:
  - `classify_error(exit_code, stderr_file, last_output_file)` — returns a
    structured error record: `CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE`
  - Categories:
    - `UPSTREAM` — API provider failures. Subcategories: `api_500` (HTTP 500/502/503),
      `api_rate_limit` (HTTP 429), `api_overloaded` (HTTP 529), `api_auth`
      (authentication_error), `api_timeout` (connection timeout), `api_unknown`
    - `ENVIRONMENT` — local system issues. Subcategories: `disk_full`, `network`
      (DNS/connection failures), `missing_dep` (claude CLI not found, python not
      found), `permissions`, `oom` (signal 9 / 137 with no prior errors), `env_unknown`
    - `AGENT_SCOPE` — expected agent-level failures. Subcategories: `null_run`
      (died before meaningful work), `max_turns` (exhausted turn budget),
      `activity_timeout` (no output or file changes for timeout period),
      `no_summary` (completed but no CODER_SUMMARY.md), `scope_unknown`
    - `PIPELINE` — Tekhton internal errors. Subcategories: `state_corrupt`
      (invalid PIPELINE_STATE.md), `config_error` (pipeline.conf parse failure),
      `missing_file` (required artifact not found), `template_error` (prompt
      render failure), `internal` (unexpected shell error)
  - `is_transient(category, subcategory)` — returns 0 if transient, 1 if permanent.
    All `UPSTREAM` errors are transient. `ENVIRONMENT/network` is transient.
    `ENVIRONMENT/oom` is transient. All `AGENT_SCOPE` and `PIPELINE` errors are permanent.
  - `suggest_recovery(category, subcategory, context)` — returns a human-readable
    recovery string for each category/subcategory combination.
  - `redact_sensitive(text)` — strips patterns matching: `x-api-key: *`,
    `Authorization: *`, `sk-ant-*`, `ANTHROPIC_API_KEY=*`, and common API key
    formats. Preserves Anthropic request IDs (`req_*`).

**Files to modify:**
- `tekhton.sh` — source `lib/errors.sh`

**Acceptance criteria:**
- `classify_error` given exit code 1 + output containing `"type":"server_error"`
  returns `UPSTREAM|api_500|true|HTTP 500...`
- `classify_error` given exit code 137 + no API errors returns
  `ENVIRONMENT|oom|true|Process killed (signal 9)...`
- `classify_error` given exit code 0 + turns=0 + no file changes returns
  `AGENT_SCOPE|null_run|false|Agent completed without meaningful work`
- `is_transient` returns 0 for all `UPSTREAM` errors and `ENVIRONMENT/network`,
  `ENVIRONMENT/oom`; returns 1 for all `AGENT_SCOPE` and `PIPELINE` errors
- `suggest_recovery` returns actionable recovery text for every known subcategory
- `redact_sensitive` strips API keys and auth tokens but preserves Anthropic
  request IDs (`req_011CZ9DVb...`)
- Unrecognized error patterns fall back to `*_unknown` subcategories
- All existing tests pass
- `bash -n` and `shellcheck` pass on `lib/errors.sh`

**Watch For:**
- Claude CLI error output format is not formally documented — classification is
  pattern-based. Always fall back to `*_unknown` subcategories for unrecognized
  errors. The taxonomy must be extensible by adding new grep patterns.
- Exit code 137 may not map to signal 9 on all platforms (Windows/Git Bash).
- Redaction must be conservative — better to over-redact than leak a key. But do
  NOT redact the Anthropic request ID.
- `classify_error` must accept optional parameters for file change count and turn
  count (needed for `AGENT_SCOPE/null_run` classification). Default to 0 if not
  provided.

**Seeds Forward:**
- Milestone 12.2 integrates these functions into the agent monitoring and exit
  handling path
- Milestone 12.3 uses `redact_sensitive()` for log summaries and error categories
  for metrics records

#### Milestone 12.2: Agent Exit Analysis, Real-Time Detection & Structured Reporting

Integrate the error classification engine into the agent monitoring loop and exit
handling. Add real-time API error detection in the FIFO reader, a ring buffer for
capturing last output, stderr redirection, and the structured error reporting box
in `lib/common.sh`. Wire classification into all stage exit paths and extend
pipeline state with error attribution.

**Files to modify:**
- `lib/agent_monitor.sh` — In the FIFO reader loop, maintain a ring buffer of the
  last 50 lines of raw agent output (fixed-size bash array with modular index
  `buffer[i % 50]`). On agent exit, write ring buffer to
  `$SESSION_TMP/agent_last_output.txt`. While reading the stream, detect API error
  JSON patterns in real-time: `"type":"error"`, `"error":{"type":"server_error"`,
  `"error":{"type":"rate_limit_error"`, `"error":{"type":"overloaded_error"`,
  HTTP status codes 429/500/502/503/529. Set `API_ERROR_DETECTED=true` and
  `API_ERROR_TYPE=<subcategory>` flags.
- `lib/agent.sh` — After agent process exits, before existing null-run detection:
  1. Redirect agent stderr to `$SESSION_TMP/agent_stderr.txt`
  2. Call `classify_error` with exit code, stderr file, and last output file
  3. Store result in `AGENT_ERROR_CATEGORY`, `AGENT_ERROR_SUBCATEGORY`,
     `AGENT_ERROR_TRANSIENT`, `AGENT_ERROR_MESSAGE`
  4. If `AGENT_ERROR_CATEGORY=UPSTREAM`, skip null-run classification entirely
- `lib/common.sh` — Add `report_error(category, subcategory, transient, message,
  recovery)` that formats a structured, boxed error block to stderr using Unicode
  box-drawing characters. Falls back to ASCII (`+`, `-`, `|`) when terminal does
  not support Unicode (check `LANG`/`LC_ALL` for UTF-8). Does NOT replace existing
  `log()`, `warn()`, `error()` functions.
- `stages/coder.sh`, `stages/review.sh`, `stages/tester.sh`, `stages/architect.sh`
  — After agent completion, check for `AGENT_ERROR_CATEGORY`. If set and not
  `AGENT_SCOPE`, call `report_error()`. For `UPSTREAM` errors, replace the null-run
  exit path with a transient-error exit path: "This was an API failure, not a scope
  issue. Re-run the same command."
- `lib/state.sh` — Extend `PIPELINE_STATE.md` with `## Error Classification`
  section containing: category, subcategory, transient flag, recovery suggestion,
  and the last 10 lines of agent output (redacted via `redact_sensitive()`). Resume
  logic reads this on next invocation to display previous failure context.

**Acceptance criteria:**
- API error patterns (500, 429, 529, auth errors) are detected from the agent's
  JSON output stream in real-time during monitoring
- Ring buffer captures last 50 lines without memory leaks on long-running agents
- `UPSTREAM` errors bypass null-run classification entirely — an API 500 is never
  misreported as a "null run"
- `report_error` produces a boxed, structured error block with category, message,
  and actionable recovery suggestion
- ASCII fallback for box-drawing characters when terminal lacks Unicode support
- `PIPELINE_STATE.md` includes error classification section on failure
- Resume prompt displays previous failure context on next invocation
- Unclassified errors produce the existing generic error messages (no regression)
- Sensitive values are redacted in state files and error reports
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The ring buffer must use a fixed-size bash array with modular index
  (`buffer[i % 50]`), not an unbounded append. Memory safety on long runs.
- `stderr` capture requires redirecting stderr to a file before the FIFO tee.
  Must not break existing FIFO monitoring, activity detection, turn counting,
  or null-run detection.
- The `UPSTREAM` bypass of null-run classification is critical. Without it, an
  API 500 that produces 0 turns and 0 file changes gets misclassified as a null
  run, leading to incorrect split/rework suggestions.
- Do NOT add error classification to the scout stage. Scout failures are already
  non-fatal and advisory.
- Do NOT change how the pipeline decides to save state vs exit. Only add
  attribution to those decisions.

**Seeds Forward:**
- Milestone 12.3 adds metrics integration and log structure that depend on the
  `AGENT_ERROR_*` variables and `report_error()` function established here

#### Milestone 12.3: Metrics Integration & Structured Log Summaries

Add error category fields to metrics JSONL records, error breakdown to the
`--metrics` dashboard, ensure metrics are recorded on all exit paths, and append
structured agent run summary blocks to log files for tail-friendly diagnostics.

**Files to modify:**
- `lib/metrics.sh` — Add fields to the JSONL record: `error_category` (string or
  null), `error_subcategory` (string or null), `error_transient` (boolean or null).
  Only populated on non-success outcomes. Null fields omitted from JSON output.
  In `summarize_metrics()`, add an error breakdown section to the `--metrics`
  dashboard output grouped by top-level category with count and transient/permanent
  distinction. If all errors in a category are transient, note that auto-retry
  would resolve them.
- `lib/hooks.sh` — Ensure `record_run_metrics()` is called on ALL exit paths, not
  just success. Pass error classification when available. Verify and fix any early
  exit paths that skip metrics recording.
- `lib/agent.sh` — At the end of each agent run (success or failure), append a
  structured summary block to the log file:
  ```
  ═══ Agent Run Summary ═══
  Agent:     coder (claude-sonnet-4-20250514)
  Turns:     25 / 50
  Duration:  12m 34s
  Exit Code: 0
  Class:     SUCCESS
  Files:     8 modified, 2 created
  ═════════════════════════
  ```
  On failure, include error classification, message, and recovery suggestion.
  This block appears at the END of the log file so `tail -20 <logfile>` is
  always sufficient to diagnose a failure.

**Acceptance criteria:**
- `metrics.jsonl` records `error_category` and `error_subcategory` on failures
- `--metrics` dashboard shows error breakdown by category with transient/permanent
  distinction
- `record_run_metrics()` is called on all exit paths including early exits and
  signal traps
- Log files end with a structured agent summary block (tail-friendly)
- Success runs show `Class: SUCCESS` in log summary; failures show the full
  error classification with recovery suggestion
- Sensitive values are redacted in log summaries (via `redact_sensitive()`)
- Raw FIFO logs are NOT redacted (preserved for deep debugging)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- JSONL is append-only. Never read-modify-write the metrics file — only append.
- The log summary block must use the same Unicode/ASCII detection as `report_error()`
  for consistent rendering.
- Early exit paths (Ctrl+C, signal traps, config errors) may bypass the normal
  finalization flow. Verify that the EXIT trap in `tekhton.sh` calls
  `record_run_metrics()`.
- Do NOT make error classification slow. The log summary is a few string
  concatenations, not an LLM call.

**Seeds Forward:**
- Milestone 13 uses `is_transient()` from 12.1 + error categories from this
  milestone to automatically retry `UPSTREAM` errors
- Milestone 14 uses `AGENT_ERROR_*` variables to distinguish turn exhaustion
  (continuable) from real failures (not continuable)
- Milestone 15 uses all error infrastructure to make retry/continue/split/stop
  decisions in the outer orchestration loop

#### Milestone 13: Transient Error Retry Loop

Wrap each `run_agent()` call in a retry envelope that detects transient errors
(API 500, 429, 529, network blips, OOM) via the error classification from
Milestone 12 and automatically retries with exponential backoff instead of saving
state and exiting. This is the single highest-impact change for autonomous
operation — roughly half of all pipeline failures are transient errors that
succeed on the next invocation.

**Files to modify:**
- `lib/agent.sh` — Add `_retry_agent()` wrapper around the core agent invocation
  inside `run_agent()`. After agent process exits and `classify_error()` runs:
  1. If `AGENT_ERROR_TRANSIENT=true`: enter retry loop
  2. Backoff schedule: 30s, 60s, 120s (exponential with cap)
  3. For `api_rate_limit` (429): parse `retry-after` from last output if available,
     otherwise minimum 60s wait
  4. For `api_overloaded` (529): minimum 60s wait
  5. For `oom`: wait 15s (allow OS to reclaim memory)
  6. Log each retry with attempt number, error category, and wait time
  7. On retry: re-invoke the same agent command with identical arguments
  8. After `MAX_TRANSIENT_RETRIES` exhausted: fall through to existing error path
     (state save and exit)
  9. Reset `AGENT_ERROR_*` variables between retries
- `lib/config.sh` — Add defaults: `MAX_TRANSIENT_RETRIES=3`,
  `TRANSIENT_RETRY_BASE_DELAY=30`, `TRANSIENT_RETRY_MAX_DELAY=120`,
  `TRANSIENT_RETRY_ENABLED=true`
- `lib/agent_monitor.sh` — Ensure the FIFO, ring buffer, and activity monitoring
  are cleanly re-initialized on retry. The monitoring subprocess from the failed
  attempt must be fully terminated before the retry starts. Add
  `_reset_monitoring_state()` helper that kills any lingering FIFO reader, removes
  stale temp files, and resets activity timestamps.
- `lib/common.sh` — Add `report_retry(attempt, max, category, delay)` that prints
  a clearly formatted retry notice: "Transient error (API 500). Retrying in 30s
  (attempt 1/3)..." Uses the same Unicode/ASCII detection as `report_error()`.
- `stages/coder.sh` — Remove the tester-only OOM retry special case (lines that
  check exit code 137 and sleep 15). This is now handled generically by the retry
  envelope for ALL agents, not just tester.
- `stages/tester.sh` — Remove the tester-specific OOM retry (same as above). The
  generic retry in `run_agent()` subsumes this.
- `lib/metrics.sh` — Add `retry_count` field to the JSONL record. Record number
  of retries per agent invocation (0 for first-attempt success).
- `templates/pipeline.conf.example` — Add retry config keys with comments

**Acceptance criteria:**
- API 500 error during coder stage triggers automatic retry after 30s delay
- API 429 (rate limit) triggers retry with 60s minimum delay
- API 529 (overloaded) triggers retry with 60s minimum delay
- OOM (exit 137) triggers retry after 15s for ALL agents (not just tester)
- Network errors (DNS, connection timeout) trigger retry after 30s
- Maximum 3 retries before falling through to state-save-and-exit
- Delay doubles on each attempt (30s → 60s → 120s) capped at `TRANSIENT_RETRY_MAX_DELAY`
- FIFO monitoring and ring buffer are cleanly re-initialized between retries
- Activity timeout detection works correctly on retry attempts
- Retry attempts are logged with attempt number and category
- `metrics.jsonl` records retry count per agent invocation
- Permanent errors (`AGENT_SCOPE`, `PIPELINE`) are NEVER retried — they fall
  through immediately to existing error paths
- `TRANSIENT_RETRY_ENABLED=false` disables retry entirely (1.0-compatible behavior)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The retry envelope wraps the agent invocation INSIDE `run_agent()`, not at the
  stage level. Stages should not know about retries — they see success or failure.
- FIFO cleanup between retries is critical. A stale FIFO reader from attempt 1
  will interfere with attempt 2's monitoring. Kill the subshell, remove the FIFO,
  create a fresh one.
- The existing tester OOM retry is a special case that must be removed — otherwise
  tester gets double retry (once in the agent wrapper, once in the stage).
- `retry-after` header parsing from Claude CLI JSON output is best-effort. If the
  header isn't present or parseable, fall back to the exponential backoff schedule.
- Do NOT retry on `AGENT_SCOPE/null_run` or `AGENT_SCOPE/max_turns`. Those are
  permanent conditions — the agent genuinely couldn't do the work. Retrying the
  same prompt will produce the same result.
- Do NOT add retry to the scout stage. Scout failures are already non-fatal. Adding
  retry there adds latency without value.
- Consider process group cleanup on retry: the killed agent may have spawned child
  processes. Use `kill -- -$PID` (process group kill) before retrying.

**Seeds Forward:**
- Milestone 14 (Turn Exhaustion Continuation) and Milestone 15 (Outer Loop)
  both depend on reliable transient error handling being solved first
- The `retry_count` metric enables future adaptive retry calibration (e.g., if
  a project consistently sees 429s, increase the base delay)

#### Milestone 14: Turn Exhaustion Continuation Loop

Add automatic continuation when an agent hits its turn limit but made substantive
progress. Instead of saving state and requiring a human to re-run, the pipeline
immediately re-invokes the agent with full prior-progress context and a fresh turn
budget. This eliminates the most common human-in-the-loop scenario: "coder did 80%
of the work, ran out of turns, I re-ran and it finished."

**Files to modify:**
- `stages/coder.sh` — After coder completion, before the existing turn-limit exit
  path:
  1. Check if `CODER_SUMMARY.md` exists and contains `## Status: IN PROGRESS`
  2. Check if substantive work was done: `git diff --stat` shows ≥1 file modified
  3. If both true: **do not exit**. Instead:
     a. Increment `CONTINUATION_ATTEMPT` counter (starts at 0)
     b. If `CONTINUATION_ATTEMPT >= MAX_CONTINUATION_ATTEMPTS`: trigger milestone
        split (existing M11 path) or save state and exit
     c. Build continuation context: git diff stat + CODER_SUMMARY.md contents +
        "You are continuing from a previous run that hit the turn limit. Read the
        modified files to understand current state. Do NOT redo completed work."
     d. Log: "Coder hit turn limit with progress (attempt N/M). Continuing..."
     e. Re-invoke `run_agent "Coder (continuation N)"` with the continuation
        context injected into the prompt
     f. After continuation agent completes, loop back to the status check
  4. If `CODER_SUMMARY.md` says `## Status: COMPLETE`: proceed to review normally
  5. If no substantive work (0 files modified): fall through to existing null-run
     path (split or exit)
- `stages/tester.sh` — Same pattern for tester: if partial tests remain and
  substantive test files were created, re-invoke tester with "continue writing
  the remaining tests" context. Cap at `MAX_CONTINUATION_ATTEMPTS`.
- `lib/config.sh` — Add defaults: `MAX_CONTINUATION_ATTEMPTS=3`,
  `CONTINUATION_ENABLED=true`
- `lib/agent.sh` — Add `build_continuation_context(stage, attempt_num)` that
  assembles: (1) previous CODER_SUMMARY.md or tester report, (2) git diff stat
  of files modified so far, (3) explicit instruction not to redo work, (4) the
  attempt number for the agent's awareness. Returns the context as a string for
  prompt injection.
- `prompts/coder.prompt.md` — Add `{{IF:CONTINUATION_CONTEXT}}` block that injects
  the continuation instructions when present. Place it before the task section
  so the agent reads its own prior summary before starting work.
- `prompts/tester.prompt.md` — Add equivalent `{{IF:CONTINUATION_CONTEXT}}` block.
- `lib/metrics.sh` — Add `continuation_attempts` field to JSONL record. Track how
  many continuation loops were needed per stage.
- `templates/pipeline.conf.example` — Add continuation config keys

**Substantive work detection heuristic:**
```
substantive = (files_modified >= 1) AND (
    (coder_summary_lines >= 20) OR
    (git_diff_lines >= 50)
)
```
This distinguishes "agent did real implementation work but ran out of time" from
"agent spent all turns planning/reading and wrote almost nothing." The latter
should go to the split path, not the continuation path.

**Acceptance criteria:**
- Coder hitting turn limit with `Status: IN PROGRESS` and ≥1 modified file triggers
  automatic continuation (no human prompt)
- Continuation agent receives prior CODER_SUMMARY.md contents and git diff stat
- Continuation agent does NOT redo work already shown in the prior summary
- Maximum 3 continuation attempts before escalating to split or exit
- After 3 failed continuations: if milestone mode, trigger auto-split; if not
  milestone mode, save state and exit with clear message
- Tester partial completion with ≥1 test file created triggers continuation
- Each continuation attempt is logged with attempt number and progress metrics
- `CONTINUATION_ENABLED=false` disables continuation (1.0-compatible behavior)
- `metrics.jsonl` records continuation attempt count
- Null runs (0 files modified) are NOT continued — they go to existing split/exit
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The continuation context must include the FULL `CODER_SUMMARY.md`, not just the
  status line. The agent needs its own prior plan and checklist to know what remains.
- Git diff stat is a snapshot at re-invocation time. If the agent's continuation
  modifies the same files, the next snapshot grows — this is expected and correct.
- Do NOT reset the turn counter for the overall pipeline. Each continuation gets
  a fresh agent turn budget, but the pipeline should track cumulative turns for
  metrics and cost awareness.
- The continuation prompt must be strong enough that the agent reads modified files
  FIRST. Without this, the agent will re-read the task description and start from
  scratch, wasting its turn budget re-implementing what's already done.
- Do NOT continue after review-stage failures. If the reviewer found blockers, the
  existing rework routing (sr/jr coder) handles it. Continuation is only for
  turn exhaustion, not for quality failures.
- When continuation transitions to milestone split (after MAX_CONTINUATION_ATTEMPTS),
  the partial work must be preserved. The split agent should see what was already
  implemented so it can scope sub-milestones around the remaining work, not the
  total work.
- Consider injecting the cumulative turn count into the continuation prompt:
  "Previous attempts used N turns total. You have M turns. Focus on completing
  the remaining items efficiently."

**Seeds Forward:**
- Milestone 15 (Outer Loop) uses continuation as one of its recovery strategies
  in the orchestration state machine
- The `continuation_attempts` metric enables future adaptive turn budgeting:
  if a project consistently needs 2 continuations, increase the default turn cap
- The substantive-work heuristic can be refined using metrics data from Milestone 8

#### Milestone 15: Outer Orchestration Loop (Milestone-to-Completion)

Add a `--complete` flag that wraps the entire pipeline in an outer orchestration
loop with a clear contract: **run this milestone until it passes acceptance or all
recovery options are exhausted.** This is the capstone of V2 — combining transient
retry (M13), turn continuation (M14), milestone splitting (M11), and error
classification (M12) into a single autonomous loop that eliminates the human
re-run cycle.

**Files to modify:**
- `tekhton.sh` — Add `--complete` flag parsing. When active, wrap
  `_run_pipeline_stages()` in an outer loop:
  ```
  PIPELINE_ATTEMPT=0
  while true; do
      PIPELINE_ATTEMPT=$((PIPELINE_ATTEMPT + 1))
      
      _run_pipeline_stages  # coder → review → tester
      
      if check_milestone_acceptance; then
          break  # SUCCESS — commit, archive, done
      fi
      
      # Acceptance failed — diagnose and recover
      if [ $PIPELINE_ATTEMPT -ge $MAX_PIPELINE_ATTEMPTS ]; then
          save state, exit with full diagnostic
          break
      fi
      
      # Check for progress between attempts
      if no_progress_since_last_attempt; then
          # Degenerate loop detected
          save state, exit with "stuck" diagnostic
          break
      fi
      
      log "Acceptance not met. Re-running pipeline (attempt $PIPELINE_ATTEMPT/$MAX_PIPELINE_ATTEMPTS)..."
      # Loop back — coder gets prior progress context automatically
  done
  ```
- `tekhton.sh` — Add safety bounds enforced in the outer loop:
  1. `MAX_PIPELINE_ATTEMPTS=5` — hard cap on full pipeline cycles
  2. `AUTONOMOUS_TIMEOUT=7200` (2 hours) — wall-clock kill switch checked at
     the top of each loop iteration
  3. `MAX_AUTONOMOUS_AGENT_CALLS=20` — cumulative agent invocations across all
     loop iterations (prevents runaway in pathological rework cycles)
  4. Progress detection: compare `git diff --stat` between loop iterations. If
     the diff is identical, the pipeline is stuck. Exit after 2 no-progress
     iterations.
- `lib/config.sh` — Add defaults: `COMPLETE_MODE_ENABLED=true`,
  `MAX_PIPELINE_ATTEMPTS=5`, `AUTONOMOUS_TIMEOUT=7200`,
  `MAX_AUTONOMOUS_AGENT_CALLS=20`, `AUTONOMOUS_PROGRESS_CHECK=true`
- `lib/state.sh` — Extend `write_pipeline_state()` with `## Orchestration Context`
  section: pipeline attempt number, cumulative agent calls, cumulative turns used,
  wall-clock elapsed, and outcome of each prior attempt (one-line summary). On
  resume, this context is available to diagnose why the loop stopped.
- `lib/hooks.sh` — In the outer loop's post-acceptance path: run the existing
  commit flow, then call `archive_completed_milestone()`. If `--auto-advance` is
  also set, advance to next milestone and continue the outer loop for the next
  milestone (combining `--complete` with `--auto-advance` chains milestone
  completion).
- `lib/milestones.sh` — Add `record_pipeline_attempt(milestone_num, attempt,
  outcome, turns_used, files_changed)` that logs attempt metadata for the
  progress detector and metrics.
- `lib/common.sh` — Add `report_orchestration_status(attempt, max, elapsed,
  agent_calls)` that prints a banner at the start of each loop iteration showing
  the autonomous loop state.
- `lib/metrics.sh` — Add `pipeline_attempts` and `total_agent_calls` fields to
  JSONL record.
- `templates/pipeline.conf.example` — Add `--complete` config keys with comments

**Recovery decision tree inside the loop:**
```
After _run_pipeline_stages returns non-zero:
├── Was it a transient error? → Already retried by M13. If still failing,
│   save state and exit (sustained outage — human should check API status)
├── Was it turn exhaustion? → Already continued by M14. If still exhausting
│   after MAX_CONTINUATION_ATTEMPTS, trigger split (existing M11)
├── Was it a null run? → Already split by M11. If split depth exhausted,
│   save state and exit (milestone irreducible)
├── Was it a review cycle max? → Bump MAX_REVIEW_CYCLES by 2 (one time only),
│   re-run from review stage. If still failing, save state and exit.
├── Was it a build gate failure after rework? → Re-run from coder stage with
│   BUILD_ERRORS_CONTENT injected (one retry). If still failing, save state
│   and exit.
└── Was it an unclassified error? → Save state and exit immediately.
    Never retry an unknown error.
```

**Acceptance criteria:**
- `--complete` runs the pipeline in a loop until milestone acceptance passes
- `MAX_PIPELINE_ATTEMPTS=5` prevents infinite loops
- `AUTONOMOUS_TIMEOUT=7200` (2 hours) is a hard wall-clock kill switch
- `MAX_AUTONOMOUS_AGENT_CALLS=20` caps total agent invocations across all attempts
- Progress detection exits the loop if `git diff --stat` is unchanged between
  iterations (stuck detection after 2 no-progress attempts)
- Recovery decisions follow the documented decision tree — transient, turn
  exhaustion, null run, review max, build failure, and unclassified each have
  distinct handling
- Review cycle max gets ONE bump of +2 cycles before giving up
- Build failure after rework gets ONE coder re-run before giving up
- Unclassified errors are NEVER retried
- `--complete` combined with `--auto-advance` chains milestone completions
- Orchestration state is persisted in `PIPELINE_STATE.md` on interruption
- Resume from `PIPELINE_STATE.md` restores attempt counter and cumulative metrics
- Each loop iteration prints a status banner showing attempt, elapsed time, and
  agent call count
- `metrics.jsonl` records pipeline attempts and total agent calls
- Without `--complete`, behavior is identical to current (single attempt, exit on
  failure)
- All existing tests pass
- `bash -n` and `shellcheck` pass on all modified files

**Watch For:**
- The outer loop DOES NOT re-run stages that already succeeded in the same
  iteration. If coder + review succeeded but tester failed, the next iteration
  should `--start-at tester`, not re-run coder. Use `EXIT_STAGE` from the state
  file to determine the restart point.
- Progress detection must compare MEANINGFUL state, not just diff output. A
  rework cycle that reverts and re-applies the same changes looks like "progress"
  in terms of diff but is actually stuck. Compare diff CONTENT hashes, not just
  line counts.
- The cumulative agent call counter must account for retries (M13) and
  continuations (M14). A single "coder" stage might invoke 3 retries × 2
  continuations = 6 agent calls. All count toward the cap.
- Wall-clock timeout should be checked at the TOP of each loop iteration, not
  inside stages. This ensures clean state persistence before timeout exit.
- `--complete` without `--milestone` should work for non-milestone tasks too: run
  the pipeline, check if build/test pass, retry if not. The acceptance check
  falls back to "build gate passes" when no milestone criteria exist.
- Do NOT attempt to automatically resolve REPLAN_REQUIRED verdicts. If the
  reviewer says the milestone is mis-scoped, the outer loop should save state
  and exit with a clear message. Replanning requires human judgment.
- Do NOT allow the outer loop to run cleanup sweeps between attempts. Cleanup
  only runs after final success. Running cleanup mid-loop risks introducing
  new failures from debt resolution.
- The `--complete` + `--auto-advance` combination is the closest V2 gets to
  fully autonomous operation. It chains: complete milestone N → advance to
  N+1 → complete N+1 → ... up to `AUTO_ADVANCE_LIMIT`. This is deliberately
  capped. V3 removes the cap.

**What NOT To Do:**
- Do NOT add a `--build-project` flag. That's V3 scope. `--complete` operates on
  one milestone (or a limited chain with `--auto-advance`).
- Do NOT add cost budgeting. V3 scope. V2 uses invocation counts and wall-clock
  time as proxy limits.
- Do NOT add scheduled execution or daemon mode. V3 scope.
- Do NOT modify the inner pipeline stages. The outer loop wraps them; it does not
  change their behavior. Stages see a single invocation — they don't know they're
  inside a loop.
- Do NOT retry REPLAN_REQUIRED verdicts. The reviewer is saying the task is wrong.
  Retrying the same wrong task is wasteful.
- Do NOT override user config inside the loop. If `MAX_REVIEW_CYCLES=3` and the
  one-time bump makes it 5, that's the maximum. The loop cannot keep bumping.

**Seeds Forward:**
- V3 `--build-project` extends the outer loop to span ALL milestones without the
  `AUTO_ADVANCE_LIMIT` cap
- V3 cost budgeting adds dollar-amount tracking alongside the invocation cap
- V3 adaptive strategy selection replaces the fixed decision tree with a
  metrics-informed classifier that learns which recovery strategy works best
  for each project
- The orchestration state (attempt count, cumulative metrics, per-attempt outcomes)
  becomes the foundation for V3's project-level progress reporting
