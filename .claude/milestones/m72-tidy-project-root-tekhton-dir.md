# Milestone 72: Tidy Project Root — Move Tekhton Files into .tekhton/
<!-- milestone-meta
id: "72"
status: "done"
-->

## Overview

When Tekhton is installed into a project (greenfield or brownfield), it scatters
~30 files across the project root: logs, reports, state trackers, error dumps,
and planning docs. A healthy target project's root ends up looking like this:

```
my-project/
├── ARCHITECTURE_LOG.md
├── BUILD_ERRORS.md
├── CLARIFICATIONS.md
├── CLAUDE.md
├── CODER_SUMMARY.md
├── DESIGN.md
├── DIAGNOSIS.md
├── DRIFT_LOG.md
├── HEALTH_REPORT.md
├── HUMAN_ACTION_REQUIRED.md
├── HUMAN_NOTES.md
├── HUMAN_NOTES.md.bak
├── INTAKE_REPORT.md
├── JR_CODER_SUMMARY.md
├── MILESTONE_ARCHIVE.md
├── NON_BLOCKING_LOG.md
├── PREFLIGHT_ERRORS.md
├── REVIEWER_REPORT.md
├── SECURITY_NOTES.md
├── SECURITY_REPORT.md
├── SPECIALIST_REPORT.md
├── TESTER_PREFLIGHT.md
├── TESTER_REPORT.md
├── TEST_AUDIT_REPORT.md
├── UI_VALIDATION_REPORT.md
├── README.md         ← actual project file
├── package.json      ← actual project file
└── src/              ← actual project code
```

Twenty-four Tekhton files swamp the two real project files. This milestone
consolidates all Tekhton-managed files (except `CLAUDE.md`, which Claude Code
must load from the project root) into a single `.tekhton/` directory, mirroring
how `.claude/` already holds state and config.

This is a large but mechanical refactor: ~30 files to relocate, ~17 new config
variables to introduce for currently-hardcoded paths, and ~538 string
references across `lib/`, `stages/`, and `prompts/` to update. A migration
script moves existing files on upgrade, preserving git history via `git mv`
when files are tracked.

## Design Decisions

### 1. New base directory: `.tekhton/` (flat layout)

All Tekhton-managed files go directly into `.tekhton/` without subdirectories.
A flat layout keeps the path-update surface minimal for this milestone.
Subdivision into `reports/`, `state/`, `errors/`, `planning/` can be a
follow-up polish milestone if needed — splitting the structural move from the
categorization move reduces risk.

### 2. New config variable: `TEKHTON_DIR`

```bash
: "${TEKHTON_DIR:=.tekhton}"
```

All Tekhton-managed file defaults are re-based under `${TEKHTON_DIR}`. A user
who wants a different directory name sets `TEKHTON_DIR` in `pipeline.conf`
once, and every downstream default follows.

### 3. What stays at the project root

These files are **NOT moved**:

| File | Why it stays |
|------|--------------|
| `CLAUDE.md` | Claude Code CLI loads this from the project root on every invocation. Moving it breaks the entire tool. This is the canonical project-instructions file and must remain at `./CLAUDE.md`. |
| `README.md` | Standard project file, not Tekhton-managed. |
| `LICENSE` | Standard project file, not Tekhton-managed. |
| `.claude/` | Already organized; out of scope. Contains `pipeline.conf`, agent roles, milestones, logs, index, dashboard, etc. |
| Any user-configured path with a non-default value | If a user set `ARCHITECTURE_FILE="docs/ARCH.md"` in their pipeline.conf, the migration leaves it alone. Only files whose effective path matches the old default are relocated. |
| `DESIGN_v2.md`, `DESIGN_v3.md`, `DESIGN_v4.md` (Tekhton repo only) | These are custom design documents for the Tekhton project itself, not `DESIGN_FILE`. The migration targets only `DESIGN.md` (the default `DESIGN_FILE` value), not files matching `DESIGN_v*.md`. |

### 4. Introduce config variables for currently-hardcoded paths

Audit finding: ~17 frequently-referenced files have no config variable and are
hardcoded as `${PROJECT_DIR}/CODER_SUMMARY.md` (etc.) in 368 places across
`lib/` and `stages/`. Before we can re-base them, each needs a config variable.
Adding these variables is a pure refactor with no behavior change — the
defaults match the current literal paths — so it can land safely as step 1.

