# Tekhton V3 Polish Recommendations — First-Time Developer Analysis

> Analysis performed by walking through the brownfield setup experience as a
> first-time developer, then tracing the milestone authoring and execution loop.
> Recommendations are firmly grounded in V3 polish — no overlap with V4 scope
> (provider abstraction, structured logging, parallel execution, Watchtower
> served mode, project owner experience, external integrations, NFR framework,
> auth/identity, learning/adaptation, language intelligence).

## Virtual Walkthrough Summary

### What Works Well (No Changes Needed)

- **Detection breadth**: 18 languages, 5 CI providers, workspace/monorepo
  detection, doc quality scoring, AI artifact detection. Genuinely impressive
  for a shell-based engine.
- **Express mode**: Zero-config execution with auto-detection and
  post-success persistence. Correct trade-off between speed and completeness.
- **Planning system**: Interactive interview with resume support,
  browser-based mode, YAML import, completeness scoring with depth analysis,
  and auto-migration of inline milestones to DAG files.
- **Pipeline resilience**: Scout-calibrated turn budgets, transient error
  retry with exponential backoff, turn-exhaustion continuation, build gate
  auto-remediation, null-run auto-splitting, test baseline detection,
  acceptance-failure stuck detection, pre-finalization test gate with Jr Coder
  fix. The recovery mechanisms are sophisticated and well-layered.
- **State persistence**: Comprehensive resume support via
  `PIPELINE_STATE.md`, checkpoint-based rollback, causal event log, run
  summary JSON, metrics JSONL. The interactive resume prompt is thoughtful.
- **Notes system**: ID-based tracking, tag registry (BUG/FEAT/POLISH),
  claim/resolve lifecycle, rollback support, triage gate, tag-specialized
  execution paths. Mature and well-designed.
- **Migration framework**: Version-aware, idempotent, backup + rollback,
  chain-on-failure semantics. Well-documented migration script interface.

### Three Friction Themes

| # | Theme | Description | Where It Bites |
|---|-------|-------------|----------------|
| 1 | **Milestone blindness** | No CLI command to view DAG progress, next actionable milestone, or blocking dependencies | After init, between runs, during multi-milestone campaigns |
| 2 | **Config opacity** | Generated config has no provenance annotations; no validation before first API call | After init, after express persist, on first pipeline run |
| 3 | **Next-action ambiguity** | After runs complete (success or failure), developer must figure out what to type next | After every pipeline run, after diagnose, after rollback |

### Why These Are V3 Scope

- **V4 Structured Logging** = runtime output tiers + JSONL event streams for
  enterprise tools. These proposals are one-shot inspection commands and config
  annotations — not runtime log levels.
- **V4 Project Owner Experience** = restructuring for non-engineers with
  natural language intake, release notes, cost forecasting. These proposals
  help *engineers* navigate the *existing* CLI.
- **V4 Watchtower Served Mode** = interactive browser dashboard with
  WebSocket, REST API, swimlanes. These proposals are terminal-only, reading
  existing data files.

---

## Milestone 82: Milestone Progress CLI & Run-Boundary Guidance

### Overview

Two gaps closed by one milestone: (1) developers cannot see milestone progress
without reading raw MANIFEST.cfg, and (2) after every pipeline interaction,
developers must figure out the right next command themselves.

Extends the M81 pattern (post-init guidance) to every run boundary.

### Design Decisions

#### 1. `--milestones` subcommand — progress-at-a-glance

New early-exit command that reads MANIFEST.cfg and renders:

```
Milestones: 5 done / 8 total (62%)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Done (recent):
  ✓ m03  User Authentication
  ✓ m04  Database Schema Migration
  ✓ m05  API Gateway Setup

Next:
  ▶ m06  Payment Processing          (ready)
     m07  Email Notifications         (blocked by m06)
     m08  Admin Dashboard             (blocked by m06, m07)

Run: tekhton --milestone "M06: Payment Processing"
```

Uses existing DAG query functions: `load_manifest()`, `dag_get_frontier()`,
`dag_find_next()`, `dag_deps_satisfied()`. No new state files. Falls back to
inline milestone parsing if DAG mode disabled.

Optional flags:
- `--milestones --all` — show the full manifest including all done milestones
- `--milestones --deps` — show dependency edges

#### 2. Enriched `--status` — add milestone section

Current `--status` does a raw `cat` of PIPELINE_STATE.md. Append a milestone
progress summary after the existing output:

