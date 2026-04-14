# Milestone 84: Complete TEKHTON_DIR Migration — Remaining Hardcoded Paths
<!-- milestone-meta
id: "84"
status: "done"
-->

## Overview

M72 introduced `TEKHTON_DIR` and moved ~25 Tekhton-managed files from the
project root into `.tekhton/`. However, a post-mortem audit (M72_QUALITY_ANALYSIS.md)
discovered that 11 additional files were missed entirely — they have no `_FILE`
config variable and continue to be written to the project root.

Four of these are persistent files (DRIFT_ARCHIVE.md, PROJECT_INDEX.md,
REPLAN_DELTA.md, MERGE_CONTEXT.md) that accumulate across runs. Seven are
transient single-run artifacts (SCOUT_REPORT.md, ARCHITECT_PLAN.md,
CLEANUP_REPORT.md, and four SPECIALIST_*_FINDINGS.md variants) that pollute
the project root during execution and leave orphans on interruption.

Additionally, 12 prompt templates instruct agents to write files by literal
name rather than `{{VAR}}` substitution, and the migration script omits 7
files from its relocation list.

This milestone completes the M72 migration by parameterizing all remaining
hardcoded paths, updating all prompt templates, and fixing the migration script.

## Design Decisions

### 1. Config variables for transient artifacts

Even though SCOUT_REPORT.md and ARCHITECT_PLAN.md are transient (created,
read, and archived within a single run), they still need config variables.
Reasons: (a) they appear at the project root during the run, (b) interrupted
runs leave orphans, (c) consistency with the parameterized pattern used by
all other Tekhton files. The default path will be `${TEKHTON_DIR}/SCOUT_REPORT.md`.

### 2. Specialist findings pattern variable

The four `SPECIALIST_*_FINDINGS.md` files use dynamic names constructed via
`SPECIALIST_${spec_name^^}_FINDINGS.md`. Rather than four separate config
variables, introduce a single `SPECIALIST_FINDINGS_PATTERN` or use the
existing interpolation with `${TEKHTON_DIR}/` prefix. The specialists code
in `lib/specialists.sh` and `lib/specialists_helpers.sh` already uses a
dynamic pattern; we just need to prefix it with `${TEKHTON_DIR}/`.

### 3. Migration script addendum

Rather than modifying the existing `003_to_031.sh`, add the new files to its
`files=()` array. The migration is already idempotent (skips files that don't
exist at source or already exist at destination), so adding files is safe.

### 4. PROJECT_INDEX.md stays at project root (design consideration)

PROJECT_INDEX.md is a user-visible project summary that some users may want
at the root for discoverability. However, for consistency with the TEKHTON_DIR
goal, we default it to `${TEKHTON_DIR}/PROJECT_INDEX.md` but document the
override option. Users who want it at root can set
`PROJECT_INDEX_FILE=PROJECT_INDEX.md` in pipeline.conf.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New config variables | ~8 | SCOUT_REPORT_FILE, ARCHITECT_PLAN_FILE, CLEANUP_REPORT_FILE, DRIFT_ARCHIVE_FILE, PROJECT_INDEX_FILE, REPLAN_DELTA_FILE, MERGE_CONTEXT_FILE + specialist pattern |
| lib/ and stages/ code sites updated | ~80 | Replace literal filenames with config vars |
| Prompt templates updated | ~12 | Replace literal filenames with {{VAR}} refs |
| Migration script additions | 7 | New files in migration list |
| tekhton.sh fixes | 2 | Lines 132-134, 2457 |

## Implementation Plan

### Step 1 — Add config variables to config_defaults.sh

Add after the existing `_FILE` variable block:

```bash
# --- Transient artifact file paths ---
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"
```

For specialist findings, prefix the dynamic pattern in `lib/specialists.sh`
and `lib/specialists_helpers.sh` with `${TEKHTON_DIR}/`.

### Step 2 — Replace hardcoded paths in lib/ and stages/

Replace all literal filename references with the new config variables.
Priority order by site count:
1. SCOUT_REPORT.md (~23 sites in stages/coder.sh, lib/dry_run.sh, lib/turns.sh, lib/context_compiler.sh)
2. ARCHITECT_PLAN.md (~11 sites in stages/architect.sh, tekhton.sh)
3. PROJECT_INDEX.md (~10 sites in lib/crawler.sh, lib/rescan.sh, lib/index_view.sh, stages/intake.sh)
4. Remaining files (3-6 sites each)

### Step 3 — Update prompt templates

Replace literal filenames in prompts/ with {{VAR}} template references.
Register new variables in lib/prompts.sh template variable map.

### Step 4 — Update migration file list

Add DRIFT_ARCHIVE.md, PROJECT_INDEX.md, and transient orphan files to the
`files=()` array in `migrations/003_to_031.sh`.

### Step 5 — Fix tekhton.sh mixed patterns