Once every site reads the variable, step 2 (changing the defaults to
`${TEKHTON_DIR}/FILENAME.md`) is a one-line diff per variable.

### 5. Migration via the existing framework

A new migration script `migrations/003_to_031.sh` bumps `TEKHTON_CONFIG_VERSION`
from `3.0` to `3.1` and performs the file relocation. Idempotent via
`migration_check` (returns 1 once the watermark is `3.1`). Uses `git mv` when
the file is tracked by git, plain `mv` otherwise. Creates `${TEKHTON_DIR}/` if
missing. Backup copies (`*.bak`, `*.back`, `*.v1-backup`) follow their parent
file. Running twice is a no-op.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Files relocated at runtime | ~30 | Listed in "File Inventory" below |
| New config variables introduced | ~17 | For currently-hardcoded paths |
| Existing config variables whose defaults change | ~13 | E.g. `DRIFT_LOG_FILE`, `SECURITY_REPORT_FILE` |
| `lib/` + `stages/` occurrences updated | ~368 | Replace literal `PROJECT_DIR/NAME.md` with `${VAR}` |
| `prompts/*.prompt.md` occurrences updated | ~170 | Replace literal names with `{{VAR}}` template refs |
| New migration script | 1 | `migrations/003_to_031.sh` |
| New template variables exposed to prompts | ~17 | Mirror the new config vars |
| Tests touched | ~5–10 | Self-tests that assert file locations |

## File Inventory

### Files with existing `_FILE` config variables (change default only)

| Variable | Old default | New default |
|----------|-------------|-------------|
| `ARCHITECTURE_LOG_FILE` | `ARCHITECTURE_LOG.md` | `${TEKHTON_DIR}/ARCHITECTURE_LOG.md` |
| `DRIFT_LOG_FILE` | `DRIFT_LOG.md` | `${TEKHTON_DIR}/DRIFT_LOG.md` |
| `HUMAN_ACTION_FILE` | `HUMAN_ACTION_REQUIRED.md` | `${TEKHTON_DIR}/HUMAN_ACTION_REQUIRED.md` |
| `NON_BLOCKING_LOG_FILE` | `NON_BLOCKING_LOG.md` | `${TEKHTON_DIR}/NON_BLOCKING_LOG.md` |
| `MILESTONE_ARCHIVE_FILE` | `MILESTONE_ARCHIVE.md` | `${TEKHTON_DIR}/MILESTONE_ARCHIVE.md` |
| `SECURITY_NOTES_FILE` | `SECURITY_NOTES.md` | `${TEKHTON_DIR}/SECURITY_NOTES.md` |
| `SECURITY_REPORT_FILE` | `SECURITY_REPORT.md` | `${TEKHTON_DIR}/SECURITY_REPORT.md` |
| `INTAKE_REPORT_FILE` | `INTAKE_REPORT.md` | `${TEKHTON_DIR}/INTAKE_REPORT.md` |
| `TDD_PREFLIGHT_FILE` | `TESTER_PREFLIGHT.md` | `${TEKHTON_DIR}/TESTER_PREFLIGHT.md` |
| `TEST_AUDIT_REPORT_FILE` | `TEST_AUDIT_REPORT.md` | `${TEKHTON_DIR}/TEST_AUDIT_REPORT.md` |
| `HEALTH_REPORT_FILE` | `HEALTH_REPORT.md` | `${TEKHTON_DIR}/HEALTH_REPORT.md` |
| `DESIGN_FILE` | `""` (empty; resolved to `DESIGN.md` by planning) | `${TEKHTON_DIR}/DESIGN.md` |
| `PROJECT_RULES_FILE` | `CLAUDE.md` | `CLAUDE.md` **(unchanged — stays at root)** |

### New config variables for currently-hardcoded paths