```
Milestone Progress: 5/8 (62%)
  Current: m06 — Payment Processing
  Next:    m07 — Email Notifications
```

4-line addition to the `--status` handler. Reads MANIFEST.cfg, calls
`dag_get_active()` and `dag_find_next()`.

#### 3. Contextual next-action line at finalization

After the existing completion banner and action items in `finalize_display.sh`,
append a single "What's next" line:

| Condition | Guidance |
|-----------|----------|
| Success + milestone complete + more pending | `What's next: tekhton --milestone "M07: Title"` |
| Success + milestone complete + none pending | `All milestones complete. Run tekhton --draft-milestones for next steps.` |
| Success + non-milestone task | `Run tekhton --status to review pipeline state.` |
| Failure + build gate | `What's next: fix build errors, then tekhton --start-at coder "task"` |
| Failure + review exhaustion | `What's next: tekhton --diagnose for recovery plan` |
| Failure + API/transient error | `What's next: re-run when API is available (transient error)` |
| Failure + stuck/timeout | `What's next: tekhton --diagnose for root cause analysis` |

New helper `_compute_next_action()` — pure function reading VERDICT,
milestone state, and error classification.

#### 4. Enrich `--diagnose` with recommended command

Current `--diagnose` shows failure analysis and recovery suggestions as prose.
Add a concrete command at the bottom:

```
Recommended recovery:
  tekhton --start-at review --milestone "M06: Payment Processing"
```

Maps recovery classification from `orchestrate_recovery.sh` to a concrete CLI
invocation.

### Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New subcommands | 1 | `--milestones` (early-exit) |
| Modified commands | 2 | `--status`, `--diagnose` |
| New helpers | 3 | `_render_milestone_progress`, `_compute_next_action`, `_diagnose_recovery_command` |
| New config vars | 0 | — |
| Files modified | ~5 | `tekhton.sh`, `lib/finalize_display.sh`, `lib/diagnose_output.sh`, new `lib/milestone_progress.sh` |
| Tests | 2–3 | Milestone rendering, next-action logic, diagnose recovery |
| Migration | None | Pure additive |

### Acceptance Criteria

- [ ] `tekhton --milestones` renders progress bar, done/pending sections, and
      a run command for the next milestone
- [ ] `tekhton --milestones` handles: no manifest (graceful message), all
      done, all pending, mixed states, split milestones
- [ ] `tekhton --milestones --all` shows all milestones including done
- [ ] `tekhton --milestones --deps` shows dependency edges per milestone
- [ ] `tekhton --status` includes a milestone progress section when
      MANIFEST.cfg exists
- [ ] Finalization banner includes a "What's next" line computed from run
      outcome and milestone state
- [ ] `_compute_next_action()` covers: success+complete+more, success+complete+none,
      success+non-milestone, failure+build, failure+review, failure+API,
      failure+stuck
- [ ] `tekhton --diagnose` includes a concrete recovery command line
- [ ] All output respects `NO_COLOR=1` and non-UTF-8 terminals
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on modified files reports zero warnings

### Dependencies

Depends on M81 (establishes the guided-next-step pattern and `▶` marker
convention).

### Backwards Compatibility

Pure additive. New CLI output only. No existing behavior changes. No migration
needed.

---

## Milestone 83: Config Self-Documentation & Validation Gate

### Overview

Generated pipeline configs are opaque — values appear with no provenance,
placeholders go unnoticed, and misconfigured commands silently waste agent
turns. This milestone makes configs self-documenting (detection source
annotations) and adds a lightweight validation gate that catches common
misconfigurations before the first API call.

### Design Decisions

#### 1. Detection source annotations in generated config

When `--init` generates pipeline.conf, annotate auto-detected values:

```bash
# Detected from: package.json scripts.test (confidence: high)
TEST_CMD="npm test"

# Detected from: .eslintrc.json + package.json scripts.lint (confidence: high)
ANALYZE_CMD="npx eslint ."

# Detected from: package.json scripts.build (confidence: medium)
BUILD_CHECK_CMD="npm run build"

# Not auto-detected — fill in manually
# PROJECT_DESCRIPTION="(fill in a one-line description)"
```

The detection engine already returns `cmd_type|cmd|source|confidence` tuples
from `detect_commands()`. The source information exists but is discarded at
config-write time. Thread it through `_emit_section_essential()` and related
emitters in `init_config_emitters.sh`.