Replace literal `ARCHITECT_PLAN.md` at tekhton.sh:2457 with
`${ARCHITECT_PLAN_FILE}`. Same for lines 132-134.

### Step 6 — Register template variables in prompts.sh

Add all new `_FILE` variables to the template substitution registry so
`{{SCOUT_REPORT_FILE}}` etc. render correctly in prompts.

### Step 7 — Run tests and shellcheck

```bash
bash tests/run_tests.sh
shellcheck tekhton.sh lib/*.sh stages/*.sh migrations/*.sh
```

## Files Touched

### Modified
- `lib/config_defaults.sh` — add ~8 new _FILE variables
- `lib/prompts.sh` — register new template variables
- `stages/coder.sh` — replace SCOUT_REPORT.md references (~14 sites)
- `stages/architect.sh` — replace ARCHITECT_PLAN.md references (~7 sites)
- `stages/cleanup.sh` — replace CLEANUP_REPORT.md references (3 sites)
- `lib/dry_run.sh` — replace SCOUT_REPORT.md references (5 sites)
- `lib/turns.sh` — replace SCOUT_REPORT.md references (2 sites)
- `lib/context_compiler.sh` — replace SCOUT_REPORT.md reference (2 sites)
- `lib/specialists.sh` — prefix SPECIALIST_*_FINDINGS.md with TEKHTON_DIR (4 sites)
- `lib/specialists_helpers.sh` — prefix findings pattern (2 sites)
- `lib/drift_prune.sh` — replace DRIFT_ARCHIVE.md (1 site)
- `lib/crawler.sh` — replace PROJECT_INDEX.md (2 sites)
- `lib/index_view.sh` — replace PROJECT_INDEX.md (1 site)
- `lib/rescan.sh` — replace PROJECT_INDEX.md (2 sites)
- `lib/replan_brownfield.sh` — replace REPLAN_DELTA.md (3 sites)
- `lib/replan_midrun.sh` — replace REPLAN_DELTA.md (3 sites)
- `lib/init.sh` — replace MERGE_CONTEXT.md (2 sites)
- `lib/artifact_handler_ops.sh` — replace MERGE_CONTEXT.md (1 site)
- `lib/init_synthesize_helpers.sh` — replace MERGE_CONTEXT.md (2 sites)
- `tekhton.sh` — replace ARCHITECT_PLAN.md (lines 132-134, 2457)
- `migrations/003_to_031.sh` — add files to migration list
- `prompts/scout.prompt.md` — use {{SCOUT_REPORT_FILE}}
- `prompts/tester_write_failing.prompt.md` — use {{SCOUT_REPORT_FILE}}
- `prompts/architect.prompt.md` — use {{ARCHITECT_PLAN_FILE}}
- `prompts/architect_jr_rework.prompt.md` — use {{ARCHITECT_PLAN_FILE}}
- `prompts/architect_sr_rework.prompt.md` — use {{ARCHITECT_PLAN_FILE}}
- `prompts/architect_review.prompt.md` — use {{ARCHITECT_PLAN_FILE}}
- `prompts/cleanup.prompt.md` — use {{CLEANUP_REPORT_FILE}}
- `prompts/specialist_ui.prompt.md` — use {{VAR}} for findings file
- `prompts/specialist_performance.prompt.md` — use {{VAR}} for findings file
- `prompts/specialist_api.prompt.md` — use {{VAR}} for findings file
- `prompts/specialist_security.prompt.md` — use {{VAR}} for findings file

## Acceptance Criteria

- [ ] All 8 new `_FILE` variables exist in `lib/config_defaults.sh` with `${TEKHTON_DIR}/` prefix defaults
- [ ] Zero literal occurrences of SCOUT_REPORT.md, ARCHITECT_PLAN.md, CLEANUP_REPORT.md, DRIFT_ARCHIVE.md, PROJECT_INDEX.md, REPLAN_DELTA.md, MERGE_CONTEXT.md remain in `lib/**/*.sh` and `stages/**/*.sh` (excluding config_defaults.sh, migrations/, and tests/)
- [ ] All specialist findings files use `${TEKHTON_DIR}/` prefix in their dynamic construction
- [ ] All prompt templates that instruct agents to write files use `{{VAR}}` substitution
- [ ] `tekhton.sh` has zero literal Tekhton-managed filenames outside of CLAUDE.md references
- [ ] `migrations/003_to_031.sh` includes DRIFT_ARCHIVE.md and PROJECT_INDEX.md in its file list
- [ ] **Behavioral:** A full pipeline run on a fresh test project creates zero `.md` files at the project root other than CLAUDE.md, README.md, CHANGELOG.md, and ARCHITECTURE.md
- [ ] **Self-referential:** Tekhton's own `.claude/pipeline.conf` does not override any of the new `_FILE` variables
- [ ] `bash tests/run_tests.sh` passes
- [ ] `shellcheck tekhton.sh lib/*.sh stages/*.sh` reports zero warnings