| New variable | Default | Used by |
|--------------|---------|---------|
| `TEKHTON_DIR` | `.tekhton` | Base directory (new root for everything below) |
| `CODER_SUMMARY_FILE` | `${TEKHTON_DIR}/CODER_SUMMARY.md` | `stages/coder.sh`, `lib/hooks.sh`, `lib/context_compiler.sh`, `lib/drift_cleanup.sh`, `lib/finalize*`, `lib/notes_acceptance*`, prompts |
| `REVIEWER_REPORT_FILE` | `${TEKHTON_DIR}/REVIEWER_REPORT.md` | `stages/review*`, `lib/hooks.sh`, `lib/drift_cleanup.sh`, prompts |
| `TESTER_REPORT_FILE` | `${TEKHTON_DIR}/TESTER_REPORT.md` | `stages/tester*`, `lib/test_audit.sh`, `lib/hooks.sh`, prompts |
| `JR_CODER_SUMMARY_FILE` | `${TEKHTON_DIR}/JR_CODER_SUMMARY.md` | `stages/coder.sh`, `lib/state.sh`, `lib/hooks.sh`, prompts |
| `BUILD_ERRORS_FILE` | `${TEKHTON_DIR}/BUILD_ERRORS.md` | `lib/gates*.sh`, `lib/orchestrate_recovery.sh`, `lib/error_patterns.sh`, prompts |
| `BUILD_RAW_ERRORS_FILE` | `${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt` | `lib/gates_phases.sh`, `lib/gates_ui.sh` |
| `UI_TEST_ERRORS_FILE` | `${TEKHTON_DIR}/UI_TEST_ERRORS.md` | `lib/gates_ui.sh`, `lib/gates.sh`, prompts |
| `PREFLIGHT_ERRORS_FILE` | `${TEKHTON_DIR}/PREFLIGHT_ERRORS.md` | `lib/orchestrate.sh`, `lib/state.sh`, `stages/coder.sh`, prompts |
| `DIAGNOSIS_FILE` | `${TEKHTON_DIR}/DIAGNOSIS.md` | `lib/diagnose_output.sh`, `lib/diagnose_rules.sh` |
| `CLARIFICATIONS_FILE` | `${TEKHTON_DIR}/CLARIFICATIONS.md` | `lib/clarify.sh`, `lib/intake_verdict_handlers.sh`, `lib/context_cache.sh`, prompts |
| `HUMAN_NOTES_FILE` | `${TEKHTON_DIR}/HUMAN_NOTES.md` | `lib/notes*.sh`, `lib/context.sh`, `lib/inbox.sh`, prompts |
| `SPECIALIST_REPORT_FILE` | `${TEKHTON_DIR}/SPECIALIST_REPORT.md` | `lib/specialists.sh` |
| `UI_VALIDATION_REPORT_FILE` | `${TEKHTON_DIR}/UI_VALIDATION_REPORT.md` | `lib/ui_validate*.sh`, `lib/gates.sh`, `lib/hooks.sh`, prompts |

### Backup variants (follow their parent file automatically)

- `HUMAN_NOTES.md.bak` → `${TEKHTON_DIR}/HUMAN_NOTES.md.bak`
- `HUMAN_NOTES.md.back` → `${TEKHTON_DIR}/HUMAN_NOTES.md.back`
- `HUMAN_NOTES.md.v1-backup` → `${TEKHTON_DIR}/HUMAN_NOTES.md.v1-backup`

These don't need explicit config variables; `lib/notes*.sh` derives them as
`${HUMAN_NOTES_FILE}.bak` etc. The migration sweeps `HUMAN_NOTES.md*` as a
single glob.

## Implementation Plan

### Step 1 — Introduce config variables (no behavior change)

Edit `lib/config_defaults.sh`:

1. Add `TEKHTON_DIR` near the top of the file (right after `PROJECT_NAME`):
   ```bash
   # Base directory for all Tekhton-managed files (logs, reports, state).
   # CLAUDE.md stays at the project root — Claude Code loads it there.
   : "${TEKHTON_DIR:=.tekhton}"
   ```
2. Add the ~14 new `_FILE` variables listed in the "File Inventory" table
   above, **pointing at the OLD root-level paths** (e.g.
   `CODER_SUMMARY_FILE:=CODER_SUMMARY.md`). Do NOT re-base to `${TEKHTON_DIR}`
   yet. This is the pure-refactor step — no observable change.
3. Export the new variables from `lib/prompts.sh`'s template-variable registry
   so they can be referenced as `{{CODER_SUMMARY_FILE}}` etc. in prompts.

Validate: `bash tests/run_tests.sh` must pass with zero behavior change.