Same treatment for express mode persistence in `persist_express_config()`.

#### 2. `--validate` subcommand — config health check

New early-exit command:

```
Config validation: my-project
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✓ PROJECT_NAME set (my-project)
  ⚠ PROJECT_DESCRIPTION is placeholder — edit pipeline.conf line 14
  ✓ TEST_CMD configured (npm test)
  ✓ ANALYZE_CMD configured (npx eslint .)
  ⚠ ARCHITECTURE_FILE="ARCHITECTURE.md" — file not found on disk
  ✓ Agent role files present (4/4)
  ✓ Milestone manifest valid (8 milestones, 0 errors)
  ⚠ TEKHTON_CONFIG_VERSION absent — run tekhton --migrate --status

5 passed, 3 warnings, 0 errors
```

Checks performed:
- Required keys present and non-placeholder (`PROJECT_NAME`,
  `PROJECT_DESCRIPTION`, `TEST_CMD`, `ANALYZE_CMD`)
- Referenced files exist on disk (`ARCHITECTURE_FILE`, `DESIGN_FILE`, all
  role files specified in config, milestone files referenced in MANIFEST.cfg)
- Commands are not no-ops (detects `TEST_CMD="echo 'No test command...'"`,
  `TEST_CMD="true"`, and other placeholder patterns)
- Config version watermark present
- Milestone manifest valid (delegates to existing `validate_manifest()`)
- Model names are recognized (`claude-opus-*`, `claude-sonnet-*`,
  `claude-haiku-*`)
- No stale/orphaned state files (PIPELINE_STATE.md from a different task)

Implementation: New file `lib/validate_config.sh` (~100–150 lines). Pure-read
function checking file existence and value patterns. No agent invocation, no
network calls, no new dependencies.

#### 3. Automatic validation hint on first pipeline run

On first pipeline run (detected via absence of both `RUN_SUMMARY.json` and
`CAUSAL_LOG.jsonl`), print a brief summary before the pipeline starts:

```
[tekhton] Config check: 5 passed, 2 warnings (run --validate for details)
```

If any *errors* (not warnings) are found, print the full output and prompt
`Continue anyway? [y/N]`. Warnings log the one-liner but don't block.

Runs once — subsequent runs skip the check. Cost: a few file-existence checks
adding <100ms.

#### 4. Backwards compatibility

- Source annotations are comments — no behavior change to config parsing
- `--validate` is a new command — no existing behavior changes
- First-run hint is gated on "no prior run data" — existing projects never
  see it
- No migration needed. Existing configs without annotations work identically

### Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New subcommands | 1 | `--validate` (early-exit) |
| New files | 1 | `lib/validate_config.sh` |
| Modified files | ~4 | `tekhton.sh`, `lib/init_config_emitters.sh`, `lib/express_persist.sh`, `lib/config_defaults.sh` |
| New config vars | 0 | — |
| Tests | 2 | Validation logic, annotation rendering |
| Migration | None | Pure additive |

### Acceptance Criteria

- [ ] `tekhton --init` generates pipeline.conf with detection source
      annotations above each auto-detected key
- [ ] Annotations include source description and confidence level
- [ ] Keys with no detection source are annotated with
      "Not auto-detected — fill in manually"
- [ ] `persist_express_config()` includes source annotations in the
      persisted config
- [ ] `tekhton --validate` prints a structured summary of config health
- [ ] Validation checks: placeholder values, no-op commands, missing files,
      model names, config version watermark, manifest validity
- [ ] `tekhton --validate` returns exit code 0 (all pass or warnings only)
      or exit code 1 (errors found)
- [ ] First pipeline run on a new project prints a one-line validation summary
- [ ] First-run hint does not appear on projects with existing run history
- [ ] Existing configs without annotations parse and load identically
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on modified files reports zero warnings

### Dependencies

Depends on M81 (M81 establishes `_INIT_FILES_WRITTEN` tracking in init, which
this milestone's annotation system augments).

### Backwards Compatibility

Pure additive. Annotations are comments. New CLI command. First-run gate is
conditional. No migration needed.

---

## Dependency Graph

```
M80 (done) ── M81 (pending) ─┬── M82 (Milestone Progress & Guidance)
                              └── M83 (Config Self-Documentation & Validation)
```

M82 and M83 are independent of each other and could execute in parallel.
