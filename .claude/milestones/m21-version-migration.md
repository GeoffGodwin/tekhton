#### Milestone 21: Version Migration Framework & Project Upgrade
<!-- milestone-meta
id: "21"
status: "done"
-->

Build a general-purpose migration system that automatically upgrades project
configurations when Tekhton's version advances past what the project was set up
with. Handles config schema evolution, directory structure changes, new required
files, and deprecated features — non-destructively and idempotently.

This solves the "I updated Tekhton and now my 7 projects are broken" problem.
Every project gets a version watermark. Every Tekhton startup checks the watermark
against the running version. When there's a gap, migrations run automatically
(with user confirmation) or on-demand via `tekhton --migrate`.

This is infrastructure that every future major version depends on. Build it once,
use it forever.

Files to create:
- `lib/migrate.sh` — Migration framework:
  **Version watermark:**
  - Every project gets `TEKHTON_CONFIG_VERSION=X.Y` in pipeline.conf (written
    by --init, updated after successful migration). This tracks which version of
    Tekhton last configured this project, NOT which version is currently running.
  - The watermark uses MAJOR.MINOR only (not PATCH). Patch versions never
    require migration — they're hotfixes to existing behavior.

  **Version detection** (`detect_config_version(project_dir)`):
  - If TEKHTON_CONFIG_VERSION exists in pipeline.conf → return it
  - If pipeline.conf exists but no version key → infer version from artifacts:
    - Has MANIFEST.cfg + .claude/milestones/ → V3 (3.0)
    - Has pipeline.conf with V2-era keys (CONTEXT_BUDGET_PCT, etc.) → V2 (2.0)
    - Has pipeline.conf with only basic keys → V1 (1.0)
    - Has .claude/ but no pipeline.conf → pre-Tekhton (0.0, prompt for --init)
  - Version inference is a heuristic fallback for projects created before the
    watermark was introduced. Once migrated, the explicit version is used.

  **Migration runner** (`run_migrations(from_version, to_version)`):
  - Load all migration scripts from `${TEKHTON_HOME}/migrations/`
  - Filter to scripts that apply (from_version < script_version <= to_version)
  - Sort by version number (ascending)
  - For each applicable migration:
    1. Print: "Migrating project from X.Y to X.Z..."
    2. Run the migration's `check()` function (returns 0 if migration needed,
       1 if already applied — idempotency check)
    3. If needed: run the migration's `apply()` function
    4. If apply() returns 0: print success, continue
    5. If apply() returns non-zero: print error, STOP (don't run further
       migrations — partial migration state is safer than skipping failures)
  - After all migrations complete: update TEKHTON_CONFIG_VERSION in pipeline.conf
  - Print summary: "Migration complete: X.Y → X.Z (N migrations applied)"

  **Migration script interface:**
  Each migration script exports three functions:
  ```bash
  # migrations/002_to_003.sh
  migration_version() { echo "3.0"; }

  migration_check() {
      # Return 0 if this migration needs to run, 1 if already applied
      # Must be idempotent — safe to call repeatedly
      local project_dir="$1"
      [[ -f "${project_dir}/.claude/agents/security.md" ]] && return 1
      return 0
  }

  migration_apply() {
      # Perform the migration. Return 0 on success, non-zero on failure.
      # Must be non-destructive — never delete user content without backup.
      local project_dir="$1"
      # ... migration logic ...
      return 0
  }

  migration_description() {
      echo "Add V3 agent roles, migrate milestones to DAG, add new config keys"
  }
  ```

  **Startup integration** (`check_project_version()`):
  Called at tekhton.sh startup, after config is loaded but before any pipeline
  stage runs:
  1. Read TEKHTON_CONFIG_VERSION from pipeline.conf
  2. Compare against TEKHTON_VERSION (running version)
  3. If equal or config is newer: proceed (no migration needed)
  4. If config is older:
     - If MIGRATION_AUTO=true (default): print migration summary and ask
       for confirmation ("Project configured for V2.0, running V3.5.
       N migrations available. Apply? [Y/n]")
     - If MIGRATION_AUTO=false: print warning and suggest `tekhton --migrate`
     - If `--migrate` flag was passed: run without confirmation
     - If running in --complete/--auto-advance: auto-apply (with logging)
       to avoid blocking autonomous runs. This is safe because migrations
       are non-destructive and idempotent.
  5. After migration: proceed with pipeline as normal

  **Backup before migration** (`backup_project_config()`):
  Before ANY migration runs:
  - Create `.claude/migration-backups/pre-X.Y-to-X.Z/` directory
  - Copy: pipeline.conf, CLAUDE.md, all files in .claude/agents/,
    MANIFEST.cfg (if exists), any file that a migration might modify
  - Print: "Backup created at .claude/migration-backups/pre-X.Y-to-X.Z/"
  - This enables `tekhton --migrate --rollback` to restore the pre-migration state

  **Milestone migration impact validation** (`validate_milestone_migration_section()`):
  During milestone loading (when DAG is parsed), check each pending milestone
  file for a `Migration impact:` section. If missing:
  - Log a warning: "Milestone M{XX} has no Migration impact section"
  - Add to Watchtower data as a milestone health warning
  - The PM agent (M10) also checks this during intake evaluation and can
    auto-add the section (TWEAKED verdict) or ask the human (NEEDS_CLARITY)
  This is a WARNING, not a hard block — milestones without the section still
  run, but the gap is visible everywhere (terminal, Watchtower, intake report).

  **Migration impact section format** (in milestone .md files):
  ```markdown
  Migration impact:
  - New config keys: KEY1, KEY2, ...
  - New files in .claude/: path/to/file.md
  - Modified file formats: FILE (description of change)
  - Breaking changes: description (or "None")
  - Migration script update required: YES|NO
  ```
  Or: `Migration impact: NONE — no config or file format changes.`
  The section is required in all new milestones going forward. Existing
  milestones (M01-M20) are grandfathered but should be backfilled when
  convenient.

  **Template enforcement:**
  - Update `templates/plans/*.md` (design doc templates used by --plan) to
    include the Migration impact section as a required field
  - Update `prompts/milestone_split.prompt.md` to require the section in
    sub-milestones generated by the splitter
  - Update `prompts/plan_generate.prompt.md` to include the section in
    generated milestones

  **Rollback** (`rollback_migration(project_dir)`):
  - List available backups in .claude/migration-backups/
  - User selects which backup to restore
  - Copy backup files back to their original locations
  - Restore TEKHTON_CONFIG_VERSION to the backup's version
  - Print: "Rolled back to pre-migration state (V X.Y)"

- `migrations/001_to_002.sh` — V1 → V2 migration:
  **check:** Does pipeline.conf have CONTEXT_BUDGET_PCT? If yes → already V2.
  **apply:**
  - Add V2 config keys with defaults (context budget, milestones, clarification,
    specialist, metrics, cleanup, replan keys)
  - Create .claude/agents/ directory if missing
  - Ensure agent role files exist (copy from templates if missing)
  - Add milestone metadata support (if milestones exist in CLAUDE.md)
  - Log all changes to migration output

- `migrations/002_to_003.sh` — V2 → V3 migration:
  **check:** Does pipeline.conf have SECURITY_AGENT_ENABLED? If yes → already V3.
  **apply:**
  - **Config keys:** Add all V3 config keys to pipeline.conf with defaults:
    SECURITY_*, INTAKE_*, HEALTH_*, DASHBOARD_*, QUOTA_*, TEST_AUDIT_*,
    MILESTONE_DAG_ENABLED, REPO_MAP_*, SERENA_*. Each new key is added with
    a comment: "# Added by V3 migration — see docs for details"
  - **Agent roles:** Copy security.md and intake.md to .claude/agents/ from
    Tekhton templates (only if they don't already exist — don't overwrite
    user customizations)
  - **Milestone DAG:** If inline milestones exist in CLAUDE.md and no
    MANIFEST.cfg exists, call `migrate_inline_milestones()` (reuse M01/M02
    infrastructure). This subsumes the existing auto-migration logic.
  - **Watchtower:** If DASHBOARD_ENABLED=true (the default), create
    .claude/dashboard/ with static files (same as --init would)
  - **Pipeline.conf format:** Add section headers as comments to organize
    the growing config file:
    ```
    # === Security Agent ===
    SECURITY_AGENT_ENABLED=true
    ...
    # === Task Intake / PM Agent ===
    INTAKE_AGENT_ENABLED=true
    ...
    ```
  - **Template refresh:** Check if agent role files (.claude/agents/coder.md,
    reviewer.md, tester.md) are from V2 templates (check for a template
    version marker comment). If so, offer to update them while preserving
    user customizations (diff + merge, not overwrite). If no marker exists,
    leave them untouched (assume user-customized).

  **Non-destructive guarantees:**
  - NEVER delete any user file
  - NEVER overwrite existing agent role files (only add new ones)
  - NEVER modify CLAUDE.md content (only the milestone DAG migration moves
    milestone blocks, which is already proven in M01/M02)
  - All new config keys are appended, never replacing existing values
  - Backup exists before any changes

- `migrations/README.md` — Migration authoring guide:
  How to write a migration script for future versions. Documents the interface
  (version, check, apply, description), the non-destructive guarantees,
  the idempotency requirement, and testing expectations.

Files to modify:
- `tekhton.sh` — Add `--migrate` flag handling:
  - `--migrate` → run migrations with confirmation
  - `--migrate --force` → run without confirmation (for CI/scripts)
  - `--migrate --rollback` → restore from backup
  - `--migrate --check` → show what migrations would run, don't apply
  - `--migrate --status` → show current config version vs running version
  Add `check_project_version()` call at startup (after config load).
  Source lib/migrate.sh.

- `lib/config_defaults.sh` — Add:
  TEKHTON_CONFIG_VERSION="" (set by --init and migration, never defaulted),
  MIGRATION_AUTO=true (auto-prompt on version mismatch),
  MIGRATION_BACKUP_DIR=.claude/migration-backups.

- `lib/config.sh` — Add TEKHTON_CONFIG_VERSION to config loading (but don't
  require it — absence means "pre-watermark project, needs inference").
  Validate MIGRATION_BACKUP_DIR is a relative path within .claude/.

- `lib/init.sh` (or equivalent --init orchestration) — Write
  TEKHTON_CONFIG_VERSION=${TEKHTON_VERSION%.*} (major.minor only) to
  pipeline.conf during --init. This establishes the watermark for new projects.

- `lib/update_check.sh` (M19) — After `perform_update()` completes,
  print: "Updated Tekhton to X.Y.Z. Run 'tekhton --migrate' in each project
  to apply configuration updates." This is the bridge between updating the
  tool and updating the projects.

- `lib/diagnose_rules.sh` (M17) — Add diagnostic rule `_rule_version_mismatch()`:
  If TEKHTON_CONFIG_VERSION < TEKHTON_VERSION, suggest "tekhton --migrate".
  This catches the case where a user updates Tekhton but forgets to migrate
  their projects, and something breaks as a result.

- `templates/pipeline.conf.example` — Add TEKHTON_CONFIG_VERSION at the top,
  MIGRATION_AUTO, and section header comments for V3 config groups.

Acceptance criteria:
- `detect_config_version()` correctly identifies V1, V2, V3 projects by
  artifact inspection when no explicit watermark exists
- `TEKHTON_CONFIG_VERSION` written to pipeline.conf by --init
- `TEKHTON_CONFIG_VERSION` updated after successful migration
- V1→V2 migration adds V2 config keys and agent role files
- V2→V3 migration adds V3 config keys, new agent roles, milestone DAG,
  Watchtower dashboard, and pipeline.conf section headers
- V1→V3 migration runs both V1→V2 and V2→V3 in sequence
- Migrations are idempotent: running twice produces the same result
- Migrations are non-destructive: no user files deleted or overwritten
- Backup created before any migration runs
- `--migrate --rollback` restores pre-migration state from backup
- `--migrate --check` shows what would run without applying
- `--migrate --status` shows config version vs running version
- Startup auto-detection prompts for migration when version mismatch detected
- In --complete/--auto-advance mode, migration auto-applies with logging
- Migration failure stops the chain (no partial-then-skip behavior)
- Each migration's `check()` correctly detects already-applied state
- Agent role files are only ADDED, never overwritten (existing roles preserved)
- New config keys added with descriptive comments
- `--update` (M19) prints reminder to run --migrate in each project
- `--diagnose` (M17) detects version mismatch as a potential failure cause
- Milestone files without "Migration impact:" section produce a visible warning
  during milestone loading (terminal + Watchtower)
- Plan generation templates (--plan) include Migration impact as a required section
- Milestone split prompt includes Migration impact in sub-milestone template
- PM agent (M10) evaluates Migration impact completeness in its clarity rubric
- migrations/README.md documents the migration authoring interface and conventions
- All existing tests pass
- `bash -n lib/migrate.sh migrations/*.sh` passes
- `shellcheck lib/migrate.sh migrations/*.sh` passes
- New test file `tests/test_migration.sh` covers: version detection from
  artifacts, migration check/apply for V1→V2 and V2→V3, idempotency,
  backup creation, rollback, chain execution order, failure mid-chain

Watch For:
- **pipeline.conf is not a standard format.** It's sourced as bash. Appending
  new keys is safe. Modifying existing keys requires careful sed/awk. Prefer
  append-only for new keys and never modify user-set values.
- **The version inference heuristic** (for pre-watermark projects) must be
  conservative. If unsure whether a project is V1 or V2, treat as V1 (run
  more migrations rather than fewer — idempotency makes this safe).
- **Agent role file merging** (template refresh) is the hardest part. The
  safest approach: if the file has been modified from the V2 template (diff
  against the original), leave it alone and note "custom role file detected,
  skipping update — see templates/ for new version." Only update if the file
  is identical to the old template.
- **Migration backups can grow.** Add a cleanup mechanism: `--migrate --cleanup-backups`
  removes backups older than MIGRATION_BACKUP_RETENTION (default: keep last 3).
- **Concurrent Tekhton instances.** If two projects share the same Tekhton
  installation and one is being migrated while the other runs, the running
  project should not be affected. Migrations only modify the project directory,
  never TEKHTON_HOME. This is already the case by design.
- **The --init path must also set the watermark.** Every new project starts
  with the current version watermark. The migration system only applies to
  projects created by older versions.
- **Config key ordering** in pipeline.conf matters for readability. New keys
  should be appended in logical groups (security, intake, health, etc.) with
  section header comments. Don't scatter them randomly.
- **Testing migrations requires fixture projects.** Create test fixtures for
  V1-era and V2-era project structures. The migration tests must run against
  these fixtures, not the live Tekhton repo.

Seeds Forward:
- Every future major version adds one migration script to migrations/
- V4's parallel execution may need a migration to restructure .claude/runs/
  for multi-worktree support
- The migration backup system is the foundation for a future `tekhton --rollback`
  command that rolls back the last pipeline run's changes (separate from
  migration rollback)
- Enterprise environments can set MIGRATION_AUTO=false and control migration
  timing centrally (e.g., "migrate all projects to V3 this sprint")
- The version detection heuristic enables `tekhton --audit` to scan a directory
  tree for all Tekhton projects and report their version status