### Step 2 — Replace hardcoded paths with config variables

For each new config variable, replace every literal
`${PROJECT_DIR}/CODER_SUMMARY.md` (and equivalent) with `${CODER_SUMMARY_FILE}`.
Work through the variables one at a time so each diff is reviewable and
testable in isolation.

**Order of attack** (highest-count first, so each batch is self-contained):

1. `CODER_SUMMARY_FILE` — 51 sites in `stages/coder.sh` alone, plus
   `lib/hooks.sh`, `lib/context_compiler.sh`, `lib/drift_cleanup.sh`,
   `lib/finalize*`, `lib/notes_acceptance*`, `lib/run_memory.sh`,
   `lib/report.sh`, `stages/cleanup.sh`.
2. `REVIEWER_REPORT_FILE` — `stages/review.sh`, `stages/review_helpers.sh`,
   `lib/hooks.sh`, `lib/drift_cleanup.sh`, `lib/orchestrate*.sh`.
3. `TESTER_REPORT_FILE` — `stages/tester*.sh`, `lib/test_audit.sh`,
   `lib/hooks.sh`, `lib/state.sh`, `lib/finalize*`.
4. `BUILD_ERRORS_FILE`, `BUILD_RAW_ERRORS_FILE`, `UI_TEST_ERRORS_FILE` —
   `lib/gates*.sh`, `lib/error_patterns.sh`, `lib/orchestrate_recovery.sh`.
5. `HUMAN_NOTES_FILE` — `lib/notes*.sh` (18+4+7+23+7+5+1+3 occurrences),
   `lib/context.sh`, `lib/context_cache.sh`, `lib/inbox.sh`.
6. `JR_CODER_SUMMARY_FILE`, `PREFLIGHT_ERRORS_FILE`, `DIAGNOSIS_FILE`,
   `CLARIFICATIONS_FILE`, `SPECIALIST_REPORT_FILE`, `UI_VALIDATION_REPORT_FILE`
   — smaller batches, group by coupling.

For each file touched, run `bash tests/run_tests.sh` before moving on.

### Step 3 — Update prompt templates

Replace literal filenames in `prompts/*.prompt.md` with `{{VAR}}` template
references. This is mechanical: the template engine already handles `{{VAR}}`
substitution.

Grep list (from audit): 32 prompt files with 170 occurrences. Highest-impact:
- `prompts/coder.prompt.md` (14)
- `prompts/reviewer.prompt.md` (12)
- `prompts/tester.prompt.md` (10)
- `prompts/plan_generate.prompt.md` (25) — mostly `DESIGN.md` references
- `prompts/init_synthesize_claude.prompt.md` (10)
- `prompts/replan.prompt.md` (10)

Be careful with two patterns:
- **Instructional references** ("Write `REVIEWER_REPORT.md` to report your
  findings") — these should become "Write `{{REVIEWER_REPORT_FILE}}` to
  report your findings" so the agent is told the correct path.
- **Literal path references inside code blocks/examples** — same treatment;
  let the template engine expand them.

### Step 4 — Re-base defaults to `${TEKHTON_DIR}/`

Now that every site reads the variables, change the defaults in
`lib/config_defaults.sh`:

```bash
: "${ARCHITECTURE_LOG_FILE:=${TEKHTON_DIR}/ARCHITECTURE_LOG.md}"
: "${DRIFT_LOG_FILE:=${TEKHTON_DIR}/DRIFT_LOG.md}"
# ...etc. for all ~27 variables
```

Leave `PROJECT_RULES_FILE:=CLAUDE.md` untouched.

Important: `TEKHTON_DIR` must be declared **before** any `_FILE` variable that
references it, because bash `:=` expansion is left-to-right.

Create `${TEKHTON_DIR}/` in `tekhton.sh`'s startup sequence (right after
config load, before any stage runs) so writes don't fail on fresh projects:

```bash
mkdir -p "${PROJECT_DIR}/${TEKHTON_DIR}" 2>/dev/null || true
```

### Step 5 — Write the migration script

Create `migrations/003_to_031.sh`, modeled on `002_to_003.sh`:

