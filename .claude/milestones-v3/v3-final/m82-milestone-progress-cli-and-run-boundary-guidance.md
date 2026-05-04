# Milestone 82: Milestone Progress CLI & Run-Boundary Guidance
<!-- milestone-meta
id: "82"
status: "done"
-->

## Overview

Two gaps closed by one milestone: (1) developers cannot see milestone progress
without reading raw MANIFEST.cfg, and (2) after every pipeline interaction,
developers must figure out the right next command themselves.

Extends the M81 pattern (post-init guidance) to every run boundary.

## Design Decisions

### 1. New file: `lib/milestone_progress.sh`

Contains all milestone progress rendering and next-action logic. Sourced by
`tekhton.sh` alongside other lib files.

**Functions:**

#### `_render_milestone_progress()`

Reads MANIFEST.cfg via `load_manifest()` and renders a progress view.

```bash
# Usage: _render_milestone_progress [--all] [--deps]
# Output: writes directly to stdout
# Globals read: MILESTONE_DAG_ENABLED, MILESTONE_DIR, MILESTONE_MANIFEST
# Fallback: when MILESTONE_DAG_ENABLED=false, delegates to
#   parse_milestones_auto() from lib/milestone_dag_helpers.sh for inline
#   CLAUDE.md milestone parsing. In that case, dependency edges and
#   frontier detection are unavailable — show a flat status list with
#   done/pending markers and omit blocked-by annotations.
```

Progress bar uses `_BOX_H` from `lib/common.sh` (falls back to `=` on
non-UTF-8 terminals). Status markers:

| Symbol (UTF-8) | Fallback (ASCII) | Meaning |
|----------------|-------------------|---------|
| `✓`            | `+`               | Done    |
| `▶`            | `>`               | Ready (next actionable) |
| ` ` (space)    | ` `               | Blocked/pending |

Check `_is_utf8_terminal()` from `lib/common.sh` to select symbol set. When
`NO_COLOR=1` is set, strip ANSI color codes (use existing color variables
from `common.sh` — they are currently always emitted, so this milestone must
also add a `_setup_colors()` guard that sets `RED=""`, `GREEN=""`, etc. when
`NO_COLOR=1`).

#### `_compute_next_action()`

Pure function that computes a single guidance string.

```bash
# Usage: _compute_next_action
# Output: prints a single "What's next: ..." line to stdout
# Globals read:
#   PIPELINE_OUTCOME   — "success" or "failure" (set in tekhton.sh finalization)
#   MILESTONE_MODE     — true/false
#   MILESTONE_COMPLETE — true/false (set by milestone_ops.sh on completion)
#   ERROR_CATEGORY     — from lib/errors.sh classification (e.g., "build_gate",
#                        "review_exhaustion", "api_error", "transient",
#                        "stuck", "timeout")
# Returns: 0 always (informational only)
```

Decision table:

| PIPELINE_OUTCOME | MILESTONE_MODE | MILESTONE_COMPLETE | ERROR_CATEGORY | Output |
|------------------|----------------|--------------------|--------------------|--------|
| success | true | true | — | `What's next: tekhton --milestone "MNN: Title"` (next frontier milestone via `dag_find_next()`) |
| success | true | true | — | `All milestones complete. Run tekhton --draft-milestones for next steps.` (when no milestones remain) |
| success | false | — | — | `Run tekhton --status to review pipeline state.` |
| failure | — | — | build_gate | `What's next: fix build errors, then tekhton --start-at coder "task"` |
| failure | — | — | review_exhaustion | `What's next: tekhton --diagnose for recovery plan` |
| failure | — | — | api_error/transient | `What's next: re-run when API is available (transient error)` |
| failure | — | — | stuck/timeout | `What's next: tekhton --diagnose for root cause analysis` |
| failure | — | — | *(other)* | `What's next: tekhton --diagnose for details` |

#### `_diagnose_recovery_command()`

Maps the recovery classification from `_classify_failure()` in
`lib/orchestrate_recovery.sh` to a concrete CLI invocation string.

```bash
# Usage: _diagnose_recovery_command
# Output: prints "tekhton --start-at STAGE ..." to stdout
# Globals read:
#   PIPELINE_STATE_FILE — for current task/milestone
#   LAST_FAILED_STAGE   — set by orchestration on failure
#   MILESTONE_MODE, CURRENT_MILESTONE_ID, CURRENT_MILESTONE_TITLE
# Returns: 0; prints empty string if no concrete command can be derived
```

### 2. `--milestones` subcommand — progress-at-a-glance

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
`dag_find_next()`, `dag_deps_satisfied()`. No new state files.