```bash
migration_version() { echo "3.1"; }

migration_description() {
    echo "Move Tekhton-managed files from project root into .tekhton/"
}

migration_check() {
    local project_dir="$1"
    local conf_file="${project_dir}/.claude/pipeline.conf"
    [[ -f "$conf_file" ]] || return 1
    # Already applied if watermark is >= 3.1
    local ver
    ver=$(grep '^TEKHTON_CONFIG_VERSION=' "$conf_file" | cut -d'=' -f2 | tr -d '"')
    [[ "$ver" == "3.1" || "$ver" > "3.1" ]] && return 1
    return 0
}

migration_apply() {
    local project_dir="$1"
    local tekhton_dir="${project_dir}/.tekhton"
    mkdir -p "$tekhton_dir"

    local files=(
        ARCHITECTURE_LOG.md DRIFT_LOG.md HUMAN_ACTION_REQUIRED.md
        NON_BLOCKING_LOG.md MILESTONE_ARCHIVE.md SECURITY_NOTES.md
        SECURITY_REPORT.md INTAKE_REPORT.md TESTER_PREFLIGHT.md
        TEST_AUDIT_REPORT.md HEALTH_REPORT.md DESIGN.md
        CODER_SUMMARY.md REVIEWER_REPORT.md TESTER_REPORT.md
        JR_CODER_SUMMARY.md BUILD_ERRORS.md BUILD_RAW_ERRORS.txt
        UI_TEST_ERRORS.md PREFLIGHT_ERRORS.md DIAGNOSIS.md
        CLARIFICATIONS.md SPECIALIST_REPORT.md UI_VALIDATION_REPORT.md
    )

    local f src dst
    for f in "${files[@]}"; do
        src="${project_dir}/${f}"
        dst="${tekhton_dir}/${f}"
        [[ -e "$src" ]] || continue
        _move_preserving_history "$src" "$dst" "$project_dir"
    done

    # HUMAN_NOTES.md + all its backup variants (glob)
    local hn
    for hn in "${project_dir}/HUMAN_NOTES.md"*; do
        [[ -e "$hn" ]] || continue
        _move_preserving_history "$hn" "${tekhton_dir}/$(basename "$hn")" "$project_dir"
    done

    return 0
}

# _move_preserving_history SRC DST PROJECT_DIR
# Uses git mv if the file is tracked, plain mv otherwise.
_move_preserving_history() {
    local src="$1" dst="$2" project_dir="$3"
    local rel
    rel="${src#"${project_dir}/"}"
    if ( cd "$project_dir" && git ls-files --error-unmatch -- "$rel" ) &>/dev/null; then
        ( cd "$project_dir" && git mv -- "$rel" "${dst#"${project_dir}/"}" )
    else
        mv -- "$src" "$dst"
    fi
}
```

### Step 6 — Update init flow + `.gitignore` guidance

- `lib/init_config.sh` / `lib/init_config_emitters.sh`: emit `.tekhton/` as the
  new default base and add a commented `TEKHTON_DIR="..."` line in the
  generated `pipeline.conf`.
- `templates/pipeline.conf.example`: add `TEKHTON_DIR` section header +
  comment.