**CLI parsing**: Add a case branch in `tekhton.sh`'s argument parser
(alongside existing `--status`, `--diagnose`, etc.):

```bash
--milestones)
    MILESTONES_CMD=true
    shift
    ;;
--all)
    MILESTONES_ALL=true
    shift
    ;;
--deps)
    MILESTONES_DEPS=true
    shift
    ;;
```

`--all` and `--deps` are standalone flags that are only meaningful when
`MILESTONES_CMD=true`. The early-exit block (after config loading,
before pipeline execution) checks `MILESTONES_CMD` and calls
`_render_milestone_progress`.

**Flags:**
- `--milestones --all` — show all milestones including completed
- `--milestones --deps` — show dependency edges (e.g., `depends: m04, m05`)

**Fallback (DAG disabled):** When `MILESTONE_DAG_ENABLED=false`, use
`parse_milestones_auto()` to read inline milestones from CLAUDE.md. Show a
flat list without dependency information. Print a note:
`(dependency tracking requires MILESTONE_DAG_ENABLED=true)`.

**No manifest:** When no MANIFEST.cfg exists and no inline milestones are
found, print: `No milestones found. Run tekhton --draft-milestones to create
some.`

### 3. Enriched `--status` — add milestone section

Current `--status` does a raw `cat` of PIPELINE_STATE.md. Append a milestone
progress summary after the existing output:

```
Milestone Progress: 5/8 (62%)
  Current: m06 — Payment Processing
  Next:    m07 — Email Notifications
```

4-line addition to the `--status` handler in `tekhton.sh`. Reads
MANIFEST.cfg, calls `dag_get_active()` and `dag_find_next()`.
Only shown when MANIFEST.cfg exists.

### 4. Contextual next-action line at finalization

After the existing completion banner and action items in
`lib/finalize_display.sh`, append the output of `_compute_next_action()`.

Insert the call at the end of the finalization display function, after the
existing diagnose hint (currently the last thing printed around line ~180).

### 5. Enrich `--diagnose` with recommended command

In `lib/diagnose_output.sh`, after the existing suggestions section in
`generate_diagnosis_report()`, append:

```
Recommended recovery:
  tekhton --start-at review --milestone "M06: Payment Processing"
```

Calls `_diagnose_recovery_command()` from `lib/milestone_progress.sh`.

### 6. `NO_COLOR` support

Add to `_setup_colors()` in `lib/common.sh` (or create it if inlined):

```bash
if [[ "${NO_COLOR:-}" == "1" ]]; then
    RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
fi
```

This is a prerequisite for the acceptance criterion and a minor gap in the
existing codebase. Scope is limited to the color variable initialization
block.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| New subcommands | 1 | `--milestones` (early-exit) |
| Modified commands | 2 | `--status`, `--diagnose` |
| New files | 1 | `lib/milestone_progress.sh` |
| New helpers | 3 | `_render_milestone_progress`, `_compute_next_action`, `_diagnose_recovery_command` |
| New config vars | 0 | — |
| Files modified | ~6 | `tekhton.sh`, `lib/finalize_display.sh`, `lib/diagnose_output.sh`, `lib/common.sh`, new `lib/milestone_progress.sh` |
| Tests | 3 | Milestone rendering, next-action logic, diagnose recovery |
| Migration | None | Pure additive |

## Acceptance Criteria

- [ ] `tekhton --milestones` renders progress bar, done/pending sections, and
      a run command for the next milestone
- [ ] `tekhton --milestones` handles: no manifest (graceful message), all
      done, all pending, mixed states, split milestones
- [ ] `tekhton --milestones --all` shows all milestones including done
- [ ] `tekhton --milestones --deps` shows dependency edges per milestone
- [ ] When `MILESTONE_DAG_ENABLED=false`, `--milestones` falls back to
      inline parsing via `parse_milestones_auto()` with a flat list
- [ ] `tekhton --status` includes a milestone progress section when
      MANIFEST.cfg exists
- [ ] Finalization banner includes a "What's next" line computed from run
      outcome and milestone state
- [ ] `_compute_next_action()` covers: success+complete+more, success+complete+none,
      success+non-milestone, failure+build, failure+review, failure+API,
      failure+stuck, failure+other
- [ ] `tekhton --diagnose` includes a concrete recovery command line
- [ ] All output respects `NO_COLOR=1` (color variables blanked)
- [ ] All output uses `_is_utf8_terminal()` to select UTF-8 or ASCII symbols
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck` on modified files reports zero warnings

## Dependencies

Depends on M81 (establishes the guided-next-step pattern and `▶` marker
convention).

## Backwards Compatibility

Pure additive. New CLI output only. No existing behavior changes. No migration
needed.