- `lib/init.sh`: create `${PROJECT_DIR}/${TEKHTON_DIR}/` during init (same
  call as step 4's startup mkdir — deduplicate via a helper if clean).
- Update the init report / welcome message to mention `.tekhton/` as the new
  artifact directory.
- `.gitignore` guidance: add a commented recommendation to the init flow that
  users MAY want to gitignore `${TEKHTON_DIR}/` (except for intentionally
  tracked files like `DESIGN.md` and `MILESTONE_ARCHIVE.md`). Do NOT
  auto-generate a `.gitignore` entry — that's the user's choice.

### Step 7 — Update documentation + the manifest

- `README.md` top-level description: mention `.tekhton/` alongside `.claude/`.
- `docs/`: update any page that lists root-level files or shows example
  directory trees.
- `CLAUDE.md` (this repo's project-level file): update the "Repository Layout"
  section header if it describes target-project layout (it mostly describes
  Tekhton's own `lib/stages/prompts/` layout, which is unaffected).
- `.claude/milestones/MANIFEST.cfg`: add the M72 row:
  ```
  m72|Tidy Project Root — Move Tekhton Files into .tekhton/|done|m71|m72-tidy-project-root-tekhton-dir.md|devx
  ```

### Step 8 — Tekhton version bump

Edit `tekhton.sh`: change `TEKHTON_VERSION="3.71.0"` to `TEKHTON_VERSION="3.72.0"`.

### Step 9 — Run full self-test suite + shellcheck

```bash
bash tests/run_tests.sh
shellcheck tekhton.sh lib/*.sh stages/*.sh migrations/*.sh
```

## Files Touched (summary)

### Added
- `migrations/003_to_031.sh` — new migration script
- `.claude/milestones/m72-tidy-project-root-tekhton-dir.md` — this file

### Modified (config + libraries)
- `lib/config_defaults.sh` — adds `TEKHTON_DIR` + ~14 new `_FILE` vars, re-bases ~27 defaults
- `lib/config.sh` — validation for `TEKHTON_DIR` if needed
- `lib/prompts.sh` — expose new vars as template variables
- `lib/init.sh`, `lib/init_config.sh`, `lib/init_config_emitters.sh`,
  `lib/init_config_sections.sh` — init flow updates
- `tekhton.sh` — create `${TEKHTON_DIR}/` at startup; bump `TEKHTON_VERSION`

### Modified (path references; exact list produced during step 2)
Approximately 59 files in `lib/` and `stages/` — grep baseline:
`gates.sh`, `gates_phases.sh`, `gates_completion.sh`, `gates_ui.sh`,
`hooks.sh`, `orchestrate.sh`, `orchestrate_helpers.sh`,
`orchestrate_recovery.sh`, `state.sh`, `turns.sh`, `report.sh`, `agent.sh`,
`agent_helpers.sh`, `agent_retry.sh`, `errors.sh`, `errors_helpers.sh`,
`error_patterns.sh`, `error_patterns.sh`, `clarify.sh`,
`intake_verdict_handlers.sh`, `inbox.sh`, `context.sh`, `context_cache.sh`,
`context_compiler.sh`, `drift.sh`, `drift_artifacts.sh`, `drift_cleanup.sh`,
`diagnose_output.sh`, `diagnose_rules.sh`, `dashboard_emitters.sh`,
`dashboard_parsers.sh`, `finalize.sh`, `finalize_display.sh`,
`milestone_split.sh`, `milestone_window.sh`, `indexer_helpers.sh`,
`run_memory.sh`, `notes.sh`, `notes_core.sh`, `notes_single.sh`,
`notes_cli.sh`, `notes_cli_write.sh`, `notes_migrate.sh`,
`notes_acceptance.sh`, `notes_acceptance_helpers.sh`, `notes_triage_report.sh`,
`ui_validate.sh`, `ui_validate_report.sh`, `specialists.sh`, `test_audit.sh`,
`security_helpers.sh`, `stages/coder.sh`, `stages/review.sh`,
`stages/review_helpers.sh`, `stages/tester.sh`, `stages/tester_fix.sh`,
`stages/tester_continuation.sh`, `stages/tester_validation.sh`,
`stages/tester_timing.sh`, `stages/cleanup.sh`, `stages/intake.sh`.

### Modified (prompts)
32 prompt files in `prompts/` — see step 3 for the highest-count targets.

### Modified (docs + templates)
- `README.md`
- `docs/` pages that list root-level files
- `templates/pipeline.conf.example`
- `.claude/milestones/MANIFEST.cfg` — add M72 row
- `CLAUDE.md` — add a note under "Repository Layout" if it describes target
  project layout

## Acceptance Criteria

- [ ] `TEKHTON_DIR` config var exists in `lib/config_defaults.sh` with default `.tekhton`
- [ ] `lib/config_defaults.sh` declares `TEKHTON_DIR` **before** any variable that expands it
- [ ] All ~14 new `_FILE` variables listed in "File Inventory" exist in `config_defaults.sh`
- [ ] All ~13 existing `_FILE` variables that moved have their defaults re-based under `${TEKHTON_DIR}`
- [ ] `PROJECT_RULES_FILE` default is still `CLAUDE.md` (unchanged — verified)
- [ ] Zero literal occurrences of the 25 migrated filenames remain in `lib/**/*.sh` and `stages/**/*.sh` outside of `config_defaults.sh` and `migrations/003_to_031.sh`. Verify via:
      ```
      grep -rEn '\b(CODER_SUMMARY|REVIEWER_REPORT|TESTER_REPORT|JR_CODER_SUMMARY|BUILD_ERRORS|DIAGNOSIS|CLARIFICATIONS|UI_VALIDATION_REPORT|SPECIALIST_REPORT|PREFLIGHT_ERRORS|BUILD_RAW_ERRORS|UI_TEST_ERRORS|HUMAN_NOTES|DRIFT_LOG|ARCHITECTURE_LOG|MILESTONE_ARCHIVE|SECURITY_REPORT|SECURITY_NOTES|INTAKE_REPORT|TEST_AUDIT_REPORT|HEALTH_REPORT|TESTER_PREFLIGHT|HUMAN_ACTION_REQUIRED|NON_BLOCKING_LOG)\.(md|txt)\b' lib/ stages/
      ```
      should return zero hits (exclude `config_defaults.sh` and the migration script).
- [ ] All `prompts/*.prompt.md` references to the migrated filenames use `{{VAR}}` template substitution
- [ ] `migrations/003_to_031.sh` exists, declares `migration_version() { echo "3.1"; }`, and is idempotent
- [ ] Migration uses `git mv` when the source is tracked, plain `mv` otherwise
- [ ] Migration moves `HUMAN_NOTES.md*` (including all backup variants) as a glob
- [ ] Migration does NOT move `CLAUDE.md`, `README.md`, or `LICENSE`
- [ ] Migration does NOT move files if the user has configured a non-default `_FILE` path in their `pipeline.conf`
- [ ] Running the migration twice is a no-op (`migration_check` returns 1 the second time)
- [ ] `tekhton.sh` creates `${PROJECT_DIR}/${TEKHTON_DIR}/` on startup before any stage runs
- [ ] `tekhton.sh` `TEKHTON_VERSION` is `3.72.0`
- [ ] `.claude/milestones/MANIFEST.cfg` contains the M72 row with `status=done`, `depends_on=m71`
- [ ] `bash tests/run_tests.sh` passes with zero failures
- [ ] `shellcheck tekhton.sh lib/*.sh stages/*.sh migrations/*.sh` reports zero warnings
- [ ] On a fresh project (no `.tekhton/` yet), a full `tekhton "trivial task"` run writes all artifacts under `.tekhton/` and leaves the project root clean
- [ ] On a V3-era project with existing root-level files, `tekhton --migrate` moves them into `.tekhton/` and bumps the config version watermark to `3.1`

## Watch For

- **CLAUDE.md must stay at the project root.** Claude Code CLI reads it from
  there on every invocation — moving it breaks the entire tool. The
  `PROJECT_RULES_FILE` default is already `CLAUDE.md` (not prefixed) and must
  remain that way. The migration's file list must NOT include `CLAUDE.md`.
- **`DESIGN_v2.md`, `DESIGN_v3.md`, `DESIGN_v4.md` in the Tekhton repo are
  NOT migrated.** These are custom design documents for this repo, not
  `DESIGN_FILE` output. The migration only moves files whose name matches the
  default `DESIGN.md`. Similarly, `V3_REVIEW_PLAN.md`, `ARCHITECTURE.md` (if
  it's a user-maintained architecture doc), and other repo-specific files are
  not on the migration list.
- **Respect user-configured paths.** If a user set `DRIFT_LOG_FILE="logs/drift.md"`
  in their `pipeline.conf`, the migration must NOT touch that file. The check
  is: only migrate a file if its current effective path equals the *old*
  default (e.g. `DRIFT_LOG.md` at project root). The simplest implementation
  is to look for files at the hardcoded old-default paths in project root and
  not consult the user's overridden config at all — any user who's already
  customized will not have the default-named file to move.
- **`git mv` vs `mv`.** Use `git mv` for tracked files to preserve history,
  plain `mv` otherwise. Do NOT use `git mv` unconditionally — it fails on
  untracked files. Check with `git ls-files --error-unmatch`.
- **Left-to-right bash expansion in defaults.** `TEKHTON_DIR` must be declared
  **before** any `_FILE` variable that interpolates it. `: "${X:=${Y}/foo}"`
  requires `Y` to already be set. Put `TEKHTON_DIR` at the top of
  `config_defaults.sh` next to `PROJECT_NAME`.
- **Template variable registry.** New `_FILE` vars must be added to
  `lib/prompts.sh`'s template substitution map, otherwise `{{CODER_SUMMARY_FILE}}`
  in a prompt will render as the literal string `{{CODER_SUMMARY_FILE}}`.
  Cross-check every new var against the registry.
- **`HUMAN_NOTES.md.bak` is atomic-swap territory.** `lib/notes_single.sh`
  creates backups via `cp` → edit → `mv` in-place. After this milestone those
  backups live next to `${HUMAN_NOTES_FILE}` in `.tekhton/`. Verify the
  notes-rewrite flow still works end-to-end.
- **Intra-run context cache** (`lib/context_cache.sh`) snapshots file contents
  keyed by path. Make sure its cache keys use the *new* paths so a run after
  migration doesn't spuriously read a stale root-level copy.
- **Dashboard file watchers** (`lib/dashboard_emitters.sh`,
  `lib/dashboard_parsers.sh`) probably hardcode paths. The Watchtower UI will
  break if those aren't updated.
- **Causal log and metrics files are already in `.claude/logs/`** — do not
  move them into `.tekhton/`. Keeping observability data under `.claude/`
  aligns with the "runtime state" vs "pipeline artifacts" split.
- **The `.claude/` directory is not renamed.** Agent roles, pipeline.conf,
  milestones, logs, dashboard, index, serena, and checkpoints stay under
  `.claude/` because that's the Claude Code convention and changing it would
  be gratuitous churn. Only **project-root** files move — not `.claude/` files.
- **Idempotency check in the migration.** `migration_check` returns 1 once
  the watermark is `3.1` — but also gracefully handle the case where a user
  manually created `.tekhton/` and already moved some files. For each file,
  check `[[ -e "$src" ]] || continue` before attempting the move; that alone
  makes the body safe to re-run.
- **Zero behavior change at step 1.** Introducing the config vars with
  identical old defaults must not alter any observable behavior. Run the
  test suite after step 1 before touching anything else, so any later
  regression can be localized to the path-rewriting step.
- **Don't over-abstract.** Resist the temptation to introduce a
  `tekhton_path()` helper function or symbolic-name lookup table. A flat set
  of `_FILE` variables is simpler and matches the existing convention for
  `ARCHITECTURE_LOG_FILE`, `DRIFT_LOG_FILE`, etc.
- **File-length guardrail.** If `lib/config_defaults.sh` grows past 300 lines
  after adding the new vars, extract to a companion `lib/config_defaults_paths.sh`
  (per M71's shell hygiene rule and M70's file-length rule). Current length:
  501 lines. It's already over the guardrail — this is an existing violation,
  not something M72 introduces, but be aware. A future cleanup could split it
  regardless of M72; that's out of scope here.

## Seeds Forward

- **Subdirectory layout.** A follow-up milestone could split `.tekhton/` into
  `reports/`, `state/`, `errors/`, and `planning/` subdirs for even more
  organization. With every `_FILE` variable already in place, that's a
  one-line-per-var change in `config_defaults.sh` plus a migration script —
  much cheaper than trying to do it now.
- **`.gitignore` opinionation.** Tekhton could auto-generate a `.gitignore`
  stanza for `.tekhton/errors/` and `.tekhton/*.log` during init, while
  leaving user-facing files (`DESIGN.md`, `HUMAN_NOTES.md`, `MILESTONE_ARCHIVE.md`)
  tracked by default. Out of scope for M72 — that's a policy decision, not
  a tidying one.
- **Symlinks for CLAUDE.md-adjacent files.** If users ask for `DESIGN.md` or
  `HUMAN_NOTES.md` to remain at the project root for discoverability, we
  could support root-level symlinks pointing into `.tekhton/`. Out of scope.
- **V4 reset opportunity.** When V4 begins, the `.claude/milestones/` reset
  is a natural moment to also reconsider whether `.claude/` and `.tekhton/`
  should be consolidated further. Flagging for V4 design.
- **Test fixtures.** The self-test fixtures in `tests/fixtures/` may reference
  root-level paths. Audit during step 9 and update as needed — not expected
  to be a large change, but worth grepping `tests/` for the same filename
  list used in acceptance criteria.
